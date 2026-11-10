import 'dart:io';
import 'dart:typed_data';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/ask_ai.dart';
import 'package:maprisma_theme_core/src/theme_ai.dart';
import 'package:maprisma_theme_core/src/web_images.dart';
import 'package:test/test.dart';

import 'support.dart';

final _png = Uint8List.fromList(tinyPng)..[36] = 0x0A;
InternetAddress _ip(String a) => InternetAddress(a);

void main() {
  group('public addresses', () {
    test('private, loopback, link-local, shared and special ranges are refused', () {
      for (final a in ['127.0.0.1', '10.1.2.3', '172.16.0.1', '172.31.255.1', '192.168.178.1', '169.254.1.1',
          '100.64.0.1', '0.0.0.0', '224.0.0.1', '255.255.255.255', '192.0.2.1', '::1', '::', 'fe80::1', 'fd00::1',
          'fc00::1', '::ffff:192.168.1.1', '::ffff:127.0.0.1', '2001:db8::1', '2002:c0a8:101::1', '64:ff9b::a00:1', 'ff02::1']) {
        expect(isPublicAddress(_ip(a)), isFalse, reason: a);
      }
    });
    test('public ones pass', () {
      for (final a in ['93.184.216.34', '1.1.1.1', '172.32.0.1', '2606:4700::1111', '::ffff:93.184.216.34']) {
        expect(isPublicAddress(_ip(a)), isTrue, reason: a);
      }
    });
  });

  group('image links', () {
    test('only https image files on host names', () {
      expect(publicImageUrl('https://upload.wikimedia.org/a/b/Snow.jpg'), isNotNull);
      expect(publicImageUrl('https://i.example.com/x.webp?w=3840'), isNotNull);
      for (final bad in [
        'http://example.com/a.jpg',
        'https://192.168.1.1/a.jpg',
        'https://[::1]/a.jpg',
        'https://localhost/a.jpg',
        'https://router.local/a.jpg',
        'https://fritz.box.lan/a.jpg',
        'https://user:pw@example.com/a.jpg',
        'https://example.com:8443/a.jpg',
        'https://example.com/page.html',
        'https://example.com/a.svg',
        'file:///etc/passwd.jpg',
        'https://example.com/a b.jpg',
        42,
      ]) {
        expect(publicImageUrl(bad), isNull, reason: '$bad');
      }
    });

    test('the answer: at most eight, no repeats, page only when public', () {
      final images = verifyWallpaperImages({
        'images': [
          {'url': 'https://a.example.com/1.jpg', 'page': 'https://a.example.com/1', 'title': 'Snow'},
          {'url': 'https://a.example.com/1.jpg'},
          {'url': 'https://10.0.0.1/2.jpg'},
          {'url': 'https://b.example.com/2.png', 'page': 'http://b.example.com/'},
          for (var i = 0; i < 12; i++) {'url': 'https://c.example.com/$i.webp'},
        ],
      });
      expect(images, hasLength(maxWebImages));
      expect(images[0], {'url': 'https://a.example.com/1.jpg', 'page': 'https://a.example.com/1', 'title': 'Snow'});
      expect(images[1].containsKey('page'), isFalse);
    });

    test('the web prompt asks for direct links; the plain one for none', () {
      final theme = ThemeFacts(slug: 'nord', name: 'Nord', colors: completeColors({'background': '#2e3440', 'foreground': '#d8dee9', 'accent': '#81a1c1'}));
      expect(buildWallpaperPrompt('snow', theme, web: true), allOf(contains('"images"'), contains('DIRECT links'), contains('or on web pages')));
      expect(buildWallpaperPrompt('snow', theme), allOf(isNot(contains('"images"')), contains('Do not use tools')));
    });

    test('Claude gets only WebSearch and WebFetch, the others nothing new', () {
      final claude = helperFor('claude')!;
      final argv = withWebTools(claude, claude.argv);
      const tools = 'WebSearch,WebFetch';
      expect(argv.sublist(argv.indexOf('--tools'), argv.indexOf('--tools') + 4), ['--tools', tools, '--allowedTools', tools]);
      expect(argv.where((a) => a == '--tools'), hasLength(1));
      final pi = helperFor('pi')!;
      expect(withWebTools(pi, pi.argv), pi.argv);
      expect(canSearchWeb('claude'), isTrue);
      expect(canSearchWeb('pi:ollama/qwen3'), isFalse, reason: 'until pi gets web tools');
    });
  });

  group('theme suggestions', () {
    final nord = ThemeFacts(slug: 'nord', name: 'Nord', colors: completeColors({'background': '#2e3440', 'foreground': '#d8dee9', 'accent': '#81a1c1'}));
    final answer = {
      'summary': 'x',
      'candidates': [
        {
          'kind': 'installed',
          'base': 'nord',
          'wallpaper_query': 'snowy forest',
          'wallpaper_images': [
            {'url': 'https://img.example.com/a.jpg', 'title': 'A'},
            {'url': 'https://192.168.1.2/b.jpg'},
            for (var i = 0; i < 5; i++) {'url': 'https://img.example.com/$i.png'},
          ],
          'reason': 'calm',
        },
      ],
    };
    test('a web Ask keeps up to three checked pictures per suggestion; a plain one none', () {
      final (_, web) = verify(answer, [nord], const [], const [], web: true);
      expect([for (final i in web.single['wallpaper_images'] as List) i['url']],
          ['https://img.example.com/a.jpg', 'https://img.example.com/0.png', 'https://img.example.com/1.png']);
      final (_, plain) = verify(answer, [nord], const [], const []);
      expect(plain.single.containsKey('wallpaper_images'), isFalse);
      expect(buildPrompt('snow', [nord], const [], const [], web: true), allOf(contains('"wallpaper_images"'), contains(webImageRules)));
      expect(buildPrompt('snow', [nord], const [], const []), isNot(contains('wallpaper_images')));
    });
    test('a refine keeps the pictures while the search words stay', () {
      final parent = checkParent({...(verify(answer, [nord], const [], const [], web: true).$2.single), 'theme': 'nord'}, [nord], const [], const [])!;
      expect(parent['wallpaper_images'], hasLength(3));
      final (_, refined) = verify({
        'candidates': [
          {'kind': 'edit', 'base': 'nord', 'palette': {'accent': '#ff0000'}, 'reason': 'red'},
        ],
      }, [nord], const [], const [], parent: parent, web: true);
      expect(refined.single['wallpaper_images'], hasLength(3));
    });
  });

  group('fetching', () {
    test('a private address is never fetched; a picture is kept and added', () async {
      final env = TestEnv.create();
      addTearDown(env.dispose);
      env.addTheme('nord', wallpapers: const []);
      final fetched = <String>[];
      Future<Uint8List?> fetch(String url, InternetAddress a, int max, Duration t) async {
        fetched.add('$url@${a.address}');
        return url.endsWith('page.jpg') ? Uint8List.fromList('<html>'.codeUnits) : _png;
      }

      final lan = WebImages(env.core.ctx, fetch: fetch, resolve: (h) async => [_ip('93.184.216.34'), _ip('192.168.178.1')]);
      await expectLater(lan.get('https://rebind.example.com/a.jpg'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_public')));
      expect(fetched, isEmpty);

      final web = WebImages(env.core.ctx, fetch: fetch, resolve: (h) async => [_ip('93.184.216.34')]);
      final path = await web.get('https://img.example.com/Snowy%20Hill.jpg');
      expect(fetched, ['https://img.example.com/Snowy%20Hill.jpg@93.184.216.34']);
      expect(await web.get('https://img.example.com/Snowy%20Hill.jpg'), path, reason: 'cached');
      expect(fetched, hasLength(1));
      await expectLater(web.get('https://img.example.com/page.jpg'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_image')));
      await expectLater(web.get('https://10.0.0.1/a.jpg'), throwsA(isA<RouteError>()));

      final added = await web.add('nord', 'https://img.example.com/Snowy%20Hill.jpg');
      expect(added, endsWith('/web-Snowy-Hill.png'));
      expect(File(added).existsSync(), isTrue);
    });
  });
}
