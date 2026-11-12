import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestEnv env;
  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => env.core.call(m, p);

  setUp(() {
    env = TestEnv.create();
  });
  tearDown(() => env.dispose());

  test('3D flip settings: defaults, validation, normalization and reset', () async {
    final initial = (await call('settings.get'))['settings'] as Map<String, dynamic>;
    expect(initial['preview_flip_3d'], isTrue);
    expect(initial['preview_flip_delay'], 2);
    expect(initial['preview_pin_apply_theme'], isTrue);
    expect(initial['preview_big_card'], isTrue);
    expect(initial['preview_big_auto_rotate'], isTrue);

    for (final choice in [0, 0.5, 1, 1.5, 2, 3, 5, 10]) {
      final s = (await call('settings.set', {'key': 'preview_flip_delay', 'value': choice}))['settings'] as Map;
      expect(s['preview_flip_delay'], choice);
    }
    final fromFloat = (await call('settings.set', {'key': 'preview_flip_delay', 'value': 2.0}))['settings'] as Map;
    expect(fromFloat['preview_flip_delay'], 2);

    await call('settings.set', {'key': 'preview_flip_3d', 'value': false});
    await call('settings.set', {'key': 'preview_pin_apply_theme', 'value': false});
    final updated = (await call('settings.get'))['settings'] as Map;
    expect(updated['preview_flip_3d'], isFalse);
    expect(updated['preview_pin_apply_theme'], isFalse);

    for (final (k, bad) in [
      ('preview_flip_3d', 'yes'),
      ('preview_pin_apply_theme', 1),
      ('preview_flip_delay', -1),
      ('preview_flip_delay', 4),
      ('preview_flip_delay', true),
    ]) {
      expect(() => call('settings.set', {'key': k, 'value': bad}), throwsA(isA<RouteError>()), reason: '$k=$bad');
    }

    final afterReset = (await call('settings.reset'))['settings'] as Map;
    expect(afterReset['preview_flip_3d'], isTrue);
    expect(afterReset['preview_flip_delay'], 2);
    expect(afterReset['preview_pin_apply_theme'], isTrue);
  });

  test('backup preview and restore validate 3D flip settings', () async {
    final file = '${env.root.path}/flip-backup.json';
    File(file).writeAsStringSync(jsonEncode({
      'format': 'theme-manager-backup',
      'version': 1,
      'files': {
        'settings.json': {
          'preview_flip_3d': false,
          'preview_flip_delay': 0.5,
          'preview_pin_apply_theme': false,
        },
      },
    }));
    await call('backup.restore', {'path': file});
    final s = (await call('settings.get'))['settings'] as Map;
    expect(s['preview_flip_3d'], isFalse);
    expect(s['preview_flip_delay'], 0.5);
    expect(s['preview_pin_apply_theme'], isFalse);

    for (final bad in [
      {'preview_flip_3d': 'false'},
      {'preview_flip_delay': 7},
      {'preview_pin_apply_theme': null},
    ]) {
      File(file).writeAsStringSync(jsonEncode({
        'format': 'maprisma-theme-backup',
        'version': 1,
        'files': {'settings.json': bad},
      }));
      expect(() => call('backup.preview', {'path': file}), throwsA(isA<RouteError>()), reason: '$bad');
    }
  });

  test('themes.list flip wallpapers: active first on current, remembered first on others, samefile skipped', () async {
    final kanagawaDir = env.addTheme('kanagawa', wallpapers: ['1-a.png', '2-b.png', '3-c.png']);
    File('$kanagawaDir/preview.png').writeAsBytesSync(tinyPng);

    final nordDir = env.addTheme('nord', wallpapers: ['1-n.png', '2-n.png', '3-n.png']);
    File('$nordDir/preview.png').writeAsBytesSync(tinyPng);

    env.addTheme('no-preview', wallpapers: ['1.png', '2.png']);

    final sameDir = env.addTheme('same-file', wallpapers: ['only.png']);
    Link('$sameDir/preview.png').createSync('$sameDir/backgrounds/only.png');

    await call('themes.apply', {'slug': 'kanagawa'});
    // Active wallpaper on current theme moves to index 0.
    await call('wallpapers.set', {'slug': 'kanagawa', 'path': '$kanagawaDir/backgrounds/3-c.png'});
    // Pinning/remembering wallpaper on non-active theme moves to index 0 without switching current theme.
    final rem = await call('wallpapers.set', {'slug': 'nord', 'path': '$nordDir/backgrounds/2-n.png'});
    expect(rem['set'], isFalse);
    expect(rem['remembered'], isTrue);
    expect(env.core.ctx.current.slug, 'kanagawa');

    final listed = await call('themes.list');
    expect(listed['current'], 'kanagawa');
    expect(listed['current_wallpaper'], '$kanagawaDir/backgrounds/3-c.png');
    final bySlug = {for (final t in listed['themes'] as List) (t as Map)['slug'] as String: t};

    expect(
      (bySlug['kanagawa']!['wallpapers'] as List).map((p) => (p as String).split('/').last).toList(),
      ['3-c.png', '1-a.png', '2-b.png'],
    );
    expect(
      (bySlug['nord']!['wallpapers'] as List).map((p) => (p as String).split('/').last).toList(),
      ['2-n.png', '3-n.png', '1-n.png'],
    );
    expect(bySlug['no-preview']!['wallpapers'], isEmpty);
    // A card shows another theme's wallpaper pinned only when it is remembered for it.
    expect(bySlug['nord']!['chosen_wallpaper'], '2-n.png');
    expect(bySlug['same-file']!['chosen_wallpaper'], isNull);
    expect(bySlug['same-file']!['wallpapers'], isEmpty);

    // Applying nord without an explicit wallpaper uses its remembered 2-n.png.
    await call('themes.apply', {'slug': 'nord'});
    expect(env.core.ctx.current.slug, 'nord');
    expect(env.core.ctx.current.wallpaper, '$nordDir/backgrounds/2-n.png');
  });

  test('the theme in use: a same-named file of another theme is not its pinned wallpaper', () async {
    final a = env.addTheme('alpha', wallpapers: ['wallpaper.png', 'other.png']);
    File('$a/preview.png').writeAsBytesSync(tinyPng);
    final b = env.addTheme('beta', wallpapers: ['wallpaper.png', 'b2.png']);
    File('$b/preview.png').writeAsBytesSync(tinyPng);
    File('$b/backgrounds/wallpaper.png').writeAsBytesSync([...tinyPng, 0]);   // another file, same name
    await call('themes.apply', {'slug': 'beta'});
    await call('wallpapers.set', {'slug': 'beta', 'path': '$b/backgrounds/b2.png'});
    var bySlug = {for (final t in (await call('themes.list'))['themes'] as List) (t as Map)['slug'] as String: t};
    expect(bySlug['beta']!['pinned_wallpaper'], '$b/backgrounds/b2.png');
    // The desktop shows alpha's wallpaper.png while beta is in use: beta's file of that name is not it.
    await (env.core.ctx.desktop as FakeDesktop).setWallpaper('$a/backgrounds/wallpaper.png');
    bySlug = {for (final t in (await call('themes.list'))['themes'] as List) (t as Map)['slug'] as String: t};
    expect(bySlug['beta']!['pinned_wallpaper'], isNull);
    expect(bySlug['alpha']!['pinned_wallpaper'], isNull);    // not the theme in use
  });

  test('themes.apply with wallpaper remembers and applies that wallpaper directly', () async {
    final dir = env.addTheme('fireside', wallpapers: ['1-f.png', '2-f.png']);
    File('$dir/preview.png').writeAsBytesSync(tinyPng);

    await call('themes.apply', {'slug': 'fireside', 'wallpaper': '$dir/backgrounds/2-f.png'});
    expect(env.core.ctx.current.slug, 'fireside');
    expect(env.core.ctx.current.wallpaper, '$dir/backgrounds/2-f.png');
    expect(chosenWallpapers(env.core.ctx)['fireside'], '2-f.png');

    expect(
      () => call('themes.apply', {'slug': 'fireside', 'wallpaper': '$dir/backgrounds/missing.png'}),
      throwsA(isA<RouteError>()),
    );
  });

  test('themes.apply says whether the asked wallpaper is on the desktop', () async {
    final dir = env.addTheme('ember', wallpapers: ['1-e.png']);
    File('$dir/preview.png').writeAsBytesSync(tinyPng);
    final r = await call('themes.apply', {'slug': 'ember', 'wallpaper': '$dir/backgrounds/1-e.png'});
    expect(r['wallpaper_set'], (r['done'] as List).contains('wallpaper'));
    final plain = await call('themes.apply', {'slug': 'ember'});
    expect(plain.containsKey('wallpaper_set'), isFalse);
  });

  test('a pin whose wallpaper the desktop refuses leaves the remembered one as it was', () async {
    final dir = env.addTheme('dusk', wallpapers: ['1-d.png', '2-d.png']);
    File('$dir/preview.png').writeAsBytesSync(tinyPng);
    await call('wallpapers.set', {'slug': 'dusk', 'path': '$dir/backgrounds/1-d.png'});
    expect(chosenWallpapers(env.core.ctx)['dusk'], '1-d.png');
    (env.core.ctx.desktop as FakeDesktop).refuseWallpaper = true;
    final r = await call('themes.apply', {'slug': 'dusk', 'wallpaper': '$dir/backgrounds/2-d.png'});
    expect(r['wallpaper_set'], isFalse);
    expect(chosenWallpapers(env.core.ctx)['dusk'], '1-d.png');
  });

  test('the remembered wallpapers are read bounded, never waiting on a FIFO, links kept', () async {
    final ctx = env.core.ctx;
    final file = '${ctx.paths.state}/theme-backgrounds.json';
    Directory(ctx.paths.state).createSync(recursive: true);
    File(file).writeAsStringSync('{"nord": "2-n.png", "bad": 3}');
    expect(chosenWallpapers(ctx), {'nord': '2-n.png'});
    File(file).deleteSync();
    final elsewhere = '${ctx.paths.state}/elsewhere.json';
    File(elsewhere).writeAsStringSync('{"nord": "2-n.png"}');
    Link(file).createSync(elsewhere);
    expect(chosenWallpapers(ctx), {'nord': '2-n.png'}); // a dotfiles link is read (and written) alike
    rememberWallpaper(ctx, 'dusk', '1-d.png');
    expect(jsonDecode(File(elsewhere).readAsStringSync()), {'nord': '2-n.png', 'dusk': '1-d.png'});
    Link(file).deleteSync();
    expect(Process.runSync('mkfifo', [file]).exitCode, 0);
    expect(chosenWallpapers(ctx), isEmpty); // returns at once, no writer needed
    File(file).deleteSync();
    File(file).writeAsStringSync('{"x": "${'a' * (300 * 1024)}"}');
    expect(chosenWallpapers(ctx), isEmpty);
  });
}
