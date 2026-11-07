import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/pages/editor_page.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

/// The editor against the real core in a temporary HOME (FakeDesktop).
void main() {
  late Directory root;
  late CoreService core;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-editor-test-');
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '/usr/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory('${paths.systemThemes}/nord/backgrounds').createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    File('${paths.systemThemes}/nord/colors.toml').writeAsStringSync(
        'background = "#2e3440"\nforeground = "#d8dee9"\naccent = "#81a1c1"\nred = "#bf616a"\n');
    core = CoreService(environment: env, paths: paths, desktop: FakeDesktop());
  });
  tearDown(() => root.deleteSync(recursive: true));

  for (final width in [700.0, 1200.0]) {
    testWidgets('renders, edits a color and creates a theme (width $width)', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => core.call(m, p);
      await tester.runAsync(() async {
        await tester.pumpWidget(MaprismaThemeApp(call: call));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
      state.navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const EditorPage(base: 'nord', initial: {'accent': '#ff0000', 'name': 'Red Nord'})));
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('New theme from Nord'), findsOneWidget);
      expect(find.text('Red Nord'), findsOneWidget);
      expect(find.text('#ff0000'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Create'));
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      });
      await tester.pump();
      expect(File('${core.ctx.paths.userThemes}/red-nord/colors.toml').readAsStringSync(), contains('accent = "#ff0000"'));
    });
  }
}
