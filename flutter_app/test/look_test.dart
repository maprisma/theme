import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/theme.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

/// The window follows the desktop's look (colours, Hyprland's window rounding) and re-reads it
/// while it runs, so a theme applied elsewhere shows without a restart.
void main() {
  late Directory root;
  late CoreService core;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-look-');
    final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '/usr/bin'};
    final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    Directory(paths.systemThemes).createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    core = CoreService(environment: env, paths: paths, desktop: FakeDesktop(id: 'hyprland', name: 'Hyprland', terminalName: null));
  });
  tearDown(() => root.deleteSync(recursive: true));

  testWidgets('desktop colours and window rounding, re-read every few seconds', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var look = <String, dynamic>{
      'desktop': 'hyprland',
      'colors': {'background': '#231a13', 'accent': '#e78a4e', 'foreground': '#e8d5b7'},
      'is_dark': true,
      'corner_radius': 15,
    };
    var lookCalls = 0;
    Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
      if (method == 'desktop.look') {
        lookCalls++;
        return look;
      }
      return core.call(method, params);
    }

    // The theme the window builds (MaterialApp.theme).
    ThemeData theme() => tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;
    // The core answers outside the fake clock: let it, then build.
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 50 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }

    // Built in the fake clock, so the window's 5 s timer runs on it.
    await tester.pumpWidget(MaprismaThemeApp(call: call));
    await until(() => find.byType(MaterialApp).evaluate().isNotEmpty && theme().colorScheme.surface == const Color(0xff231a13));
    expect(theme().colorScheme.surface, const Color(0xff231a13));
    expect(theme().colorScheme.primary, const Color(0xffe78a4e));
    expect(theme().colorScheme.onPrimary, Colors.white); // a dark accent
    expect(theme().extension<Corners>()!.radius, 15);
    expect(theme().extension<Corners>()!.control, 8);

    // Maprisma Theme applied another theme and Hyprland's rounding changed.
    look = {
      'desktop': 'hyprland',
      'colors': {'background': '#fafafb', 'accent': '#f8e45c', 'foreground': '#323233'},
      'is_dark': false,
      'corner_radius': 4,
    };
    final before = lookCalls;
    await tester.pump(const Duration(seconds: 5));
    await until(() => theme().colorScheme.surface == const Color(0xfffafafb));
    expect(lookCalls, greaterThan(before));
    expect(theme().colorScheme.surface, const Color(0xfffafafb));
    expect(theme().colorScheme.primary, const Color(0xfff8e45c));
    expect(theme().colorScheme.onPrimary, Colors.black); // a light accent
    expect(theme().extension<Corners>()!.radius, 4);

    // Back in the window: read again at once.
    final calls = lookCalls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await until(() => lookCalls > calls);
    expect(lookCalls, greaterThan(calls));
    await tester.pumpWidget(const SizedBox());
  });

  test('"Like windows" takes the desktop\'s rounding, the other settings their own', () {
    expect(cornerRadius('windows', 15), 15);
    expect(cornerRadius('windows', null), 12);
    expect(cornerRadius('slight', 15), 6);
    expect(cornerRadius('square', 15), 0);
  });
}
