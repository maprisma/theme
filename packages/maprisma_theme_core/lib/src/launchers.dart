import 'dart:convert';
import 'dart:io';
import 'bounded.dart';
import 'context.dart';
import 'posix.dart';

/// Only installed desktop entries are launchable; saved command lines are ignored.
class Launcher {
  Launcher(
    this.id,
    this.path,
    this.startupClass, {
    this.name = '',
    this.icon = '',
  });
  final String id, path, startupClass, name, icon;
}

List<Launcher> scanLaunchers(Ctx ctx) {
  final dirs = [
    ctx.paths.data,
    ...(ctx.environment['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share')
        .split(':'),
  ];
  final seen = <String>{};
  final result = <Launcher>[];
  var count = 0;
  for (final dir in dirs.where((d) => d.startsWith('/'))) {
    try {
      for (final f in Directory(
        '$dir/applications',
      ).listSync(followLinks: false)) {
        if (++count > 4000) return result;
        final id = f.uri.pathSegments.last;
        if (!id.endsWith('.desktop') || id.startsWith('.') || !seen.add(id)) {
          continue;
        }
        final bytes = Posix.instance.readRegular(f.path, 256 * 1024);
        if (bytes == null) continue;
        final values = <String, String>{};
        var section = false;
        for (final raw in const LineSplitter().convert(
          utf8.decode(bytes, allowMalformed: true),
        )) {
          final line = raw.trim();
          if (line.startsWith('[')) {
            section = line == '[Desktop Entry]';
            continue;
          }
          final eq = line.indexOf('=');
          if (section && eq > 0) {
            values[line.substring(0, eq)] = line.substring(eq + 1);
          }
        }
        if (values['Hidden'] == 'true' ||
            values['Type'] != 'Application' ||
            values['Exec'] == null) {
          continue;
        }
        if (id.length > 255 || id.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
          continue;
        }
        String bounded(String? value) {
          final clean = (value ?? '').replaceAll(
            RegExp(r'[\x00-\x1f\x7f]'),
            '',
          );
          return clean.substring(0, clean.length.clamp(0, 255));
        }

        result.add(
          Launcher(
            id,
            f.path,
            bounded(values['StartupWMClass']),
            name: bounded(values['Name'] ?? id),
            icon: bounded(values['Icon']),
          ),
        );
      }
    } on FileSystemException {
      continue;
    }
  }
  return result;
}

Launcher? findLauncher(List<Launcher> launchers, String appId) {
  final id = appId.toLowerCase();
  for (final l in launchers) {
    if (l.id.toLowerCase() == id ||
        l.id.substring(0, l.id.length - 8).toLowerCase() == id ||
        l.startupClass.toLowerCase() == id) {
      return l;
    }
  }
  return null;
}

Future<bool> launchApp(Ctx ctx, Launcher launcher) async {
  final gtk = which('gtk-launch', ctx.environment);
  final gio = which('gio', ctx.environment);
  final argv = gtk != null
      ? [gtk, launcher.id]
      : gio != null
      ? [gio, 'launch', launcher.path]
      : <String>[];
  if (argv.isEmpty) return false;
  return await readBoundedText(
        argv,
        maxBytes: 8192,
        timeout: const Duration(seconds: 5),
        environment: ctx.environment,
      ) !=
      null;
}

/// Desktop IDs saved by the chooser also match compositor application IDs.
bool launcherMatchesApp(List<Launcher> launchers, String saved, Object? appId) {
  if (appId is! String) return false;
  if (saved == appId) return true;
  final launcher = findLauncher(launchers, saved);
  return launcher != null && findLauncher([launcher], appId) != null;
}
