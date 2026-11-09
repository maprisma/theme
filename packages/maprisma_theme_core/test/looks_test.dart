import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Theme looks (docs/theme-looks.md): fonts per theme for any theme, the
/// look over the theme's own font, the user's own fonts back afterwards.
void main() {
  late TestEnv env;
  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) async => env.core.call(m, p);

  setUp(() {
    env = TestEnv.create();
    env.addTheme('nord', system: true);
    env.addTheme('mine');
    File('${env.paths.userThemes}/mine/theme-manager.json').writeAsStringSync('{"font": "Fira Code"}');
  });
  tearDown(() => env.dispose());

  test('checkLook keeps only what fits', () {
    expect(checkLook({'mono_font': 'Fira Code', 'ui_font': null, 'blur': {'on': true, 'strength': 15}}),
        {'mono_font': 'Fira Code', 'blur': {'on': true, 'strength': 15}});
    for (final bad in [
      {'other': 1},
      {'mono_font': 'Comic; rm -rf /'},
      {'blur': {'on': 1, 'strength': 3}},
      {'blur': {'on': true, 'strength': 0}},
      {'blur': {'on': true, 'strength': 16}},
      {'blur': {'on': true, 'strength': 3, 'x': 1}},
      'nope',
    ]) {
      expect(checkLook(bad), isNull, reason: '$bad');
    }
  });

  test('a system theme gets fonts; the user\'s own come back with the next theme', () async {
    await env.desktop.setMonospaceFont('JetBrains Mono');
    await call('looks.set', {'slug': 'nord', 'look': {'mono_font': 'Fira Code', 'ui_font': 'Inter'}});
    final r = await call('themes.apply', {'slug': 'nord'});
    expect(r['done'], containsAll(['font', 'ui_font']));
    expect(env.desktop.monospaceFont(), 'Fira Code');
    expect(env.desktop.interfaceFont(), 'Inter');
    expect(env.core.ctx.settings.get('own_font'), 'JetBrains Mono');
    expect(env.core.ctx.settings.get('own_ui_font'), defaultFontMark);

    // mine brings Fira Code itself, no interface font: the default interface font back
    await call('themes.apply', {'slug': 'mine'});
    expect(env.desktop.monospaceFont(), 'Fira Code');
    expect(env.desktop.calls, contains('ui font reset'));
    expect(env.desktop.interfaceFont(), isNull);
    expect(env.core.ctx.settings.get('own_ui_font'), isNull);
    expect(env.core.ctx.settings.get('own_font'), 'JetBrains Mono');

    env.addTheme('plain', system: true);
    await call('themes.apply', {'slug': 'plain'});
    expect(env.desktop.monospaceFont(), 'JetBrains Mono');
    expect(env.core.ctx.settings.get('own_font'), isNull);
  });

  test('the look wins over the theme\'s own font', () async {
    await call('looks.set', {'slug': 'mine', 'look': {'mono_font': 'JetBrains Mono'}});
    await call('themes.apply', {'slug': 'mine'});
    expect(env.desktop.monospaceFont(), 'JetBrains Mono');
    final data = await call('looks.get', {'slug': 'mine'});
    expect(data['theme'], {'mono_font': 'Fira Code', 'ui_font': null});
    expect(data['look'], {'mono_font': 'JetBrains Mono'});
    expect(data['caps'], ['mono_font', 'ui_font']);
    expect((data['fonts'] as Map)['ui_font'], contains('Inter'));
  });

  test('looks.set on the theme in use applies at once; {} removes the look', () async {
    await call('themes.apply', {'slug': 'nord'});
    final r = await call('looks.set', {'slug': 'nord', 'look': {'ui_font': 'Open Sans'}});
    expect(r['applied'], ['ui_font']);
    expect(r['previous'], isEmpty);
    expect(env.desktop.interfaceFont(), 'Open Sans');

    final back = await call('looks.set', {'slug': 'nord', 'look': {}});
    expect(back['previous'], {'ui_font': 'Open Sans'});
    expect(env.desktop.interfaceFont(), isNull);
    expect(File(env.paths.file('looks.json')).readAsStringSync(), isNot(contains('nord')));
  });

  test('looks.set refuses fonts that are not installed and unknown themes', () async {
    await expectLater(call('looks.set', {'slug': 'nord', 'look': {'mono_font': 'Not Installed Mono'}}), throwsA(isA<RouteError>()));
    await expectLater(call('looks.set', {'slug': 'nord', 'look': {'mono_font': 'Inter'}}), throwsA(isA<RouteError>())); // not monospaced
    await expectLater(call('looks.set', {'slug': 'gone', 'look': {}}), throwsA(isA<RouteError>()));
    await expectLater(call('looks.set', {'slug': 'nord', 'look': {'blur': true}}), throwsA(isA<RouteError>()));
    expect(File(env.paths.file('looks.json')).existsSync(), isFalse);
  });

  test('a desktop without an interface font only has the monospace field', () async {
    env.dispose();
    env = TestEnv.create(desktop: FakeDesktop(caps: Cap.values.toSet().difference({Cap.uiFont})));
    env.addTheme('nord', system: true);
    await call('looks.set', {'slug': 'nord', 'look': {'ui_font': 'Inter'}});
    final data = await call('looks.get', {'slug': 'nord'});
    expect(data['caps'], ['mono_font']);
    await call('themes.apply', {'slug': 'nord'});
    expect(env.desktop.interfaceFont(), isNull);
  });

  test('renaming a theme takes its look along; forgetting it drops the look', () {
    final looks = Looks(env.core.ctx)..set('mine', {'mono_font': 'Fira Code'});
    looks.rename('mine', 'yours');
    expect(looks.all().keys, ['yours']);
    looks.forget('yours');
    expect(looks.all(), isEmpty);
  });

  test('backups carry looks.json and refuse bad ones', () async {
    await call('looks.set', {'slug': 'nord', 'look': {'mono_font': 'Fira Code', 'blur': {'on': true, 'strength': 4}}});
    final file = '${env.root.path}/backup.json';
    await call('backup.export', {'path': file});
    final data = jsonDecode(File(file).readAsStringSync()) as Map;
    expect(data['files']['looks.json'], {'nord': {'mono_font': 'Fira Code', 'blur': {'on': true, 'strength': 4}}});

    await call('looks.set', {'slug': 'nord', 'look': {}});
    await call('backup.restore', {'path': file});
    expect(Looks(env.core.ctx).of('nord'), {'mono_font': 'Fira Code', 'blur': {'on': true, 'strength': 4}});

    data['files']['looks.json'] = {'nord': {'mono_font': 'x; y'}};
    File(file).writeAsStringSync(jsonEncode(data));
    await expectLater(call('backup.preview', {'path': file}), throwsA(anything));
  });
}
