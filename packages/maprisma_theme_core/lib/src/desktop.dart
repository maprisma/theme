import 'dart:convert';
import 'dart:io';

import 'bounded.dart';
import 'images.dart';
import 'paths.dart';
import 'posix.dart';
import 'store.dart';

/// What Maprisma Theme asks of the desktop. [CosmicDesktop] is the real one
/// (COSMIC config files + maprisma-theme-helper, docs/cosmic-interface.md);
/// tests use [FakeDesktop].
abstract interface class Desktop {
  /// Applies Omarchy-style [colors] (docs/cosmic-interface.md) as the COSMIC theme.
  Future<bool> applyColors(Map<String, String> colors);

  /// Applies a COSMIC ThemeBuilder RON file.
  Future<bool> applyRon(String path);

  /// The colors a COSMIC ThemeBuilder RON file stands for, or null.
  Future<Map<String, String>?> ronColors(String path);

  /// {colors, is_dark, corner_radius} of the COSMIC theme in use.
  Future<Map<String, dynamic>?> current();

  /// The desktop background (every output), or false.
  Future<bool> setWallpaper(String path);

  /// The background shown now (cosmic-bg's config), or null.
  String? wallpaper();

  /// Everything a background change touches, to put back after a preview.
  Object? snapshotBackground();
  Future<bool> restoreBackground(Object? snapshot);

  /// The COSMIC Terminal color scheme [name] from [colors].
  Future<bool> setTerminal(Map<String, String> colors, String name);

  String? monospaceFont();
  Future<bool> setMonospaceFont(String family);

  /// Back to COSMIC's default monospace font (its config entry removed).
  Future<bool> resetMonospaceFont();
  Future<List<String>> monospaceFonts();

  String? iconTheme();
  bool setIconTheme(String name);
  List<String> iconThemes();

  /// The helper's JSON for `workspaces` / `windows`, or null.
  Future<Map<String, dynamic>?> helperJson(List<String> args, {Duration timeout});
}

