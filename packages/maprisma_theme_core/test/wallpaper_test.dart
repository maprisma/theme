import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/images.dart';
import 'package:maprisma_theme_core/src/trash.dart';
import 'package:maprisma_theme_core/src/wallhaven.dart';
import 'package:maprisma_theme_core/src/wallpapers.dart';
import 'package:test/test.dart';

import 'support.dart';

List<int> _chunk(String type, List<int> data) => [
  ...[(data.length >> 24) & 255, (data.length >> 16) & 255, (data.length >> 8) & 255, data.length & 255],
  ...ascii.encode(type),
  ...data,
  0, 0, 0, 0, // CRC (not checked)
];

/// A PNG with [width]×[height] in its IHDR and the given extra chunks before IDAT.
Uint8List png({int width = 1, int height = 1, List<List<int>> extra = const []}) {
  int b(int v, int s) => (v >> s) & 255;
  final ihdr = [b(width, 24), b(width, 16), b(width, 8), b(width, 0), b(height, 24), b(height, 16), b(height, 8), b(height, 0), 8, 6, 0, 0, 0];
  return Uint8List.fromList([
    ...pngSignature,
    ..._chunk('IHDR', ihdr),
    for (final e in extra) ...e,
    ..._chunk('IDAT', [0x78, 0x9C, 0x63, 0, 1, 0, 0, 5, 0, 1]),
    ..._chunk('IEND', []),
  ]);
}

/// A minimal JPEG header with a SOF0 of [width]×[height].
Uint8List jpeg(int width, int height) => Uint8List.fromList([
  0xff, 0xd8, 0xff, 0xe0, 0, 16, ...ascii.encode('JFIF'), 0, 1, 1, 0, 0, 1, 0, 1, 0, 0,
  0xff, 0xc0, 0, 11, 8, height >> 8, height & 255, width >> 8, width & 255, 1, 1, 0x11, 0,
  0xff, 0xd9,
]);

/// support.dart's tinyPng with its IDAT length fixed (it says 13 for 10
/// bytes, which the strict chunk walk calls a damaged PNG).
final validPng = Uint8List.fromList(tinyPng)..[36] = 0x0A;

/// [TestEnv.addTheme] with valid PNG wallpapers.
String addTheme(TestEnv env, String slug, {bool system = false, List<String> wallpapers = const ['1.png']}) {
  final dir = env.addTheme(slug, system: system, wallpapers: wallpapers);
  for (final w in wallpapers) {
    File('$dir/backgrounds/$w').writeAsBytesSync(validPng);
  }
  return dir;
}

Future<Map<String, dynamic>> list(TestEnv env, String slug) => env.core.call('wallpapers.list', {'slug': slug});

List<String> names(Map<String, dynamic> listing, {bool? hidden}) => [
  for (final w in listing['wallpapers'] as List)
    if (hidden == null || w['hidden'] == hidden) w['name'] as String,
];

