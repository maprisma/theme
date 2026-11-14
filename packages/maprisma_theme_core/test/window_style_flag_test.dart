import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/src/window_style_flag.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Map<String, String> env;
  late String file;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('window-style-flag-');
    env = {'HOME': '${tmp.path}/home', 'XDG_CONFIG_HOME': '${tmp.path}/config'};
    file = '${tmp.path}/config/maprisma/windows.json';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, dynamic> read() => jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
  List<String> leftovers() => [
        for (final e in Directory('${tmp.path}/config/maprisma').listSync())
          if (e.path.endsWith('.tmp')) e.path,
      ];

  test('XDG_CONFIG_HOME when absolute, else HOME/.config, else nothing', () {
    expect(windowsFileFor(env), file);
    expect(windowsFileFor({'HOME': '/h', 'XDG_CONFIG_HOME': 'relative'}), '/h/.config/maprisma/windows.json');
    expect(windowsFileFor(const {}), isNull);
    expect(windowsFileFor({'HOME': 'relative'}), isNull);
    writeThemeBlurFlag(true, const {}); // no HOME: nothing, no error
  });

  test('creates the file and keeps the other keys', () {
    writeThemeBlurFlag(true, env);
    expect(read(), {'theme_blur': true});
    File(file).writeAsStringSync('{"style": "follow", "theme_blur": true}');
    writeThemeBlurFlag(false, env);
    expect(read(), {'style': 'follow', 'theme_blur': false});
    expect(leftovers(), isEmpty);
  });

  test('oversized or broken JSON is started anew', () {
    Directory(File(file).parent.path).createSync(recursive: true);
    File(file).writeAsStringSync('{"style": "${'x' * 5000}"}');
    writeThemeBlurFlag(true, env);
    expect(read(), {'theme_blur': true});
    File(file).writeAsStringSync('not json');
    writeThemeBlurFlag(false, env);
    expect(read(), {'theme_blur': false});
  });

  test('a symlink or a folder in its place is left alone, without an error', () {
    Directory(File(file).parent.path).createSync(recursive: true);
    final target = File('${tmp.path}/elsewhere.json')..writeAsStringSync('{"style": "solid"}');
    Link(file).createSync(target.path);
    writeThemeBlurFlag(true, env);
    expect(target.readAsStringSync(), '{"style": "solid"}');
    expect(FileSystemEntity.isLinkSync(file), isTrue);
    Link(file).deleteSync();
    Directory(file).createSync();
    writeThemeBlurFlag(true, env);
    expect(FileSystemEntity.isDirectorySync(file), isTrue);
    expect(leftovers(), isEmpty);
  });

  test('a maprisma folder that is a symlink is not followed', () {
    Directory('${tmp.path}/config').createSync();
    final other = Directory('${tmp.path}/other')..createSync();
    Link('${tmp.path}/config/maprisma').createSync(other.path);
    writeThemeBlurFlag(true, env);
    expect(other.listSync(), isEmpty);
  });
}
