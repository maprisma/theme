import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/pages/import_page.dart';
import 'package:maprisma_theme/pages/info_page.dart';
import 'package:maprisma_theme/pages/settings_page.dart';
import 'package:maprisma_theme/pages/wallhaven_page.dart';
import 'package:maprisma_theme/pages/wallpapers_page.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

import 'page_shots.dart';

/// The plugin-like pages against the real core in a temporary HOME: they
/// render without errors at a narrow and a wide size, keep the plugin's
/// texts, and (with MAPRISMA_SHOTS set to a folder) write PNG screenshots.
const _themes = {
  'Fireside': ('#1d1714', '#e6d5c3', '#e07a3f'),
  'Jade Horse': ('#0f1a14', '#d3e6da', '#5fbf8a'),
  'Kanagawa': ('#1f1f28', '#dcd7ba', '#7e9cd8'),
  'Ristretto': ('#2c2525', '#e6d9db', '#f38d70'),
  'Starship': ('#14161c', '#cfd6e6', '#e5b45f'),
  'Tokyo Night': ('#1a1b26', '#c0caf5', '#bb9af7'),
  'Nord': ('#2e3440', '#d8dee9', '#88c0d0'),
  'Catppuccin Latte': ('#eff1f5', '#4c4f69', '#1e66f5'),
  'Hackerman': ('#0b0f0b', '#7cff7c', '#2fd06a'),
};

Future<void> _png(String path, Color bg, Color fg, Color accent, {int w = 480, int h = 270}) async {
  final recorder = ui.PictureRecorder();
  final c = Canvas(recorder);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = bg);
  final pane = Paint()..color = Color.lerp(bg, fg, .08)!;
  c.drawRect(Rect.fromLTWH(10, 10, w * .55, h - 20.0), pane);
  c.drawRect(Rect.fromLTWH(w * .58, 10, w * .42 - 10, h * .45), pane);
  c.drawRect(Rect.fromLTWH(w * .58, h * .5, w * .42 - 10, h * .5 - 10), pane);
  final border = Paint()
    ..color = accent
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  c.drawRect(Rect.fromLTWH(10, 10, w * .55, h - 20.0), border);
  for (var i = 0; i < 9; i++) {
    c.drawRect(Rect.fromLTWH(20, 24.0 + i * 18, (i * 37 % 120) + 60.0, 6), Paint()..color = fg.withValues(alpha: .6));
  }
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

Color _hex(String s) => Color(0xff000000 | int.parse(s.substring(1), radix: 16));

