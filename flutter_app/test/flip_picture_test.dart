import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/flip_picture.dart';
import 'package:maprisma_theme/pages/settings_page.dart';
import 'package:maprisma_theme/pages/themes_page.dart';
import 'package:maprisma_theme/pages/wallpapers_page.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

import 'page_shots.dart';

Future<void> _paintPng(String path, Color bg, Color accent, {bool wallpaper = false}) async {
  const w = 320, h = 180;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = bg);
  if (wallpaper) {
    c.drawCircle(const Offset(230, 62), 42, Paint()..color = accent.withValues(alpha: .55));
    final hills = Path()
      ..moveTo(0, h.toDouble())
      ..lineTo(0, 120)
      ..lineTo(100, 78)
      ..lineTo(205, 128)
      ..lineTo(w.toDouble(), 88)
      ..lineTo(w.toDouble(), h.toDouble())
      ..close();
    c.drawPath(hills, Paint()..color = Color.lerp(bg, accent, .28)!);
  } else {
    c.drawRect(const Rect.fromLTWH(14, 14, 175, 152), Paint()..color = Color.lerp(bg, Colors.white, .08)!);
    c.drawRect(
      const Rect.fromLTWH(14, 14, 175, 152),
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    c.drawRect(const Rect.fromLTWH(198, 14, 108, 72), Paint()..color = Color.lerp(bg, Colors.white, .08)!);
    c.drawRect(const Rect.fromLTWH(198, 94, 108, 72), Paint()..color = Color.lerp(bg, Colors.white, .08)!);
  }
  final img = await rec.endRecording().toImage(w, h);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes!.buffer.asUint8List());
}

Color _hex(String s) => Color(0xff000000 | int.parse(s.substring(1), radix: 16));

