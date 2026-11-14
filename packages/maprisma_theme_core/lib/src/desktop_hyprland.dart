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
import 'window_style_flag.dart';

/// Hyprland with Maprisma Shell (a Quickshell config): the colours go to the
/// shell's scheme.json (which the other Maprisma apps read too), to
/// Hyprland's own scheme/current.lua (borders, groups; then `hyprctl reload`),
/// to GTK's colors.css (Breeze's colours for title bars and dialogs, which Plasma
/// writes on KDE and nothing on Hyprland),
/// the terminals open now get the colours as escape sequences, and the
/// wallpaper is the `wallpaper` key of the shell's shell.json. Fonts go to GTK's settings
/// (gsettings, which the Maprisma apps read too, and GTK's settings.ini) and foot's foot.ini,
/// blur to hypr-theme.lua (loaded last from hypr-user.lua). The rest (icons, windows,
/// shortcuts) is not done here yet: those caps are missing.
final class HyprlandDesktop extends DesktopBase {
  HyprlandDesktop(super.paths, super.environment, {this.ptsDir = '/dev/pts', DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  int? _rounding;
  DateTime? _roundingAt;

  /// Hyprland's window rounding (`hyprctl -j getoption decoration:rounding`, its `int`, 0–64),
  /// asked at most every 30 s (the window re-reads its look every few seconds); null outside a
  /// Hyprland session, without hyprctl or without a readable answer.
  @override
  Future<int?> windowRounding() async {
    if ((environment['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isEmpty) return null;
    final now = _clock();
    final at = _roundingAt;
    if (at != null && now.difference(at).abs() < const Duration(seconds: 30)) return _rounding;
    _roundingAt = now;
    final hyprctl = findProgram(paths, environment, 'hyprctl');
    final out = hyprctl == null
        ? null
        : await readBoundedText([hyprctl, '-j', 'getoption', 'decoration:rounding'],
            timeout: const Duration(seconds: 2), environment: environment);
    return _rounding = hyprRounding(out);
  }

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
  late final Set<Cap> caps = !File(shellQml).existsSync()
      ? const {}
      : {
          Cap.appearance,
          Cap.wallpaper,
          if (findProgram(paths, environment, 'gsettings') != null) ...{Cap.fonts, Cap.uiFont},
          if (Directory('$_configHome/hypr').existsSync() && findProgram(paths, environment, 'hyprctl') != null) Cap.blur,
        };

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
      'corner_radius': await windowRounding(),
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
  String? iconTheme() => null;
  @override
  Future<bool> setIconTheme(String name) async => false;
  @override
  Future<Map<String, dynamic>?> wm(List<String> args, {Duration timeout = const Duration(seconds: 20)}) async => wmNotAvailable(name);
  @override
  ShortcutBinder? shortcutBinder(Paths paths) => null;
  @override
  Stream<Map<String, dynamic>>? watch() => null;

  // --- fonts: GTK's gsettings and settings.ini, foot's foot.ini -------------------------------

  String? _gsettings(String key) {
    final g = findProgram(paths, environment, 'gsettings');
    if (g == null) return null;
    try {
      final r = Process.runSync(g, ['get', 'org.gnome.desktop.interface', key], environment: environment);
      if (r.exitCode != 0) return null;
      final out = '${r.stdout}'.trim();
      return out.length >= 2 && out.startsWith("'") && out.endsWith("'") ? out.substring(1, out.length - 1) : null;
    } on ProcessException {
      return null;
    }
  }

  Future<bool> _gsettingsSet(String key, String? value) async {
    final g = findProgram(paths, environment, 'gsettings');
    if (g == null) return false;
    final (code, _) = await runBounded(
        [g, if (value == null) ...['reset', 'org.gnome.desktop.interface', key] else ...['set', 'org.gnome.desktop.interface', key, value]],
        timeout: const Duration(seconds: 5), environment: environment);
    return code == 0;
  }

  List<String> get _gtkSettings => ['$_configHome/gtk-3.0/settings.ini', '$_configHome/gtk-4.0/settings.ini'];
  String get footIni => '$_configHome/foot/foot.ini';

  /// The `gtk-font-name=` value of a GTK settings.ini, or null.
  static String? _iniFont(String? text) =>
      text == null ? null : RegExp(r'^\s*gtk-font-name\s*=\s*(.*?)\s*$', multiLine: true).firstMatch(text)?.group(1);

  /// foot.ini's `font=` line of its main section (before the first [section]), or null.
  static String? _footFont(String? text) {
    if (text == null) return null;
    for (final line in const LineSplitter().convert(text)) {
      if (line.trimLeft().startsWith('[')) break;
      final m = RegExp(r'^\s*font\s*=\s*(.*?)\s*$').firstMatch(line);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// [text] with its `key=` line set to [value] ([main]-section only for foot: before the first
  /// section, inserted there when missing); null [value] takes the line out.
  static String _setIniLine(String text, String key, String? value, {bool mainOnly = false}) {
    final lines = const LineSplitter().convert(text);
    var at = -1, sectionAt = lines.length;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trimLeft().startsWith('[')) {
        if (mainOnly) {
          sectionAt = i;
          break;
        }
        continue;
      }
      if (RegExp('^\\s*${RegExp.escape(key)}\\s*=').hasMatch(lines[i])) {
        at = i;
        break;
      }
    }
    if (value == null) {
      if (at >= 0) lines.removeAt(at);
    } else if (at >= 0) {
      lines[at] = '$key=$value';
    } else if (!mainOnly) {
      final s = lines.indexWhere((l) => l.trim() == '[Settings]');
      lines.insert(s < 0 ? lines.length : s + 1, '$key=$value');
    } else {
      lines.insert(sectionAt, '$key=$value');
    }
    return '${lines.join('\n')}\n';
  }

  /// A Pango font ("Noto Sans 10", "Hack, 10") split into its family and the rest.
  static (String, String) pangoSplit(String font) {
    final m = RegExp(r'^(.*?)(,?\s+\d+(?:\.\d+)?)$').firstMatch(font.trim());
    return m == null ? (font.trim(), ' 11') : (m.group(1)!.trim(), m.group(2)!);
  }

  /// foot's `Family:size=12`, perhaps with fallbacks after a comma, with the first family replaced.
  static String footWithFamily(String? value, String family) {
    if (value == null || value.trim().isEmpty) return '$family:size=11';
    final cut = value.indexOf(RegExp('[:,]'));
    return cut < 0 ? family : '$family${value.substring(cut)}';
  }

  /// The values a theme's font changed, as they were before ({where: value or null}); written
  /// before the first change, so going back touches exactly those and puts back what they were.
  String _receipt(FontRoleKey role) => '${paths.state}/hyprland-${role.name}-font.json';

  Map<String, String?>? _readReceipt(FontRoleKey role) {
    final m = readJsonMap(_receipt(role));
    if (m.isEmpty || m.values.any((v) => v != null && v is! String)) return null;
    return {for (final e in m.entries) e.key: e.value as String?};
  }

  void _dropReceipt(FontRoleKey role) {
    try {
      File(_receipt(role)).deleteSync();
    } on FileSystemException {
      // already gone
    }
  }

  String? _read(String path) => FileSystemEntity.isFileSync(path) ? readSmall(path) : null;

  /// Everything one font role touches now: `{gsettings: value, file: its line value}`.
  Map<String, String?> _fontValues(FontRoleKey role) {
    final files = role == FontRoleKey.ui ? _gtkSettings : [footIni];
    return {
      'gsettings': _gsettings(role.gsettingsKey),
      for (final f in files)
        if (_read(f) case final String t) f: role == FontRoleKey.ui ? _iniFont(t) : _footFont(t),
    };
  }

  /// Writes [values] (as from [_fontValues]); on a failure what was written goes back.
  Future<bool> _writeFontValues(FontRoleKey role, Map<String, String?> values) async {
    final before = _fontValues(role);
    Future<bool> write(Map<String, String?> v) async {
      if (v.containsKey('gsettings') && !await _gsettingsSet(role.gsettingsKey, v['gsettings'])) return false;
      for (final e in v.entries) {
        if (e.key == 'gsettings') continue;
        final text = _read(e.key);
        if (text == null) continue;
        try {
          writeText(e.key, role == FontRoleKey.ui ? _setIniLine(text, 'gtk-font-name', e.value) : _setIniLine(text, 'font', e.value, mainOnly: true),
              mode: _modeOf(e.key));
        } on FileSystemException {
          return false;
        }
      }
      return true;
    }

    if (await write(values)) return true;
    await write(before);
    return false;
  }

  Future<bool> _setFont(FontRoleKey role, String family) async {
    final choices = role == FontRoleKey.ui ? await interfaceFonts() : await monospaceFonts();
    if (!choices.contains(family)) return false;
    final receipt = _readReceipt(role);
    if (receipt != null && receipt['gsettings'] != null && pangoSplit(receipt['gsettings']!).$1 == family) return _restoreFont(role, receipt);
    final now = _fontValues(role);
    final values = {
      for (final e in now.entries)
        e.key: e.key == 'gsettings' || role == FontRoleKey.ui
            ? (e.value == null ? '$family 11' : '$family${pangoSplit(e.value!).$2}')
            : footWithFamily(e.value, family),
    };
    final fresh = receipt == null;
    if (fresh) writeJson(_receipt(role), now);
    if (!await _writeFontValues(role, values)) {
      if (fresh) _dropReceipt(role);
      return false;
    }
    return true;
  }

  Future<bool> _restoreFont(FontRoleKey role, Map<String, String?> receipt) async {
    if (!await _writeFontValues(role, receipt)) return false;
    _dropReceipt(role);
    return true;
  }

  /// Back to the default: what a theme changed goes back as it was; without a theme's change
  /// only gsettings goes back to GTK's default.
  Future<bool> _resetFont(FontRoleKey role) async {
    final receipt = _readReceipt(role);
    if (receipt != null) return _restoreFont(role, receipt);
    return _gsettingsSet(role.gsettingsKey, null);
  }

  String? _family(FontRoleKey role) {
    final v = _gsettings(role.gsettingsKey);
    return v == null ? null : pangoSplit(v).$1;
  }

  @override
  String? monospaceFont() => caps.contains(Cap.fonts) ? _family(FontRoleKey.mono) : null;
  @override
  Future<bool> setMonospaceFont(String family) async => caps.contains(Cap.fonts) && await _setFont(FontRoleKey.mono, family);
  @override
  Future<bool> resetMonospaceFont() async => caps.contains(Cap.fonts) && await _resetFont(FontRoleKey.mono);
  @override
  String? interfaceFont() => caps.contains(Cap.uiFont) ? _family(FontRoleKey.ui) : null;
  @override
  Future<bool> setInterfaceFont(String family) async => caps.contains(Cap.uiFont) && await _setFont(FontRoleKey.ui, family);
  @override
  Future<bool> resetInterfaceFont() async => caps.contains(Cap.uiFont) && await _resetFont(FontRoleKey.ui);

  // --- blur: Hyprland's decoration:blur, set in hypr-theme.lua -----------------------------

  String get hyprThemeLua => '$_configHome/hypr/hypr-theme.lua';
  String get hyprUserLua => '$_configHome/hypr/hypr-user.lua';
  static const requireLine = 'pcall(require, "hypr-theme") -- Maprisma Theme: blur (Font & effects; keep last)';

  Future<Map<String, dynamic>?> _option(String name) async {
    final hyprctl = findProgram(paths, environment, 'hyprctl');
    if (hyprctl == null || (environment['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isEmpty) return null;
    final out = await readBoundedText([hyprctl, '-j', 'getoption', name], timeout: const Duration(seconds: 2), environment: environment);
    if (out == null) return null;
    try {
      final v = jsonDecode(out);
      return v is Map<String, dynamic> ? v : null;
    } on FormatException {
      return null;
    }
  }

  /// What hypr-theme.lua sets ({enabled, size}), or null when it sets nothing.
  Map<String, dynamic>? _themeBlurFile() {
    final text = _read(hyprThemeLua);
    if (text == null) return null;
    final m = RegExp(r'enabled = (true|false), size = (\d+)').firstMatch(text);
    return m == null ? null : {'enabled': m.group(1) == 'true', 'size': int.parse(m.group(2)!)};
  }

  /// {enabled, size}: Hyprland's blur now; `file`: what hypr-theme.lua sets (null: nothing,
  /// the user's own config decides). Null outside a Hyprland session.
  @override
  Future<Map<String, dynamic>?> blurState() async {
    if (!caps.contains(Cap.blur)) return null;
    final enabled = await _option('decoration:blur:enabled');
    final size = await _option('decoration:blur:size');
    final on = enabled?['bool'] ?? (enabled?['int'] is int ? enabled!['int'] != 0 : null);
    if (on is! bool || size?['int'] is! int) return null;
    return {'enabled': on, 'size': size!['int'], 'file': _themeBlurFile()};
  }

  @override
  Map<String, dynamic> blurTarget(Map<String, dynamic> now, {required bool on, required int strength}) {
    final size = strength.clamp(1, 15);
    return {'enabled': on, 'size': size, 'file': {'enabled': on, 'size': size}};
  }

  @override
  Map<String, dynamic> blurAsLook(Map<String, dynamic> state) => {
    'on': state['enabled'] != false,
    'strength': ((state['size'] is int ? state['size'] as int : 8)).clamp(1, 15),
  };

  bool _writeBlurFile(Map? file) {
    try {
      if (file == null) {
        if (File(hyprThemeLua).existsSync()) File(hyprThemeLua).deleteSync();
        return true;
      }
      writeText(
        hyprThemeLua,
        '-- Written by Maprisma Theme (Font & effects). Changes made here by hand are replaced on the\n'
        '-- next change there; delete this file to give the blur back to your own config.\n'
        'hl.config({ decoration = { blur = { enabled = ${file['enabled'] == true}, size = ${file['size']} } } })\n',
        mode: _modeOf(hyprThemeLua),
      );
      final user = File(hyprUserLua);
      final text = user.existsSync() ? user.readAsStringSync() : '-- Personal Hyprland settings, loaded last (from hyprland.lua)\n';
      if (!text.contains('require, "hypr-theme")')) {
        writeText(hyprUserLua, '${text.endsWith('\n') ? text : '$text\n'}\n$requireLine\n', mode: _modeOf(hyprUserLua));
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// hypr-theme.lua as [state] has it (its `file`), then Hyprland reloads; when Hyprland doesn't
  /// show the values afterwards the file goes back as it was and the result is false.
  @override
  Future<bool> restoreBlur(Map<String, dynamic> state) async {
    if (!caps.contains(Cap.blur)) return false;
    final file = state['file'];
    if (file != null && (file is! Map || file['enabled'] is! bool || file['size'] is! int)) return false;
    final before = _themeBlurFile();
    Future<bool> write(Map? f) async {
      if (!_writeBlurFile(f)) return false;
      final hyprctl = findProgram(paths, environment, 'hyprctl');
      if (hyprctl != null && (environment['HYPRLAND_INSTANCE_SIGNATURE'] ?? '').isNotEmpty) {
        await readBoundedText([hyprctl, 'reload'], timeout: const Duration(seconds: 5), okCodes: const {}, environment: environment);
      }
      if (f == null) return true;
      final now = await blurState();
      return now == null || (now['enabled'] == f['enabled'] && now['size'] == f['size']);
    }

    if (!await write(file as Map?)) {
      await write(before);
      return false;
    }
    // Settings › App windows › Follow the desktop: Glassy while the blur is on.
    final after = await blurState();
    writeThemeBlurFlag(blurAsLook(after ?? state)['on'] == true, environment);
    return true;
  }

  @override
  Future<Map<String, dynamic>> health(Paths paths, Map<String, String> environment) async => {
    'helper': {'ok': File(shellQml).existsSync(), 'path': shellQml, 'name': 'Maprisma Shell'},
  };
}

/// The two fonts and their GTK key.
enum FontRoleKey {
  mono('monospace-font-name'),
  ui('font-name');

  const FontRoleKey(this.gsettingsKey);
  final String gsettingsKey;
}

/// `hyprctl -j getoption decoration:rounding`'s `int` (0–64), or null.
int? hyprRounding(String? json) {
  if (json == null) return null;
  try {
    final v = jsonDecode(json);
    final n = v is Map ? v['int'] : null;
    return n is int && n >= 0 ? (n > 64 ? 64 : n) : null;
  } on FormatException {
    return null;
  }
}
