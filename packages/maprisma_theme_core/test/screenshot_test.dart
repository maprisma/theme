import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// F12 screenshots (Maprisma Playground's screenshot_test.dart): new names only, notes next to the
/// picture, no file for an empty note, never through a link, private files and folder.
void main() {
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('theme-shot-'));
  tearDown(() => folder.deleteSync(recursive: true));

  int mode(String path) => FileStat.statSync(path).mode & 0x1ff;

  test('free name never reuses a picture or a note', () {
    final where = folder.path;
    final handle = PrivateFolder.open(where);
    addTearDown(handle.close);
    String free(String stamp) => p.join(where, freeScreenshotName(handle, stamp));
    final first = free('2026-11-10-12-00-00');
    expect(p.basename(first), 'maprisma-theme-2026-11-10-12-00-00.png');
    File(first).writeAsBytesSync([1]);
    final second = free('2026-11-10-12-00-00');
    expect(p.basename(second), 'maprisma-theme-2026-11-10-12-00-00-2.png');
    File(p.join(where, 'maprisma-theme-2026-11-10-12-00-00-2.txt')).writeAsStringSync('note');
    expect(p.basename(free('2026-11-10-12-00-00')), 'maprisma-theme-2026-11-10-12-00-00-3.png');
    // A link that points nowhere takes its name too.
    Link(p.join(where, 'maprisma-theme-2026-11-10-12-00-00-3.png')).createSync(p.join(where, 'gone'));
    expect(p.basename(free('2026-11-10-12-00-00')), 'maprisma-theme-2026-11-10-12-00-00-4.png');
  });

  test('the stamp is the local date and time', () {
    expect(screenshotStamp(DateTime(2026, 1, 2, 3, 4, 5)), '2026-01-02-03-04-05');
  });

  test('the note goes next to the picture, none when empty, never over a file', () {
    final picture = p.join(folder.path, 'maprisma-theme-1.png');
    expect(saveScreenshotNote(picture, '   '), isNull);
    expect(File(p.setExtension(picture, '.txt')).existsSync(), isFalse);
    final note = saveScreenshotNote(picture, ' The gear is cut off ')!;
    expect(File(note).readAsStringSync(), 'The gear is cut off\n');
    expect(mode(note), 0x180);
    expect(() => saveScreenshotNote(picture, 'again'), throwsA(isA<FileSystemException>()));
    expect(File(note).readAsStringSync(), 'The gear is cut off\n');
  });

  test('a note is cut at its limit', () {
    final picture = p.join(folder.path, 'long.png');
    final note = saveScreenshotNote(picture, 'x' * (screenshotNoteLimit + 50))!;
    expect(File(note).readAsStringSync().length, screenshotNoteLimit + 1);
  });

  test('writing never goes through a link', () {
    final target = File(p.join(folder.path, 'elsewhere'))..writeAsStringSync('keep');
    final link = p.join(folder.path, 'maprisma-theme-2.png');
    Link(link).createSync(target.path);
    expect(Posix.instance.writeNewPrivate(link, [1, 2, 3]), isFalse);
    final handle = PrivateFolder.open(folder.path);
    addTearDown(handle.close);
    expect(() => handle.writeNew(p.basename(link), [1, 2, 3]), throwsA(isA<FileSystemException>()));
    expect(target.readAsStringSync(), 'keep');
  });

  test('a screenshot is a new private file in a private folder', () {
    final where = p.join(folder.path, 'Pictures', 'MaprismaTheme');
    final at = DateTime(2026, 11, 10, 12, 0, 0);
    final first = saveScreenshot(where, [0x89, 0x50, 0x4e, 0x47], at: at);
    expect(p.basename(first), 'maprisma-theme-2026-11-10-12-00-00.png');
    expect(mode(where), 0x1c0);
    expect(mode(first), 0x180);
    expect(File(first).readAsBytesSync(), [0x89, 0x50, 0x4e, 0x47]);
    final second = saveScreenshot(where, [1], at: at);
    expect(p.basename(second), 'maprisma-theme-2026-11-10-12-00-00-2.png');
    expect(File(first).readAsBytesSync(), [0x89, 0x50, 0x4e, 0x47]);
  });

  test('the folder: XDG_PICTURES_DIR from user-dirs.dirs, else ~/Pictures', () {
    final home = folder.path;
    expect(screenshotFolder({'HOME': home}), p.join(home, 'Pictures', 'MaprismaTheme'));
    Directory(p.join(home, '.config')).createSync();
    File(p.join(home, '.config', 'user-dirs.dirs')).writeAsStringSync('XDG_PICTURES_DIR="\$HOME/Bilder"\n');
    expect(screenshotFolder({'HOME': home}), p.join(home, 'Bilder', 'MaprismaTheme'));
    File(p.join(home, '.config', 'user-dirs.dirs')).writeAsStringSync('XDG_PICTURES_DIR="\$HOME/"\n');
    expect(screenshotFolder({'HOME': home}), p.join(home, 'Pictures', 'MaprismaTheme'));
  });

  test('the dialog names the file with ~ for the home folder', () {
    expect(homeShort('/home/u/Pictures/a.png', {'HOME': '/home/u'}), '~/Pictures/a.png');
    expect(homeShort('/home/other/a.png', {'HOME': '/home/u'}), '/home/other/a.png');
  });

  test('the setting is on by default and Corners stays compatible', () async {
    final env = TestEnv.create();
    addTearDown(env.dispose);
    final first = await env.core.call('settings.get', {});
    expect(first['settings']['screenshot_key'], isTrue);
    for (final value in ['slight', 'windows', 'rounded', 'square']) {
      final out = await env.core.call('settings.set', {'key': 'corners', 'value': value});
      expect(out['settings']['corners'], value);
    }
    await expectLater(env.core.call('settings.set', {'key': 'corners', 'value': 'pill'}), throwsA(anything));
  });

  test('the folder is refused when a link or a file stands in its place', () {
    final elsewhere = Directory(p.join(folder.path, 'elsewhere'))..createSync();
    final link = p.join(folder.path, 'linked');
    Link(link).createSync(elsewhere.path);
    expect(() => makePrivateFolder(link), throwsA(isA<FileSystemException>()));
    expect(() => saveScreenshot(link, [1]), throwsA(isA<FileSystemException>()));
    expect(elsewhere.listSync(), isEmpty);
    final file = File(p.join(folder.path, 'a file'))..writeAsStringSync('x');
    expect(() => makePrivateFolder(file.path), throwsA(isA<FileSystemException>()));
    makePrivateFolder(p.join(folder.path, 'real'));
    makePrivateFolder(p.join(folder.path, 'real')); // an existing folder is fine
  });

  test('a folder that cannot be made reports mkdir\'s own reason', () {
    final locked = Directory(p.join(folder.path, 'locked'))..createSync();
    Process.runSync('/bin/chmod', ['500', locked.path]);
    addTearDown(() => Process.runSync('/bin/chmod', ['700', locked.path]));
    try {
      makePrivateFolder(p.join(locked.path, 'MaprismaTheme'));
      fail('made a folder in a read-only one');
    } on FileSystemException catch (e) {
      expect(e.osError?.errorCode, 13); // EACCES, not the ENOENT of a later stat
    }
  });

  test('only a real folder of yours that others cannot write to is used', () {
    final open = Directory(p.join(folder.path, 'shared'))..createSync();
    Process.runSync('/bin/chmod', ['777', open.path]);
    expect(() => saveScreenshot(open.path, [1]), throwsA(isA<FileSystemException>()));
    Process.runSync('/bin/chmod', ['775', open.path]);
    expect(() => saveScreenshot(open.path, [1]), throwsA(isA<FileSystemException>()));
    expect(open.listSync(), isEmpty);
    Process.runSync('/bin/chmod', ['755', open.path]); // readable by others, writable only by you: fine
    expect(File(saveScreenshot(open.path, [1])).existsSync(), isTrue);
    // The note checks the folder again.
    final picture = saveScreenshot(open.path, [2]);
    Process.runSync('/bin/chmod', ['757', open.path]);
    expect(() => saveScreenshotNote(picture, 'note'), throwsA(isA<FileSystemException>()));
    expect(File(p.setExtension(picture, '.txt')).existsSync(), isFalse);
    Process.runSync('/bin/chmod', ['700', open.path]);
  });

  test('a write that fails leaves no file behind', () {
    final where = p.join(folder.path, 'MaprismaTheme');
    debugFailWriteAfter = 3;
    addTearDown(() => debugFailWriteAfter = null);
    expect(() => saveScreenshot(where, List.filled(10, 7)), throwsA(isA<FileSystemException>()));
    expect(Directory(where).listSync(), isEmpty);
    debugFailWriteAfter = null;
    final picture = saveScreenshot(where, List.filled(10, 7));
    expect(File(picture).lengthSync(), 10);
    debugFailWriteAfter = 2;
    expect(() => saveScreenshotNote(picture, 'a longer note'), throwsA(isA<FileSystemException>()));
    expect(Directory(where).listSync().map((e) => p.basename(e.path)), [p.basename(picture)]);
  });

  test('a folder handle takes plain names only', () {
    final handle = PrivateFolder.open(folder.path);
    addTearDown(handle.close);
    expect(() => handle.writeNew('../escape.png', [1]), throwsArgumentError);
    expect(() => handle.taken('a/b'), throwsArgumentError);
  });
}
