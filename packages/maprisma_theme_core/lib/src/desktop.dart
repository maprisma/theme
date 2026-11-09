import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bounded.dart';
import 'desktop_cosmic.dart';
import 'shortcuts_cosmic.dart';
import 'paths.dart';
import 'posix.dart';
import 'shortcuts.dart';
import 'store.dart';

/// What a desktop backend can do (docs/multi-desktop.md). The UI hides what
/// the active backend lacks; routes refuse it with `not_available`.
enum Cap {
  /// applyColors / current: the desktop's own theme follows the colors.
  appearance,

  /// applyRon: COSMIC ThemeBuilder files applied natively.
  ron,

  /// applyKdeScheme: Plasma color scheme files applied natively.
  kdeScheme,
  wallpaper,

  /// setTerminal: the desktop's own terminal gets a color scheme.
  terminal,
  fonts,
  icons,

  /// wm `workspaces` (and `watch` events).
  workspaces,

  /// wm `set-tiling` per workspace.
  tiling,

  /// wm `windows`, `move`, `close`, `activate`.
  windows,

  /// shortcutBinder is not null.
  shortcuts,

  /// A native panel applet of Maprisma Theme exists for this desktop.
  panel,

  /// wm `animations` / `set-animations`: workspace switch and window open
  /// animations can be turned off (KDE: KWin effects).
  animations,
}

/// What Maprisma Theme asks of the desktop: one backend per desktop
/// ([CosmicDesktop] in desktop_cosmic.dart, GenericDesktop in desktops.dart),
/// chosen by `selectDesktop`; tests use [FakeDesktop]. A call the backend
/// cannot do returns false/null (see [caps]).
abstract interface class Desktop {
  /// `cosmic`, `generic`, `fake`, … (stable, for settings and the protocol).
  String get id;

  /// For texts: "COSMIC".
  String get name;

  /// The desktop's own terminal, for texts ("COSMIC Terminal"), or null.
  String? get terminalName;
  Set<Cap> get caps;
  /// The window manager handles overflow without daemon moves.
  bool get enforcesWindowLimits;
  /// Mirrors published limits into the backend; callers need not await it.
  Future<void> publishTilingAutomation(Map<String, dynamic> tiling);

  /// Applies Omarchy-style [colors] (docs/cosmic-interface.md) as the desktop's theme.
  Future<bool> applyColors(Map<String, String> colors);

  /// Applies a COSMIC ThemeBuilder RON file (only with [Cap.ron]).
  Future<bool> applyRon(String path);

  /// Applies a Plasma color scheme file as it is (only with [Cap.kdeScheme]).
  Future<bool> applyKdeScheme(String path);

  /// The colors a COSMIC ThemeBuilder RON file stands for, or null (any
  /// backend: the helper only parses the file).
  Future<Map<String, String>?> ronColors(String path);

  /// {colors, is_dark, corner_radius} of the desktop theme in use.
  Future<Map<String, dynamic>?> current();

  /// The desktop background (every output), or false.
  Future<bool> setWallpaper(String path);

  /// The background shown now, or null.
  String? wallpaper();

  /// Everything a background change touches, to put back after a preview.
  Future<Object?> snapshotBackground();
  Future<bool> restoreBackground(Object? snapshot);

  /// The desktop terminal's color scheme [name] from [colors].
  Future<bool> setTerminal(Map<String, String> colors, String name);

  String? monospaceFont();
  Future<bool> setMonospaceFont(String family);

  /// Back to the desktop's default monospace font.
  Future<bool> resetMonospaceFont();
  Future<List<String>> monospaceFonts();

  String? iconTheme();
  Future<bool> setIconTheme(String name);
  List<String> iconThemes();

  /// The window-manager contract (docs/cosmic-interface.md: `workspaces`,
  /// `windows`, `move`, `close`, `activate`, `set-tiling`): the same JSON on
  /// every desktop; `{"error": "not_available"}` without the cap; null when
  /// the backend did not answer.
  Future<Map<String, dynamic>?> wm(List<String> args, {Duration timeout});

  /// The wm contract's `watch` events as a stream for the daemon, or null
  /// (COSMIC: its applet watches; desktops without workspaces).
  Stream<Map<String, dynamic>>? watch();

  /// Where the theme keys are written ([Cap.shortcuts]), or null.
  ShortcutBinder? shortcutBinder(Paths paths);

  /// The backend's part of the health check: `helper` and `applet` entries
  /// ({ok, path, …}); keys a backend has nothing for are left out.
  Future<Map<String, dynamic>> health(Paths paths, Map<String, String> environment);
}

