import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/pages/ask_page.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

/// The Ask AI page against the real core in a temporary HOME; the helper
/// list and the answer are faked (no agent ever runs).
void main() {
  late Directory root;
  late CoreService core;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-ask-page-test-');
    Directory('${root.path}/bin').createSync();
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '${root.path}/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory('${paths.systemThemes}/nord/backgrounds').createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    File('${paths.systemThemes}/nord/colors.toml')
        .writeAsStringSync('background = "#2e3440"\nforeground = "#d8dee9"\naccent = "#81a1c1"\nred = "#bf616a"\n');
    core = CoreService(environment: env, paths: paths, desktop: FakeDesktop());
  });
  tearDown(() => root.deleteSync(recursive: true));

  for (final width in [700.0, 1200.0]) {
    testWidgets('off state, turn on, ask, cards (width $width)', (tester) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final asked = <Map<String, dynamic>>[];
      Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) async {
        if (m == 'ask.helpers') {
          final real = await core.call(m, p);
          return {
            ...real,
            'helpers': [
              {
                'id': 'claude',
                'name': 'Claude Code',
                'installed': true,
                'signed_in': true,
                'local': false,
                'login': '',
              },
            ],
            'chosen': 'claude',
          };
        }
        if (m == 'ask.run') {
          asked.add(p);
          return {
            'summary': 'Two ideas',
            'candidates': [
              {
                'kind': 'custom',
                'mode': 'new',
                'theme': 'nord',
                'base_name': 'Nord',
                'name': 'Deep Sea',
                'colors': {'background': '#102030', 'foreground': '#e0e0e0', 'accent': '#3366ff', 'red': '#ff0000'},
                'changes': {'background': '#102030'},
                'font': 'Fira Code',
                'wallpaper_query': 'ocean night',
                'summary': 'Calm and blue',
              },
              {'kind': 'catalog', 'theme': 'kanagawa-paper', 'name': 'Kanagawa Paper', 'summary': 'Warm'},
            ],
          };
        }
        return core.call(m, p);
      }

      await tester.runAsync(() async {
        await tester.pumpWidget(MaprismaThemeApp(call: call));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
      state.navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const AskPage()));
      Future<void> settle() async {
        await tester.runAsync(() async {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump(const Duration(seconds: 1));
      }

      await settle();
      expect(find.text('Turn Ask AI on'), findsOneWidget);
      await tester.tap(find.text('Turn Ask AI on'));
      await settle();
      await settle();
      expect(find.text('Helper:'), findsOneWidget);
      expect(find.text('A calm light theme for daytime'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'something blue');
      await tester.tap(find.text('Ask'));
      await settle();
      await settle();
      expect(asked.single['request'], 'something blue');
      expect(find.text('Deep Sea'), findsOneWidget);
      expect(find.text('Kanagawa Paper'), findsOneWidget);
      expect(find.text('Fira Code'), findsOneWidget);
      expect(find.text('Use'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Not this').last);
      await tester.pump();
      await tester.tap(find.text('Not this').last);
      await settle();
      expect(find.text('Kanagawa Paper'), findsNothing);
    });
  }
}
