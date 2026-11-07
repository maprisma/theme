import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/auto.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestEnv env;
  var now = DateTime(2026, 11, 7, 12, 0);
  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => env.core.call(m, p);
  void active(int ws) => env.desktop.workspaces = {
    'workspaces': [
      for (var i = 1; i <= 4; i++) {'index': i, 'name': '$i', 'active': i == ws, 'tiling': true, 'output': 'DP-1'},
    ],
    'can_tile': true,
  };
  String? shown() => env.desktop.wallpaper();
  String name(String? p) => p == null ? '' : p.substring(p.lastIndexOf('/') + 1);

  setUp(() {
    now = DateTime(2026, 11, 7, 12, 0);
    env = TestEnv.create(clock: () => now);
    env.addTheme('nord', wallpapers: ['a.png', 'b.png', 'c.png']);
    env.addTheme('gruvbox', bg: '#282828', wallpapers: ['g1.png', 'g2.png']);
    env.addTheme('kanagawa', bg: '#1f1f28', wallpapers: ['k.png']);
    active(1);
  });
  tearDown(() => env.dispose());

  group('menu and favorites', () {
    test('menu: favorites in the order added, else the five most recent', () async {
      var m = await call('auto.menu');
      expect(m['source'], 'recent');
      expect(m['title'], 'Recently used');
      expect(m['themes'], isEmpty);
      expect(m['items'], [
        {'id': 'next_wallpaper', 'label': 'Next wallpaper'},
        {'id': 'open', 'label': 'Open Maprisma Theme'},
      ]);
      await call('themes.apply', {'slug': 'gruvbox'});
      now = now.add(const Duration(minutes: 1));
      await call('themes.apply', {'slug': 'nord'});
      m = await call('auto.menu');
      expect([for (final t in m['themes']) t['slug']], ['nord', 'gruvbox']);
      expect(m['themes'][0]['current'], isTrue);
      await call('themes.favorite', {'slug': 'kanagawa', 'favorite': true});
      await call('themes.favorite', {'slug': 'gruvbox', 'favorite': true});
      m = await call('auto.menu');
      expect(m['title'], 'Favorite themes');
      expect([for (final t in m['themes']) t['slug']], ['kanagawa', 'gruvbox']);
      expect(m['themes'][0], {'slug': 'kanagawa', 'name': 'Kanagawa', 'current': false});
    });

    test('step_theme cycles the favorites, without favorites every visible theme', () async {
      await call('themes.apply', {'slug': 'nord'});
      expect((await call('auto.step_theme', {'direction': 1}))['theme'], 'gruvbox'); // by name: gruvbox, kanagawa, nord
      await call('themes.favorite', {'slug': 'nord', 'favorite': true});
      await call('themes.favorite', {'slug': 'kanagawa', 'favorite': true});
      expect((await call('auto.step_theme', {'direction': 1}))['theme'], 'nord');
      expect((await call('auto.step_theme', {'direction': 1}))['theme'], 'kanagawa');
      expect((await call('auto.step_theme', {'direction': 1}))['theme'], 'nord');
      expect((await call('auto.step_theme', {'direction': -1}))['theme'], 'kanagawa');
      expect(env.core.ctx.current.slug, 'kanagawa');
    });
  });

  group('wallpapers', () {
    test('step_background goes through the visible wallpapers', () async {
      await call('themes.apply', {'slug': 'nord'});
      expect(name(shown()), 'a.png');
      expect(name((await call('auto.step_background', {'direction': 1}))['wallpaper']), 'b.png');
      expect(name((await call('auto.step_background', {'direction': 1}))['wallpaper']), 'c.png');
      expect(name((await call('auto.step_background', {'direction': 1}))['wallpaper']), 'a.png');
      expect(name((await call('auto.step_background', {'direction': -1}))['wallpaper']), 'c.png');
      expect(name(shown()), 'c.png');
      // a hidden one is skipped
      saveHiddenWallpapers(env.paths, {'nord': {'a.png'}});
      expect(name((await call('auto.step_background', {'direction': 1}))['wallpaper']), 'b.png');
    });

    test('a wallpaper per workspace, the others return to the background', () async {
      await call('themes.apply', {'slug': 'nord'});
      final r = await call('auto.set_workspace_wallpaper', {'slug': 'nord', 'name': 'c.png', 'workspaces': [2, 3]});
      expect(r['map'], {'2': 'c.png', '3': 'c.png'});
      expect((await call('auto.workspace_wallpapers', {'slug': 'nord'}))['map'], {'2': 'c.png', '3': 'c.png'});
      await call('auto.workspace', {'workspace': 1});
      expect(name(shown()), 'a.png');
      active(2);
      await call('auto.workspace', {'workspace': 2});
      expect(name(shown()), 'c.png');
      // scrolling on a workspace with its own wallpaper changes that workspace's
      await call('auto.step_background', {'direction': -1});
      expect(name(shown()), 'b.png');
      expect((await call('auto.workspace_wallpapers', {'slug': 'nord'}))['map'], {'2': 'b.png', '3': 'c.png'});
      active(1);
      await call('auto.workspace', {'workspace': 1});
      expect(name(shown()), 'a.png');
      await call('auto.workspace', {'workspace': 3});
      expect(name(shown()), 'c.png');
      // only for the theme it belongs to
      await call('themes.apply', {'slug': 'gruvbox'});
      await call('auto.workspace', {'workspace': 3});
      expect(name(shown()), 'g1.png');
      // cleared
      await call('auto.set_workspace_wallpaper', {'slug': 'nord', 'name': 'c.png', 'workspaces': []});
      expect((await call('auto.workspace_wallpapers', {'slug': 'nord'}))['map'], {'2': 'b.png'});
    });

    test('the first assignment switches workspace wallpapers on', () async {
      await call('settings.set', {'key': 'workspace_wallpapers', 'value': false});
      final r = await call('auto.set_workspace_wallpaper', {'slug': 'nord', 'name': 'b.png', 'workspaces': [2]});
      expect(r['switched_on'], isTrue);
      expect(env.core.ctx.settings.get('workspace_wallpapers'), isTrue);
    });
  });

  group('workspace themes', () {
    test('a theme per workspace returns to the base theme; a manual pick wins', () async {
      await call('themes.apply', {'slug': 'nord'});
      await call('auto.set_workspace_themes', {'slug': 'gruvbox', 'workspaces': [2]});
      expect((await call('auto.workspace_themes'))['themes'], {'2': 'gruvbox'});
      expect(env.core.ctx.settings.get('workspace_themes'), isTrue);
      active(2);
      await call('auto.workspace', {'workspace': 2});
      expect(env.core.ctx.current.slug, 'gruvbox');
      active(1);
      await call('auto.workspace', {'workspace': 1});
      expect(env.core.ctx.current.slug, 'nord');
      // picked by hand on workspace 2: that becomes the theme to stay
      active(2);
      await call('auto.workspace', {'workspace': 2});
      await call('themes.apply', {'slug': 'kanagawa'});
      active(1);
      await call('auto.workspace', {'workspace': 1});
      expect(env.core.ctx.current.slug, 'kanagawa');
    });

    test('use on all workspaces, with undo while nothing changed', () async {
      await call('themes.apply', {'slug': 'nord'});
      await call('auto.set_workspace_themes', {'slug': 'gruvbox', 'workspaces': [2, 3]});
      final saved = (await call('auto.use_everywhere'))['saved'] as Map<String, dynamic>;
      expect(saved['theme'], 'nord');
      expect((await call('auto.workspace_themes'))['themes'], isEmpty);
      // through JSON, as the GUI hands it back
      final back = jsonDecode(jsonEncode(saved));
      expect((await call('auto.undo_use_everywhere', {'saved': back}))['restored'], isTrue);
      expect((await call('auto.workspace_themes'))['themes'], {'2': 'gruvbox', '3': 'gruvbox'});
      final again = (await call('auto.use_everywhere'))['saved'];
      await call('themes.apply', {'slug': 'kanagawa'});
      expect(() => call('auto.undo_use_everywhere', {'saved': again}), throwsA(isA<RouteError>()));
      expect((await call('auto.use_everywhere'))['saved'], isNull);
    });
  });

  group('timed', () {
    test('day and night switch at the boundaries; a manual pick stays until the next', () async {
      await call('themes.apply', {'slug': 'nord'});
      await call('auto.schedule_set', {'enabled': true, 'day': 'gruvbox', 'night': 'kanagawa', 'day_at': '07:00', 'night_at': '19:00'});
      expect((await call('auto.schedule'))['schedule']['day'], 'gruvbox');
      expect((await call('auto.tick'))['theme'], 'gruvbox');
      await call('themes.apply', {'slug': 'nord'});
      now = DateTime(2026, 11, 7, 18, 59);
      expect(await call('auto.tick'), isEmpty);
      expect(env.core.ctx.current.slug, 'nord');
      now = DateTime(2026, 11, 7, 19, 0);
      expect((await call('auto.tick'))['theme'], 'kanagawa');
      now = DateTime(2026, 11, 8, 2, 0);
      expect(await call('auto.tick'), isEmpty);
      now = DateTime(2026, 11, 8, 7, 1);
      expect((await call('auto.tick'))['theme'], 'gruvbox');
      expect(periodAt(DateTime(2026, 1, 1, 23), '22:00', '06:00'), 'day');
      expect(periodAt(DateTime(2026, 1, 1, 7), '22:00', '06:00'), 'night');
      expect(() => call('auto.schedule_set', {'day_at': '25:00'}), throwsA(isA<RouteError>()));
      expect(() => call('auto.schedule_set', {'day': 'nope'}), throwsA(isA<RouteError>()));
    });

    test('the slideshow steps on time and keeps a workspace with its own wallpaper', () async {
      await call('themes.apply', {'slug': 'nord'});
      await call('settings.set', {'key': 'slideshow_minutes', 'value': 5});
      expect(await call('auto.tick'), isEmpty); // the first tick only starts the clock
      now = now.add(const Duration(minutes: 3));
      expect(await call('auto.tick'), isEmpty);
      now = now.add(const Duration(minutes: 2));
      expect(name((await call('auto.tick'))['background']), 'b.png');
      await call('auto.set_workspace_wallpaper', {'slug': 'nord', 'name': 'c.png', 'workspaces': [1]});
      await call('auto.workspace', {'workspace': 1});
      expect(name(shown()), 'c.png');
      now = now.add(const Duration(minutes: 5));
      expect((await call('auto.tick')).containsKey('background'), isFalse);
      expect(name(shown()), 'c.png');
    });
  });

  test('automation.json follows the settings', () async {
    Map auto() => jsonDecode(File(env.paths.automationFile).readAsStringSync()) as Map;
    expect(auto()['workspace_events'], isTrue);
    expect(auto()['tick'], isFalse);
    expect(auto()['tiling']['active'], isFalse);
    expect(auto().containsKey('autostart'), isTrue);
    await call('settings.set', {'key': 'slideshow_minutes', 'value': 10});
    expect(auto()['tick'], isTrue);
    await call('settings.set', {'key': 'slideshow_minutes', 'value': 0});
    await call('auto.schedule_set', {'enabled': true});
    expect(auto()['tick'], isTrue);
    await call('settings.set', {'key': 'workspace_wallpapers', 'value': false});
    expect(auto()['workspace_events'], isFalse);
  });

  test('rename and forget carry or drop every list', () async {
    final ctx = env.core.ctx;
    await call('themes.apply', {'slug': 'nord'});
    await call('themes.favorite', {'slug': 'nord', 'favorite': true});
    await call('auto.set_workspace_themes', {'slug': 'nord', 'workspaces': [4]});
    await call('auto.set_workspace_wallpaper', {'slug': 'nord', 'name': 'b.png', 'workspaces': [2]});
    await call('auto.schedule_set', {'night': 'nord'});
    renameThemeState(ctx, 'nord', 'nordic');
    expect(ctx.lists.favorites, ['nordic']);
    expect(ctx.lists.recent.containsKey('nordic'), isTrue);
    expect(loadWorkspaceThemes(ctx), {4: 'nordic'});
    expect(loadWorkspaceMap(ctx), {'nordic': {2: 'b.png'}});
    expect(schedule(ctx)['night'], 'nordic');
    forgetThemeState(ctx, 'nordic');
    expect(ctx.lists.favorites, isEmpty);
    expect(loadWorkspaceThemes(ctx), isEmpty);
    expect(loadWorkspaceMap(ctx), isEmpty);
    expect(schedule(ctx)['night'], '');
  });
}
