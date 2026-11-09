import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/custom.dart' show blurOf;
import 'package:maprisma_theme_core/src/extract.dart' show hlsOf;
import 'package:test/test.dart';

import 'support.dart';

Matcher routeError(String code) => throwsA(isA<RouteError>().having((e) => e.code, 'code', code));

void main() {
  late TestEnv env;
  setUp(() => env = TestEnv.create());
  tearDown(() => env.dispose());

  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => env.core.call(m, p);

  String addNord() {
    final dir = env.addTheme(
      'nord',
      system: true,
      wallpapers: [],
      extraToml:
          'border_glow = "rgba(1,2,3)"\nframe = "#123456"\nopacity = 0.9\nselection = "bad"\n'
          '[table]\ninside = "#ffffff"\n',
    );
    File('$dir/icons.theme').writeAsStringSync('Yaru-blue\n');
    // support.dart's tinyPng is one byte short (its IEND chunk is cut off), so
    // the header check rightly refuses it: real PNGs here.
    for (final name in ['a.png', 'b.png']) {
      File('$dir/backgrounds/$name').writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 3)));
    }
    return dir;
  }

  Map<String, String> colorsOf(Map<String, dynamic> editor) => Map<String, String>.from(editor['colors'] as Map);

  test('editor data for a new theme from a base', () async {
    addNord();
    final ed = await call('custom.editor', {'base': 'nord'});
    expect(ed['name'], 'My Nord');
    expect(ed['copy_wallpapers'], true);
    expect(ed['base'], 'nord');
    expect(ed['fonts'], ['JetBrains Mono', 'Fira Code']);
    final keys = ed['editable_keys'] as Map;
    expect(keys['main'], ['background', 'foreground', 'accent', 'selection', 'muted']);
    expect(keys['terminal'], containsAll(['red', 'cyan', 'bright_red', 'bright_cyan']));
    expect(keys['more'], containsAll(['orange', 'brown', 'dark_background', 'frame']));
    final colors = colorsOf(ed);
    expect(colors['background'], '#2e3440');
    expect(colors['frame'], '#123456');
    expect(colors.containsKey('border_glow'), isFalse); // kept, but not a plain color
    expect(colors.values.every((v) => RegExp(r'^#[0-9a-f]{6}$').hasMatch(v)), isTrue);
    expect((await call('fonts.list'))['fonts'], contains('Fira Code'));
  });

  test('save a new theme: folder, colors, wallpapers, icons, marker, preview', () async {
    addNord();
    final ed = await call('custom.editor', {'base': 'nord'});
    final colors = colorsOf(ed)..['accent'] = '#FF8800';
    final r = await call('custom.save', {'name': 'My Nord', 'colors': colors, 'font': 'Fira Code', 'base': 'nord'});
    expect(r['slug'], 'my-nord');
    final dir = '${env.paths.userThemes}/my-nord';
    final toml = File('$dir/colors.toml').readAsStringSync();
    expect(toml, contains('accent = "#ff8800"'));
    expect(File('$dir/backgrounds/a.png').existsSync(), isTrue);
    expect(File('$dir/backgrounds/b.png').existsSync(), isTrue);
    expect(File('$dir/icons.theme').readAsStringSync(), 'Yaru-blue\n');
    final marker = readJsonMap('$dir/theme-manager.json');
    expect(marker['base'], 'nord');
    expect(marker['font'], 'Fira Code');
    final t = findTheme(env.paths, 'my-nord')!;
    expect(t.custom, isTrue);
    expect(t.font, 'Fira Code');
    expect(t.preview, '$dir/preview.png');
    // Not the theme in use, no apply asked for: nothing applied.
    expect(env.desktop.calls, isNot(contains('applyColors')));
  });

  test('a theme made here keeps its blur; editing keeps or changes it', () async {
    addNord();
    final ed = await call('custom.editor', {'base': 'nord'});
    expect(ed['blur'], isNull);
    final blur = {'on': true, 'strength': 6};
    await call('custom.save', {'name': 'Frost', 'colors': colorsOf(ed), 'base': 'nord', 'blur': blur});
    final dir = '${env.paths.userThemes}/frost';
    expect(readJsonMap('$dir/theme-manager.json')['blur'], blur);
    expect(blurOf(findTheme(env.paths, 'frost')!), blur);
    final again = await call('custom.editor', {'edit': 'frost'});
    expect(again['blur'], blur);
    await call('custom.save', {'name': 'Frost', 'colors': colorsOf(again), 'edit': 'frost'});
    expect(readJsonMap('$dir/theme-manager.json').containsKey('blur'), isFalse);
    expect(
      () => call('custom.save', {
        'name': 'Bad',
        'colors': colorsOf(ed),
        'base': 'nord',
        'blur': {'on': 'yes', 'strength': 3},
      }),
      routeError('bad_blur'),
    );
  });

  test('refuses to overwrite an existing theme', () async {
    addNord();
    final colors = colorsOf(await call('custom.editor', {'base': 'nord'}));
    await call('custom.save', {'name': 'Mine', 'colors': colors, 'base': 'nord'});
    final before = File('${env.paths.userThemes}/mine/colors.toml').readAsStringSync();
    await expectLater(
      call('custom.save', {
        'name': 'mine',
        'colors': {...colors, 'background': '#000000'},
        'base': 'nord',
      }),
      routeError('exists'),
    );
    await expectLater(call('custom.save', {'name': 'Nord', 'colors': colors, 'base': 'nord'}), routeError('exists'));
    expect(File('${env.paths.userThemes}/mine/colors.toml').readAsStringSync(), before);
    await expectLater(call('custom.save', {'name': '!!!', 'colors': colors}), routeError('bad_name'));
  });

  test('only #rrggbb is written; the base theme\'s other values are kept', () async {
    addNord();
    final colors = colorsOf(await call('custom.editor', {'base': 'nord'}));
    await expectLater(
      call('custom.save', {
        'name': 'Bad',
        'colors': {...colors, 'red': 'rgb(1,2,3)'},
        'base': 'nord',
      }),
      routeError('bad_color'),
    );
    await expectLater(
      call('custom.save', {
        'name': 'Bad',
        'colors': {...colors, 'red': '#12345'},
        'base': 'nord',
      }),
      routeError('bad_color'),
    );
    expect(Directory('${env.paths.userThemes}/bad').existsSync(), isFalse);
    await call('custom.save', {'name': 'Good', 'colors': colors, 'base': 'nord'});
    final toml = File('${env.paths.userThemes}/good/colors.toml').readAsStringSync();
    final values = parseColorsToml(toml);
    expect(values['mode'], 'dark');
    expect(values['border_glow'], 'rgba(1,2,3)');
    expect(values['frame'], '#123456');
    expect(values.containsKey('opacity'), isFalse);
    expect(values.containsKey('inside'), isFalse);
    expect(toml, isNot(contains('[table]')));
    for (final e in values.entries) {
      if (e.key == 'mode' || e.key == 'border_glow') continue;
      expect(e.value, matches(RegExp(r'^#[0-9a-f]{6}$')), reason: e.key);
    }
    expect(values['selection'], isNot('bad'));
  });

  test('a changed main color moves the shades that were not given', () async {
    addNord();
    final slug = await createThemeFolder(
      env.core.ctx,
      name: 'Imported',
      colors: {'background': '#101820', 'foreground': '#e0e0e0', 'accent': '#ff0066'},
      cosmicRon: '(palette: Dark(()))',
    );
    final dir = '${env.paths.userThemes}/$slug';
    final values = parseColorsToml(File('$dir/colors.toml').readAsStringSync());
    expect(values['dark_background'], mixColor('#101820', '#000000', 0.25));
    expect(File('$dir/cosmic.ron').readAsStringSync(), '(palette: Dark(()))');
    expect(findTheme(env.paths, slug)!.cosmicNative, isTrue);
  });

  test('an edited cosmic-themes.org import is applied from colors.toml and keeps its source', () async {
    final slug = await createThemeFolder(
      env.core.ctx,
      name: 'Imported',
      colors: {'background': '#101820', 'foreground': '#e0e0e0', 'accent': '#ff0066'},
      cosmicRon: '(palette: Dark(()))',
    );
    final dir = '${env.paths.userThemes}/$slug';
    writeJson('$dir/theme-manager.json', {
      'name': 'Imported',
      'source': 'cosmic-themes.org',
      'id': 42,
      'author': 'Someone',
      'homepage': 'https://example.org',
    }, mode: 420);
    env.core.ctx.current.save(slug: slug);
    final changed = colorsOf(await call('custom.editor', {'edit': slug}))..['foreground'] = '#ffffff';
    env.desktop.calls.clear();
    final r = await call('custom.save', {'name': 'Imported', 'colors': changed, 'edit': slug});
    expect(r['applied'], isTrue);
    expect(env.desktop.calls, contains('applyColors'));
    expect(env.desktop.calls.where((c) => c.startsWith('applyRon')), isEmpty);
    expect(File('$dir/cosmic.ron').existsSync(), isFalse);
    expect(File('$dir/cosmic.ron.orig').readAsStringSync(), '(palette: Dark(()))');
    expect(findTheme(env.paths, slug)!.cosmicNative, isFalse);
    final meta = readJsonMap('$dir/theme-manager.json');
    expect(meta['source'], 'cosmic-themes.org');
    expect(meta['id'], 42);
    expect(meta['author'], 'Someone');
    expect(meta['homepage'], 'https://example.org');
    expect(File('$dir/colors.toml').readAsStringSync(), contains('foreground = "#ffffff"'));
  });

  test('edit and rename a custom theme; the state follows; re-applied when in use', () async {
    addNord();
    final colors = colorsOf(await call('custom.editor', {'base': 'nord'}));
    await call('custom.save', {'name': 'My Nord', 'colors': colors, 'base': 'nord'});
    final ctx = env.core.ctx;
    ctx.lists.favorites = ['my-nord'];
    ctx.lists.markUsed('my-nord');
    saveHiddenWallpapers(env.paths, {
      'my-nord': {'a.png'},
    });
    Directory('${env.paths.backgrounds}/my-nord').createSync(recursive: true);
    File('${env.paths.backgrounds}/my-nord/added.png').writeAsBytesSync(tinyPng);
    ctx.current.save(slug: 'my-nord');

    final ed = await call('custom.editor', {'edit': 'my-nord'});
    expect(ed['name'], 'My Nord');
    expect(ed['current'], isTrue);
    final changed = colorsOf(ed)..['foreground'] = '#ffffff';
    final r = await call('custom.save', {'name': 'Cool Nord', 'colors': changed, 'edit': 'my-nord', 'font': 'JetBrains Mono'});
    expect(r['slug'], 'cool-nord');
    expect(r['applied'], isTrue);
    expect(env.desktop.calls, contains('applyColors'));
    expect(Directory('${env.paths.userThemes}/my-nord').existsSync(), isFalse);
    final dir = '${env.paths.userThemes}/cool-nord';
    expect(File('$dir/colors.toml').readAsStringSync(), contains('foreground = "#ffffff"'));
    expect(File('${env.paths.backgrounds}/cool-nord/added.png').existsSync(), isTrue);
    expect(ctx.lists.favorites, ['cool-nord']);
    expect(ctx.lists.recent.containsKey('cool-nord'), isTrue);
    expect(loadHiddenWallpapers(env.paths)['cool-nord'], {'a.png'});
    expect(ctx.current.slug, 'cool-nord');
    expect(readJsonMap('$dir/theme-manager.json')['font'], 'JetBrains Mono');
    expect(readJsonMap('$dir/theme-manager.json')['base'], 'nord');

    // Renaming onto another theme is refused; system and git themes are not editable.
    await expectLater(call('custom.save', {'name': 'Nord', 'colors': changed, 'edit': 'cool-nord'}), routeError('exists'));
    expect(Directory(dir).existsSync(), isTrue);
    await expectLater(call('custom.editor', {'edit': 'nord'}), routeError('not_custom'));
    await expectLater(call('custom.save', {'name': 'Nord', 'colors': changed, 'edit': 'nord'}), routeError('not_custom'));
    Directory('$dir/.git').createSync();
    await expectLater(call('custom.editor', {'edit': 'cool-nord'}), routeError('not_custom'));
  });

  test('preview.png is a 1280×720 picture in the theme\'s colors', () async {
    env.addTheme('plain', system: true, wallpapers: []);
    final colors = colorsOf(await call('custom.editor', {'base': 'plain'}))..['background'] = '#204060';
    colors['darker_background'] = '#102030';
    await call('custom.save', {'name': 'Plain Two', 'colors': colors, 'base': 'plain'});
    final png = File('${env.paths.userThemes}/plain-two/preview.png').readAsBytesSync();
    final image = img.decodePng(png)!;
    expect((image.width, image.height), (1280, 720));
    final inside = image.getPixel(640, 200 + 330); // inside the window, below the code
    expect((inside.r, inside.g, inside.b), (0x20, 0x40, 0x60));
    final corner = image.getPixel(5, 700); // the desktop: no wallpaper, the darkest background
    expect((corner.r, corner.g, corner.b), (0x10, 0x20, 0x30));
  });

  group('from a wallpaper', () {
    String picture(String name, img.Color base, img.Color spot) {
      final image = img.Image(width: 240, height: 160);
      img.fill(image, color: base);
      img.fillRect(image, x1: 20, y1: 20, x2: 90, y2: 70, color: spot);
      img.fillRect(image, x1: 150, y1: 90, x2: 200, y2: 140, color: img.ColorRgb8(60, 160, 70));
      final path = '${env.root.path}/$name';
      File(path).writeAsBytesSync(img.encodePng(image));
      return path;
    }

    void readable(Map<String, String> c) {
      final bg = c['background']!;
      expect(contrast(c['foreground']!, bg), greaterThanOrEqualTo(7.0));
      for (final k in ['red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'accent']) {
        expect(contrast(c[k]!, bg), greaterThanOrEqualTo(3.0), reason: k);
      }
    }

    test('a dark picture gives a dark theme with readable colors', () async {
      final path = picture('2-deep-ocean.png', img.ColorRgb8(20, 40, 90), img.ColorRgb8(240, 140, 20));
      final r = await call('custom.from_wallpaper', {'path': path});
      expect(r['mode'], 'dark');
      expect(r['name'], 'Deep Ocean');
      final c = Map<String, String>.from(r['colors'] as Map);
      readable(c);
      final (h, _, _) = hlsOf(c['background']!);
      expect((h * 360 - 222).abs(), lessThan(15)); // the picture's main hue
      final (ah, _, _) = hlsOf(c['accent']!);
      expect((ah * 360 - 33).abs(), lessThan(15)); // its most vivid color
    });

    test('a bright picture gives a light theme with readable colors', () async {
      final path = picture('wallhaven-xlqrwv.png', img.ColorRgb8(235, 225, 200), img.ColorRgb8(200, 40, 120));
      final r = await call('custom.from_wallpaper', {'path': path});
      expect(r['mode'], 'light');
      expect(r['name'], 'New Custom Theme');
      readable(Map<String, String>.from(r['colors'] as Map));
    });

    test('the editor opens with the picture; saving copies it', () async {
      addNord();
      final path = picture('forest.png', img.ColorRgb8(30, 70, 40), img.ColorRgb8(250, 200, 30));
      final ed = await call('custom.editor', {'base': 'nord', 'wallpaper': path});
      expect(ed['name'], 'Forest');
      expect(ed['copy_wallpapers'], false);
      expect(ed['sample_wallpaper'], path);
      await call('custom.save', {'name': ed['name'], 'colors': ed['colors'], 'base': 'nord', 'wallpaper': path});
      final dir = '${env.paths.userThemes}/forest';
      expect(File('$dir/backgrounds/forest.png').existsSync(), isTrue);
      expect(File('$dir/backgrounds/a.png').existsSync(), isFalse);
      final preview = img.decodePng(File('$dir/preview.png').readAsBytesSync())!;
      final p = preview.getPixel(5, 700); // the wallpaper shows on the desktop
      expect((p.r, p.g, p.b), (30, 70, 40));
    });

    test('a picture declaring a huge size is refused before decoding', () async {
      final png = Uint8List.fromList(tinyPng);
      ByteData.sublistView(png).setUint32(16, 20000);
      final path = '${env.root.path}/huge.png';
      File(path).writeAsBytesSync(png);
      await expectLater(call('custom.from_wallpaper', {'path': path}), routeError('bad_image'));
      File('${env.root.path}/note.png').writeAsStringSync('not a picture');
      await expectLater(call('custom.from_wallpaper', {'path': '${env.root.path}/note.png'}), routeError('bad_image'));
    });
  });
}
