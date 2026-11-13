import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/pages/ask_page.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

import 'page_shots.dart';
import 'voice_fake.dart';

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
                'blur': {'on': true, 'strength': 6},
                'wallpaper_query': 'ocean night',
                'wallpaper_images': [
                  {'url': 'https://img.example.com/ocean.png', 'page': 'https://img.example.com/ocean', 'title': 'Ocean at night'},
                ],
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
        if (m == 'webimg.get') {
          final png = File('${root.path}/web-ocean.png')
            ..writeAsBytesSync(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='));
          return {'path': png.path};
        }
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
      expect(find.text('Fira Code · Blur 6'), findsOneWidget);
      // A picture the helper found on the web: its badge, its page, first in the card's wallpapers.
      expect(find.text('web'), findsOneWidget);
      expect(find.byTooltip('Open on img.example.com'), findsOneWidget);
      expect(find.textContaining('Ocean at night · web · 1/'), findsOneWidget);
      // A new theme is new for you: its base (Nord) is internal (2026-11-09).
      expect(find.text('New theme'), findsOneWidget);
      expect(find.textContaining('from Nord'), findsNothing);
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
      expect(find.textContaining('Nord'), findsNothing); // no "New theme from Nord", no "Also Nord's wallpapers"
      expect(find.text('Deep Sea'), findsNWidgets(2)); // the card's name: the title and the name field
      final blurDrop = tester.widget<DropdownButton<String>>(find.byKey(const ValueKey('editor-blur')));
      expect(blurDrop.value, 'on'); // the card's blur came over
      expect(find.text('Blur strength'), findsOneWidget);
      expect(find.text('#102030'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await picture('editor-from-ask-${width.round()}');
    });
  }

  testWidgets('a catalog agent nobody has tried yet is offered as "(untested)", in every language', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) async {
      if (m == 'ask.helpers') {
        final real = await core.call(m, p);
        return {
          ...real,
          'helpers': [
            {'id': 'gemini', 'name': 'Gemini CLI', 'installed': true, 'signed_in': true, 'local': false, 'login': '', 'verified': false},
            {'id': 'claude', 'name': 'Claude Code', 'installed': true, 'signed_in': true, 'local': false, 'login': '', 'verified': true},
          ],
          'chosen': 'gemini',
        };
      }
      if (m == 'wallhaven.search') return {'results': <Map>[], 'page': 1, 'last_page': 1};
      if (m == 'import.omarchy_list') return {'themes': <Map>[]};
      return core.call(m, p);
    }

    await core.call('settings.set', {'key': 'ask_ai', 'value': true});
    await tester.runAsync(() async {
      await tester.pumpWidget(MaprismaThemeApp(call: call));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    state.navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const AskPage()));
    for (var i = 0; i < 2; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Gemini CLI (untested)'), findsWidgets);
    expect(find.text('Claude Code (untested)'), findsNothing);
    final before = languageSetting;
    for (final code in ['de', 'fr', 'es', 'it', 'pt', 'nl', 'pl']) {
      languageSetting = code;
      expect(tr(' (untested)'), isNot(' (untested)'), reason: code);
    }
    languageSetting = before;
  });

  testWidgets('a new Ask stops the picture being made for the cards it replaces', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <String>[];
    var asks = 0;
    Completer<Map<String, dynamic>>? held;
    Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) async {
      if (m == 'ask.helpers') {
        final real = await core.call(m, p);
        return {
          ...real,
          'helpers': [
            {'id': 'claude', 'name': 'Claude Code', 'installed': true, 'signed_in': true, 'local': false, 'login': ''},
          ],
          'chosen': 'claude',
        };
      }
      if (m == 'ask.run') {
        asks++;
        final name = asks == 1 ? 'Old Sea' : 'New Sea';
        return {
          'summary': '',
          'candidates': [
            {
              'kind': 'custom', 'mode': 'new', 'theme': 'nord', 'base_name': 'Nord', 'name': name,
              'colors': {'background': '#102030', 'foreground': '#e0e0e0', 'accent': '#3366ff'},
              'changes': {'background': '#102030'}, 'summary': name, 'picture_prompt': 'a sea for $name',
            },
          ],
        };
      }
      if (m == 'create.status') return {'ready': true};
      if (m == 'create.make') {
        calls.add('make ${p['prompt']}');
        if (held == null || !held!.isCompleted) {
          held ??= Completer();
          return held!.future; // this picture takes long (until cancelled)
        }
        return {'path': '${root.path}/made.png'};
      }
      if (m == 'create.cancel') {
        calls.add('cancel');
        if (held != null && !held!.isCompleted) held!.completeError(StateError('cancelled'));
        return {'cancelled': true};
      }
      if (m == 'wallhaven.search') return {'results': <Map>[], 'page': 1, 'last_page': 1};
      if (m == 'import.omarchy_list') return {'themes': <Map>[]};
      return core.call(m, p);
    }

    await core.call('settings.set', {'key': 'ask_ai', 'value': true});
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
    await settle();
    await tester.enterText(find.byType(TextField).first, 'a calm sea');
    await tester.tap(find.text('Ask'));
    await settle();
    await settle();
    expect(find.text('Old Sea'), findsWidgets);
    expect(calls, ['make a sea for Old Sea']);
    await tester.enterText(find.byType(TextField).first, 'a calmer sea');
    await tester.tap(find.text('Ask'));
    await settle();
    await settle();
    expect(find.text('New Sea'), findsWidgets);
    expect(calls, ['make a sea for Old Sea', 'cancel', 'make a sea for New Sea'],
        reason: 'the replaced card\'s picture stops; the new card does not wait behind it');
    // "Not this" on a card whose picture is being made stops that picture too.
    held = Completer();
    await tester.enterText(find.byType(TextField).first, 'the calmest sea');
    await tester.tap(find.text('Ask'));
    await settle();
    await settle();
    expect(calls.last, 'make a sea for New Sea');
    await tester.ensureVisible(find.text('Not this').first);
    await tester.tap(find.text('Not this').first);
    await settle();
    expect(calls.last, 'cancel');
    expect(tester.takeException(), isNull);
  });

  for (final ready in [false, true]) {
    testWidgets('mic button (fake maprisma-voice, ready: $ready)', (tester) async {
      tester.view.physicalSize = const Size(1300, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final voice = (await tester.runAsync(() => FakeVoice.create(ready: ready)))!;
      addTearDown(() => tester.runAsync(voice.dispose));
      Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) async {
        if (m == 'ask.helpers') {
          final real = await core.call(m, p);
          return {
            ...real,
            'helpers': [
              {'id': 'claude', 'name': 'Claude Code', 'installed': true, 'signed_in': true, 'local': false, 'login': '', 'verified': true},
            ],
            'chosen': 'claude',
          };
        }
        if (m == 'wallhaven.search') return {'results': <Map>[], 'page': 1, 'last_page': 1};
        if (m == 'import.omarchy_list') return {'themes': <Map>[]};
        return core.call(m, p);
      }

      await core.call('settings.set', {'key': 'ask_ai', 'value': true});
      await tester.runAsync(() async {
        await tester.pumpWidget(MaprismaThemeApp(call: call));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
      state.navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const AskPage()));
      await settle(tester);
      final mic = find.byKey(const ValueKey('voice-mic'));
      if (!ready) {
        expect(mic, findsNothing);
        return;
      }
      expect(mic, findsOneWidget);
      final field = find.ancestor(of: mic, matching: find.byType(TextField));
      await tester.enterText(field, 'dark');
      await tester.tap(mic);
      await settle(tester);
      expect(find.text('hello'), findsOneWidget);
      await tester.tap(mic);
      await settle(tester);
      expect(tester.widget<TextField>(field).controller!.text, 'dark hello world');
      expect(voice.args.last, 'dictate --events --release --app-id com.maprisma.Theme');
    });
  }
}
