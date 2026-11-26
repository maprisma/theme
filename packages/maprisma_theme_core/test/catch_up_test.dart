import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestEnv env;
  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => env.core.call(m, p);
  File marker() => File('${env.paths.state}/desktop-applied.json');

  setUp(() {
    env = TestEnv.create(desktop: FakeDesktop(id: 'kde', name: 'KDE Plasma'));
    env.addTheme('nord', wallpapers: ['a.png', 'b.png']);
    env.addTheme('gruvbox', bg: '#282828', wallpapers: ['g1.png']);
  });
  tearDown(() => env.dispose());

  test('an apply records the theme this desktop got', () async {
    await call('themes.apply', {'slug': 'nord'});
    expect(jsonDecode(marker().readAsStringSync()), {'kde': 'nord'});
    env.desktop.calls.clear();
    expect(await call('themes.catch_up'), {'caught_up': null});
    expect(env.desktop.calls, isNot(contains('applyColors')));
  });

  test('a theme applied on another desktop is applied here at the next start, with its wallpaper', () async {
    await call('themes.apply', {'slug': 'nord'});
    final wp = env.desktop.wallpaper();
    // Meanwhile on Hyprland: gruvbox, this desktop never got it.
    await call('themes.apply', {'slug': 'gruvbox'});
    marker().writeAsStringSync(jsonEncode({'kde': 'nord', 'hyprland': 'gruvbox'}));
    env.desktop.calls.clear();
    final r = await call('themes.catch_up');
    expect(r['caught_up'], 'gruvbox');
    expect(env.desktop.calls, contains('applyColors'));
    expect(env.desktop.lastColors?['background'], '#282828');
    expect(wp, isNotNull);
    expect(jsonDecode(marker().readAsStringSync()), {'kde': 'gruvbox', 'hyprland': 'gruvbox'});
    expect(await call('themes.catch_up'), {'caught_up': null});
  });

  test('without a record (an update from before): applied once', () async {
    await call('themes.apply', {'slug': 'nord'});
    marker().deleteSync();
    expect((await call('themes.catch_up'))['caught_up'], 'nord');
    expect((await call('themes.catch_up'))['caught_up'], isNull);
  });

  test('a desktop without its own appearance has nothing to catch up', () async {
    env.dispose();
    env = TestEnv.create(desktop: FakeDesktop(id: 'other', name: 'Other', caps: {}));
    env.addTheme('nord', wallpapers: ['a.png']);
    await call('themes.apply', {'slug': 'nord'});
    expect(await call('themes.catch_up'), {'caught_up': null});
  });
}