void main() {
  late Directory root;
  late CoreService core;
  final shots = shotsDir;
  var aiOn = false;

  setUpAll(loadShotFonts);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('maprisma-ui-parity-');
    Directory('${root.path}/bin').createSync();
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '${root.path}/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory(paths.templates).createSync(recursive: true);
    for (final MapEntry(key: name, value: (bg, fg, accent)) in _themes.entries) {
      final slug = name.toLowerCase().replaceAll(' ', '-');
      final dir = slug == 'starship' ? '${paths.userThemes}/$slug' : '${paths.systemThemes}/$slug';
      File('$dir/colors.toml')
        ..createSync(recursive: true)
        ..writeAsStringSync('background = "$bg"\nforeground = "$fg"\naccent = "$accent"\nred = "#e06c75"\n'
            'green = "#98c379"\nyellow = "#e5c07b"\nblue = "#61afef"\nmagenta = "#c678dd"\ncyan = "#56b6c2"\n'
            'selection = "$accent"\n');
      await _png('$dir/preview.png', _hex(bg), _hex(fg), _hex(accent));
      for (var i = 1; i <= 3; i++) {
        await _png('$dir/backgrounds/$i-$slug.png', Color.lerp(_hex(bg), _hex(accent), i * .2)!, _hex(fg), _hex(accent));
      }
    }
    core = CoreService(environment: env, paths: paths, desktop: FakeDesktop());
    await core.call('themes.apply', {'slug': 'kanagawa'});
    await core.call('themes.hide', {'slug': 'hackerman', 'hidden': true});
    await core.call('themes.hide', {'slug': 'nord', 'hidden': true});
    await core.call('themes.favorite', {'slug': 'tokyo-night', 'favorite': true});
    await core.call('auto.set_workspace_themes', {'slug': 'fireside', 'workspaces': [2, 5]});
    await core.call('auto.set_workspace_wallpaper', {'slug': 'kanagawa', 'name': '2-kanagawa.png', 'workspaces': [3]});
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) async {
    if (m == 'wallhaven.search') {
      return {
        'results': [
          for (var i = 0; i < 6; i++)
            {
              'id': 'abc$i',
              'page': 'https://wallhaven.cc/w/abc$i',
              'thumb': 'https://th.wallhaven.cc/small/ab/abc$i.jpg',
              'full': 'https://w.wallhaven.cc/full/ab/wallhaven-abc$i.jpg',
              'resolution': '2560x1440',
              'file_size': 1000,
              'file_name': 'wallhaven-abc$i.jpg',
              'added': i == 1,
            },
        ],
        'page': 1,
        'last_page': 1,
      };
    }
    if (m == 'wallhaven.thumb') return {'path': null};
    if (m == 'import.omarchy_list') {
      return {
        'themes': [
          for (final n in ['Aura', 'Bliss', 'Kanagawa', 'Matte Black'])
            {'slug': n.toLowerCase().replaceAll(' ', '-'), 'name': n, 'repo': 'https://github.com/x/$n', 'installed': n == 'Kanagawa'},
        ],
      };
    }
    if (m == 'import.omarchy_preview') return {'path': null};
    if (m == 'import.cosmic_list') return {'themes': <Map>[], 'next_page': null};
    if (m == 'info.plugins') return core.call(m, {'cached': true});
    if (m == 'ask.helpers') {
      return aiOn
          ? {
              'helpers': [
                {'id': 'claude', 'name': 'Claude Code', 'signed_in': true},
              ],
              'chosen': 'claude',
              'enabled': true,
            }
          : {'helpers': <Map>[], 'chosen': null, 'enabled': false};
    }
    if (m == 'ask.wallpapers') {
      return {'summary': 'Calm, wintry scenes in the theme\'s blues.', 'queries': ['snowy mountains night', 'winter forest', 'frozen lake']};
    }
    return core.call(m, p);
  }

  Future<void> settle(WidgetTester tester, [int ms = 400]) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(Duration(milliseconds: ms));
      });
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> shoot(WidgetTester tester, GlobalKey key, String name) async {
    if (shots == null) return;
    // Decode every picture on screen before taking the shot.
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        final image = e.widget as Image;
        try {
          await precacheImage(image.image, e).timeout(const Duration(seconds: 3));
        } catch (_) {
          debugPrint('no picture: ${image.image}');
        }
      }
    });
    await tester.pump();
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage().timeout(const Duration(seconds: 10));
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shots/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  for (final width in [700.0, 1300.0]) {
    testWidgets('pages like the plugin (width $width)', (tester) async {
      tester.view.physicalSize = Size(width, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      final w = width.round();
      await tester.runAsync(() async {
        await tester.pumpWidget(RepaintBoundary(key: key, child: MaprismaThemeApp(call: call)));
      });
      await settle(tester);
      expect(find.text('Maprisma Theme'), findsWidgets);
      await shoot(tester, key, 'themes-$w');
      expect(find.text('Kanagawa'), findsOneWidget);
      expect(find.text('current'), findsOneWidget);
      await tester.drag(find.byType(ListView).first, const Offset(0, -3000));
      await settle(tester, 100);
      expect(find.textContaining('2 hidden themes not shown. The eye button in the header shows them.'), findsOneWidget);
      await shoot(tester, key, 'themes-end-$w');
      await tester.drag(find.byType(ListView).first, const Offset(0, 3000));
      await settle(tester, 100);

      // Type to filter: the title shows the query.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await settle(tester, 100);
      expect(find.textContaining('— k'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 100);

      // The ⋮ menu of the current theme: the plugin's entries in its order.
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await settle(tester, 100);
      await shoot(tester, key, 'themes-menu-$w');
      for (final t in ['Wallpapers', 'Use on workspace…', 'New theme from this…', 'Shortcut…', 'Hide from list']) {
        expect(find.text(t), findsWidgets, reason: t);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester, 100);

      final app = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
      Future<void> open(Widget page, String name) async {
        // Pushed and first built outside the fake clock, so its pictures load.
        await tester.runAsync(() async {
          app.navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        });
        await settle(tester);
        await shoot(tester, key, '$name-$w');
        expect(tester.takeException(), isNull);
      }

      await open(const WallpapersPage(slug: 'kanagawa'), 'wallpapers');
      expect(find.text('Add wallpapers…'), findsOneWidget);
      expect(find.text('Search the web'), findsOneWidget);
      expect(find.text('Ask AI…'), findsNothing, reason: 'Ask AI is off: no AI feature');
      await open(const WallhavenPage(slug: 'kanagawa', themeName: 'Kanagawa', current: true), 'wallhaven');
      await tester.enterText(find.byType(TextField).first, 'misty forest');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      await shoot(tester, key, 'wallhaven-results-$w');
      app.navigator.currentState!.popUntil((r) => r.isFirst);
      await settle(tester, 100);
      await open(const ImportPage(), 'import');
      app.navigator.currentState!.popUntil((r) => r.isFirst);
      await open(const SettingsPage(), 'settings');
      expect(find.text('Find in Settings'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'work');
      await settle(tester, 100);
      expect(find.text('A wallpaper for each workspace'), findsOneWidget);
      await shoot(tester, key, 'settings-search-$w');
      app.navigator.currentState!.popUntil((r) => r.isFirst);
      await open(const InfoPage(), 'info');
      app.navigator.currentState!.popUntil((r) => r.isFirst);
      await settle(tester, 100);
    });
  }

  testWidgets('wallpapers: Ask AI only while it is on and a helper is ready', (tester) async {
    aiOn = true;
    tester.view.physicalSize = const Size(1300, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(RepaintBoundary(key: key, child: MaprismaThemeApp(call: call)));
    });
    await settle(tester);
    final app = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    Future<void> open(Widget page) async {
      await tester.runAsync(() async {
        app.navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      });
      await settle(tester);
    }

    await open(const WallpapersPage(slug: 'kanagawa'));
    expect(find.text('Ask AI…'), findsOneWidget);
    await shoot(tester, key, 'wallpapers-ai-1300');
    await open(const WallhavenPage(slug: 'kanagawa', themeName: 'Kanagawa', current: true, askAi: true));
    expect(find.text('Ask'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(1), 'calm and wintry');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    for (final q in ['snowy mountains night', 'winter forest', 'frozen lake']) {
      expect(find.widgetWithText(ActionChip, q), findsOneWidget, reason: q);
    }
    expect(find.text('snowy mountains night'), findsWidgets);
    await shoot(tester, key, 'wallhaven-ai-1300');
    expect(tester.takeException(), isNull);
  });
}
