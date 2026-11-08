import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/catalog_kde.dart';
import 'package:maprisma_theme_core/src/import_net.dart';
import 'package:test/test.dart';

import 'support.dart';

const scheme = '[Colors:Window]\nBackgroundNormal=40,44,52\nForegroundNormal=220,223,228\nForegroundInactive=92,99,112\n\n'
    '[Colors:View]\nForegroundNegative=224,108,117\nForegroundPositive=152,195,121\nForegroundNeutral=229,192,123\n'
    'ForegroundLink=97,175,239\nForegroundVisited=198,120,221\nDecorationHover=86,182,194\n\n'
    '[Colors:Selection]\nBackgroundNormal=97,175,239\n\n[General]\nColorScheme=OneDark\nName=One Dark\n';

Map<String, dynamic> entry(int id, String name, {String file = 'x.colors', String host = 'files06.pling.com'}) => {
  'id': id,
  'name': name,
  'personid': 'someone',
  'downloads': '1234',
  'score': 84,
  'downloadname1': file,
  'downloadlink1': 'https://$host/api/files/download/j/token/$file',
  'previewpic1': 'https://images.pling.com/cache/img/$id.png',
};

void main() {
  late TestEnv env;
  final requests = <String>[];
  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => env.core.call(m, p);
  late Map<String, NetReply Function()> answers;

  NetReply reply(int status, List<int> body, {Map<String, String> headers = const {}}) =>
      NetReply(status, headers, Uint8List.fromList(body));

  setUp(() {
    env = TestEnv.create();
    requests.clear();
    answers = {};
    netFetch = (r) async {
      requests.add('${r.uri}');
      if (urlProblem(r.uri, r.hosts) != null) return null;
      for (final e in answers.entries) {
        if ('${r.uri}'.startsWith(e.key)) return e.value();
      }
      return reply(404, const []);
    };
  });
  tearDown(() {
    netFetch = httpsFetch;
    env.dispose();
  });

  void list(List<Map<String, dynamic>> data, {int total = 3}) => answers['https://api.kde-look.org/ocs/v1/content/data?'] =
      () => reply(200, utf8.encode(jsonEncode({'status': 'ok', 'totalitems': total, 'data': data})));

  test('the list keeps single .colors files from the file servers only', () async {
    list([
      entry(1, 'One Dark'),
      entry(2, 'Archive', file: 'pack.tar.gz'),
      entry(3, 'Elsewhere', host: 'evil.example.com'),
      {'id': 'x'},
    ], total: 45);
    final r = await call('import.kde_list', {'sort': 'new', 'search': 'dark', 'page': 2});
    expect([for (final t in r['themes']) t['id']], [1]);
    expect(r['themes'][0], containsPair('page', 'https://store.kde.org/p/1'));
    expect(r['themes'][0], containsPair('installed', false));
    expect(r['next_page'], 3);
    final uri = Uri.parse(requests.single);
    expect(uri.host, 'api.kde-look.org');
    expect(uri.queryParameters, containsPair('categories', '112'));
    expect(uri.queryParameters, containsPair('page', '1'));
    expect(uri.queryParameters, containsPair('sortmode', 'new'));
    expect(uri.queryParameters, containsPair('search', 'dark'));
    expect(() => call('import.kde_list', {'sort': 'evil'}), throwsA(isA<RouteError>()));
  });

  test('install follows one redirect to the CDN, keeps the scheme and derives colors', () async {
    list([entry(7, 'One Dark')]);
    await call('import.kde_list');
    answers['https://files06.pling.com/'] = () =>
        reply(302, const [], headers: {'location': 'https://ocs-dl.fra1.cdn.digitaloceanspaces.com/data/files/7/x.colors?sig=1'});
    answers['https://ocs-dl.fra1.cdn.digitaloceanspaces.com/'] = () => reply(200, utf8.encode(scheme));
    final r = await call('import.kde_install', {'id': 7, 'apply': true});
    expect(r['slug'], 'one-dark');
    expect(r['applied'], isTrue);
    final dir = '${env.paths.userThemes}/one-dark';
    expect(File('$dir/kde.colors').readAsStringSync(), scheme);
    final colors = File('$dir/colors.toml').readAsStringSync();
    expect(colors, contains('background = "#282c34"'));
    expect(colors, contains('accent = "#61afef"'));
    expect(colors, contains('red = "#e06c75"'));
    expect(jsonDecode(File('$dir/theme-manager.json').readAsStringSync()),
        containsPair('homepage', 'https://store.kde.org/p/7'));
    // on a desktop with native schemes the file itself is applied
    expect(env.desktop.calls, contains('applyKdeScheme $dir/kde.colors'));
    expect((await call('import.kde_list'))['themes'][0]['installed'], isTrue);
    await expectLater(call('import.kde_install', {'id': 7}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'exists')));
  });

  test('a redirect anywhere else and a file that is no scheme are refused', () async {
    list([entry(8, 'Bad')]);
    await call('import.kde_list');
    answers['https://files06.pling.com/'] = () => reply(302, const [], headers: {'location': 'https://evil.example.com/x.colors'});
    await expectLater(call('import.kde_install', {'id': 8}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'download_failed')));
    answers['https://files06.pling.com/'] = () => reply(200, utf8.encode('<html>nope</html>'));
    await expectLater(call('import.kde_install', {'id': 8}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'bad_theme')));
    expect(Directory(env.paths.userThemes).existsSync() ? Directory(env.paths.userThemes).listSync() : const [], isEmpty);
  });

  test('previews: only checked images from the image server are cached', () async {
    list([entry(9, 'Pic')]);
    await call('import.kde_list');
    answers['https://images.pling.com/'] = () => reply(200, tinyPng);
    final path = (await call('import.kde_preview', {'id': 9}))['path'] as String;
    expect(File(path).readAsBytesSync(), tinyPng);
    expect((await call('import.kde_list'))['themes'][0]['preview'], path);
  });

  test('scheme colors: window, selection and view roles', () {
    final c = kdeSchemeColors(scheme);
    expect(c, containsPair('background', '#282c34'));
    expect(c, containsPair('foreground', '#dcdfe4'));
    expect(c, containsPair('accent', '#61afef'));
    expect(c, containsPair('mode', 'dark'));
    expect(c, containsPair('magenta', '#c678dd'));
    expect(checkKdeColors(utf8.encode('[Colors:Window]\nBackgroundNormal=1,2,3\n')), isNull);
    expect(kdeOpenable('https://store.kde.org/p/123'), isTrue);
    expect(kdeOpenable('https://store.kde.org/p/123/evil'), isFalse);
  });

  test('without native schemes a KDE Store theme is applied as its colors', () async {
    final e = TestEnv.create(desktop: FakeDesktop(id: 'cosmic', caps: Cap.values.toSet().difference({Cap.kdeScheme})));
    addTearDown(e.dispose);
    final dir = Directory('${e.paths.userThemes}/one-dark')..createSync(recursive: true);
    File('${dir.path}/kde.colors').writeAsStringSync(scheme);
    File('${dir.path}/colors.toml').writeAsStringSync(writeColorsToml(kdeSchemeColors(scheme)));
    await e.core.call('themes.apply', {'slug': 'one-dark'});
    expect(e.desktop.calls, contains('applyColors'));
    expect(e.desktop.calls.where((c) => c.startsWith('applyKdeScheme')), isEmpty);
  });
}
