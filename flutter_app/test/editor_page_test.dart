import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/pages/editor_page.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

import 'page_shots.dart';

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
    File('${paths.systemThemes}/nord/colors.toml')
        .writeAsStringSync('background = "#2e3440"\nforeground = "#d8dee9"\naccent = "#81a1c1"\nred = "#bf616a"\n');
    // A wallpaper behind the sample in the screenshots (MAPRISMA_SHOT_WALLS).
    final wall = File('${Platform.environment['MAPRISMA_SHOT_WALLS']}/wall2.jpg');
    if (Platform.environment['MAPRISMA_SHOT_WALLS'] != null && wall.existsSync()) {
      wall.copySync('${paths.systemThemes}/nord/backgrounds/1-moon.jpg');
    }
    core = CoreService(environment: env, paths: paths, desktop: FakeDesktop());
  });
  tearDown(() => root.deleteSync(recursive: true));

  setUpAll(loadShotFonts);

  for (final width in [700.0, 1300.0]) {
    testWidgets('renders, edits a color and creates a theme (width $width)', (tester) async {
      tester.view.physicalSize = Size(width, 900);
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
      state.navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const EditorPage(base: 'nord', initial: {'accent': '#ff0000', 'name': 'Red Nord'}),
        ),
      );
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('New theme from Nord'), findsOneWidget);
      expect(find.text('Red Nord'), findsOneWidget);
      expect(find.text('#ff0000'), findsOneWidget);
      // The plugin's order: name, font, wallpapers, then one list of colors.
      expect(find.text('Name'), findsOneWidget);
      expect(find.text('Font'), findsOneWidget);
      expect(find.textContaining('Take over its wallpapers'), findsOneWidget);
      expect(find.text('Colors'), findsOneWidget);
      expect(find.text('Background'), findsOneWidget);
      expect(find.text('Create and apply'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (shotsDir != null) {
        Future<void> picture(String name) async {
          await tester.pump(const Duration(seconds: 1)); // route transitions over
          await tester.runAsync(() async {
            for (var i = 0; i < 4; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
              await tester.pump();
            }
            await saveShot(shot.currentContext!.findRenderObject()! as RenderRepaintBoundary, name);
          });
        }

        await picture('editor-${width.round()}');
        await tester.dragUntilVisible(
          find.text('More colors: shades and bright variants'),
          find.byType(ListView).last,
          const Offset(0, -200),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('More colors: shades and bright variants'));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView).last, const Offset(0, -400));
        await tester.pumpAndSettle();
        await picture('editor-more-${width.round()}');
      }
      await tester.tap(find.text('Create'));
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      });
      await tester.pump();
      expect(
        File('${core.ctx.paths.userThemes}/red-nord/colors.toml').readAsStringSync(),
        contains('accent = "#ff0000"'),
      );
    });
  }
}
