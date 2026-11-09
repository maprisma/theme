import 'dart:io';

import 'desktop.dart';
import 'images.dart';
import 'paths.dart';
import 'shortcuts.dart';
import 'shortcuts_cosmic.dart';
import 'store.dart';
import 'themes.dart';

/// The applet's id in COSMIC's panels.
const appletId = 'io.github.ubruckhaus.CosmicMaprismaTheme';

/// COSMIC: its config files + maprisma-theme-helper (docs/cosmic-interface.md).
final class CosmicDesktop extends DesktopBase {
  CosmicDesktop(super.paths, super.environment);

  @override
  String get id => 'cosmic';
  @override
  String get name => 'COSMIC';
  @override
  String get terminalName => 'COSMIC Terminal';
  @override
  Set<Cap> get caps => Cap.values.toSet().difference({Cap.kdeScheme, Cap.animations});

  @override
  Future<bool> applyKdeScheme(String path) async => false;

  String get _cosmic => paths.cosmicConfig;
  String get _bgDir => '$_cosmic/com.system76.CosmicBackground/v1';
  String get _tkDir => '$_cosmic/com.system76.CosmicTk/v1';

  @override
  Future<Map<String, dynamic>?> wm(List<String> args, {Duration timeout = const Duration(seconds: 20)}) =>
      helperJson(args, timeout: timeout);

  @override
  ShortcutBinder shortcutBinder(Paths paths) => CosmicShortcutBinder(paths);

  /// The applet watches on COSMIC.
  @override
  Stream<Map<String, dynamic>>? watch() => null;

  Future<bool> _helperOk(List<String> args) async {
    final r = await helperJson(args, timeout: const Duration(seconds: 30));
    return r != null && r['error'] == null;
  }

  @override
  Future<bool> applyColors(Map<String, String> colors) async {
    final file = tempJson(colors);
    try {
      return await _helperOk(['apply', '--colors', file]);
    } finally {
      DesktopBase.deleteQuietly(file);
    }
  }

  @override
  Future<bool> applyRon(String path) => _helperOk(['apply', '--ron', path]);

  @override
  Future<Map<String, dynamic>?> current() async {
    final r = await helperJson(['current']);
    return r == null || r['error'] != null ? null : r;
  }

  @override
  Future<bool> setTerminal(Map<String, String> colors, String name) async {
    final file = tempJson(colors);
    try {
      return await _helperOk(['terminal', '--colors', file, '--name', name]);
    } finally {
      DesktopBase.deleteQuietly(file);
    }
  }

  // --- wallpaper: cosmic-bg follows its config files -------------------------

  @override
  String? wallpaper() {
    final text = readSmall('$_bgDir/all', limit: 64 * 1024);
    return text == null ? null : ronField(text, 'source');
  }