void main() {
  late Directory root;
  late CoreService core;

  setUpAll(loadShotFonts);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('maprisma-flip-ui-');
    final env = {
      'HOME': '${root.path}/home',
      'XDG_RUNTIME_DIR': '${root.path}/run',
      'PATH': '/usr/bin',
    };
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory(paths.templates).createSync(recursive: true);
    for (final (slug, bg, accent) in [
      ('kanagawa', '#1f1f28', '#7e9cd8'),
      ('fireside', '#1d1714', '#e07a3f'),
    ]) {
      final dir = '${paths.systemThemes}/$slug';
      Directory('$dir/backgrounds').createSync(recursive: true);
      File('$dir/colors.toml').writeAsStringSync(
        'background = "$bg"\nforeground = "#e6e6e6"\naccent = "$accent"\ngreen = "#98c379"\n',
      );
      await _paintPng('$dir/preview.png', _hex(bg), _hex(accent));
      for (var i = 1; i <= 3; i++) {
        await _paintPng(
          '$dir/backgrounds/$i-$slug.png',
          Color.lerp(_hex(bg), _hex(accent), i * .15)!,
          _hex(accent),
          wallpaper: true,
        );
      }
    }
    core = CoreService(environment: env, paths: paths, desktop: FakeDesktop());
    await core.call('themes.apply', {'slug': 'kanagawa'});
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<GlobalKey> pumpInitial(WidgetTester tester) async {
    tester.view.physicalSize = const Size(980, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(RepaintBoundary(key: key, child: MaprismaThemeApp(call: core.call)));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();
    return key;
  }

  Future<void> shoot(WidgetTester tester, GlobalKey key, String name) async {
    if (shotsDir == null) return;
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        try {
          await precacheImage((e.widget as Image).image, e).timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    });
    await tester.pump();
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await saveShot(boundary, name);
    });
  }

  FlipPictureState flipOf(WidgetTester tester, String slug) =>
      tester.state<FlipPictureState>(find.byKey(ValueKey('flip-$slug')));

  testWidgets('1 s delay shows subtle ~16° 3D hint then flips to wallpaper with < / > preview+wallpaper cycle', (
    tester,
  ) async {
    await tester.runAsync(() => core.call('settings.set', {'key': 'preview_flip_delay', 'value': 1})); // 2 s by default
    final shotKey = await pumpInitial(tester);
    final kanagawa = flipOf(tester, 'kanagawa');
    expect(kanagawa.visibleFace, -1);
    expect(find.byKey(const ValueKey('flip-prev-kanagawa')), findsNothing);
    expect(find.byKey(const ValueKey('flip-pin-kanagawa')), findsNothing);

    // At ~300 ms (after 70 ms skim guard, before 1000 ms rotation): ~16° 3D hint on preview.
    await tester.pump(const Duration(milliseconds: 80));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(kanagawa.visibleFace, -1);
    expect(kanagawa.currentAngleDegrees, greaterThan(12.0));
    expect(kanagawa.currentAngleDegrees, lessThan(20.0));
    expect(find.byKey(const ValueKey('flip-pin-kanagawa')), findsNothing);
    await shoot(tester, shotKey, 'flip-hint');

    // Finish the 1 s delay + 0.42 s flip -> lands on wallpaper 0 (pinned).
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(kanagawa.visibleFace, 0);
    await shoot(tester, shotKey, 'flip-wallpaper');
    expect(kanagawa.isCurrentWallpaperPinned, isTrue);
    expect(find.byKey(const ValueKey('flip-pin-kanagawa')), findsOneWidget);
    expect(find.byKey(const ValueKey('flip-prev-kanagawa')), findsOneWidget);
    expect(find.byKey(const ValueKey('flip-next-kanagawa')), findsOneWidget);
    expect(
      tester.widget<Tooltip>(find.descendant(of: find.byKey(const ValueKey('flip-pin-kanagawa')), matching: find.byType(Tooltip))).message,
      'Current background (1/3)',
    );
    expect(
      tester.widget<Tooltip>(find.descendant(of: find.byKey(const ValueKey('flip-prev-kanagawa')), matching: find.byType(Tooltip))).message,
      'Preview',
    );

    // Cycle forward through wallpapers 0 -> 1 -> 2 -> original preview (-1).
    await tester.tap(find.byKey(const ValueKey('flip-next-kanagawa')));
    await tester.pumpAndSettle();
    expect(kanagawa.visibleFace, 1);
    expect(kanagawa.isCurrentWallpaperPinned, isFalse);

    await tester.tap(find.byKey(const ValueKey('flip-next-kanagawa')));
    await tester.pumpAndSettle();
    expect(kanagawa.visibleFace, 2);
    expect(
      tester.widget<Tooltip>(find.descendant(of: find.byKey(const ValueKey('flip-next-kanagawa')), matching: find.byType(Tooltip))).message,
      'Preview',
    );

    await tester.tap(find.byKey(const ValueKey('flip-next-kanagawa')));
    await tester.pumpAndSettle();
    expect(kanagawa.visibleFace, -1);
    // On original preview (-1), < and > remain visible while pin is hidden!
    expect(find.byKey(const ValueKey('flip-prev-kanagawa')), findsOneWidget);
    expect(find.byKey(const ValueKey('flip-next-kanagawa')), findsOneWidget);
    expect(find.byKey(const ValueKey('flip-pin-kanagawa')), findsNothing);

    // Cycle backward from preview (-1) wraps to last wallpaper (2).
    await tester.tap(find.byKey(const ValueKey('flip-prev-kanagawa')));
    await tester.pumpAndSettle();
    expect(kanagawa.visibleFace, 2);
  });

  testWidgets('0 s delay keeps original preview and immediately shows < and > arrows on selected theme', (
    tester,
  ) async {
    await core.call('settings.set', {'key': 'preview_flip_delay', 'value': 0});
    final shotKey = await pumpInitial(tester);
    await tester.pumpAndSettle();
    await shoot(tester, shotKey, 'flip-zero-delay');

    final kanagawa = flipOf(tester, 'kanagawa');
    expect(kanagawa.visibleFace, -1);
    expect(kanagawa.currentAngleDegrees, 0.0);
    expect(find.byKey(const ValueKey('flip-prev-kanagawa')), findsOneWidget);
    expect(find.byKey(const ValueKey('flip-next-kanagawa')), findsOneWidget);
    expect(find.byKey(const ValueKey('flip-pin-kanagawa')), findsNothing);

    // Manual rotation starts only when clicking < or >.
    await tester.tap(find.byKey(const ValueKey('flip-next-kanagawa')));
    await tester.pumpAndSettle();
    expect(kanagawa.visibleFace, 0);
    expect(find.byKey(const ValueKey('flip-pin-kanagawa')), findsOneWidget);
  });

  testWidgets('pinning on active theme vs non-active theme with preview_pin_apply_theme off and on', (
    tester,
  ) async {
    await core.call('settings.set', {'key': 'preview_flip_delay', 'value': 0});
    await core.call('settings.set', {'key': 'preview_pin_apply_theme', 'value': false});
    final shotKey = await pumpInitial(tester);
    await tester.pumpAndSettle();

    // 1. Active theme (kanagawa): pin wallpaper 2 -> sets active desktop wallpaper without opening WallpapersPage.
    await tester.tap(find.byKey(const ValueKey('flip-next-kanagawa')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flip-next-kanagawa')));
    await tester.pumpAndSettle();
    final kanagawa = flipOf(tester, 'kanagawa');
    expect(kanagawa.visibleFace, 1);
    expect(kanagawa.isCurrentWallpaperPinned, isFalse);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('flip-pin-kanagawa')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byType(WallpapersPage), findsNothing);
    expect(kanagawa.isCurrentWallpaperPinned, isTrue);
    expect(core.ctx.current.wallpaper, endsWith('/2-kanagawa.png'));

    // 2. Select non-active theme (fireside) with preview_pin_apply_theme == false:
    //    pinning saves wallpaper as current for fireside ONLY without switching active theme.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(kanagawa.visibleFace, -1); // kanagawa closed back to preview!

    final fireside = flipOf(tester, 'fireside');
    await tester.tap(find.byKey(const ValueKey('flip-next-fireside')));
    await tester.pumpAndSettle();
    expect(fireside.visibleFace, 0);
    // Nothing remembered for fireside yet: its first wallpaper is not shown as pinned.
    expect(fireside.isCurrentWallpaperPinned, isFalse);
    expect(
      tester.widget<Tooltip>(find.descendant(of: find.byKey(const ValueKey('flip-pin-fireside')), matching: find.byType(Tooltip))).message,
      'Set as wallpaper for this theme (1/3)',
    );

    await tester.tap(find.byKey(const ValueKey('flip-next-fireside')));
    await tester.pumpAndSettle();
    expect(fireside.visibleFace, 1);
    expect(fireside.isCurrentWallpaperPinned, isFalse);
    expect(
      tester.widget<Tooltip>(find.descendant(of: find.byKey(const ValueKey('flip-pin-fireside')), matching: find.byType(Tooltip))).message,
      'Set as wallpaper for this theme (2/3)',
    );

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('flip-pin-fireside')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(core.ctx.current.slug, 'kanagawa'); // active theme unchanged!
    expect(chosenWallpapers(core.ctx)['fireside'], '2-fireside.png');
    expect(fireside.isCurrentWallpaperPinned, isTrue);

    // 3. Re-enable preview_pin_apply_theme in Settings and pin on fireside -> applies fireside immediately!
    final app = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    await tester.runAsync(() async {
      app.openPage('settings');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    await tester.tap(find.text('Themes'));
    await tester.pumpAndSettle();
    expect(find.text('3D flip to wallpaper on hover'), findsOneWidget);
    expect(find.text('3D rotation delay'), findsOneWidget);
    expect(find.text('Apply theme when pinning wallpaper'), findsOneWidget);
    await shoot(tester, shotKey, 'flip-settings');

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('setting-preview-pin-apply-theme')));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    app.navigator.currentState!.pop();
    await tester.pumpAndSettle();

    final firesideAfter = flipOf(tester, 'fireside');
    expect(firesideAfter.visibleFace, -1);
    await tester.tap(find.byKey(const ValueKey('flip-next-fireside')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flip-next-fireside')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Tooltip>(find.descendant(of: find.byKey(const ValueKey('flip-pin-fireside')), matching: find.byType(Tooltip))).message,
      'Apply theme with this wallpaper (2/3)',
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('flip-pin-fireside')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(core.ctx.current.slug, 'fireside');
    expect(core.ctx.current.wallpaper, endsWith('/3-fireside.png'));
  });

  testWidgets('big preview Apply pins the wallpaper rotated to, then stays for another one', (tester) async {
    await tester.runAsync(() async {
      await core.call('settings.set', {'key': 'preview_flip_delay', 'value': 0});
      await core.call('settings.set', {'key': 'preview_pin_apply_theme', 'value': false}); // Apply pins anyway
    });
    await pumpInitial(tester);
    await tester.pumpAndSettle();
    final page = tester.state(find.byType(ThemesPage)) as dynamic;
    page.openBig('fireside');
    await tester.pumpAndSettle();
    FlipPictureState big() =>
        tester.state<FlipPictureState>(find.byWidgetPredicate((w) => w is FlipPicture && w.key is GlobalKey));
    ButtonStyleButton apply() => tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('big-apply')));
    expect(apply().onPressed, isNotNull); // another theme: always applicable
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(big().visibleFace, 1);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('big-apply')));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    expect(core.ctx.current.slug, 'fireside');
    expect(core.ctx.current.wallpaper, endsWith('/2-fireside.png'));
    expect(page.bigSlug, 'fireside');
    // Now in use: the shown wallpaper is the desktop's, nothing to apply …
    expect(big().isCurrentWallpaperPinned, isTrue);
    expect(apply().onPressed, isNull);
    // … until it is rotated further.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(big().isCurrentWallpaperPinned, isFalse);
    expect(apply().onPressed, isNotNull);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('big-apply')));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    expect(core.ctx.current.slug, 'fireside');
    expect(core.ctx.current.wallpaper, isNot(endsWith('/2-fireside.png')));
    expect(big().isCurrentWallpaperPinned, isTrue);
    expect(apply().onPressed, isNull);
  });

  testWidgets('click opens the big preview: it has the keys, 0 s stays arrows only, Esc closes it first', (tester) async {
    await tester.runAsync(() => core.call('settings.set', {'key': 'preview_flip_delay', 'value': 0}));
    await pumpInitial(tester);
    await tester.pumpAndSettle();
    final page = tester.state(find.byType(ThemesPage)) as dynamic;
    page.openBig('fireside');
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close preview (Esc)'), findsOneWidget);
    expect(page.bigSlug, 'fireside');
    // typing does not filter the list behind it
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pumpAndSettle();
    expect(page.filter, '');
    expect(page.bigSlug, 'fireside');
    // 0 s: no turn by itself, arrows turn it
    final big = tester.state<FlipPictureState>(find.byWidgetPredicate((w) => w is FlipPicture && w.key is GlobalKey));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(big.visibleFace, -1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(big.visibleFace, 0);
    // Tab goes round the preview's own buttons, never to the list or the header behind it
    final closeButton = find.byTooltip('Close preview (Esc)');
    final scope = find.ancestor(of: closeButton, matching: find.byType(FocusScope)).first;
    final scopeNode = FocusScope.of(tester.element(closeButton));
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus;
      expect(focused == scopeNode || (focused?.ancestors.contains(scopeNode) ?? false), isTrue);
    }
    expect(scope, findsOneWidget);
    // Backspace (and Esc) close the preview before anything else
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(page.bigSlug, isNull);
    expect(find.byTooltip('Close preview (Esc)'), findsNothing);
  });
}
