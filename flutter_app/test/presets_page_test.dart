import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/pages/presets_page.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

/// The Presets page against the real core in a temporary HOME (FakeDesktop).
/// With MAPRISMA_SHOTS=`folder` it also saves PNGs of the page (700 and
/// 1300 px wide) to compare with the plugin's preview.png.
void main() {
  late Directory root;
  late CoreService core;
  late FakeDesktop desktop;
  final shots = Platform.environment['MAPRISMA_SHOTS'];

  setUpAll(() async {
    // Real fonts, so the screenshots are readable (tests use Ahem otherwise).
    final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? '/mnt/Data/flutter'}/bin/cache/artifacts/material_fonts';
    Future<void> load(String family, List<String> files) async {
      final loader = FontLoader(family);
      var any = false;
      for (final f in files) {
        final file = File('$fonts/$f');
        if (!file.existsSync()) continue;
        any = true;
        loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      }
      if (any) await loader.load();
    }

    await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
    await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  });

  Future<List<int>> wallpaperPng() async {
    // A dusk sky, a mountain and a fire: something to see behind the windows.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const size = Size(640, 360);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, const Offset(0, 360), [
          const Color(0xff9aa3a8),
          const Color(0xff2b3036),
          const Color(0xff101418),
        ], [0, .55, 1]),
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, 230)
        ..lineTo(180, 150)
        ..lineTo(330, 210)
        ..lineTo(470, 140)
        ..lineTo(640, 220)
        ..lineTo(640, 360)
        ..lineTo(0, 360)
        ..close(),
      Paint()..color = const Color(0xff1c2126),
    );
    canvas.drawCircle(const Offset(330, 300), 18, Paint()..color = const Color(0xffff8a2a));
    final image = await recorder.endRecording().toImage(640, 360);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('maprisma-presets-test-');
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '/usr/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    final dir = '${paths.systemThemes}/fireside';
    Directory('$dir/backgrounds').createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    File('$dir/colors.toml').writeAsStringSync(
        'background = "#14181d"\nforeground = "#d6d9dc"\naccent = "#c9ced3"\nred = "#bf616a"\n');
    final nord = '${paths.systemThemes}/nord';
    Directory('$nord/backgrounds').createSync(recursive: true);
    File('$nord/colors.toml').writeAsStringSync(
        'background = "#2e3440"\nforeground = "#d8dee9"\naccent = "#88c0d0"\nred = "#bf616a"\n');
    desktop = FakeDesktop()
      ..workspaces = {
        'workspaces': [
          for (var i = 1; i <= 5; i++) {'index': i, 'name': '$i', 'active': i == 2, 'tiling': true, 'output': 'DP-1'},
        ],
        'can_tile': true,
      };
    core = CoreService(environment: env, paths: paths, desktop: desktop);
    final png = await wallpaperPng();
    File('$dir/backgrounds/1.png').writeAsBytesSync(png);
    File('$nord/backgrounds/1.png').writeAsBytesSync(png);
    core.ctx.current.save(slug: 'fireside', wallpaper: '$dir/backgrounds/1.png');
    await core.call('workspaces.set', {'maxWindows': 3});
    await core.call('workspaces.set', {'defaultLimit': 3, 'defaultMode': 'tiled'});
    await core.call('workspaces.set', {'workspace': 4, 'mode': 'floating'});
    await core.call('workspaces.set', {'workspace': 5, 'limit': 4});
    await core.call('workspaces.set', {'workspace': 3, 'mode': 'default'});
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester, [int ms = 300]) async {
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (shots == null) return;
    // Let decoded wallpapers arrive, then paint them.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.runAsync(() async {
      final view = tester.binding.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      final size = view.size;
      final image = await layer.toImage(Offset.zero & size);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(shots).createSync(recursive: true);
      File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  Future<void> open(WidgetTester tester, double width, double height) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => core.call(m, p);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaprismaThemeApp(call: call));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    // Readable button labels in the screenshots: the test engine draws text
    // without a family (Material's button labels) in its box font.
    state.navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (context) => Theme(
              data: Theme.of(context).copyWith(
                outlinedButtonTheme: const OutlinedButtonThemeData(style: _roboto),
                filledButtonTheme: const FilledButtonThemeData(style: _roboto),
                textButtonTheme: const TextButtonThemeData(style: _roboto),
              ),
              child: const PresetsPage(),
            )));
    await settle(tester, 600);
  }

  test('COSMIC autotile splits the newest window along its longer side', () {
    expect(layoutRects('tiled', 0), isEmpty);
    final two = layoutRects('tiled', 2);
    expect(two[0].top, two[1].top); // side by side
    final three = layoutRects('tiled', 3);
    expect(three[1].left, three[2].left); // the right half split top/bottom
    expect(three[2].top, greaterThan(three[1].top));
    final four = layoutRects('tiled', 4);
    expect(four[2].top, four[3].top); // the bottom-right quarter split left/right
    final floating = layoutRects('floating', 3);
    expect(floating[1].left, greaterThan(floating[0].left)); // cascaded
  });

  testWidgets('wide: cards, controls and the large preview on the right', (tester) async {
    await open(tester, 1300, 1000);
    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.text('App Presets'), findsOneWidget);
    expect(find.text('Save/Load Presets'), findsOneWidget);
    expect(find.text('Workspaces 1–5'), findsOneWidget);
    expect(find.text('Workspaces 6–10'), findsOneWidget);
    expect(find.text('All Workspaces'), findsOneWidget);
    expect(find.text('WORKSPACE 2'), findsOneWidget); // the active one is chosen
    expect(find.text('WINDOW LIMIT'), findsOneWidget);
    expect(find.text('LAYOUT PRESET'), findsOneWidget);
    expect(find.text('Max 3 · Tiled'), findsWidgets);
    expect(find.text('Max 3 · Floating'), findsOneWidget);
    expect(find.text('Max 4 · Native'), findsOneWidget);
    expect(find.textContaining('Fireside · 1.png · Max 3 · Tiled'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shot(tester, 'presets-1300');

    // + on the preview: one window more on Workspace 2.
    await tester.tap(find.byTooltip('One window more'));
    await settle(tester);
    expect(loadLimit(core, 2), 4);
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect(loadLimit(core, 2), 3);

    // Floating tile on Workspace 2, then again: the preset goes.
    await tester.tap(find.text('Floating').last);
    await settle(tester);
    expect(stored(core)['workspaceModes']['2'], 'floating');
    await tester.tap(find.text('Floating').last);
    await settle(tester);
    expect(stored(core)['workspaceModes']['2'], isNull);

    // All Workspaces: its own controls.
    await tester.tap(find.text('All Workspaces'));
    await settle(tester);
    expect(find.text('Tiling active'), findsOneWidget);
    expect(find.text('DEFAULT WINDOW LIMIT (ALL WORKSPACES)'), findsOneWidget);
    expect(find.text('Reset All to Default'), findsOneWidget);
    await shot(tester, 'presets-1300-all');

    // Keyboard: Tab to the preview, + raises the default limit.
    final preview = find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'workspace preview');
    expect(preview, findsOneWidget);
    (tester.widget<Focus>(preview).focusNode!).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadAdd);
    await settle(tester);
    expect(stored(core)['maxWindows'], 4);

    await tester.tap(find.text('App Presets'));
    await settle(tester);
    expect(find.text('No App Preset saved yet'), findsOneWidget);
    expect(find.text('Auto-move on restore'), findsOneWidget);
    await shot(tester, 'presets-1300-apps');

    await tester.tap(find.text('Save/Load Presets'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Evening');
    await tester.pump();
    await tester.tap(find.text('Save current'));
    await settle(tester);
    expect(find.text('Evening'), findsOneWidget);
    expect(find.textContaining('Workspace presets:'), findsOneWidget);
    await shot(tester, 'presets-1300-saved');
  });

  testWidgets('narrow: magnifier opens the large preview', (tester) async {
    await open(tester, 700, 1000);
    expect(find.text('WORKSPACE 2'), findsNothing); // no right panel
    await shot(tester, 'presets-700');
    await tester.tap(find.byTooltip('Preview').at(2)); // Workspace 2
    await settle(tester);
    expect(find.textContaining('Workspace 2 · Fireside · 1.png'), findsOneWidget);
    await shot(tester, 'presets-700-zoom');
    // − in the large preview: one window less, and it stays open.
    await tester.tap(find.byTooltip('One window less'));
    await settle(tester);
    expect(loadLimit(core, 2), 2);
    expect(find.textContaining('Workspace 2 · Fireside · 1.png · Max 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.textContaining('Workspace 2 · Fireside'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

const _roboto = ButtonStyle(textStyle: WidgetStatePropertyAll(TextStyle(fontFamily: 'Roboto')));

Map<String, dynamic> stored(CoreService core) => readJsonMap(core.ctx.paths.file('workspaces.json'));

int loadLimit(CoreService core, int ws) {
  final s = stored(core);
  return ((s['workspaceCaps'] as Map?)?['$ws'] as int?) ?? s['maxWindows'] as int;
}
