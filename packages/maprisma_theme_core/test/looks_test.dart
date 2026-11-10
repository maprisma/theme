import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/apps.dart' show currentAppsDir;
import 'package:maprisma_theme_core/src/kde_formats.dart' show kdeWithForeground;
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
    expect(data['caps'], ['mono_font', 'ui_font', 'blur']);
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

  test('a saved font no longer installed may stay, and Undo may put it back', () async {
    await call('looks.set', {'slug': 'nord', 'look': {'mono_font': 'Fira Code'}});
    env.desktop.fonts = ['JetBrains Mono']; // Fira Code uninstalled
    // only blur changes: the stored font stays
    await call('looks.set', {'slug': 'nord', 'look': {'mono_font': 'Fira Code', 'blur': {'on': true, 'strength': 3}}});
    final r = await call('looks.set', {'slug': 'nord', 'look': {'mono_font': 'JetBrains Mono'}});
    await expectLater(call('looks.set', {'slug': 'nord', 'look': r['previous']}), throwsA(isA<RouteError>()));
    await call('looks.set', {'slug': 'nord', 'look': r['previous'], 'restore': true});
    expect(Looks(env.core.ctx).of('nord')['mono_font'], 'Fira Code');
  });

  test('a desktop without an interface font only has the monospace field', () async {
    env.dispose();
    env = TestEnv.create(desktop: FakeDesktop(caps: Cap.values.toSet().difference({Cap.uiFont})));
    env.addTheme('nord', system: true);
    await call('looks.set', {'slug': 'nord', 'look': {'ui_font': 'Inter'}});
    final data = await call('looks.get', {'slug': 'nord'});
    expect(data['caps'], ['mono_font', 'blur']);
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

  test('a preset\'s font keeps the user\'s own font; its undo puts the fonts back exactly', () async {
    await env.desktop.setMonospaceFont('JetBrains Mono');
    await call('themes.apply', {'slug': 'nord'});
    await env.desktop.setMonospaceFont('Fira Code'); // the font in use when the preset is saved
    await call('presets.save', {'name': 'Work'});
    await env.desktop.setMonospaceFont('JetBrains Mono');

    final r = await call('presets.apply', {'name': 'Work'});
    expect(env.desktop.monospaceFont(), 'Fira Code');
    expect(env.core.ctx.settings.get('own_font'), 'JetBrains Mono');
    await call('presets.undo', {'receipt': r['receipt'], 'appearance': true});
    expect(env.desktop.monospaceFont(), 'JetBrains Mono');
    expect(env.core.ctx.settings.get('own_font'), isNull);

    await call('presets.apply', {'name': 'Work'});
    env.addTheme('plain', system: true);
    await call('themes.apply', {'slug': 'plain'});
    expect(env.desktop.monospaceFont(), 'JetBrains Mono');
  });

  test('looks.get: the user\'s own fonts while a theme\'s font is in use', () async {
    await env.desktop.setMonospaceFont('JetBrains Mono');
    await call('themes.apply', {'slug': 'mine'});
    final data = await call('looks.get', {'slug': 'nord'});
    expect(data['current'], {'mono_font': 'Fira Code', 'ui_font': null});
    expect(data['own'], {'mono_font': 'JetBrains Mono', 'ui_font': null});
    expect(data['in_use'], isFalse);
  });

  test('blur: a theme\'s look sets it; the user\'s whole blur state comes back after', () async {
    env.desktop.blur = {'on': false, 'strength': 3, 'other': 7};
    await call('looks.set', {'slug': 'nord', 'look': {'blur': {'on': true, 'strength': 12}}});
    final r = await call('themes.apply', {'slug': 'nord'});
    expect(r['done'], contains('blur'));
    expect(env.desktop.blur, {'on': true, 'strength': 12, 'other': 7});
    expect(env.core.ctx.settings.get('own_blur'), {'on': false, 'strength': 3, 'other': 7});

    // the same blur again: nothing to write
    env.desktop.calls.clear();
    await call('themes.apply', {'slug': 'nord'});
    expect(env.desktop.calls.where((c) => c.startsWith('blur')), isEmpty);

    final data = await call('looks.get', {'slug': 'nord'});
    expect(data['caps'], contains('blur'));
    expect(data['blur'], {
      'current': {'on': true, 'strength': 12},
      'own': {'on': false, 'strength': 3},
      'theme': null,
    });

    await call('themes.apply', {'slug': 'mine'}); // no blur of its own
    expect(env.desktop.blur, {'on': false, 'strength': 3, 'other': 7});
    expect(env.core.ctx.settings.get('own_blur'), isNull);
  });

  test('blur on the theme in use follows looks.set at once; a desktop without blur shows none', () async {
    await call('themes.apply', {'slug': 'nord'});
    final r = await call('looks.set', {'slug': 'nord', 'look': {'blur': {'on': true, 'strength': 5}}});
    expect(r['applied'], ['blur']);
    expect(env.desktop.blur['on'], isTrue);

    env.dispose();
    env = TestEnv.create(desktop: FakeDesktop(caps: Cap.values.toSet().difference({Cap.blur})));
    env.addTheme('nord', system: true);
    await call('looks.set', {'slug': 'nord', 'look': {'blur': {'on': true, 'strength': 5}}});
    await call('themes.apply', {'slug': 'nord'});
    expect(env.desktop.blur['on'], isFalse);
    expect((await call('looks.get', {'slug': 'nord'}))['caps'], isNot(contains('blur')));
  });

  test('blur: the user\'s own is kept before the change, also when the write fails', () async {
    env.desktop.blur = {'on': true, 'strength': 2, 'other': 0};
    env.desktop.blurWrites = false;
    await call('looks.set', {'slug': 'nord', 'look': {'blur': {'on': false, 'strength': 2}}});
    await call('themes.apply', {'slug': 'nord'});
    expect(env.core.ctx.settings.get('own_blur'), {'on': true, 'strength': 2, 'other': 0});
    env.desktop.blurWrites = true;
    await call('themes.apply', {'slug': 'nord'});
    expect(env.desktop.blur['on'], isFalse);
    // the own value is still the user's, not the half-done state
    expect(env.core.ctx.settings.get('own_blur'), {'on': true, 'strength': 2, 'other': 0});
  });

  test('preset undo puts blur back exactly, with a blur set by hand', () async {
    await call('looks.set', {'slug': 'nord', 'look': {'blur': {'on': true, 'strength': 10}}});
    await call('themes.apply', {'slug': 'nord'});
    env.desktop.blur = {'on': true, 'strength': 4, 'other': 1}; // changed by hand
    await call('themes.apply', {'slug': 'mine'});
    await call('presets.save', {'name': 'Plain'});
    await call('themes.apply', {'slug': 'nord'});
    env.desktop.blur = {'on': true, 'strength': 4, 'other': 1};
    final r = await call('presets.apply', {'name': 'Plain'});
    expect(env.desktop.blur['strength'], isNot(4));
    await call('presets.undo', {'receipt': r['receipt'], 'appearance': true});
    expect(env.desktop.blur, {'on': true, 'strength': 4, 'other': 1});
  });

  test('saved but not applied: pending for the theme in use; looks.apply clears it', () async {
    await env.desktop.setMonospaceFont('JetBrains Mono');
    await call('themes.apply', {'slug': 'nord'});
    Map<String, dynamic> nord(Map<String, dynamic> list) =>
        (list['themes'] as List).cast<Map<String, dynamic>>().firstWhere((t) => t['slug'] == 'nord');
    expect(nord(await call('themes.list'))['pending'], isEmpty);

    final r = await call('looks.set', {'slug': 'nord', 'look': {'mono_font': 'Fira Code', 'blur': {'on': true, 'strength': 5}}, 'apply': false});
    expect(r['applied'], isEmpty);
    expect(r['pending'], ['mono_font', 'blur']);
    expect(env.desktop.monospaceFont(), 'JetBrains Mono');
    expect(nord(await call('themes.list'))['pending'], ['mono_font', 'blur']);
    expect((await call('looks.get', {'slug': 'nord'}))['pending'], ['mono_font', 'blur']);

    final a = await call('looks.apply', {'slug': 'nord'});
    expect(a['applied'], ['mono_font', 'blur']);
    expect(env.desktop.monospaceFont(), 'Fira Code');
    expect(nord(await call('themes.list'))['pending'], isEmpty);

    // the look removed without applying: the user's own font is still to come back
    await call('looks.set', {'slug': 'nord', 'look': {}, 'apply': false});
    expect(nord(await call('themes.list'))['pending'], ['mono_font', 'blur']);
    await call('looks.apply', {'slug': 'nord'});
    expect(env.desktop.monospaceFont(), 'JetBrains Mono');
    expect(nord(await call('themes.list'))['pending'], isEmpty);

    // only the theme in use can be reapplied; other themes never have anything pending
    await expectLater(call('looks.apply', {'slug': 'mine'}), throwsA(isA<RouteError>()));
    expect((await call('looks.get', {'slug': 'mine'}))['pending'], isEmpty);
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

  test('text colour: in place of the foreground on the desktop, terminal and apps; pending until applied', () async {
    File('../../templates/alacritty.toml.tpl').copySync('${env.paths.templates}/alacritty.toml.tpl');
    final colorsToml = File('${env.paths.systemThemes}/nord/colors.toml').readAsStringSync();
    await call('themes.apply', {'slug': 'nord'});
    expect(env.desktop.lastColors!['foreground'], '#d8dee9');
    expect(checkLook({'text_color': 'red'}), isNull);
    expect(checkLook({'text_color': '#FF8800'}), {'text_color': '#ff8800'});

    final r = await call('looks.set', {'slug': 'nord', 'look': {'text_color': '#FF8800'}, 'apply': false});
    expect(r['pending'], ['text_color']);
    expect(env.desktop.lastColors!['foreground'], '#d8dee9', reason: 'stored only');
    expect((await call('looks.get', {'slug': 'nord'}))['look'], {'text_color': '#ff8800'});

    final a = await call('looks.apply', {'slug': 'nord'});
    expect(a['applied'], contains('text_color'));
    expect(env.desktop.lastColors!['foreground'], '#ff8800');
    expect(env.desktop.lastColors!['background'], '#2e3440', reason: 'only the foreground');
    expect(env.desktop.lastTerminal!['foreground'], '#ff8800');
    expect(File('${currentAppsDir(env.core.ctx)}/alacritty.toml').readAsStringSync(), contains('foreground = "#ff8800"'));
    expect((await call('looks.get', {'slug': 'nord'}))['pending'], isEmpty);
    expect(File('${env.paths.systemThemes}/nord/colors.toml').readAsStringSync(), colorsToml, reason: 'theme files unchanged');

    // another theme shows its own text colour; back on nord the look comes again
    await call('themes.apply', {'slug': 'mine'});
    expect(env.desktop.lastColors!['foreground'], '#d8dee9');
    await call('themes.apply', {'slug': 'nord'});
    expect(env.desktop.lastColors!['foreground'], '#ff8800');

    // Theme's own again, applied at once on the theme in use
    final b = await call('looks.set', {'slug': 'nord', 'look': {}, 'apply': true});
    expect(b['applied'], contains('text_color'));
    expect(env.desktop.lastColors!['foreground'], '#d8dee9');
    expect(b['pending'], isEmpty);
    final info = await call('looks.get', {'slug': 'nord'});
    expect(info['text_color'], {'theme': '#d8dee9', 'background': '#2e3440'});
  });

  test('text colour on a native KDE scheme: its text roles, the file itself unchanged', () async {
    final kde = TestEnv.create(desktop: FakeDesktop(id: 'kde', name: 'KDE Plasma'));
    addTearDown(kde.dispose);
    final dir = kde.addTheme('breezy');
    File('$dir/kde.colors').writeAsStringSync('[Colors:View]\nForegroundNormal=1,2,3\n');
    await kde.core.call('looks.set', {'slug': 'breezy', 'look': {'text_color': '#102030'}});
    await kde.core.call('themes.apply', {'slug': 'breezy'});
    expect(kde.desktop.calls, contains('applyKdeScheme $dir/kde.colors foreground=#102030'));
    expect(File('$dir/kde.colors').readAsStringSync(), contains('ForegroundNormal=1,2,3'));
    final scheme = '[Colors:View]\nForegroundNormal=1,2,3\n[Colors:Selection]\nForegroundNormal=9,9,9\n[Colors:Window]\nForegroundNormal=4,5,6\n';
    final out = kdeWithForeground(scheme, '#102030');
    expect(out, contains('[Colors:View]\nForegroundNormal=16,32,48'));
    expect(out, contains('[Colors:Window]\nForegroundNormal=16,32,48'));
    expect(out, contains('[Colors:Selection]\nForegroundNormal=9,9,9'), reason: 'text on the selection stays');
  });
}
