import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';

import 'bounded.dart';
import 'colors.dart';
import 'desktop.dart';
import 'gtk_colors.dart';
import 'paths.dart';
import 'posix.dart';
import 'shell_scheme.dart';
import 'shortcuts.dart';
import 'store.dart';

/// Hyprland with Maprisma Shell (a Quickshell config): the colours go to the
/// shell's scheme.json (which the other Maprisma apps read too), to
/// Hyprland's own scheme/current.lua (borders, groups; then `hyprctl reload`),
/// to GTK's colors.css (Breeze's colours for title bars and dialogs, which Plasma
/// writes on KDE and nothing on Hyprland),
/// the terminals open now get the colours as escape sequences, and the
/// wallpaper is the `wallpaper` key of the shell's shell.json. The rest (fonts,
/// icons, windows, shortcuts) is not done here yet: those caps are missing.
final class HyprlandDesktop extends DesktopBase {
  HyprlandDesktop(super.paths, super.environment, {this.ptsDir = '/dev/pts'});

  /// Where the open terminals are (tests: a folder of plain files).
  final String ptsDir;

  @override
  String get id => 'hyprland';
  @override
  String get name => 'Hyprland';
  @override
  String? get terminalName => null;

  String _xdg(String key, String fallback) {
    final v = environment[key];
    return v != null && v.startsWith('/') ? v : '${paths.home}/$fallback';
  }

  String get _configHome => _xdg('XDG_CONFIG_HOME', '.config');

  /// Maprisma Shell's main file: the shell is installed when it exists.
  String get shellQml => '$_configHome/quickshell/maprisma-shell/shell.qml';

  /// The colours Maprisma Shell (and the Maprisma apps) read.
  String get schemeFile => '${_xdg('XDG_STATE_HOME', '.local/state')}/maprisma-shell/scheme.json';

  /// The shell's settings; its `wallpaper` key is the picture shown.
  String get shellConfigFile => '$_configHome/maprisma-shell/shell.json';

  /// Hyprland's colours (`require("scheme.current")` in its Lua config).
  String get hyprSchemeFile => '$_configHome/hypr/scheme/current.lua';

  /// GTK 3's and 4's colours (Breeze's `@define-color …_breeze`, imported by their gtk.css).
  List<String> get gtkColorFiles => ['$_configHome/gtk-3.0/colors.css', '$_configHome/gtk-4.0/colors.css'];

  /// GTK's colours for the Breeze theme; a gtk.css that doesn't import them yet gets the import
  /// (one line at its top), one that does stays as it is. False when a file couldn't be written.
  bool writeGtkColors(Map<String, String> colors, Map<String, String> colours) {
    final css = gtkColorsCss(colors, colours);
    for (final file in gtkColorFiles) {
      final dir = file.substring(0, file.lastIndexOf('/'));
      try {
        writeText(file, css, mode: _modeOf(file));
        final gtkCss = File('$dir/gtk.css');
        final text = gtkCss.existsSync() ? gtkCss.readAsStringSync() : '';
        if (!RegExp(r'''@import\s+(url\()?["']?colors\.css''').hasMatch(text)) {
          writeText(gtkCss.path, "@import 'colors.css';\n$text", mode: _modeOf(gtkCss.path));
        }
      } on FileSystemException {
        return false;
      }
    }
    return true;
  }

  /// Only with Maprisma Shell installed: plain Hyprland (Omarchy, for one) has
  /// nothing to apply to, so there it is as [GenericDesktop] (themes,
  /// wallpaper files and app templates still work).
  @override
  late final Set<Cap> caps = File(shellQml).existsSync() ? const {Cap.appearance, Cap.wallpaper} : const {};

  /// The mode bits of an existing file, else [fallback] (0644).
  static int _modeOf(String path, {int fallback = 420}) {
    final stat = FileStat.statSync(path);
    return stat.type == FileSystemEntityType.notFound ? fallback : stat.mode & 511;
  }

