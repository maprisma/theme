import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/theme.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

/// F12 (as Maprisma Playground's shell_test): a private PNG in a private folder, the note dialog
/// (Done, Enter and Esc keep the note), no second dialog, no modifiers; Corners in three sizes.
void main() {
  late Directory root;
  late CoreService core;
  late String shots;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-theme-f12-');
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '/usr/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory(paths.systemThemes).createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    core = CoreService(environment: env, paths: paths, desktop: FakeDesktop());
    shots = '${root.path}/home/Shots';
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<String> files() => Directory(shots).existsSync()
      ? (Directory(shots).listSync().map((f) => f.uri.pathSegments.last).toList()..sort())
      : <String>[];

  Future<MaprismaThemeAppState> pump(WidgetTester tester, {bool key = true}) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await core.call('settings.set', {'key': 'screenshot_dir', 'value': shots});
      if (!key) await core.call('settings.set', {'key': 'screenshot_key', 'value': false});
      await tester.pumpWidget(MaprismaThemeApp(call: (m, [p = const {}]) => core.call(m, p)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
    return tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
  }

  Future<void> press(WidgetTester tester, {LogicalKeyboardKey? modifier}) async {
    await tester.runAsync(() async {
      if (modifier != null) await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.f12);
      if (modifier != null) await tester.sendKeyUpEvent(modifier);
      for (var i = 0; i < 50 && files().where((f) => f.endsWith('.png')).isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('F12 saves a private PNG, asks for a note and writes it beside the picture', (tester) async {
    await pump(tester);
    await press(tester);
    final saved = files();
    expect(saved, hasLength(1));
    expect(saved.single, matches(RegExp(r'^maprisma-theme-\d{4}-\d\d-\d\d-\d\d-\d\d-\d\d\.png$')));
    final png = File('$shots/${saved.single}');
    expect(png.readAsBytesSync().take(4), [0x89, 0x50, 0x4e, 0x47]);
    expect(FileStat.statSync(png.path).mode & 0x1ff, 0x180);
    expect(FileStat.statSync(shots).mode & 0x1ff, 0x1c0);
    expect(find.text('Screenshot saved'), findsOneWidget);
    expect(find.textContaining('Saved as '), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('screenshot-note')), 'The gear is cut off');
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(files(), [saved.single, saved.single.replaceFirst('.png', '.txt')]);
    expect(File('$shots/${saved.single.replaceFirst('.png', '.txt')}').readAsStringSync(), 'The gear is cut off\n');
  });

  testWidgets('F12 while the note is asked for opens no second dialog; Esc keeps the note', (tester) async {
    await pump(tester);
    await press(tester);
    await tester.enterText(find.byKey(const ValueKey('screenshot-note')), 'Twice?');
    await press(tester);
    expect(find.text('Screenshot saved'), findsOneWidget);
    expect(files(), hasLength(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.text('Screenshot saved'), findsNothing);
    expect(files(), hasLength(2));
    expect(File('$shots/${files().last}').readAsStringSync(), 'Twice?\n');
  });

  testWidgets('no note, no .txt; F12 with a modifier saves nothing', (tester) async {
    await pump(tester);
    await press(tester);
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(files(), hasLength(1));
    for (final m in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await press(tester, modifier: m);
      expect(find.text('Screenshot saved'), findsNothing);
    }
    expect(files(), hasLength(1));
  });

  testWidgets('a switched-off key saves nothing', (tester) async {
    await pump(tester, key: false);
    await press(tester);
    expect(files(), isEmpty);
    expect(find.text('Screenshot saved'), findsNothing);
  });

  test('corners: slight is 6; the sizes follow the radius; Square squares all', () {
    expect(cornerRadius('slight', 20), 6);
    expect(cornerRadius('rounded', null), 12);
    expect(cornerRadius('square', 10), 0);
    expect(cornerRadius('windows', 10), 10);
    expect(cornerRadius('windows', null), 12);
    const big = Corners(14), square = Corners(0), slight = Corners(6);
    expect([big.radius, big.control, big.small], [14, 8, 4]);
    expect([slight.control, slight.small], [6, 4]);
    expect([square.radius, square.control, square.small], [0, 0, 0]);
  });

  test('every control takes its corner size; Square keeps a small square knob', () {
    final t = appTheme(Brightness.dark, const {}, 12);
    BorderRadius of(OutlinedBorder? shape) => (shape! as RoundedRectangleBorder).borderRadius as BorderRadius;
    expect(of(t.outlinedButtonTheme.style!.shape!.resolve({})), BorderRadius.circular(8));
    expect(of(t.textButtonTheme.style!.shape!.resolve({})), BorderRadius.circular(8));
    expect(of(t.filledButtonTheme.style!.shape!.resolve({})), BorderRadius.circular(8));
    expect(of(t.iconButtonTheme.style!.shape!.resolve({})), BorderRadius.circular(8));
    expect((t.inputDecorationTheme.border! as OutlineInputBorder).borderRadius, BorderRadius.circular(8));
    expect((t.tooltipTheme.decoration! as BoxDecoration).borderRadius, BorderRadius.circular(8));
    expect(of(t.checkboxTheme.shape), BorderRadius.circular(4));
    expect(t.progressIndicatorTheme.borderRadius, BorderRadius.circular(4));
    expect(of(t.dialogTheme.shape! as OutlinedBorder), BorderRadius.circular(12));
    expect(of(t.popupMenuTheme.shape! as OutlinedBorder), BorderRadius.circular(12));
    expect(of(t.cardTheme.shape! as OutlinedBorder), BorderRadius.circular(12));
    expect((t.sliderTheme.thumbShape! as KnobShape).square, isFalse);
    final sq = appTheme(Brightness.dark, const {}, 0);
    expect((sq.sliderTheme.thumbShape! as KnobShape).square, isTrue);
    expect(sq.sliderTheme.thumbShape!.getPreferredSize(true, false), const Size.square(14));
    expect(of(sq.outlinedButtonTheme.style!.shape!.resolve({})), BorderRadius.zero);
  });
}
