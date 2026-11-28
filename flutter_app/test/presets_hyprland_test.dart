import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/pages/presets_page.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

void main() {
  test('preset helpers cover all 9 presets and split labels', () {
    expect(presetLabel('side-by-side'), 'Side by side');
    expect(presetLabel('side-by-side', cap: 1), 'One window');
    expect(presetLabel('side-by-side', cap: 2), 'Side by side');
    expect(presetLabel('stacked'), 'Stacked');
    expect(presetLabel('master-left'), 'Master left');
    expect(presetLabel('master-right'), 'Master right');
    expect(presetLabel('columns'), 'Columns');
    expect(presetLabel('grid'), 'Grid');
    expect(presetLabel('floating'), 'Floating');
    expect(presetLabel('scrolling'), 'Scrolling');
    expect(presetLabel('none'), 'Native');

    expect(isUnlimitedPreset('floating'), isTrue);
    expect(isUnlimitedPreset('scrolling'), isTrue);
    expect(isUnlimitedPreset('none'), isTrue);
    expect(isUnlimitedPreset('grid'), isFalse);

    expect(splitLabel('side-by-side', null), '50% / 50%');
    expect(splitLabel('side-by-side', 0.6), '60% / 40%');
    expect(splitLabel('columns', null), '33% / 33% / 33%');
    expect(splitLabel('columns', 0.33), '33% / 33% / 34%');
    expect(splitLabel('columns', 0.34), '33% / 34% / 33%');
    expect(splitLabel('columns', 0.21), '39% / 21% / 40%');
    expect(splitLabel('columns', 0.5), '25% / 50% / 25%');
  });

  late Directory root;
  late CoreService core;
  late FakeDesktop desktop;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('maprisma-hypr-presets-test-');
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '/usr/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    final dir = '${paths.systemThemes}/fireside';
    Directory('$dir/backgrounds').createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    File('$dir/colors.toml').writeAsStringSync(
        'background = "#14181d"\nforeground = "#d6d9dc"\naccent = "#c9ced3"\nred = "#bf616a"\n');
    desktop = FakeDesktop(
      id: 'hyprland',
      name: 'Hyprland',
      terminalName: null,
      caps: Cap.values.toSet(),
    )
      ..workspaces = {
        'workspaces': [
          for (var i = 1; i <= 5; i++) {'index': i, 'name': '$i', 'active': i == 2, 'tiling': true, 'output': 'DP-1'},
        ],
        'can_tile': true,
      };
    core = CoreService(environment: env, paths: paths, desktop: desktop);
    core.ctx.current.save(slug: 'fireside');
    await core.call('workspaces.set', {'active': true, 'maxWindows': 2});
    await core.call('workspaces.set', {'workspace': 3, 'preset': 'floating'});
    await core.call('workspaces.set', {'workspace': 4, 'preset': 'scrolling'});
    await core.call('workspaces.set', {'workspace': 5, 'preset': 'none'});
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester, [int ms = 250]) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(Duration(milliseconds: ms ~/ 3 + 1));
      });
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> open(WidgetTester tester, {double width = 1300, double height = 1400}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => core.call(m, p);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaprismaThemeApp(call: call));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    state.navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const PresetsPage()));
    await settle(tester, 500);
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await settle(tester);
  }

  bool isDimmedTile(WidgetTester tester, String label) {
    final text = find.text(label).last;
    final opacities = tester.widgetList<Opacity>(find.ancestor(of: text, matching: find.byType(Opacity)));
    return opacities.any((o) => o.opacity < 0.9);
  }

  Map<String, dynamic> stored() => readJsonMap(core.ctx.paths.file('workspaces.json'));

  testWidgets('Hyprland: 9 preset tiles, compatibility dimming, selection, undo, unlimited summary', (tester) async {
    await open(tester);

    // Hyprland note wording (not COSMIC/KWin).
    expect(find.textContaining('Maprisma Theme daemon arranges windows on Hyprland'), findsOneWidget);

    // Unlimited workspaces show their preset label directly (no "Max N ·").
    expect(find.text('Floating'), findsWidgets);
    expect(find.text('Scrolling'), findsWidgets);
    expect(find.text('Native'), findsWidgets);
    expect(find.textContaining('Max 2 · Floating'), findsNothing);
    expect(find.textContaining('Max 2 · Scrolling'), findsNothing);
    expect(find.textContaining('Max 2 · Native'), findsNothing);

    // Active workspace 2 (cap 2) renders all 9 preset tiles.
    for (final label in [
      'Side by side',
      'Stacked',
      'Master left',
      'Master right',
      'Columns',
      'Grid',
      'Floating',
      'Scrolling',
      'Native',
    ]) {
      expect(find.text(label), findsWidgets, reason: 'missing tile $label');
    }

    // For cap 2: Side by side, Stacked, Floating, Scrolling, Native are active;
    // Master left, Master right, Columns, Grid are dimmed.
    expect(isDimmedTile(tester, 'Side by side'), isFalse);
    expect(isDimmedTile(tester, 'Stacked'), isFalse);
    expect(isDimmedTile(tester, 'Floating'), isFalse);
    expect(isDimmedTile(tester, 'Scrolling'), isFalse);
    expect(isDimmedTile(tester, 'Native'), isFalse);
    expect(isDimmedTile(tester, 'Master left'), isTrue);
    expect(isDimmedTile(tester, 'Master right'), isTrue);
    expect(isDimmedTile(tester, 'Columns'), isTrue);
    expect(isDimmedTile(tester, 'Grid'), isTrue);

    // Tapping a dimmed tile does not set it.
    await tapVisible(tester, find.text('Grid').last);
    expect((stored()['workspacePresets'] as Map)['2'], isNull);

    // Clicking compatible Stacked sets workspacePresets['2'] = 'stacked'.
    await tapVisible(tester, find.text('Stacked').last);
    expect((stored()['workspacePresets'] as Map)['2'], 'stacked');
    expect(find.text('Max 2 · Stacked'), findsOneWidget);

    // Undo restores previous state.
    expect(find.text('Undo'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await settle(tester);
    expect((stored()['workspacePresets'] as Map)['2'], isNull);

    // Click Stacked, then click Stacked again removes it.
    await tapVisible(tester, find.text('Stacked').last);
    expect((stored()['workspacePresets'] as Map)['2'], 'stacked');
    await tapVisible(tester, find.text('Stacked').last);
    expect((stored()['workspacePresets'] as Map)['2'], isNull);

    // Switch Workspace 2 limit to 4: Grid/Columns/Master become active, Side by side/Stacked dim.
    await tapVisible(tester, find.text('4'));
    expect((stored()['workspaceCaps'] as Map)['2'], 4);
    expect(isDimmedTile(tester, 'Grid'), isFalse);
    expect(isDimmedTile(tester, 'Columns'), isFalse);
    expect(isDimmedTile(tester, 'Master left'), isFalse);
    expect(isDimmedTile(tester, 'Master right'), isFalse);
    expect(isDimmedTile(tester, 'Side by side'), isTrue);
    expect(isDimmedTile(tester, 'Stacked'), isTrue);

    // Click Grid -> no split divider/card for grid.
    await tapVisible(tester, find.text('Grid').last);
    expect((stored()['workspacePresets'] as Map)['2'], 'grid');
    expect(find.text('SPLIT RATIO'), findsNothing);

    // Click Floating -> unlimited hint shows; tapping limit 1 switches back and shows "One window".
    await tapVisible(tester, find.text('Floating').last);
    expect((stored()['workspacePresets'] as Map)['2'], 'floating');
    expect(find.textContaining('Floating has no window limit'), findsOneWidget);

    await tapVisible(tester, find.text('1'));
    expect((stored()['workspaceCaps'] as Map)['2'], 1);
    expect((stored()['workspacePresets'] as Map)['2'], 'side-by-side');
    expect(find.text('One window'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Hyprland: split slider, Even split button, interactive divider, and keyboard shortcuts', (tester) async {
    await open(tester);

    // Workspace 2 defaults to cap 2 / side-by-side -> Split ratio card & divider visible.
    expect(find.text('SPLIT RATIO'), findsOneWidget);
    expect(find.text('50% / 50%'), findsOneWidget);
    expect(find.byKey(const ValueKey('split-divider-0')), findsOneWidget);

    // Even split button starts disabled when no custom split is set.
    final evenBtnFinder = find.ancestor(of: find.text('Even split'), matching: find.byType(OutlinedButton));
    expect(tester.widget<OutlinedButton>(evenBtnFinder).onPressed, isNull);

    // Drag the Slider right to commit a split ratio.
    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    await tester.ensureVisible(slider);
    await tester.pump();
    await tester.drag(slider, const Offset(80, 0));
    await settle(tester);
    final committed = ((stored()['workspaceSplits'] as Map)['2'] as num?)?.toDouble();
    expect(committed, isNotNull);
    expect(committed!, greaterThan(0.5));

    // Even split button is now enabled; tapping resets split to null.
    expect(tester.widget<OutlinedButton>(evenBtnFinder).onPressed, isNotNull);
    await tapVisible(tester, evenBtnFinder);
    expect((stored()['workspaceSplits'] as Map)['2'], isNull);
    expect(find.text('50% / 50%'), findsOneWidget);

    // Keyboard on preview: ] raises split by +0.05, [ lowers by -0.05, Home resets to null.
    final preview = find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'workspace preview');
    expect(preview, findsOneWidget);
    tester.widget<Focus>(preview).focusNode!.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
    await settle(tester);
    expect(((stored()['workspaceSplits'] as Map)['2'] as num).toDouble(), closeTo(0.55, 0.001));

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await settle(tester);
    expect(((stored()['workspaceSplits'] as Map)['2'] as num).toDouble(), closeTo(0.50, 0.001));

    await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
    await settle(tester);
    expect(((stored()['workspaceSplits'] as Map)['2'] as num).toDouble(), closeTo(0.45, 0.001));

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await settle(tester);
    expect((stored()['workspaceSplits'] as Map)['2'], isNull);

    // Keyboard ↑/↓ cycles compatible presets for cap 2: side-by-side -> stacked -> floating -> scrolling -> none.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect((stored()['workspacePresets'] as Map)['2'], 'stacked');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect((stored()['workspacePresets'] as Map)['2'], 'floating');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await settle(tester);
    expect((stored()['workspacePresets'] as Map)['2'], 'stacked');

    // Drag the preview divider vertically for stacked, then double-tap to reset.
    final dividerFinder = find.byKey(const ValueKey('split-divider-0'));
    expect(dividerFinder, findsOneWidget);
    await tester.ensureVisible(dividerFinder);
    await tester.pump();
    await tester.drag(dividerFinder, const Offset(0, 40));
    await settle(tester);
    final dragged = ((stored()['workspaceSplits'] as Map)['2'] as num?)?.toDouble();
    expect(dragged, isNotNull);
    expect(dragged!, greaterThan(0.5));

    // Double-tap divider resets split to null.
    await tester.tap(dividerFinder);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(dividerFinder);
    await settle(tester);
    expect((stored()['workspaceSplits'] as Map)['2'], isNull);

    // All Workspaces default preset & split.
    await tapVisible(tester, find.text('All Workspaces'));
    await tapVisible(tester, find.text('Stacked').last);
    expect((stored()['defaultPresets'] as Map)['2'], 'stacked');

    expect(tester.takeException(), isNull);
  });

  testWidgets('regressions: App Presets floating count, old mode cleared on limit, Even split preserves defaultSplit, Esc cancels drags', (tester) async {
    // 1) App Presets tab with Floating workspace: draws exact app count (1 and 5, not fixed 3).
    final wsJsonPath = core.ctx.paths.file('workspaces.json');
    final initial = readJsonMap(wsJsonPath);
    initial['workspaceLayouts'] = {
      '3': {'autostart': false, 'apps': ['only-one.desktop']},
    };
    // 2) Old-style workspaceModes['2'] = 'floating' without workspacePresets['2'], with defaultPresets['2'] = 'stacked'.
    (initial['workspaceModes'] as Map)['2'] = 'floating';
    (initial['workspacePresets'] as Map).remove('2');
    (initial['defaultPresets'] as Map)['2'] = 'stacked';
    writeJson(wsJsonPath, initial);

    await open(tester);

    // Check App Presets tab on Workspace 3 (floating, 1 app -> 1 rect, not 3).
    await tapVisible(tester, find.text('App Presets'));
    await tapVisible(tester, find.text('Workspace 3'));
    CustomPaint lookPaint() => tester.widgetList<CustomPaint>(find.byType(CustomPaint))
        .firstWhere((c) => c.painter is LookPainter);
    expect((lookPaint().painter! as LookPainter).rects.length, 1);

    // Update Workspace 3 to 5 apps and reload -> 5 rects.
    final withFive = readJsonMap(wsJsonPath);
    withFive['workspaceLayouts']['3'] = {
      'autostart': false,
      'apps': ['a.desktop', 'b.desktop', 'c.desktop', 'd.desktop', 'e.desktop'],
    };
    writeJson(wsJsonPath, withFive);
    tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp)).changed();
    await settle(tester);
    expect((lookPaint().painter! as LookPainter).rects.length, 5);

    // Back to Workspaces tab, select Workspace 2 (floating via legacy workspaceModes only).
    await tapVisible(tester, find.text('Workspaces'));
    await tapVisible(tester, find.text('Workspace 2'));
    expect(find.textContaining('Floating has no window limit'), findsOneWidget);

    // Picking limit 2 clears legacy workspaceModes['2'] so Workspace 2 switches to defaultPresets['2'] ('stacked').
    await tapVisible(tester, find.text('2'));
    expect((stored()['workspaceModes'] as Map)['2'], isNull);
    expect(find.text('Max 2 · Stacked'), findsNWidgets(2));
    expect(find.textContaining('Fireside · Max 2 · Stacked'), findsOneWidget);

    // 3) Even split and Home on one workspace must NOT wipe global defaultSplit.
    await core.call('workspaces.set', {'split': 0.65});
    tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp)).changed();
    await settle(tester);
    expect(stored()['defaultSplit'], closeTo(0.65, 0.001));
    expect(find.text('65% / 35%'), findsOneWidget);

    final evenBtnFinder = find.ancestor(of: find.text('Even split'), matching: find.byType(OutlinedButton));
    expect(tester.widget<OutlinedButton>(evenBtnFinder).onPressed, isNotNull);
    await tapVisible(tester, evenBtnFinder);
    expect(stored()['defaultSplit'], closeTo(0.65, 0.001));
    expect(((stored()['workspaceSplits'] as Map)['2'] as num).toDouble(), closeTo(0.5, 0.001));
    expect(find.text('50% / 50%'), findsOneWidget);

    // Home key on Workspace 1 (which inherits defaultSplit 0.65) also keeps defaultSplit intact.
    await tapVisible(tester, find.text('Workspace 1'));
    expect(find.text('65% / 35%'), findsOneWidget);
    final preview = find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'workspace preview');
    tester.widget<Focus>(preview).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await settle(tester);
    expect(stored()['defaultSplit'], closeTo(0.65, 0.001));
    expect(((stored()['workspaceSplits'] as Map)['1'] as num).toDouble(), closeTo(0.5, 0.001));

    // Clear defaultSplit and Workspace 2's own split to test Esc drag cancellation cleanly.
    await core.call('workspaces.set', {'split': null});
    await core.call('workspaces.set', {'workspace': 2, 'split': null});
    await core.call('workspaces.set', {'workspace': 2, 'preset': 'side-by-side'});
    tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp)).changed();
    await settle(tester);
    await tapVisible(tester, find.text('Workspace 2'));
    expect((stored()['workspaceSplits'] as Map)['2'], isNull);

    // 4a) Esc cancels divider drag: pointer up must not commit.
    final dividerFinder = find.byKey(const ValueKey('split-divider-0'));
    await tester.ensureVisible(dividerFinder);
    await tester.pump();
    final divCenter = tester.getCenter(dividerFinder);
    final divGesture = await tester.startGesture(divCenter);
    await divGesture.moveBy(const Offset(50, 0));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await divGesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await divGesture.up();
    await settle(tester);
    expect((stored()['workspaceSplits'] as Map)['2'], isNull);

    // 4b) Esc cancels slider drag: pointer up must not commit.
    final sliderFinder = find.byType(Slider);
    await tester.ensureVisible(sliderFinder);
    await tester.pump();
    final sliderCenter = tester.getCenter(sliderFinder);
    final sliderGesture = await tester.startGesture(sliderCenter);
    await sliderGesture.moveBy(const Offset(70, 0));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await sliderGesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await sliderGesture.up();
    await settle(tester);
    expect((stored()['workspaceSplits'] as Map)['2'], isNull);

    // Subsequent normal slider drag works again (_dragCancelled cleared).
    await tester.drag(sliderFinder, const Offset(80, 0));
    await settle(tester);
    expect((stored()['workspaceSplits'] as Map)['2'], isNotNull);

    expect(tester.takeException(), isNull);
  });

  testWidgets('regression: note checks presetLayouts capability rather than desktopId', (tester) async {
    final altDesktop = FakeDesktop(
      id: 'other-wl',
      name: 'OtherWM',
      terminalName: null,
      caps: Cap.values.toSet(),
    )
      ..workspaces = desktop.workspaces;
    final altEnv = {'HOME': '${root.path}/home2', 'XDG_RUNTIME_DIR': '${root.path}/run2', 'PATH': '/usr/bin'};
    final altPaths = Paths.fromEnvironment(altEnv, share: '${root.path}/share2');
    Directory('${altPaths.systemThemes}/fireside/backgrounds').createSync(recursive: true);
    Directory(altPaths.templates).createSync(recursive: true);
    File('${altPaths.systemThemes}/fireside/colors.toml').writeAsStringSync(
        'background = "#14181d"\nforeground = "#d6d9dc"\naccent = "#c9ced3"\n');
    final altCore = CoreService(environment: altEnv, paths: altPaths, desktop: altDesktop);
    altCore.ctx.current.save(slug: 'fireside');
    await altCore.call('workspaces.set', {'active': true, 'maxWindows': 2});

    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaprismaThemeApp(call: (m, [p = const {}]) => altCore.call(m, p)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    final state = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    state.navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => const PresetsPage()));
    await settle(tester, 500);
    expect(find.textContaining('Maprisma Theme daemon arranges windows on Hyprland'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
