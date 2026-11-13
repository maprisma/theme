import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/pages/editor_page.dart';
import 'package:maprisma_theme/pages/wallpapers_page.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

void main() {
  late Directory root;
  late CoreService core;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-caps-');
    final env = {
      'HOME': '${root.path}/home',
      'XDG_RUNTIME_DIR': '${root.path}/run',
      'PATH': '/usr/bin',
    };
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory('${paths.systemThemes}/nord/backgrounds')
        .createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    File('${paths.systemThemes}/nord/colors.toml').writeAsStringSync(
      'background = "#2e3440"\nforeground = "#d8dee9"\naccent = "#81a1c1"\n',
    );
    File('${paths.systemThemes}/nord/backgrounds/one.png').writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=',
      ),
    );
    core = CoreService(environment: env, paths: paths, desktop: FakeDesktop());
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  for (final kde in [true, false]) {
    final desktop = kde ? 'KDE Plasma' : 'your desktop';
    testWidgets(
      '$desktop keeps appearance presets and hides unavailable operations',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 950);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final calls = <String>[];
        Future<Map<String, dynamic>> call(
          String method, [
          Map<String, dynamic> params = const {},
        ]) async {
          calls.add(method);
          if (method == 'desktop.info') {
            return {
              'id': kde ? 'kde' : 'generic',
              'name': desktop,
              'terminal': kde ? 'Konsole' : null,
              'caps': kde
                  ? ['appearance', 'wallpaper', 'terminal', 'fonts', 'icons']
                  : <String>[],
            };
          }
          // Stale assignments must never leak into badges or menus.
          if (method == 'shortcuts.labels') {
            return {
              'labels': {
                'apply:nord': ['Super+N'],
              },
            };
          }
          if (method == 'auto.workspace_themes') {
            return {
              'themes': {'2': 'nord'},
            };
          }
          if (method == 'auto.workspace_wallpapers') {
            return {
              'map': {'2': 'one.png'},
            };
          }
          return core.call(method, params);
        }

        await tester.runAsync(() async {
          await tester.pumpWidget(MaprismaThemeApp(call: call));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();
        final app = tester.state<MaprismaThemeAppState>(
          find.byType(MaprismaThemeApp),
        );
        expect(app.desktopName, desktop);
        expect(app.can('workspaces'), isFalse);
        expect(app.can('fonts'), kde);
        expect(app.can('icons'), kde);
        expect(app.can('terminal'), kde);
        expect(app.can('wallpaper'), kde);
        if (kde) expect(app.terminalName, 'Konsole');
        expect(find.textContaining('ws 2'), findsNothing);
        expect(find.text('Super+N'), findsNothing);
        await tester.tap(find.byType(PopupMenuButton<VoidCallback>).first);
        await tester.pumpAndSettle();
        expect(find.text('Use on workspace…'), findsNothing);
        expect(find.text('Use on all workspaces'), findsNothing);
        expect(find.textContaining('Shortcut'), findsNothing);
        await tester.tap(find.text('Wallpapers'));
        await settle(tester);
        expect(find.textContaining('ws 2'), findsNothing);
        await tester.tap(
          find
              .descendant(
                of: find.byType(WallpapersPage),
                matching: find.byType(PopupMenuButton<VoidCallback>),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.text('Show on workspace…'), findsNothing);
        expect(find.textContaining('On workspace'), findsNothing);
        expect(
          find.text('Preview on desktop'),
          kde ? findsOneWidget : findsNothing,
        );
        app.openPage('presets');
        calls.clear();
        await settle(tester);
        expect(find.text('Save current'), findsOneWidget);
        expect(find.text('Workspaces'), findsNothing);
        expect(find.text('App Presets'), findsNothing);
        expect(
          find.text('Include workspace presets and app presets'),
          findsNothing,
        );
        expect(
          find.text('Workspaces are not available on $desktop yet.'),
          findsOneWidget,
        );
        expect(calls.where((m) => m.startsWith('workspaces.')), isEmpty);

        app.openPage('settings');
        await settle(tester);
        expect(find.text('Keyboard shortcuts'), findsNothing);
        await tester.tap(find.text('Wallpapers'));
        await tester.pumpAndSettle();
        expect(find.text('A wallpaper for each workspace'), findsNothing);
        expect(find.text('A theme for each workspace'), findsNothing);
        await tester.tap(find.text('Integration and backup'));
        await tester.pumpAndSettle();
        expect(find.text('Panel applet'), findsNothing);
        expect(find.text('Shortcut file'), findsNothing);
        expect(find.textContaining('COSMIC'), findsNothing);

        app.navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const EditorPage(base: 'nord'),
          ),
        );
        await settle(tester);
        expect(find.text('Font'), kde ? findsOneWidget : findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'desktop defaults persist until loaded and last value survives a refresh failure',
    (tester) async {
      final info = Completer<Map<String, dynamic>>();
      var fail = false;
      Future<Map<String, dynamic>> call(
        String method, [
        Map<String, dynamic> params = const {},
      ]) {
        if (method == 'desktop.info') {
          if (fail) return Future.error(StateError('offline'));
          return info.future;
        }
        return core.call(method, params);
      }

      await tester.pumpWidget(MaprismaThemeApp(call: call));
      final app = tester.state<MaprismaThemeAppState>(
        find.byType(MaprismaThemeApp),
      );
      expect(app.desktopName, 'COSMIC');
      expect(app.terminalName, 'COSMIC Terminal');
      expect(app.can('workspaces'), isTrue);
      info.complete({
        'name': 'KDE Plasma',
        'terminal': 'Konsole',
        'caps': ['fonts'],
      });
      await settle(tester);
      expect(app.desktopName, 'KDE Plasma');
      expect(app.can('workspaces'), isFalse);
      fail = true;
      await tester.runAsync(app.refreshLook);
      await tester.pumpAndSettle();
      expect(app.desktopName, 'KDE Plasma');
      expect(app.terminalName, 'Konsole');
      expect(app.can('fonts'), isTrue);
    },
  );

  testWidgets('Hyprland: a Keyboard shortcuts pane chosen before desktop.info answered falls back, never blank', (tester) async {
    tester.view.physicalSize = const Size(1200, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final info = Completer<Map<String, dynamic>>();
    Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) =>
        method == 'desktop.info' ? info.future : core.call(method, params);
    await tester.runAsync(() async {
      await tester.pumpWidget(MaprismaThemeApp(call: call));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    final app = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));
    app.openPage('settings');
    await settle(tester);
    // the first caps (COSMIC's) offer it
    await tester.tap(find.text('Keyboard shortcuts').first);
    await settle(tester);
    info.complete({'id': 'hyprland', 'name': 'Hyprland', 'terminal': null, 'caps': ['appearance', 'wallpaper']});
    await settle(tester);
    expect(find.text('Keyboard shortcuts'), findsNothing);
    expect(find.text('Keyboard shortcuts are not available on Hyprland yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