  @override
  Future<bool> applyColors(Map<String, String> colors) async {
    if (!caps.contains(Cap.appearance)) return false;
    final scheme = shellScheme(colors);
    if (scheme == null) return false;
    final colours = scheme.colours;
    try {
      writeText(
        schemeFile,
        '${const JsonEncoder.withIndent('  ').convert({'name': 'maprisma-theme', 'flavour': 'default', 'mode': scheme.mode, 'variant': 'tonalspot', 'colours': colours})}\n',
        mode: _modeOf(schemeFile),
      );
    } on FileSystemException {
      return false;
    }
    // Hyprland's own colours, where its config is.
    if (Directory('$_configHome/hypr').existsSync()) {
      final lua = StringBuffer('return {\n');
      colours.forEach((k, v) => lua.write('  $k = "$v",\n'));
      lua.write('}\n');
      try {
        writeText(hyprSchemeFile, lua.toString(), mode: _modeOf(hyprSchemeFile));
      } on FileSystemException {
        return false;
      }
      final hyprctl = findProgram(paths, environment, 'hyprctl');
      if (hyprctl != null && (environment['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isNotEmpty) {
        await readBoundedText([hyprctl, 'reload'], timeout: const Duration(seconds: 5), okCodes: const {}, environment: environment);
      }
    }
    sendTerminalColours(colors, colours);
    // GTK's title bars and dialogs (new windows; open ones keep theirs until they reopen).
    if (!writeGtkColors(colors, colours)) return false;
    return true;
  }

  /// The OSC sequences for the terminals: text, background, cursor,
  /// selection, the 16 colours and 16..18 as accents (Caelestia's set; the
  /// cursor and selection are the theme's own instead of one colour).
  static String terminalSequences(Map<String, String> colors, Map<String, String> colours) {
    String osc(String hex, List<int> codes) =>
        '\x1b]${codes.join(';')};rgb:${hex.substring(0, 2)}/${hex.substring(2, 4)}/${hex.substring(4, 6)}\x1b\\';
    String own(String key, String fallback) {
      final v = colors[key];
      return isHex(v) ? v!.substring(1).toLowerCase() : colours[fallback]!;
    }

    final b = StringBuffer()
      ..write(osc(colours['onSurface']!, [10]))
      ..write(osc(colours['surface']!, [11]))
      ..write(osc(own('cursor', 'secondary'), [12]))
      ..write(osc(own('selection_background', 'secondary'), [17]));
    for (var i = 0; i < 16; i++) {
      b.write(osc(colours['term$i']!, [4, i]));
    }
    b
      ..write(osc(colours['primary']!, [4, 16]))
      ..write(osc(colours['secondary']!, [4, 17]))
      ..write(osc(colours['tertiary']!, [4, 18]));
    return b.toString();
  }

  /// Recolours the user's open terminals (each /dev/pts/N they own) at once,
  /// never waiting on one that does not read; returns how many took it.
  int sendTerminalColours(Map<String, String> colors, Map<String, String> colours) {
    final bytes = utf8.encode(terminalSequences(colors, colours));
    final uid = Posix.instance.uid;
    var sent = 0;
    try {
      for (final e in Directory(ptsDir).listSync(followLinks: false)) {
        final name = e.path.substring(e.path.lastIndexOf('/') + 1);
        if (!RegExp(r'^\d+$').hasMatch(name) || Posix.instance.ownerOf(e.path, follow: false) != uid) continue;
        if (Posix.instance.writeNonBlocking(e.path, bytes)) sent++;
      }
    } on FileSystemException {
      // no terminals
    }
    return sent;
  }

  /// The shell's scheme as a colours object (what [applyColors] wrote, or a
  /// scheme from elsewhere): secondary stands for the cursor and selection.
  @override
  Future<Map<String, dynamic>?> current() async {
    final data = readJsonMap(schemeFile);
    final c = data['colours'];
    if (c is! Map) return null;
    String? g(String key) {
      final v = c[key];
      if (v is! String) return null;
      final h = '#${v.trim().toLowerCase().replaceFirst('#', '')}';
      return isHex(h) ? h : null;
    }

    final mode = data['mode'] == 'light' ? 'light' : 'dark';
    final colors = <String, String?>{
      'mode': mode,
      'background': g('background'),
      'foreground': g('onSurface'),
      'accent': g('primary'),
      'selection': g('secondary'),
      'muted': g('outline'),
      'cursor': g('secondary'),
      for (var i = 0; i < shellTermKeys.length; i++) shellTermKeys[i]: g('term$i'),
      'orange': g('peach'),
    };
    if (colors['background'] == null) return null;
    return {
      'colors': {
        for (final e in colors.entries)
          if (e.value != null) e.key: e.value,
      },
      'is_dark': mode == 'dark',
      'corner_radius': null,
    };
  }

  /// The `wallpaper` of the shell's shell.json, or null for none.
  @override
  String? wallpaper() {
    final v = readJsonMap(shellConfigFile)['wallpaper'];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

  /// Sets the `wallpaper` key of shell.json to [value]; every other key and,
  /// where it can, the file's own layout stay. False when the file is not a
  /// JSON object (the user is editing it, say): it is then left alone.
  bool _writeShellWallpaper(String value) {
    final path = shellConfigFile;
    final exists = FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
    final text = exists ? readSmall(path) : null;
    if (exists && text == null) return false;
    var map = <String, dynamic>{};
    if (text != null && text.trim().isNotEmpty) {
      try {
        final v = jsonDecode(text);
        if (v is! Map) return false;
        map = Map<String, dynamic>.from(v);
      } on FormatException {
        return false;
      }
    }
    final want = {...map, 'wallpaper': value};
    String? out;
    if (text != null && map['wallpaper'] is String) {
      // Only the value changes, as long as the result is exactly [want].
      for (final m in RegExp(r'("wallpaper"\s*:\s*)"(?:[^"\\]|\\.)*"').allMatches(text)) {
        final candidate = text.replaceRange(m.start, m.end, '${m[1]}${jsonEncode(value)}');
        try {
          if (const DeepCollectionEquality().equals(jsonDecode(candidate), want)) {
            out = candidate;
            break;
          }
        } on FormatException {
          continue;
        }
      }
    }
    out ??= '${const JsonEncoder.withIndent('  ').convert(want)}\n';
    try {
      writeText(path, out, mode: _modeOf(path));
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<bool> setWallpaper(String path) async {
    if (!caps.contains(Cap.wallpaper) || !path.startsWith('/') || !FileSystemEntity.isFileSync(path)) return false;
    final String real;
    try {
      real = File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return false;
    }
    return _writeShellWallpaper(real);
  }

  /// {path}: the wallpaper shown now, or null when the shell shows none
  /// (restoring that clears the preview's again).
  @override
  Future<Object?> snapshotBackground() async => {'path': wallpaper()};

  @override
  Future<bool> restoreBackground(Object? snapshot) async {
    if (snapshot is! Map || !snapshot.containsKey('path')) return false;
    final path = snapshot['path'];
    if (path == null) return caps.contains(Cap.wallpaper) && _writeShellWallpaper('');
    return path is String && path.isNotEmpty && await setWallpaper(path);
  }

  @override
  Future<bool> applyRon(String path) async => false;
  @override
  Future<bool> applyKdeScheme(String path, {String? foreground}) async => false;
  @override
  Future<bool> setTerminal(Map<String, String> colors, String name) async => false;
  @override
  String? monospaceFont() => null;
  @override
  Future<bool> setMonospaceFont(String family) async => false;
  @override
  Future<bool> resetMonospaceFont() async => false;
  @override
  String? interfaceFont() => null;
  @override
  Future<bool> setInterfaceFont(String family) async => false;
  @override
  Future<bool> resetInterfaceFont() async => false;
  @override
  String? iconTheme() => null;
  @override
  Future<bool> setIconTheme(String name) async => false;
  @override
  Future<Map<String, dynamic>?> wm(List<String> args, {Duration timeout = const Duration(seconds: 20)}) async => wmNotAvailable(name);
  @override
  ShortcutBinder? shortcutBinder(Paths paths) => null;
  @override
  Stream<Map<String, dynamic>>? watch() => null;

  @override
  Future<Map<String, dynamic>> health(Paths paths, Map<String, String> environment) async => {
    'helper': {'ok': File(shellQml).existsSync(), 'path': shellQml, 'name': 'Maprisma Shell'},
  };
}
