import 'dart:convert';
import 'dart:io';

import 'bounded.dart';
import 'desktop.dart';
import 'paths.dart';
import 'shortcuts.dart';
import 'store.dart';

/// Hyprland with the Caelestia shell: colours and wallpaper go through
/// Caelestia (hyprland/maprisma-caelestia-bridge, which uses caelestia-cli's
/// own modules), so its shell, Hyprland's borders, the terminals and every
/// other app Caelestia themes follow at once. The rest (fonts, icons,
/// windows, shortcuts) is not done here yet: those caps are missing.
final class HyprlandDesktop extends DesktopBase {
  HyprlandDesktop(super.paths, super.environment);

  @override
  String get id => 'hyprland';
  @override
  String get name => 'Hyprland';
  @override
  String? get terminalName => null;
  @override
  Set<Cap> get caps => const {Cap.appearance, Cap.wallpaper};

  /// The bridge: MAPRISMA_THEME_CAELESTIA_BRIDGE, next to the running
  /// program (bin/ of the installed bundle), else PATH.
  String? get bridge {
    const name = 'maprisma-caelestia-bridge';
    final override = environment['MAPRISMA_THEME_CAELESTIA_BRIDGE'];
    if (override != null && override.startsWith('/')) return override;
    final dir = File(Platform.resolvedExecutable).parent.path;
    for (final c in ['$dir/$name', '$dir/bin/$name']) {
      if (File(c).existsSync()) return File(c).absolute.path;
    }
    return findProgram(paths, environment, name);
  }

  /// The bridge's JSON for [args], or null (no bridge, no answer, no JSON).
  Future<Map<String, dynamic>?> bridgeJson(List<String> args, {Duration timeout = const Duration(seconds: 60)}) async {
    final b = bridge;
    final python = findProgram(paths, environment, 'python3');
    if (b == null || python == null) return null;
    final out = await readBoundedText(
      [python, '-I', b, ...args],
      maxBytes: 1024 * 1024,
      timeout: timeout,
      okCodes: const {},
      environment: environment,
    );
    if (out == null) return null;
    try {
      final v = jsonDecode(out.trim());
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } on FormatException {
      return null;
    }
  }

  Future<bool> _ok(List<String> args) async {
    final r = await bridgeJson(args);
    return r != null && r['error'] == null;
  }

  @override
  Future<bool> applyColors(Map<String, String> colors) async {
    final file = tempJson(colors);
    try {
      return await _ok(['apply', file]);
    } finally {
      DesktopBase.deleteQuietly(file);
    }
  }

  @override
  Future<Map<String, dynamic>?> current() async {
    final r = await bridgeJson(['current']);
    return r == null || r['error'] != null ? null : r;
  }

  /// Caelestia's wallpaper/path.txt (its shell shows what that file names).
  @override
  String? wallpaper() {
    final state = environment['XDG_STATE_HOME']?.isNotEmpty == true ? environment['XDG_STATE_HOME']! : '${paths.home}/.local/state';
    final text = readSmall('$state/caelestia/wallpaper/path.txt', limit: 64 * 1024)?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  @override
  Future<bool> setWallpaper(String path) async {
    if (!path.startsWith('/') || !File(path).existsSync()) return false;
    return _ok(['wallpaper', path]);
  }

  /// {path}: the wallpaper shown now, or null when Caelestia has none of its
  /// own (restoring that clears the preview's state again).
  @override
  Future<Object?> snapshotBackground() async => {'path': wallpaper()};

  @override
  Future<bool> restoreBackground(Object? snapshot) async {
    if (snapshot is! Map || !snapshot.containsKey('path')) return false;
    final path = snapshot['path'];
    if (path == null) return _ok(['wallpaper-clear']);
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
  Future<Map<String, dynamic>> health(Paths paths, Map<String, String> environment) async {
    final b = bridge;
    final r = b == null ? null : await bridgeJson(['wallpaper-get'], timeout: const Duration(seconds: 10));
    return {
      'helper': {'ok': r != null && r['error'] == null, 'path': b},
    };
  }
}
