import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/pages/ask_page.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

import 'page_shots.dart';

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

  // Pictures for the screenshots only (MAPRISMA_SHOT_WALLS: a folder with
  // wall1.jpg…); without them the cards show their colors, as offline.
  final walls = Platform.environment['MAPRISMA_SHOT_WALLS'];
  String? wall(int i) {
    final path = '$walls/wall$i.jpg';
    return walls != null && File(path).existsSync() ? path : null;
  }

  setUpAll(loadShotFonts);

  for (final width in [700.0, 1300.0]) {
    testWidgets('off state, turn on, ask, cards (width $width)', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
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
                'id': 'pi:gemma',
                'name': 'pi · gemma-4-26B-A4B-it-UD-Q4_K_M',
                'installed': true,
                'signed_in': true,
                'local': true,
                'login': '',
              },
              {
                'id': 'claude',
                'name': 'Claude Code',
                'installed': true,
                'signed_in': true,
                'local': false,
                'login': '',
              },
            ],
            'chosen': 'pi:gemma',
          };
        }
        if (m == 'ask.run') {
          asked.add(p);
          return {
            'summary': 'Here are a few calm, forest-inspired theme options with misty mountain wallpapers.',
            'candidates': [
              {
                'kind': 'catalog',
                'theme': 'forest-green',
                'name': 'Forest Green',
                'wallpaper_query': 'misty mountain forest',
                'summary': 'Uses a pre-made forest green theme from the catalog.',
              },
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
              {
                'kind': 'custom',
                'mode': 'edit',
                'theme': 'nord',
                'base_name': 'Nord',
                'name': 'Nord',
                'colors': {
                  'background': '#1d2b26',
                  'foreground': '#e3efe7',
                  'accent': '#7fc8a9',
                  'red': '#e07a7a',
                  'yellow': '#d6c97a',
                  'orange': '#dba070',
                  'green': '#7fc8a9',
                  'cyan': '#6fb7b7',
                  'blue': '#7aa7c7',
                  'magenta': '#b39ddb',
                  'brown': '#9a8f6a',
                },
                'changes': {'background': '#1d2b26'},
                'font': 'JetBrainsMono Nerd Font',
                'wallpaper_query': 'misty mountain range',
                'summary': 'Updates the Nord theme with a more modern font.',
              },
            ],
          };
        }
        // No network in tests: the web routes answer empty.
        if (m == 'wallhaven.search') {
          final query = '${p['query']}';
          final at = query.contains('forest') ? 1 : (query.contains('range') ? 3 : 2);
          return {
            'results': [
              for (var i = 0; i < (wall(at) == null ? 0 : 24); i++)
                {'id': '$query-$i', 'thumb_path': wall(1 + (at + i - 1) % 3)},
            ],
            'page': 1,
            'last_page': 1,
          };
        }
        if (m == 'wallhaven.thumb') return {'path': null};
        if (m == 'import.omarchy_preview') return {'path': wall(3)};
        if (m == 'import.omarchy_list') return {'themes': <Map>[]};
        return core.call(m, p);
      }

      final shot = GlobalKey();
      Future<void> picture(String name) async {
        if (shotsDir == null) return;
        await tester.pump(const Duration(seconds: 1)); // route transitions over
        await tester.runAsync(() async {
          // Image.file decodes off the test clock: let it finish, then draw.
          for (var i = 0; i < 4; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            await tester.pump();
          }
          await saveShot(shot.currentContext!.findRenderObject()! as RenderRepaintBoundary, name);
        });
      }

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
      await picture('ask-off-${width.round()}');
      await tester.tap(find.text('Turn Ask AI on'));
      await settle();
      await settle();
      expect(find.text('Helper:'), findsOneWidget);
      expect(find.text('A calm light theme for daytime'), findsOneWidget);
      expect(find.text('pi · gemma-4-26B-A4B-it-UD-Q4_K_M · on this PC'), findsOneWidget);
      expect(find.text('On this PC: no tokens, nothing leaves it. Enter asks.'), findsOneWidget);
      // The suggestions: ✎ edits one in place, Save (or Enter) ends it.
      await tester.tap(find.byTooltip('Edit suggestion').first);
      await tester.pump();
      expect(find.byTooltip('Save'), findsOneWidget);
      await tester.tap(find.byTooltip('Save'));
      await settle();
      expect(find.byTooltip('Save'), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'A calm forest green theme with a misty mountain wallpaper');
      await tester.tap(find.text('Ask'));
      await settle();
      await settle();
      expect(asked.single['request'], 'A calm forest green theme with a misty mountain wallpaper');
      expect(find.text('Deep Sea'), findsOneWidget);
      expect(find.text('Fira Code'), findsOneWidget);
      expect(find.text('Use'), findsNWidgets(3));
      expect(find.text('Edit Nord'), findsOneWidget);
      expect(find.text('From omarchy.org'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await settle();
      await picture('ask-results-${width.round()}');
      if (wall(1) != null) {
        expect(find.text('“misty mountain forest” · 1/24'), findsOneWidget);
        await tester.tap(find.byTooltip('Next wallpaper').first);
        await tester.pump();
        expect(find.text('“misty mountain forest” · 2/24'), findsOneWidget);
      }
      // Refine… opens its field on that card, Wallpaper… its own search.
      await tester.ensureVisible(find.text('Refine…').at(1));
      await tester.pump();
      await tester.tap(find.text('Refine…').at(1));
      await tester.pump();
      expect(find.textContaining('How should it change?'), findsOneWidget);
      await tester.ensureVisible(find.text('Not this').first);
      await tester.pump();
      await tester.tap(find.text('Not this').first);
      await settle();
      expect(find.text('Forest Green'), findsNothing);
      // Use on a new theme: the editor, filled in, with the card's picture.
      await tester.ensureVisible(find.text('Use').first);
      await tester.pump();
      await tester.tap(find.text('Use').first);
      await settle();
      await settle();
      expect(find.text('New theme from Nord'), findsOneWidget);
      expect(find.text('Deep Sea'), findsOneWidget);
      expect(find.text('#102030'), findsOneWidget);
      if (wall(1) != null) expect(find.text("Also Nord's wallpapers"), findsOneWidget);
      expect(tester.takeException(), isNull);
      await picture('editor-from-ask-${width.round()}');
    });
  }
}
