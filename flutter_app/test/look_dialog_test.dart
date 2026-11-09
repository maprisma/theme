import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/pages/look_dialog.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

import 'page_shots.dart';

/// Font & effects against the real core in a temporary HOME (FakeDesktop).
void main() {
  late Directory root;
  late CoreService core;
  late FakeDesktop desktop;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-look-test-');
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '/usr/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory('${paths.systemThemes}/nord/backgrounds').createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    File('${paths.systemThemes}/nord/colors.toml')
        .writeAsStringSync('background = "#2e3440"\nforeground = "#d8dee9"\naccent = "#81a1c1"\nred = "#bf616a"\n');
    desktop = FakeDesktop();
    core = CoreService(environment: env, paths: paths, desktop: desktop);
  });
  tearDown(() => root.deleteSync(recursive: true));

  setUpAll(loadShotFonts);

  /// Real time for the core's file I/O, then the test clock for animations.
  Future<void> settle(WidgetTester tester, [int ms = 200]) async {
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('fonts and blur for a system theme, saved and applied with the theme', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => core.call(m, p);
    final shot = GlobalKey();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: shot,
          child: MaprismaThemeApp(call: call),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    lookDialog(state.navigator.currentContext!, state, 'nord');
    await settle(tester, 300);

    expect(find.textContaining('Font & effects · '), findsOneWidget);
    expect(find.text('Monospace font'), findsOneWidget);
    expect(find.text('Interface font'), findsOneWidget);
    expect(find.text('Blur'), findsOneWidget);
    expect(find.textContaining('Theme default (desktop font)'), findsWidgets);

    await tester.tap(find.text('On'));
    await settle(tester);
    expect(find.byKey(const ValueKey('look-strength')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('look-mono_font')));
    await settle(tester);
    await tester.tap(find.text('Fira Code').last);
    await settle(tester);
    await tester.runAsync(() async {
      await saveShot(shot.currentContext!.findRenderObject()! as RenderRepaintBoundary, 'look-dialog');
    });

    await tester.tap(find.byKey(const ValueKey('look-save')));
    for (var i = 0; i < 6; i++) {
      await settle(tester, 300); // the save runs through the core's lock
    }
    expect(find.text('Font & effects saved for Nord'), findsOneWidget);
    // real file I/O: outside the test's fake clock
    final look = (await tester.runAsync(() => core.call('looks.get', {'slug': 'nord'})))!;
    expect(look['look'], {
      'mono_font': 'Fira Code',
      'blur': {'on': true, 'strength': 8},
    });

    await tester.runAsync(() => core.call('themes.apply', {'slug': 'nord'}));
    expect(desktop.monospaceFont(), 'Fira Code');
    expect(desktop.blur['on'], isTrue);
  });

  testWidgets('Esc after picking a font cancels; a failed save keeps the dialog and its edits', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var failNext = true, sets = 0;
    Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) async {
      if (m == 'looks.set') {
        sets++;
        if (failNext) {
          failNext = false;
          throw RouteError('failed', 'disk full');
        }
      }
      return core.call(m, p);
    }

    await tester.runAsync(() async {
      await tester.pumpWidget(MaprismaThemeApp(call: call));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    lookDialog(state.navigator.currentContext!, state, 'nord');
    await settle(tester, 300);
    await tester.tap(find.byKey(const ValueKey('look-mono_font')));
    await settle(tester);
    await tester.tap(find.text('Fira Code').last);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.textContaining('Font & effects · '), findsNothing);
    expect(sets, 0);

    lookDialog(state.navigator.currentContext!, state, 'nord');
    await settle(tester, 300);
    await tester.tap(find.text('On'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('look-save')));
    for (var i = 0; i < 4; i++) {
      await settle(tester, 200);
    }
    expect(sets, 1);
    expect(find.textContaining('Font & effects · '), findsOneWidget); // still open
    expect(find.byKey(const ValueKey('look-strength')), findsOneWidget); // blur still on
    await tester.tap(find.byKey(const ValueKey('look-save')));
    for (var i = 0; i < 6; i++) {
      await settle(tester, 300);
    }
    expect(find.textContaining('Font & effects · '), findsNothing);
    final look = (await tester.runAsync(() => core.call('looks.get', {'slug': 'nord'})))!;
    expect(look['look'], {
      'blur': {'on': true, 'strength': 8},
    });
    // the core's apply lock is one queue for the whole test run: end on a call in real time
    await tester.runAsync(() => core.call('looks.set', {'slug': 'nord', 'look': {}}));
  });

  testWidgets('a saved font no longer installed is shown as such and kept', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    File(core.ctx.paths.file('looks.json')).writeAsStringSync('{"nord": {"mono_font": "Fira Code"}}');
    desktop.fonts = ['JetBrains Mono'];
    Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) async {
      return core.call(m, p);
    }

    await tester.runAsync(() async {
      await tester.pumpWidget(MaprismaThemeApp(call: call));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    lookDialog(state.navigator.currentContext!, state, 'nord');
    await settle(tester, 300);
    expect(find.text('Fira Code (not installed)'), findsWidgets);
    await tester.tap(find.text('Off'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('look-save')));
    for (var i = 0; i < 6; i++) {
      await settle(tester, 300);
    }
    final look = (await tester.runAsync(() => core.call('looks.get', {'slug': 'nord'})))!;
    expect(look['look'], {
      'mono_font': 'Fira Code',
      'blur': {'on': false, 'strength': 8},
    });
    // the core's apply lock is one queue for the whole test run: end on a call in real time
    await tester.runAsync(() => core.call('looks.set', {'slug': 'nord', 'look': {}, 'restore': true, 'apply': false}));
  });

  testWidgets('one Apply button: enabled after a change; the theme in use gets it at once', (tester) async {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => core.call('themes.apply', {'slug': 'nord'}));
    Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => core.call(m, p);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaprismaThemeApp(call: call));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    FilledButton apply() => tester.widget<FilledButton>(find.byKey(const ValueKey('look-save')));

    lookDialog(state.navigator.currentContext!, state, 'nord');
    await settle(tester, 300);
    expect(find.text('Reapply'), findsNothing); // one button (2026-11-09)
    expect(find.text('Save'), findsNothing);
    expect(find.text('Apply'), findsOneWidget);
    expect(apply().onPressed, isNull); // nothing changed
    await tester.tap(find.text('On'));
    await settle(tester);
    expect(apply().onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('look-save')));
    for (var i = 0; i < 6; i++) {
      await settle(tester, 300);
    }
    expect(find.text('Font & effects saved and applied'), findsOneWidget);
    expect(desktop.blur['on'], isTrue); // stored and applied at once
    final list = (await tester.runAsync(() => core.call('themes.list')))!;
    expect(((list['themes'] as List).firstWhere((t) => t['slug'] == 'nord') as Map)['pending'], isEmpty);
    await tester.runAsync(() => core.call('looks.set', {'slug': 'nord', 'look': {}}));
  });

  testWidgets('a desktop without blur shows no blur row', (tester) async {
    root.deleteSync(recursive: true);
    root = Directory.systemTemp.createTempSync('maprisma-look-test-');
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '/usr/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory('${paths.systemThemes}/nord').createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    File('${paths.systemThemes}/nord/colors.toml').writeAsStringSync('background = "#2e3440"\nforeground = "#d8dee9"\n');
    core = CoreService(
      environment: env,
      paths: paths,
      desktop: FakeDesktop(caps: {Cap.appearance, Cap.fonts}),
    );
    Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => core.call(m, p);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaprismaThemeApp(call: call));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    lookDialog(state.navigator.currentContext!, state, 'nord');
    await settle(tester, 300);
    expect(find.text('Monospace font'), findsOneWidget);
    expect(find.text('Interface font'), findsNothing);
    expect(find.text('Blur'), findsNothing);
  });
}