String ronString(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// [text] with the value of the first top-level-ish `key:` replaced by
/// [value]: the old value ends at the `,` or closing bracket at its own
/// depth (strings and nested brackets skipped), so `Color(Single((..)))`
/// and gradients are replaced whole. Null when the value has no clean end.
String? replaceRonValue(String text, String key, String value) {
  final m = RegExp('(^|[\\s(,])$key\\s*:\\s*').firstMatch(text);
  if (m == null) return null;
  final start = m.end;
  var depth = 0, i = start;
  var inString = false;
  for (; i < text.length; i++) {
    final c = text[i];
    if (inString) {
      if (c == r'\') {
        i++;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) break;
      depth--;
    } else if (c == ',' && depth == 0) {
      break;
    }
  }
  if (i >= text.length || inString || depth != 0) return null;
  return '${text.substring(0, start)}$value${text.substring(i)}';
}

/// The first `key: "value"` / `key: Path("value")` string in a RON text.
String? ronField(String text, String key) {
  final m = RegExp('$key\\s*:\\s*(?:Path\\()?"((?:[^"\\\\]|\\\\.)*)"').firstMatch(text);
  return m?[1]?.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
}

final class CosmicDesktop implements Desktop {
  CosmicDesktop(this.paths, this.environment);
  final Paths paths;
  final Map<String, String> environment;

  String get _cosmic => paths.cosmicConfig;
  String get _bgDir => '$_cosmic/com.system76.CosmicBackground/v1';
  String get _tkDir => '$_cosmic/com.system76.CosmicTk/v1';

  /// maprisma-theme-helper next to the running program, then PATH.
  String? get helper {
    final override = environment['MAPRISMA_THEME_HELPER'];
    if (override != null && override.startsWith('/')) return override;
    final dir = File(Platform.resolvedExecutable).parent.path;
    for (final c in ['$dir/maprisma-theme-helper', '$dir/bin/maprisma-theme-helper']) {
      if (File(c).existsSync()) return File(c).absolute.path;
    }
    return which('maprisma-theme-helper', environment);
  }

  @override
  Future<Map<String, dynamic>?> helperJson(List<String> args, {Duration timeout = const Duration(seconds: 20)}) async {
    final h = helper;
    if (h == null) return null;
    final out = await readBoundedText([h, ...args], maxBytes: 4 * 1024 * 1024, timeout: timeout, okCodes: const {});
    if (out == null) return null;
    try {
      final v = jsonDecode(out.trim());
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } on FormatException {
      return null;
    }
  }

  Future<bool> _helperOk(List<String> args) async {
    final r = await helperJson(args, timeout: const Duration(seconds: 30));
    return r != null && r['error'] == null;
  }

  String _tempJson(Object value) {
    final dir = Directory(paths.runtime);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    chmodPath(dir.path, 448);
    final path = '${dir.path}/colors-$pid-${DateTime.now().microsecondsSinceEpoch}.json';
    writeJson(path, value);
    return path;
  }

  @override
  Future<bool> applyColors(Map<String, String> colors) async {
    final file = _tempJson(colors);
    try {
      return await _helperOk(['apply', '--colors', file]);
    } finally {
      _delete(file);
    }
  }

  @override
  Future<bool> applyRon(String path) => _helperOk(['apply', '--ron', path]);

  @override
  Future<Map<String, String>?> ronColors(String path) async {
    final r = await helperJson(['ron-colors', path]);
    if (r == null || r['error'] != null) return null;
    return {for (final e in r.entries) if (e.value is String) e.key: e.value as String};
  }

  @override
  Future<Map<String, dynamic>?> current() async {
    final r = await helperJson(['current']);
    return r == null || r['error'] != null ? null : r;
  }

  @override
  Future<bool> setTerminal(Map<String, String> colors, String name) async {
    final file = _tempJson(colors);
    try {
      return await _helperOk(['terminal', '--colors', file, '--name', name]);
    } finally {
      _delete(file);
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
      text = '(\n    output: "all",\n    $source\n    filter_by_theme: false,\n    rotation_frequency: 300,\n'
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
  Object? snapshotBackground() {
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
  Future<List<String>> monospaceFonts() async {
    final out = await readBoundedText(['fc-list', ':spacing=mono', 'family'], maxBytes: 1024 * 1024, timeout: const Duration(seconds: 5));
    if (out == null) return [];
    final set = <String>{};
    for (final line in const LineSplitter().convert(out)) {
      final first = line.split(',').first.trim();
      if (first.isNotEmpty && first.length < 100) set.add(first);
    }
    return set.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  @override
  String? iconTheme() {
    final t = readSmall('$_tkDir/icon_theme', limit: 1024)?.trim();
    if (t == null) return null;
    return t.startsWith('"') && t.endsWith('"') ? t.substring(1, t.length - 1) : t;
  }

  @override
  bool setIconTheme(String name) {
    if (!iconThemes().contains(name)) return false;
    writeText('$_tkDir/icon_theme', ronString(name), mode: 420);
    return true;
  }

  @override
  List<String> iconThemes() {
    final names = <String>{};
    for (final base in ['${paths.home}/.icons', '${paths.data}/icons', '/usr/local/share/icons', '/usr/share/icons']) {
      try {
        for (final e in Directory(base).listSync()) {
          if (File('${e.path}/index.theme').existsSync()) names.add(e.path.substring(e.path.lastIndexOf('/') + 1));
        }
      } on FileSystemException {
        continue;
      }
    }
    return names.toList()..sort();
  }

  void _delete(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // gone
    }
  }
}

/// A desktop that only records what it was asked (tests, --dry runs).
final class FakeDesktop implements Desktop {
  final calls = <String>[];
  String? _wallpaper, _font, _icons = 'Cosmic';
  var fonts = <String>['JetBrains Mono', 'Fira Code'];
  var icons = <String>['Cosmic', 'Adwaita', 'Yaru-blue'];
  Map<String, String>? lastColors;
  Map<String, dynamic> workspaces = {
    'workspaces': [
      {'index': 1, 'name': '1', 'active': true, 'tiling': true, 'output': 'DP-1'},
    ],
    'can_tile': true,
  };
  Map<String, dynamic> windows = {'windows': []};

  @override
  Future<bool> applyColors(Map<String, String> colors) async {
    calls.add('applyColors');
    lastColors = colors;
    return true;
  }

  @override
  Future<bool> applyRon(String path) async {
    calls.add('applyRon $path');
    return true;
  }

  @override
  Future<Map<String, String>?> ronColors(String path) async => {
    'mode': 'dark', 'background': '#1e1e2e', 'foreground': '#cdd6f4', 'accent': '#b4befe',
  };

  @override
  Future<Map<String, dynamic>?> current() async => {
    'colors': lastColors ?? {'background': '#1b1b1b', 'foreground': '#e0e0e0', 'accent': '#63d0df'},
    'is_dark': true,
    'corner_radius': 8,
  };

  @override
  Future<bool> setWallpaper(String path) async {
    calls.add('wallpaper $path');
    _wallpaper = path;
    return true;
  }

  @override
  String? wallpaper() => _wallpaper;

  @override
  Object? snapshotBackground() => _wallpaper ?? '';

  @override
  Future<bool> restoreBackground(Object? snapshot) async {
    if (snapshot is! String) return false;
    calls.add('restore background');
    _wallpaper = snapshot.isEmpty ? null : snapshot;
    return true;
  }

  @override
  Future<bool> setTerminal(Map<String, String> colors, String name) async {
    calls.add('terminal $name');
    return true;
  }

  @override
  String? monospaceFont() => _font;

  @override
  Future<bool> setMonospaceFont(String family) async {
    if (!fonts.contains(family)) return false;
    calls.add('font $family');
    _font = family;
    return true;
  }

  @override
  Future<List<String>> monospaceFonts() async => fonts;

  @override
  Future<bool> resetMonospaceFont() async {
    calls.add('font reset');
    _font = null;
    return true;
  }

  @override
  String? iconTheme() => _icons;

  @override
  bool setIconTheme(String name) {
    if (!icons.contains(name)) return false;
    calls.add('icons $name');
    _icons = name;
    return true;
  }

  @override
  List<String> iconThemes() => icons;

  @override
  Future<Map<String, dynamic>?> helperJson(List<String> args, {Duration timeout = const Duration(seconds: 20)}) async {
    calls.add('helper ${args.join(' ')}');
    return switch (args.first) {
      'workspaces' => workspaces,
      'windows' => windows,
      _ => {'done': true},
    };
  }
}