  @override
  Future<bool> setWallpaper(String path) async {
    if (!path.startsWith('/') || !File(path).existsSync()) return false;
    // Every way a background reaches COSMIC (apply, presets, automation) is checked here.
    if (imageSizeProblem(path) != null) return false;
    final old = readSmall('$_bgDir/all', limit: 64 * 1024);
    String text;
    final source = 'source: Path(${ronString(path)}),';
    if (old != null && RegExp(r'source\s*:').hasMatch(old)) {
      final replaced = replaceRonValue(old, 'source', 'Path(${ronString(path)})');
      if (replaced == null) return false;
      text = replaced;
    } else {
      text =
          '(\n    output: "all",\n    $source\n    filter_by_theme: false,\n    rotation_frequency: 300,\n'
          '    filter_method: Lanczos,\n    scaling_mode: Zoom,\n    sampling_method: Alphanumeric,\n)';
    }
    try {
      writeText('$_bgDir/all', text, mode: 420);
      if (readSmall('$_bgDir/same-on-all')?.trim() != 'true') writeText('$_bgDir/same-on-all', 'true', mode: 420);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// The raw text of every file in cosmic-bg's config folder (null: missing).
  @override
  Future<Object?> snapshotBackground() async {
    final out = <String, String?>{};
    try {
      for (final e in Directory(_bgDir).listSync(followLinks: false)) {
        if (e is File) out[e.path.substring(e.path.lastIndexOf('/') + 1)] = readSmall(e.path, limit: 256 * 1024);
      }
    } on FileSystemException {
      // no config yet
    }
    for (final n in ['all', 'same-on-all']) {
      out.putIfAbsent(n, () => null);
    }
    return out;
  }

  @override
  Future<bool> restoreBackground(Object? snapshot) async {
    if (snapshot is! Map<String, String?>) return false;
    try {
      for (final e in snapshot.entries) {
        if (e.key.contains('/') || e.key.startsWith('.')) continue;
        final path = '$_bgDir/${e.key}';
        if (e.value == null) {
          if (File(path).existsSync()) File(path).deleteSync();
        } else {
          writeText(path, e.value!, mode: 420);
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  // --- fonts and icons: CosmicTk ---------------------------------------------

  @override
  String? monospaceFont() {
    final t = readSmall('$_tkDir/monospace_font', limit: 8192);
    return t == null ? null : ronField(t, 'family');
  }

  @override
  Future<bool> setMonospaceFont(String family) async {
    if (!(await monospaceFonts()).contains(family)) return false;
    final old = readSmall('$_tkDir/monospace_font', limit: 8192);
    final text = old != null && RegExp(r'family\s*:').hasMatch(old)
        ? old.replaceFirst(RegExp(r'family\s*:\s*"(?:[^"\\]|\\.)*"'), 'family: ${ronString(family)}')
        : '(\n    family: ${ronString(family)},\n    weight: Normal,\n    stretch: Normal,\n    style: Normal,\n)';
    writeText('$_tkDir/monospace_font', text, mode: 420);
    return true;
  }

  @override
  Future<bool> resetMonospaceFont() async {
    final f = File('$_tkDir/monospace_font');
    try {
      if (f.existsSync()) f.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  String? iconTheme() {
    final t = readSmall('$_tkDir/icon_theme', limit: 1024)?.trim();
    if (t == null) return null;
    return t.startsWith('"') && t.endsWith('"') ? t.substring(1, t.length - 1) : t;
  }

  @override
  Future<bool> setIconTheme(String name) async {
    if (!iconThemes().contains(name)) return false;
    writeText('$_tkDir/icon_theme', ronString(name), mode: 420);
    return true;
  }

  /// Is the helper there and answering, is the applet installed and in a panel?
  @override
  Future<Map<String, dynamic>> health(Paths paths, Map<String, String> environment) async {
    final helperPath = helper;
    final helperOk = helperPath != null && await current() != null;
    return {
      'helper': {'ok': helperOk, 'path': helperPath},
      'applet': cosmicAppletHealth(paths, environment),
    };
  }
}

/// {ok, path, in_panel} of the COSMIC panel applet.
Map<String, dynamic> cosmicAppletHealth(Paths paths, Map<String, String> environment) {
  final applet = findProgram(paths, environment, 'maprisma-theme-applet');
  final desktopFile = [
    '${paths.data}/applications/$appletId.desktop',
    '/usr/local/share/applications/$appletId.desktop',
    '/usr/share/applications/$appletId.desktop',
  ].where((p) => File(p).existsSync()).firstOrNull;
  var inPanel = false;
  try {
    for (final panel in Directory(paths.cosmicConfig).listSync()) {
      if (!baseName(panel.path).startsWith('com.system76.CosmicPanel')) continue;
      for (final f in ['plugins_center', 'plugins_wings']) {
        if ((readSmall('${panel.path}/v1/$f', limit: 64 * 1024) ?? '').contains('"$appletId"')) inPanel = true;
      }
    }
  } on FileSystemException {
    // no COSMIC config
  }
  return {'ok': applet != null || desktopFile != null, 'path': applet, 'in_panel': inPanel};
}