/// A program in ~/.local/bin, else on PATH, or null.
String? findProgram(Paths paths, Map<String, String> environment, String name) {
  final local = '${paths.home}/.local/bin/$name';
  return Posix.instance.executable(local) && FileSystemEntity.isFileSync(local) ? local : which(name, environment);
}

/// What the UI needs to know about a backend.
Map<String, dynamic> desktopInfo(Desktop d) => {
  'id': d.id,
  'name': d.name,
  'terminal': d.terminalName,
  'caps': [
    for (final c in Cap.values)
      if (d.caps.contains(c)) c.name,
  ],
};

/// `{"error": "not_available"}` for a wm call the backend cannot do.
Map<String, dynamic> wmNotAvailable(String name) => {'error': 'not_available', 'message': 'not available on $name'};

/// What every real backend shares: maprisma-theme-helper (for parsing RON
/// files on any desktop), fc-list fonts, the icon theme folders.
abstract base class DesktopBase implements Desktop {
  DesktopBase(this.paths, this.environment);
  @override
  bool get enforcesWindowLimits => false;

  @override
  Future<void> publishTilingAutomation(Map<String, dynamic> tiling) async {}

  final Paths paths;
  final Map<String, String> environment;

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

  /// The helper's JSON for [args], or null.
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

  @override
  Future<Map<String, String>?> ronColors(String path) async {
    final r = await helperJson(['ron-colors', path]);
    if (r == null || r['error'] != null) return null;
    return {
      for (final e in r.entries)
        if (e.value is String) e.key: e.value as String,
    };
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

  /// A private temporary JSON file for the helper (caller deletes it).
  String tempJson(Object value) {
    final dir = Directory(paths.runtime);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    chmodPath(dir.path, 448);
    final path = '${dir.path}/colors-$pid-${DateTime.now().microsecondsSinceEpoch}.json';
    writeJson(path, value);
    return path;
  }

  static void deleteQuietly(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // gone
    }
  }
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

/// A desktop that only records what it was asked (tests, --dry runs). It
/// stands for COSMIC unless told otherwise (its shortcuts and applet checks
/// are COSMIC's, on the test's config folder).
final class FakeDesktop implements Desktop {
  FakeDesktop({this.id = 'cosmic', this.name = 'COSMIC', this.terminalName = 'COSMIC Terminal', Set<Cap>? caps, this.hasLook = true})
    : caps = caps ?? Cap.values.toSet();

  /// False: current() is null, as on a desktop without a backend.
  final bool hasLook;

  @override
  bool enforcesWindowLimits = false;

  @override
  Future<void> publishTilingAutomation(Map<String, dynamic> tiling) async {
    lastTilingAutomation = tiling;
  }

  Map<String, dynamic>? lastTilingAutomation;

  @override
  final String id;
  @override
  final String name;
  @override
  final String? terminalName;
  @override
  final Set<Cap> caps;

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
  Future<bool> applyKdeScheme(String path) async {
    calls.add('applyKdeScheme $path');
    return true;
  }

  @override
  Future<Map<String, String>?> ronColors(String path) async => {
    'mode': 'dark',
    'background': '#1e1e2e',
    'foreground': '#cdd6f4',
    'accent': '#b4befe',
  };

  @override
  Future<Map<String, dynamic>?> current() async => !hasLook
      ? null
      : {
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
  Future<Object?> snapshotBackground() async => _wallpaper ?? '';

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
  Future<bool> setIconTheme(String name) async {
    if (!icons.contains(name)) return false;
    calls.add('icons $name');
    _icons = name;
    return true;
  }

  @override
  List<String> iconThemes() => icons;

  @override
  ShortcutBinder? shortcutBinder(Paths paths) => caps.contains(Cap.shortcuts) ? CosmicShortcutBinder(paths) : null;

  /// Events a test sends to the daemon.
  final events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>>? watch() => events.stream;

  @override
  Future<Map<String, dynamic>> health(Paths paths, Map<String, String> environment) async => caps.isEmpty
      ? const {}
      : {
    'helper': {'ok': true, 'path': null},
    'applet': cosmicAppletHealth(paths, environment),
  };

  @override
  Future<Map<String, dynamic>?> wm(List<String> args, {Duration timeout = const Duration(seconds: 20)}) async {
    calls.add('helper ${args.join(' ')}');
    return switch (args.first) {
      'workspaces' => workspaces,
      'windows' => windows,
      _ => {'done': true},
    };
  }
}
