import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

/// Rule 5a in the whole window: Esc goes back from a page, then hides the window (as the close
/// button: the process stays); a resize is saved as GTK's size, not while maximized.
void main() {
  late Directory root;
  late CoreService core;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-close-');
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '/usr/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory(paths.systemThemes).createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    core = CoreService(environment: env, paths: paths, desktop: FakeDesktop(id: 'kde', name: 'KDE Plasma', terminalName: null));
  });
  tearDown(() => root.deleteSync(recursive: true));

  testWidgets('Esc: Back from a page, then hide; a resize saves the window size', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <String>[];
    var geometry = <String, Object>{'width': 1000, 'height': 760, 'free': true};
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('maprisma-theme/window'), (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'geometry' => geometry,
        'maximized' => false,
        _ => null,
      };
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('maprisma-theme/window'), null));
    final saved = <Object?>[];
    Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
      if (method == 'settings.set' && params['key'] == 'size') saved.add(params['value']);
      return core.call(method, params);
    }

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.pumpWidget(MaprismaThemeApp(call: call));
    await settle();
    final app = tester.state<MaprismaThemeAppState>(find.byType(MaprismaThemeApp));

    app.openPage('info');
    await settle();
    expect(app.topPage.value, 'info');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
    expect(app.topPage.value, '/', reason: 'Esc on a page goes back to the list');
    expect(calls, isNot(contains('hide')));

    // The keyboard outside the pages (nothing focused below the navigator): Esc still hides.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();
    expect(calls, contains('hide'));

    // A resize by hand: GTK's size is saved half a second later; maximized it is not.
    tester.view.physicalSize = const Size(1100, 800);
    await tester.pump(const Duration(milliseconds: 600));
    await settle();
    expect(saved, [
      [1000, 760],
    ]);
    geometry = {'width': 1600, 'height': 1000, 'free': false};
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.pump(const Duration(milliseconds: 600));
    await settle();
    expect(saved, hasLength(1));
  });
}
