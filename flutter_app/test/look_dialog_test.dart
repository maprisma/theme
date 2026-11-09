import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
      await tester.pumpWidget(RepaintBoundary(key: shot, child: MaprismaThemeApp(call: call)));
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
    expect(look['look'], {'mono_font': 'Fira Code', 'blur': {'on': true, 'strength': 8}});

    await tester.runAsync(() => core.call('themes.apply', {'slug': 'nord'}));
    expect(desktop.monospaceFont(), 'Fira Code');
    expect(desktop.blur['on'], isTrue);
  });

  testWidgets('a desktop without blur shows no blur row', (tester) async {
    root.deleteSync(recursive: true);
    root = Directory.systemTemp.createTempSync('maprisma-look-test-');
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '/usr/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory('${paths.systemThemes}/nord').createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    File('${paths.systemThemes}/nord/colors.toml').writeAsStringSync('background = "#2e3440"\nforeground = "#d8dee9"\n');
    core = CoreService(environment: env, paths: paths, desktop: FakeDesktop(caps: {Cap.appearance, Cap.fonts}));
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
