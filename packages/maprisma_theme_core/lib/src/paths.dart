import 'dart:io';

/// Every place Maprisma Theme reads or writes, from the environment, so
/// tests point it at temporary folders (docs/plan.md, "Where things live").
final class Paths {
  Paths({
    required this.home,
    required this.config,
    required this.cache,
    required this.state,
    required this.runtime,
    required this.systemThemes,
    required this.templates,
    required this.cosmicConfig,
    required this.data,
  });

  /// [environment] is Platform.environment (or a test's); [share] is the
  /// installed share/maprisma-theme folder (bundled themes and templates).
  factory Paths.fromEnvironment(Map<String, String> environment, {String? share}) {
    final home = environment['HOME'] ?? '/nonexistent';
    String xdg(String key, String fallback) {
      final v = environment[key];
      return (v != null && v.startsWith('/')) ? v : '$home/$fallback';
    }

    final configHome = xdg('XDG_CONFIG_HOME', '.config');
    final shareDir = share ?? environment['MAPRISMA_THEME_SHARE'] ?? _findShare();
    final runtimeDir = environment['XDG_RUNTIME_DIR'];
    return Paths(
      home: home,
      config: '$configHome/maprisma-theme',
      cache: '${xdg('XDG_CACHE_HOME', '.cache')}/maprisma-theme',
      state: '${xdg('XDG_STATE_HOME', '.local/state')}/maprisma-theme',
      runtime: (runtimeDir != null && runtimeDir.startsWith('/'))
          ? '$runtimeDir/maprisma-theme'
          : '${xdg('XDG_CACHE_HOME', '.cache')}/maprisma-theme/run',
      systemThemes: '$shareDir/themes',
      templates: '$shareDir/templates',
      cosmicConfig: '$configHome/cosmic',
      data: xdg('XDG_DATA_HOME', '.local/share'),
    );
  }

  final String home, config, cache, state, runtime, systemThemes, templates, cosmicConfig, data;

  String get userThemes => '$config/themes';
  String get backgrounds => '$config/backgrounds';
  String get backups => '$config/backups';
  String file(String name) => '$config/$name';
  String get settingsFile => file('settings.json');
  String get automationFile => file('automation.json');
  String get currentFile => '$state/current.json';
  String get trash => '$data/Trash';
  String get pictures => '$home/Pictures';

  /// share/maprisma-theme next to the running program (bin/../share or the
  /// bundle's data/), else the source tree's checkout (development).
  static String _findShare() {
    final exe = File(Platform.resolvedExecutable).parent.path;
    for (final candidate in [
      '$exe/../share/maprisma-theme',
      '$exe/share/maprisma-theme',
      '$exe/data/maprisma-theme',
    ]) {
      if (Directory('$candidate/themes').existsSync()) return Directory(candidate).absolute.path;
    }
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      if (Directory('${dir.path}/themes').existsSync() && Directory('${dir.path}/templates').existsSync()) {
        return dir.path;
      }
      dir = dir.parent;
    }
    return '/usr/share/maprisma-theme';
  }
}
