// "theme_blur" in ~/.config/maprisma/windows.json, the file all Maprisma apps read for
// Settings › App windows (flutter_app/lib/window_style.dart): Follow the desktop is Glassy on
// KDE and COSMIC while Maprisma Theme has the desktop's blur on.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const _maxBytes = 4096;

/// ~/.config/maprisma/windows.json for [environment]; null without an absolute HOME or
/// XDG_CONFIG_HOME.
String? windowsFileFor(Map<String, String> environment) {
  final xdg = environment['XDG_CONFIG_HOME'] ?? '';
  final home = environment['HOME'] ?? '';
  final config = xdg.startsWith('/') ? xdg : (home.startsWith('/') ? '$home/.config' : null);
  return config == null ? null : '$config/maprisma/windows.json';
}

/// Sets "theme_blur" to [on], keeping the other keys: read bounded (4 KiB, else as empty),
/// replaced atomically, never through a symlink. Any failure is ignored: the blur change it
/// follows must never fail because of it.
void writeThemeBlurFlag(bool on, Map<String, String> environment) {
  try {
    final path = windowsFileFor(environment);
    if (path == null) return;
    final dir = File(path).parent;
    if (FileSystemEntity.typeSync(dir.path, followLinks: false) == FileSystemEntityType.notFound) {
      dir.createSync(recursive: true);
    }
    if (FileSystemEntity.typeSync(dir.path, followLinks: false) != FileSystemEntityType.directory) return;
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.file && type != FileSystemEntityType.notFound) return;
    var settings = <String, dynamic>{};
    if (type == FileSystemEntityType.file) {
      final file = File(path).openSync();
      try {
        final bytes = file.readSync(_maxBytes + 1);
        if (bytes.length <= _maxBytes) {
          final value = jsonDecode(utf8.decode(bytes, allowMalformed: true));
          if (value is Map<String, dynamic>) settings = value;
        }
      } on FormatException {
        // not JSON: written anew
      } finally {
        file.closeSync();
      }
    }
    if (settings['theme_blur'] == on) return;
    settings['theme_blur'] = on;
    final tmp = File('$path.$pid.${Random().nextInt(1 << 32)}.tmp');
    tmp.createSync(exclusive: true);
    try {
      tmp.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(settings)}\n', flush: true);
      tmp.renameSync(path);
    } on Object {
      try {
        tmp.deleteSync();
      } on Object {
        // gone already
      }
      rethrow;
    }
  } on Object {
    // ignored: the blur itself changed
  }
}
