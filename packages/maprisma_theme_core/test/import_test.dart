import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/catalog_cosmic.dart';
import 'package:maprisma_theme_core/src/catalog_omarchy.dart';
import 'package:maprisma_theme_core/src/import_net.dart';
import 'package:maprisma_theme_core/src/plugin_catalog.dart';
import 'package:test/test.dart';

import 'support.dart';

String fixture(String name) => File('test/data/$name').readAsStringSync();
Uint8List fixtureBytes(String name) => File('test/data/$name').readAsBytesSync();

NetReply reply(int status, List<int> body, {Map<String, String> headers = const {}, Map<String, String> cookies = const {}}) =>
    NetReply(status, headers, Uint8List.fromList(body), cookies: cookies);

/// A fake network: every request is recorded and answered by [answer];
/// nothing reaches the real one.
final class FakeNet {
  FakeNet(this.answer);
  NetReply? Function(NetRequest r) answer;
  final requests = <NetRequest>[];
  Future<NetReply?> call(NetRequest r) async {
    requests.add(r);
    // The same refusal the real fetcher applies first.
    if (urlProblem(r.uri, r.hosts) != null) return null;
    return answer(r);
  }
}

void main() {
  late TestEnv env;
  late DateTime now;
  late FakeNet net;

  setUp(() {
    now = DateTime(2026, 11, 7, 12);
    env = TestEnv.create(clock: () => now);
    net = FakeNet((_) => null);
    netFetch = net.call;
  });
  tearDown(() {
    netFetch = httpsFetch;
    env.dispose();
  });

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) => env.core.call(method, params);

  group('urls', () {
    test('only https on the exact host', () {
      const hosts = {'omarchy.org'};
      expect(urlProblem(Uri.parse('https://omarchy.org/themes/'), hosts), isNull);
      expect(urlProblem(Uri.parse('http://omarchy.org/themes/'), hosts), isNotNull);
      expect(urlProblem(Uri.parse('https://omarchy.org.evil.example/'), hosts), isNotNull);
      expect(urlProblem(Uri.parse('https://sub.omarchy.org/'), hosts), isNotNull);
      expect(urlProblem(Uri.parse('https://user@omarchy.org/'), hosts), isNotNull);
      expect(urlProblem(Uri.parse('https://omarchy.org:8443/'), hosts), isNotNull);
    });
    test('the real fetcher refuses a bad URL without the network', () async {
      expect(await httpsFetch(NetRequest(Uri.parse('http://omarchy.org/'), hosts: {'omarchy.org'})), isNull);
      expect(await httpsFetch(NetRequest(Uri.parse('https://example.com/'), hosts: {'omarchy.org'})), isNull);
    });
    test('git links must be exactly https://github.com/<owner>/<repo>', () {
      expect(slugForRepo('https://github.com/owner/omarchy-nice-theme'), 'nice');
      expect(slugForRepo('https://github.com/owner/Aetheria.git'), 'aetheria');
      expect(slugForRepo('https://github.com/owner/repo/'), 'repo');
      for (final bad in [
        'http://github.com/owner/repo',
        'https://github.com/owner/repo/tree/main',
        'https://github.com.evil.example/owner/repo',
        'https://gitlab.com/owner/repo',
        'ext::sh -c touch% /tmp/pwned',
        'https://github.com/owner/...',
        'https://github.com/../repo',
        'https://github.com/owner/repo?x=1',
        'git@github.com:owner/repo.git',
        'https://github.com/owner/-theme',
      ]) {
        expect(slugForRepo(bad), isNull, reason: bad);
      }
    });
    test('only theme pages open in the browser', () async {
      expect(omarchyOpenable('https://github.com/owner/repo'), isTrue);
      expect(omarchyOpenable(omarchyCatalogUrl), isTrue);
      expect(cosmicOpenable('https://cosmic-themes.org/11/'), isTrue);
      expect(cosmicOpenable('https://cosmic-themes.org/11/download/'), isFalse);
      expect(cosmicOpenable('https://github.com/catppuccin/cosmic-desktop/x'), isFalse);
      await expectLater(call('import.open', {'url': 'https://evil.example/'}), throwsA(isA<RouteError>()));
      await expectLater(call('import.open', {'url': 'file:///etc/passwd'}), throwsA(isA<RouteError>()));
    });
  });

  group('omarchy.org', () {
    test('parses the gallery and drops bad cards', () {
      final themes = parseOmarchyCatalog(fixture('omarchy-themes.html'));
      final slugs = [for (final t in themes) t.slug];
      expect(themes.length, 13);
      expect(slugs, containsAll(['851', 'aetheria', 'abyssal-cartographer', 'fancy']));
      expect(slugs, isNot(contains('repo')));
      expect(slugs, isNot(contains('good')));
      final fancy = themes.firstWhere((t) => t.slug == 'fancy');
      expect(fancy.repo, 'https://github.com/owner/omarchy-fancy-theme.git'); // the first card wins
      expect(fancy.name, isNot(contains('&')));
      expect(themes.firstWhere((t) => t.slug == 'aetheria').preview, 'aetheria.webp');
      // sorted by name
      final names = [for (final t in themes) t.name.toLowerCase()];
      expect(names, [...names]..sort());
    });

    test('list is cached a day and falls back to the cache offline', () async {
      net.answer = (r) => r.uri.toString() == omarchyCatalogUrl ? reply(200, utf8.encode(fixture('omarchy-themes.html'))) : null;
      env.addTheme('aetheria');
      final first = await call('import.omarchy_list');
      expect((first['themes'] as List).length, 13);
      final aetheria = (first['themes'] as List).cast<Map>().firstWhere((t) => t['slug'] == 'aetheria');
      expect(aetheria['installed'], isTrue);
      expect(aetheria['preview'], isNull);
      expect(net.requests.length, 1);
      await call('import.omarchy_list');
      expect(net.requests.length, 1, reason: 'served from the cache');
      now = now.add(const Duration(days: 2));
      net.answer = (_) => null; // offline
      final stale = await call('import.omarchy_list');
      expect((stale['themes'] as List).length, 13);
      expect(net.requests.length, 2);
    });

    test('no list at all is a refusal', () async {
      await expectLater(call('import.omarchy_list'), throwsA(isA<RouteError>()));
    });

    test('previews: only image data is kept', () async {
      final png = img.encodePng(img.Image(width: 4, height: 3));
      net.answer = (r) {
        if (r.uri.toString() == omarchyCatalogUrl) return reply(200, utf8.encode(fixture('omarchy-themes.html')));
        if (r.uri.path == '/assets/themes/aetheria.webp') return reply(200, png);
        if (r.uri.path == '/assets/themes/851.webp') return reply(200, utf8.encode('<html>not an image</html>'));
        return null;
      };
      final ok = await call('import.omarchy_preview', {'slug': 'aetheria'});
      expect(File(ok['path'] as String).readAsBytesSync(), png);
      expect((File(ok['path'] as String).statSync().mode & 511), 384);
      expect((await call('import.omarchy_preview', {'slug': '851'}))['path'], isNull);
      final list = await call('import.omarchy_list');
      expect((list['themes'] as List).cast<Map>().firstWhere((t) => t['slug'] == 'aetheria')['preview'], ok['path']);
      for (final r in net.requests) {
        expect(r.uri.host, 'omarchy.org');
      }
    });

    test('install clones with git (no prompts, hooks or templates) and never replaces', () async {
      net.answer = (r) => r.uri.toString() == omarchyCatalogUrl ? reply(200, utf8.encode(fixture('omarchy-themes.html'))) : null;
      final bin = Directory('${env.root.path}/bin')..createSync();
      final log = '${env.root.path}/git.log';
      File('${bin.path}/git')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'printf "%s\\n" "\$@" > "$log"\n'
          'echo "PROMPT=\$GIT_TERMINAL_PROMPT" >> "$log"\n'
          'for last; do :; done\n'
          'mkdir -p "\$last/.git" && printf \'background = "#101010"\\nforeground = "#eeeeee"\\n\' > "\$last/colors.toml"\n',
        )
        ..createSync();
      Process.runSync('chmod', ['+x', '${bin.path}/git']);
      env.core.ctx.environment['PATH'] = '${bin.path}:/usr/bin:/bin';

      final r = await call('import.omarchy_install', {'name': 'Aetheria', 'apply': true});
      expect(r['slug'], 'aetheria');
      expect(r['applied'], isTrue);
      final args = File(log).readAsLinesSync();
      expect(args, containsAllInOrder(['clone', '--depth', '1']));
      expect(args, contains('core.hooksPath=/dev/null'));
      expect(args, contains('--template='));
      expect(args, contains('PROMPT=0'));
      expect(args.sublist(args.indexOf('--') + 1, args.indexOf('--') + 2), ['https://github.com/JJDizz1L/aetheria']);
      expect(File('${env.paths.userThemes}/aetheria/colors.toml').existsSync(), isTrue);
      expect(env.desktop.calls, contains('applyColors'));
      // no leftovers, no second install
      expect(Directory(env.paths.userThemes).listSync().map((e) => e.path.split('/').last), ['aetheria']);
      await expectLater(
        call('import.omarchy_install', {'name': 'aetheria'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'exists')),
      );
      await expectLater(
        call('import.omarchy_install', {'name': 'evil host'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_found')),
      );
    });

    test('a clone over 512 MiB is stopped and leaves nothing behind (Codex, 2026-11-09)', () async {
      net.answer = (r) => reply(200, utf8.encode(fixture('omarchy-themes.html')));
      final bin = Directory('${env.root.path}/bin')..createSync();
      env.core.ctx.environment['PATH'] = '${bin.path}:/usr/bin:/bin';
      void fakeGit(String tail) {
        // a sparse file: 600 MiB by size, nothing on disk
        File('${bin.path}/git')
          ..writeAsStringSync('#!/bin/sh\nfor last; do :; done\nmkdir -p "\$last"\ntruncate -s 600M "\$last/huge"\n$tail\n')
          ..createSync();
        Process.runSync('chmod', ['+x', '${bin.path}/git']);
      }

      fakeGit('sleep 30'); // still cloning: stopped by the size check
      final started = DateTime.now();
      await expectLater(
        call('import.omarchy_install', {'name': '851'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'clone_failed')),
      );
      expect(DateTime.now().difference(started).inSeconds, lessThan(10));
      expect(Directory(env.paths.userThemes).listSync(), isEmpty);

      fakeGit('exit 0'); // finished, but too large
      await expectLater(
        call('import.omarchy_install', {'name': '851'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'too_large')),
      );
      expect(Directory(env.paths.userThemes).listSync(), isEmpty);
    });

    test('a failed clone leaves nothing behind', () async {
      net.answer = (r) => reply(200, utf8.encode(fixture('omarchy-themes.html')));
      final bin = Directory('${env.root.path}/bin')..createSync();
      File('${bin.path}/git')
        ..writeAsStringSync('#!/bin/sh\nfor last; do :; done\nmkdir -p "\$last"\nexit 128\n')
        ..createSync();
      Process.runSync('chmod', ['+x', '${bin.path}/git']);
      env.core.ctx.environment['PATH'] = '${bin.path}:/usr/bin:/bin';
      await expectLater(
        call('import.omarchy_install', {'name': '851'}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'clone_failed')),
      );
      expect(Directory(env.paths.userThemes).listSync(), isEmpty);
    });
  });

  group('cosmic-themes.org', () {
    test('parses the list page', () {
      final page = parseCosmicPage(fixture('cosmic-themes.html'));
      expect(page.themes.length, 20);
      expect(page.nextPage, 2);
      expect(page.csrf, startsWith('gTntN1'));
      expect([for (final s in page.sorts) s['value']], ['popular', 'new', 'name']);
      final t = page.themes.first;
      expect(t.id, 11);
      expect(t.name, 'Catppuccin Macchiato Lavender');
      expect(t.author, 'Catppuccin');
      expect(t.homepage, 'https://github.com/catppuccin/cosmic-desktop');
      expect(t.downloads, 7345);
      expect(t.dark, isTrue);
      expect(t.colors['bg-color'], '#24273a');
      expect(t.colors['accent-color'], isNotNull);
      for (final v in t.colors.values) {
        expect(isHex(v), isTrue);
      }
      expect(t.preview['background'], '#24273a');
      expect(page.themes.where((t) => !t.dark).length, 2);
      expect({for (final t in page.themes) t.id}.length, 20);
    });

    test('parses a single theme page', () {
      final page = parseCosmicPage(fixture('cosmic-theme-page.html'));
      expect(page.themes.single.id, 11);
      expect(page.csrf, isNotNull);
      expect(page.nextPage, isNull);
    });

    test('hostile markup is dropped', () {
      const evil =
          '<style>#theme-preview-5 { --bg-color: rgba(1, 2, 3, 255.00); }</style>'
          '<h3>Evil <script></h3><div>Homepage</div><div class="text-end"><a href="javascript:alert(1)">x</a></div>'
          '<form method="POST" action="/6/download/"></form>'
          '<style>#theme-preview-7 { --bg-color: rgba(1, 2, 3, 255.00); }</style>'
          '<h3>Fine &amp; &lt;b&gt;</h3><div>Homepage</div><div class="text-end"><a href="http://insecure.example/">x</a></div>'
          '<form method="POST" action="/7/download/"></form>';
      final page = parseCosmicPage(evil);
      expect(page.themes.single.id, 7); // 5's download goes to another id
      expect(page.themes.single.homepage, isNull);
      expect(page.themes.single.name, isNot(contains('<')));
    });

    test('list URL carries only checked parameters', () {
      expect(cosmicListUri().toString(), 'https://cosmic-themes.org/');
      expect(cosmicListUri(search: 'nord\x00 dark', sort: 'name', page: 3).queryParameters, {
        'search': 'nord  dark',
        'sort': 'name',
        'page': '3',
      });
      expect(cosmicListUri(sort: 'x"; drop').queryParameters, isEmpty);
    });

    test('route lists themes with installed tags', () async {
      net.answer = (r) => reply(200, utf8.encode(fixture('cosmic-themes.html')));
      final r = await call('import.cosmic_list', {'search': 'cat', 'sort': 'popular', 'page': 1});
      expect((r['themes'] as List).length, 20);
      expect(r['next_page'], 2);
      expect(net.requests.single.uri.queryParameters, {'search': 'cat', 'sort': 'popular'});
      await expectLater(call('import.cosmic_list', {'sort': 'bad sort'}), throwsA(isA<RouteError>()));
      await expectLater(call('import.cosmic_list', {'page': 0}), throwsA(isA<RouteError>()));
    });

    test('the RON check', () {
      expect(checkThemeRon(fixtureBytes('cosmic-theme.ron')), isNotNull);
      expect(checkThemeRon(utf8.encode('<!DOCTYPE html><html>palette:</html>')), isNull);
      expect(checkThemeRon(utf8.encode('(palette: Dark((\x00')), isNull);
      expect(checkThemeRon(List.filled(maxRonBytes + 1, 0x28)), isNull);
      expect(checkThemeRon([0x28, 0xff, 0xfe]), isNull);
      expect(ronName(fixture('cosmic-theme.ron')), 'Catpuccin-Macchiato-Lavender');
      expect(slugify('Catppuccin Macchiato Lavender'), 'catppuccin-macchiato-lavender');
      expect(slugify('comboom.sucht - (Nordic)'), 'comboom-sucht-nordic');
      expect(slugify('../..'), '');
    });

    test('install downloads with the CSRF token and writes a theme folder', () async {
      net.answer = (r) {
        if (r.method == 'GET' && r.uri.path == '/11/') {
          return reply(200, utf8.encode(fixture('cosmic-theme-page.html')), cookies: {'csrftoken': 'cookieTOKEN0123456789abcdef'});
        }
        if (r.method == 'POST' && r.uri.path == '/11/download/') return reply(200, fixtureBytes('cosmic-theme.ron'));
        return null;
      };
      final r = await call('import.cosmic_install', {'id': 11, 'apply': true});
      expect(r['slug'], 'catppuccin-macchiato-lavender');
      expect(r['applied'], isTrue);
      final post = net.requests.last;
      expect(post.method, 'POST');
      expect(post.headers['cookie'], 'csrftoken=cookieTOKEN0123456789abcdef');
      expect(post.headers['referer'], 'https://cosmic-themes.org/');
      expect(utf8.decode(post.body!), startsWith('csrfmiddlewaretoken=7UmBuKEek'));
      expect(post.maxBytes, 1024 * 1024);

      final dir = '${env.paths.userThemes}/catppuccin-macchiato-lavender';
      expect(File('$dir/cosmic.ron').readAsStringSync(), fixture('cosmic-theme.ron'));
      expect(parseColorsToml(File('$dir/colors.toml').readAsStringSync())['background'], '#1e1e2e');
      final meta = jsonDecode(File('$dir/theme-manager.json').readAsStringSync());
      expect(meta, containsPair('source', 'cosmic-themes.org'));
      expect(meta, containsPair('id', 11));
      expect(meta, containsPair('author', 'Catppuccin'));
      expect(env.desktop.calls, contains('applyRon $dir/cosmic.ron'));
      final theme = env.core.ctx.theme('catppuccin-macchiato-lavender');
      expect(theme.cosmicNative, isTrue);
      expect(theme.name, 'Catppuccin Macchiato Lavender');

      // shown as installed; a second install is refused before any download
      net.answer = (r) => reply(200, utf8.encode(fixture('cosmic-themes.html')));
      final list = await call('import.cosmic_list');
      final first = (list['themes'] as List).first as Map;
      expect(first['installed'], isTrue);
      expect(first['slug'], 'catppuccin-macchiato-lavender');
      final before = net.requests.length;
      await expectLater(call('import.cosmic_install', {'id': 11}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'exists')));
      expect(net.requests.length, before);
      expect(Directory(env.paths.userThemes).listSync().length, 1);
    });

    test('another theme of the same name gets its own folder', () async {
      env.addTheme('catppuccin-macchiato-lavender');
      final ron = fixture('cosmic-theme.ron');
      final slug = await installCosmicRon(env.core.ctx, 99, ron, entry: parseCosmicPage(fixture('cosmic-theme-page.html')).themes.single);
      expect(slug, 'catppuccin-macchiato-lavender-2');
    });

    test('a download that is not a theme is refused and leaves nothing', () async {
      net.answer = (r) => r.method == 'GET'
          ? reply(200, utf8.encode(fixture('cosmic-theme-page.html')), cookies: {'csrftoken': 'cookieTOKEN0123456789abcdef'})
          : reply(200, utf8.encode('<html>Forbidden (CSRF token missing)</html>'));
      await expectLater(call('import.cosmic_install', {'id': 11}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_theme')));
      expect(Directory(env.paths.userThemes).existsSync() ? Directory(env.paths.userThemes).listSync() : [], isEmpty);
      net.answer = (r) => reply(200, utf8.encode(fixture('cosmic-theme-page.html'))); // no cookie
      await expectLater(
        call('import.cosmic_install', {'id': 11}),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'download_failed')),
      );
    });
  });

  group('information', () {
    test('keeps only the author\'s entries', () {
      final plugins = parsePluginCatalog(jsonDecode(fixture('plugin-catalog.json')));
      expect(plugins.length, 13);
      expect(plugins.map((p) => p['id']), contains('ubruckhaus.maprisma-launcher'));
      expect(plugins.map((p) => p['id']), isNot(contains('evil.one')));
      expect(plugins.map((p) => p['id']), isNot(contains('evil.two')));
      expect(plugins.map((p) => p['id']), isNot(contains('ubruckhaus.noname')));
      expect(plugins.every((p) => (p['name'] as String).length <= 60), isTrue);
    });

    test('cards: built-in list without a catalog, new plugins appended', () {
      expect(pluginCards(const []).length, builtinPlugins.length);
      final cards = pluginCards([
        {'id': 'ubruckhaus.hue-lights', 'name': 'Hue Lights', 'description': '', 'version': '', 'verified': true},
        {'id': 'maprisma.new-thing', 'name': 'New Thing', 'description': 'Does new things. And more.', 'version': '', 'verified': false},
      ]);
      expect([for (final c in cards) c['id']], ['ubruckhaus.hue-lights', 'maprisma.new-thing']);
      expect(cards[0]['summary'], 'Philips Hue rooms and lights from the bar');
      expect(cards[1]['summary'], 'Does new things.');
      expect(cards[1]['url'], 'https://plugins.omarchy.org/plugin.html?id=maprisma.new-thing');
    });

    test('catalog read at most hourly, with the ETag, cached 0600', () async {
      final body = utf8.encode(fixture('plugin-catalog.json'));
      net.answer = (r) => reply(200, body, headers: {'etag': '"abc123"'});
      final first = await call('info.plugins');
      expect((first['plugins'] as List).length, 13);
      expect(net.requests.single.uri.toString(), pluginCatalogUrl);
      final cache = File('${env.paths.cache}/plugin-catalog.json');
      expect(cache.statSync().mode & 511, 384);
      expect(Directory(env.paths.cache).statSync().mode & 511, 448);

      await call('info.plugins');
      expect(net.requests.length, 1, reason: 'within the hour');

      now = now.add(const Duration(hours: 2));
      net.answer = (r) => reply(304, const []);
      final again = await call('info.plugins');
      expect(net.requests.length, 2);
      expect(net.requests.last.headers['if-none-match'], '"abc123"');
      expect((again['plugins'] as List).length, (first['plugins'] as List).length);

      now = now.add(const Duration(hours: 2));
      net.answer = (_) => null; // offline: the cached list, the attempt counted
      final offline = await call('info.plugins');
      expect((offline['plugins'] as List).length, (first['plugins'] as List).length);
      expect(loadPluginCache(env.core.ctx)['tried'], greaterThan(0));
      await call('info.plugins');
      expect(net.requests.length, 3);

      final cached = await call('info.plugins', {'cached': true});
      expect((cached['plugins'] as List).length, (first['plugins'] as List).length);
    });

    test('offline without a cache shows the built-in list', () async {
      final r = await call('info.plugins');
      expect((r['plugins'] as List).length, builtinPlugins.length);
    });

    test('a cache folder open to others is not used', () async {
      Directory(env.paths.cache).createSync(recursive: true);
      chmodPath(env.paths.cache, 493); // 0755
      net.answer = (r) => reply(200, utf8.encode(fixture('plugin-catalog.json')));
      await call('info.plugins');
      expect(File('${env.paths.cache}/plugin-catalog.json').existsSync(), isFalse);
    });
  });
}
