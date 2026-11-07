import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';

/// A temporary HOME with config/cache/state below it and a small system
/// themes folder; nothing real is read or written.
final class TestEnv {
  TestEnv._(this.root, this.paths, this.desktop, this.core);
  final Directory root;
  final Paths paths;
  final FakeDesktop desktop;
  final CoreService core;

  static TestEnv create({DateTime Function()? clock}) {
    final root = Directory.systemTemp.createTempSync('maprisma-theme-test-');
    final share = '${root.path}/share';
    final env = {
      'HOME': '${root.path}/home',
      'XDG_RUNTIME_DIR': '${root.path}/run',
      'PATH': Platform.environment['PATH'] ?? '/usr/bin',
    };
    final paths = Paths.fromEnvironment(env, share: share);
    Directory(paths.systemThemes).createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    final desktop = FakeDesktop();
    final core = CoreService(environment: env, paths: paths, desktop: desktop, clock: clock);
    return TestEnv._(root, paths, desktop, core);
  }

  /// A theme folder with a colors.toml and [wallpapers] (1×1 PNGs).
  String addTheme(String slug, {bool system = false, String bg = '#2e3440', String fg = '#d8dee9',
      String accent = '#81a1c1', List<String> wallpapers = const ['1.png'], String? extraToml}) {
    final dir = '${system ? paths.systemThemes : paths.userThemes}/$slug';
    Directory('$dir/backgrounds').createSync(recursive: true);
    File('$dir/colors.toml').writeAsStringSync(
        'accent = "$accent"\nbackground = "$bg"\nforeground = "$fg"\nred = "#bf616a"\ngreen = "#a3be8c"\n'
        'yellow = "#ebcb8b"\nblue = "#81a1c1"\nmagenta = "#b48ead"\ncyan = "#88c0d0"\n${extraToml ?? ''}');
    for (final w in wallpapers) {
      File('$dir/backgrounds/$w').writeAsBytesSync(tinyPng);
    }
    return dir;
  }

  void dispose() => root.deleteSync(recursive: true);
}

/// A valid 1×1 PNG.
final tinyPng = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