void main() {
  group('images', () {
    test('header sizes and limits', () {
      expect(imageBytesProblem(validPng), isNull);
      expect(imageBytesProblem(png(width: 20000, height: 10)), contains('too large'));
      expect(imageBytesProblem(png(width: 10000, height: 10000)), contains('too large'));
      expect(imageBytesProblem(jpeg(1920, 1080)), isNull);
      expect(imageBytesProblem(jpeg(17000, 100)), contains('17000×100'));
      expect(imageBytesProblem(Uint8List.fromList(ascii.encode('<svg></svg>'))), unsupportedImage);
      expect(imageExtension(jpeg(1, 1)), '.jpg');
      expect(imageExtension(tinyPng), '.png');
      expect(imageExtension(ascii.encode('GIF89a......')), '.gif');
    });

    test('PNG metadata limits and stripping', () {
      final many = png(extra: [for (var i = 0; i < 40; i++) _chunk('tEXt', ascii.encode('k\x00v'))]);
      expect(pngMetadataProblem(many), 'PNG has too many text chunks');
      final big = png(extra: [_chunk('zTXt', List.filled(40 * 1024, 1))]);
      expect(pngMetadataProblem(big), 'PNG has too much compressed metadata');
      final stripped = stripPngMetadata(many);
      expect(pngMetadataProblem(stripped), isNull);
      expect(stripped.length, lessThan(many.length));
      expect(String.fromCharCodes(stripped).contains('tEXt'), isFalse);
    });

    test('HEIF: no meta box is refused before any decoder', () {
      expect(heifSizeProblem(Uint8List.fromList([0, 0, 0, 16, ...ascii.encode('ftypheic'), 0, 0, 0, 0])),
          'not a readable HEIC/HEIF photo');
    });

    test('file lists: file URIs and absolute paths that exist, at most 10', () {
      final dir = Directory.systemTemp.createTempSync('wp-list-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final a = File('${dir.path}/a b.png')..writeAsBytesSync(validPng);
      final text = 'copy\nfile://${Uri.encodeFull(a.path)}\nhttps://example.com/x.png\n/nonexistent.png\n${a.path}\n';
      expect(parseFileList(text), [a.path, a.path]);
      expect(parseFileList(List.filled(20, a.path).join('\n')).length, 10);
    });

    test('sanitized names', () {
      expect(sanitizeName('../x/..'), 'image');
      expect(sanitizeName('a:b*c.png'), 'a_b_c.png');
      expect(sanitizeName('.hidden.png'), 'hidden.png');
    });
  });

  group('wallpapers', () {
    late TestEnv env;
    setUp(() => env = TestEnv.create());
    tearDown(() => env.dispose());

    test('add bytes: PNG metadata stripped, unique names, type from the bytes', () async {
      addTheme(env, 'nord', system: true);
      final withText = png(extra: [_chunk('tEXt', ascii.encode('Comment\x00hello'))]);
      final r = await env.core.call('wallpapers.add_bytes', {'slug': 'nord', 'data': base64Encode(withText), 'type': 'image/png'});
      expect(r['added'], ['dropped-image.png']);
      final stored = File(r['path'] as String).readAsBytesSync();
      expect(String.fromCharCodes(stored).contains('hello'), isFalse);
      final r2 = await env.core.call('wallpapers.add_bytes', {
        'slug': 'nord', 'data': base64Encode(jpeg(2, 2)), 'type': 'application/octet-stream;name="cat.png"',
      });
      expect(r2['added'], ['cat.jpg']);
      final r3 = await env.core.call('wallpapers.add_bytes', {'slug': 'nord', 'data': base64Encode(withText)});
      expect(r3['added'], ['dropped-image-2.png']);
      expect(names(await list(env, 'nord')), containsAll(['1.png', 'dropped-image.png', 'cat.jpg']));
      expect(
        () => env.core.call('wallpapers.add_bytes', {'slug': 'nord', 'data': base64Encode(png(width: 30000))}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_image')),
      );
      expect(
        () => env.core.call('wallpapers.add_bytes', {'slug': 'nord', 'data': base64Encode(utf8.encode('hello world, no image'))}),
        throwsA(isA<RouteError>()),
      );
    });

    test('add bytes from a private drop file in the runtime folder only', () async {
      addTheme(env, 'nord');
      Directory(env.paths.runtime).createSync(recursive: true);
      final drop = File('${env.paths.runtime}/drop-1')..writeAsBytesSync(validPng);
      final r = await env.core.call('wallpapers.add_bytes', {'slug': 'nord', 'file': drop.path, 'type': 'image/png'});
      expect(r['added'], ['dropped-image.png']);
      expect(drop.existsSync(), isFalse);
      final outside = File('${env.root.path}/drop-2')..writeAsBytesSync(validPng);
      expect(() => env.core.call('wallpapers.add_bytes', {'slug': 'nord', 'file': outside.path}), throwsA(isA<RouteError>()));
    });

    test('add files: size cap, non-images and metadata', () async {
      addTheme(env, 'nord');
      final src = Directory('${env.root.path}/pics')..createSync();
      File('${src.path}/ok.png').writeAsBytesSync(validPng);
      File('${src.path}/notes.txt').writeAsStringSync('x');
      final huge = File('${src.path}/huge.jpg')..writeAsBytesSync(jpeg(10, 10));
      final raf = huge.openSync(mode: FileMode.append)..truncateSync(51 * 1024 * 1024);
      raf.closeSync();
      File('${src.path}/meta.png').writeAsBytesSync(png(extra: [for (var i = 0; i < 40; i++) _chunk('tEXt', ascii.encode('k\x00v'))]));
      File('${src.path}/giant.png').writeAsBytesSync(png(width: 16385, height: 2));
      final r = await env.core.call('wallpapers.add_files', {
        'slug': 'nord',
        'paths': ['ok.png', 'notes.txt', 'huge.jpg', 'meta.png', 'giant.png'].map((n) => '${src.path}/$n').toList(),
      });
      expect(r['added'], ['ok.png', 'meta.png']);
      final errors = (r['errors'] as List).join('\n');
      expect(errors, contains('notes.txt: not an image'));
      expect(errors, contains('huge.jpg: image too large (max 50 MiB)'));
      expect(errors, contains('giant.png: image too large to show'));
      final meta = File('${env.paths.backgrounds}/nord/meta.png').readAsBytesSync();
      expect(pngMetadataProblem(meta), isNull);
    });

    test('hide and unhide: added files move to .hidden, shipped ones are listed; last visible refused', () async {
      addTheme(env, 'nord', system: true, wallpapers: ['a.png', 'b.png']);
      await env.core.call('wallpapers.add_bytes', {'slug': 'nord', 'data': base64Encode(validPng)});
      await env.core.call('wallpapers.hide', {'slug': 'nord', 'name': 'dropped-image.png', 'hidden': true});
      expect(File('${env.paths.backgrounds}/nord/.hidden/dropped-image.png').existsSync(), isTrue);
      await env.core.call('wallpapers.hide', {'slug': 'nord', 'name': 'a.png', 'hidden': true});
      expect(loadHiddenWallpapers(env.paths)['nord'], {'a.png'});
      expect(names(await list(env, 'nord'), hidden: false), ['b.png']);
      expect(
        () => env.core.call('wallpapers.hide', {'slug': 'nord', 'name': 'b.png', 'hidden': true}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'last_visible')),
      );
      await env.core.call('wallpapers.hide', {'slug': 'nord', 'name': 'dropped-image.png', 'hidden': false});
      await env.core.call('wallpapers.hide', {'slug': 'nord', 'name': 'a.png', 'hidden': false});
      expect(names(await list(env, 'nord'), hidden: false), ['a.png', 'b.png', 'dropped-image.png']);
      expect(File('${env.paths.backgrounds}/nord/dropped-image.png').existsSync(), isTrue);
    });

    test('hiding the wallpaper on the desktop moves to the next visible one', () async {
      addTheme(env, 'nord', wallpapers: ['a.png', 'b.png']);
      await env.core.call('themes.apply', {'slug': 'nord'});
      expect(Current(env.paths).wallpaper, endsWith('/a.png'));
      await env.core.call('wallpapers.hide', {'slug': 'nord', 'name': 'a.png', 'hidden': true});
      expect(env.desktop.wallpaper(), endsWith('/b.png'));
      expect(Current(env.paths).wallpaper, endsWith('/b.png'));
    });

    test('delete rules: added and custom yes, git and built-in no; undo from the trash', () async {
      addTheme(env, 'sys', system: true, wallpapers: ['s.png', 't.png']);
      addTheme(env, 'mine', wallpapers: ['m.png', 'n.png']);
      File('${env.paths.userThemes}/mine/theme-manager.json').writeAsStringSync('{}');
      addTheme(env, 'gitty', wallpapers: ['g.png', 'h.png']);
      Directory('${env.paths.userThemes}/gitty/.git').createSync();
      await env.core.call('wallpapers.add_bytes', {'slug': 'sys', 'data': base64Encode(validPng)});

      final listing = await list(env, 'sys');
      final byName = {for (final w in listing['wallpapers'] as List) w['name']: w};
      expect(byName['s.png']['deletable'], isFalse);
      expect(byName['dropped-image.png']['deletable'], isTrue);
      expect(
        () => env.core.call('wallpapers.delete', {'slug': 'sys', 'name': 's.png'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'locked')),
      );
      expect(
        () => env.core.call('wallpapers.delete', {'slug': 'gitty', 'name': 'g.png'}),
        throwsA(isA<RouteError>().having((e) => e.message, 'message', lockGit)),
      );

      final r = await env.core.call('wallpapers.delete', {'slug': 'sys', 'name': 'dropped-image.png'});
      expect(r['receipt'], isA<String>());
      expect(names(await list(env, 'sys')), isNot(contains('dropped-image.png')));
      expect(File('${env.paths.trash}/files/dropped-image.png').existsSync(), isTrue);
      final info = File('${env.paths.trash}/info/dropped-image.png.trashinfo').readAsStringSync();
      expect(info, startsWith('[Trash Info]\nPath=${env.paths.backgrounds}/sys/dropped-image.png\nDeletionDate='));
      expect(File('${env.paths.trash}/info/dropped-image.png.trashinfo').statSync().mode & 511, 384);

      final m = await env.core.call('wallpapers.delete', {'slug': 'mine', 'name': 'm.png'});
      expect(File('${env.paths.userThemes}/mine/backgrounds/m.png').existsSync(), isFalse);

      await env.core.call('wallpapers.undo_delete', {'receipt': r['receipt']});
      await env.core.call('wallpapers.undo_delete', {'receipt': m['receipt']});
      expect(names(await list(env, 'sys')), contains('dropped-image.png'));
      expect(File('${env.paths.userThemes}/mine/backgrounds/m.png').existsSync(), isTrue);
      expect(File('${env.paths.trash}/info/dropped-image.png.trashinfo').existsSync(), isFalse);
      expect(
        () => env.core.call('wallpapers.undo_delete', {'receipt': r['receipt']}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'expired')),
      );
    });

    test('undo refuses when the place is taken again; trash names do not clash', () async {
      addTheme(env, 'nord', system: true);
      await env.core.call('wallpapers.add_bytes', {'slug': 'nord', 'data': base64Encode(validPng)});
      final r1 = await env.core.call('wallpapers.delete', {'slug': 'nord', 'name': 'dropped-image.png'});
      await env.core.call('wallpapers.add_bytes', {'slug': 'nord', 'data': base64Encode(validPng)});
      await env.core.call('wallpapers.delete', {'slug': 'nord', 'name': 'dropped-image.png'});
      expect(File('${env.paths.trash}/files/dropped-image.2.png').existsSync(), isTrue);
      await env.core.call('wallpapers.add_bytes', {'slug': 'nord', 'data': base64Encode(validPng)});
      expect(
        () => env.core.call('wallpapers.undo_delete', {'receipt': r1['receipt']}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'undo_failed')),
      );
    });

    test('theme delete to the trash and undo; the active and built-in themes are refused', () async {
      addTheme(env, 'keep');
      addTheme(env, 'gone');
      addTheme(env, 'builtin', system: true);
      await env.core.call('themes.apply', {'slug': 'keep'});
      expect(() => env.core.call('themes.delete', {'slug': 'keep'}),
          throwsA(isA<RouteError>().having((e) => e.code, 'code', 'current')));
      expect(() => env.core.call('themes.delete', {'slug': 'builtin'}),
          throwsA(isA<RouteError>().having((e) => e.code, 'code', 'locked')));
      final r = await env.core.call('themes.delete', {'slug': 'gone'});
      expect(Directory('${env.paths.userThemes}/gone').existsSync(), isFalse);
      expect(Directory('${env.paths.trash}/files/gone').existsSync(), isTrue);
      await env.core.call('themes.undo_delete', {'receipt': r['receipt']});
      expect(File('${env.paths.userThemes}/gone/colors.toml').existsSync(), isTrue);
    });

    test('preview leaves Current alone and preview_end restores it', () async {
      addTheme(env, 'nord', wallpapers: ['a.png', 'b.png']);
      await env.core.call('themes.apply', {'slug': 'nord'});
      final a = Current(env.paths).wallpaper!;
      final b = '${env.paths.userThemes}/nord/backgrounds/b.png';
      await env.core.call('wallpapers.preview', {'path': b});
      expect(env.desktop.wallpaper(), b);
      expect(Current(env.paths).wallpaper, a);
      expect(chosenWallpapers(env.core.ctx), isEmpty);
      await env.core.call('wallpapers.preview_end');
      expect(env.desktop.wallpaper(), a);
    });

    test('set: the current theme changes the desktop, another theme only remembers', () async {
      addTheme(env, 'nord', wallpapers: ['a.png', 'b.png']);
      addTheme(env, 'other', wallpapers: ['x.png', 'y.png']);
      await env.core.call('themes.apply', {'slug': 'nord'});
      final b = '${env.paths.userThemes}/nord/backgrounds/b.png';
      expect((await env.core.call('wallpapers.set', {'slug': 'nord', 'path': b}))['set'], isTrue);
      expect(env.desktop.wallpaper(), b);
      expect(chosenWallpapers(env.core.ctx)['nord'], 'b.png');
      final y = '${env.paths.userThemes}/other/backgrounds/y.png';
      final r = await env.core.call('wallpapers.set', {'slug': 'other', 'path': y});
      expect(r['set'], isFalse);
      expect(env.desktop.wallpaper(), b);
      expect(chosenWallpapers(env.core.ctx)['other'], 'y.png');
      expect(() => env.core.call('wallpapers.set', {'slug': 'nord', 'path': '/etc/passwd'}), throwsA(isA<RouteError>()));
    });
  });

  group('wallhaven', () {
    late TestEnv env;
    setUp(() => env = TestEnv.create());
    tearDown(() => env.dispose());

    Map<String, dynamic> result(String id, {String? path, String? url, String purity = 'sfw'}) => {
      'id': id,
      'url': url ?? 'https://wallhaven.cc/w/$id',
      'purity': purity,
      'resolution': '1920x1080',
      'file_size': 12345,
      'path': path ?? 'https://w.wallhaven.cc/full/${id.substring(0, 2)}/wallhaven-$id.jpg',
      'thumbs': {'lg': 'https://th.wallhaven.cc/lg/${id.substring(0, 2)}/$id.jpg'},
    };

    final fixture = jsonEncode({
      'data': [
        result('abc123'),
        result('zz9999', path: 'https://evil.example/full/zz/wallhaven-zz9999.jpg'),
        result('qq1111', url: 'https://wallhaven.cc/w/other1'),
        result('nsfw01', purity: 'nsfw'),
        'junk',
      ],
      'meta': {'current_page': 1, 'last_page': 7},
    });

    test('reply parsing keeps only exact shapes', () {
      final (results, last) = parseResults(fixture);
      expect(results.map((r) => r.id), ['abc123']);
      expect(results.first.fileName, 'wallhaven-abc123.jpg');
      expect(last, 7);
      expect(parseResults('not json').$1, isEmpty);
      expect(parseResults('not json').$2, 0);
      expect(parseResults('{"data": 5}').$1, isEmpty);
    });

    test('search URL encodes the query and keeps the fixed filters', () {
      final url = Uri.parse(searchUrl('blue  sky&purity=111\n', page: 2));
      expect(url.host, 'wallhaven.cc');
      expect(url.queryParameters['q'], 'blue sky&purity=111');
      expect(url.queryParameters['purity'], '100');
      expect(url.queryParameters['page'], '2');
    });

    test('add downloads into the theme, refuses non-images and repeats', () async {
      addTheme(env, 'nord');
      final asked = <String>[];
      final web = Wallhaven(env.core.ctx, fetch: (url, max, timeout) async {
        asked.add(url);
        if (url.startsWith('https://wallhaven.cc/api/')) return Uint8List.fromList(utf8.encode(fixture));
        if (url.contains('/full/')) return jpeg(1920, 1080);
        return validPng;
      });
      final (results, _) = await web.search('mountains');
      final w = results.single;
      final path = await web.add('nord', w);
      expect(path, '${env.paths.backgrounds}/nord/wallhaven-abc123.jpg');
      expect(web.alreadyAdded('nord', w), isTrue);
      await expectLater(web.add('nord', w), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'exists')));
      final thumb = await web.thumb(w);
      expect(thumb, '${env.paths.cache}/wallhaven/thumbs/abc123.jpg');
      expect(asked.every((u) => u.startsWith('https://')), isTrue);

      final bad = Wallhaven(env.core.ctx, fetch: (url, max, timeout) async => Uint8List.fromList(utf8.encode('<html>')));
      await expectLater(bad.add('nord', WebWallpaper.check({...result('def456')})!), throwsA(isA<RouteError>()));
    });

    test('the GUI can only hand back items in the exact shape', () async {
      addTheme(env, 'nord');
      expect(
        () => env.core.call('wallhaven.add', {'slug': 'nord', 'item': {...result('abc123'), 'path': 'https://w.wallhaven.cc/full/ab/../x.jpg'}}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_params')),
      );
      expect(() => env.core.call('wallhaven.open', {'page': 'https://evil.example/'}), throwsA(isA<RouteError>()));
    });
  });
}
