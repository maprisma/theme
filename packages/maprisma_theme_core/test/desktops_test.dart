import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/desktop_cosmic.dart';
import 'package:maprisma_theme_core/src/desktop_kde.dart';
import 'package:maprisma_theme_core/src/desktops.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory root;
  late Paths paths;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-theme-desktops-');
    paths = Paths.fromEnvironment({'HOME': '${root.path}/home'}, share: '${root.path}/share');
  });
  tearDown(() => root.deleteSync(recursive: true));

  Desktop select(Map<String, String> env) => selectDesktop(paths, {'HOME': '${root.path}/home', ...env});

  test('XDG_CURRENT_DESKTOP: exact colon tokens, any case, first known wins', () {
    expect(select({'XDG_CURRENT_DESKTOP': 'COSMIC'}), isA<CosmicDesktop>());
    expect(select({'XDG_CURRENT_DESKTOP': 'pop:cosmic'}), isA<CosmicDesktop>());
    expect(select({'XDG_CURRENT_DESKTOP': ' Cosmic '}), isA<CosmicDesktop>());
    expect(select({'XDG_CURRENT_DESKTOP': 'COSMICX'}), isA<GenericDesktop>());
    expect(select({'XDG_CURRENT_DESKTOP': 'KDE'}), isA<KdeDesktop>());
    expect(select({'XDG_CURRENT_DESKTOP': 'GNOME'}), isA<GenericDesktop>());
    expect(select({'XDG_CURRENT_DESKTOP': ''}), isA<GenericDesktop>());
    expect(select({}), isA<GenericDesktop>());
  });

  test('MAPRISMA_THEME_DESKTOP overrides; an unknown id is an error', () {
    expect(select({'XDG_CURRENT_DESKTOP': 'COSMIC', 'MAPRISMA_THEME_DESKTOP': 'generic'}), isA<GenericDesktop>());
    expect(select({'XDG_CURRENT_DESKTOP': 'KDE', 'MAPRISMA_THEME_DESKTOP': 'COSMIC'}), isA<CosmicDesktop>());
    expect(() => select({'MAPRISMA_THEME_DESKTOP': 'gnome'}), throwsArgumentError);
  });

  test('COSMIC interface font: CosmicTk interface_font, only the family changes; reset deletes it', () async {
    final d = CosmicDesktop(paths, {'HOME': '${root.path}/home', 'PATH': Platform.environment['PATH'] ?? '/usr/bin'});
    final fonts = await d.interfaceFonts();
    if (fonts.isEmpty) return; // no fontconfig here
    final tk = Directory('${paths.cosmicConfig}/com.system76.CosmicTk/v1')..createSync(recursive: true);
    final file = File('${tk.path}/interface_font')
      ..writeAsStringSync('(\n    family: "Open Sans",\n    weight: Semibold,\n    stretch: Normal,\n    style: Normal,\n)');
    expect(d.interfaceFont(), 'Open Sans');
    expect(await d.setInterfaceFont(fonts.first), isTrue);
    expect(file.readAsStringSync(), contains('family: "${fonts.first}"'));
    expect(file.readAsStringSync(), contains('weight: Semibold'));
    expect(await d.setInterfaceFont('No Such Font 123'), isFalse);
    expect(File('${tk.path}/monospace_font').existsSync(), isFalse);
    expect(await d.resetInterfaceFont(), isTrue);
    expect(file.existsSync(), isFalse);
    expect(d.interfaceFont(), isNull);
  });

  test('COSMIC blur: 15 look strengths on 14 steps, the four parts together, maximized apps stay', () {
    final d = CosmicDesktop(paths, const {});
    const now = {'strength': 6, 'windows': false, 'system': false, 'panel': false, 'applets': false, 'maximized': true};
    final on = d.blurTarget(now, on: true, strength: 15);
    expect(on, {'strength': 13, 'windows': true, 'system': true, 'panel': true, 'applets': true, 'maximized': true});
    expect(d.blurTarget(now, on: true, strength: 1)['strength'], 0);
    expect(d.blurTarget(on, on: false, strength: 8)['windows'], isFalse);
    expect(d.blurAsLook(on), {'on': true, 'strength': 15});
    expect(d.blurAsLook(now), {'on': false, 'strength': 7});
    for (var s = 1; s <= 15; s++) {
      final step = d.blurTarget(now, on: true, strength: s)['strength'] as int;
      expect(step, inInclusiveRange(0, 13));
    }
  });

  test('the generic backend changes nothing of the desktop', () async {
    final d = GenericDesktop(paths, const {});
    expect(d.caps, isEmpty);
    expect(await d.applyColors({'background': '#000000'}), isFalse);
    expect(await d.applyRon('/x.ron'), isFalse);
    expect(await d.setWallpaper('/x.png'), isFalse);
    expect(await d.setTerminal({}, 'x'), isFalse);
    expect(await d.setIconTheme('Adwaita'), isFalse);
    expect((await d.wm(['workspaces']))?['error'], 'not_available');
    expect(d.shortcutBinder(paths), isNull);
    expect(await d.health(paths, const {}), isEmpty);
    expect(desktopInfo(d), {'id': 'generic', 'name': 'your desktop', 'terminal': null, 'caps': <String>[]});
  });

  test('COSMIC has every cap; desktop.info and core.hello name the backend', () async {
    expect(CosmicDesktop(paths, const {}).caps, Cap.values.toSet().difference({Cap.kdeScheme, Cap.animations}));
    final env = TestEnv.create();
    addTearDown(env.dispose);
    final info = await env.core.call('desktop.info');
    expect(info['id'], 'cosmic');
    expect(info['name'], 'COSMIC');
    expect(info['terminal'], 'COSMIC Terminal');
    expect(info['caps'], [for (final c in Cap.values) c.name]); // the fake has every cap
    expect((await env.core.call('core.hello'))['desktop'], 'cosmic');
  });

  test('without shortcuts the keys are kept but nothing is written', () async {
    final env = TestEnv.create(desktop: FakeDesktop(id: 'generic', name: 'your desktop', terminalName: null, caps: const {}));
    addTearDown(env.dispose);
    env.addTheme('nord');
    final list = await env.core.call('shortcuts.list');
    expect(list['available'], isFalse);
    expect(list['desktop'], 'your desktop');
    await expectLater(
      env.core.call('shortcuts.set', {'target': 'open', 'mods': ['SUPER', 'ALT'], 'combo_key': 'U'}),
      throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_available')),
    );
    final h = await env.core.call('health.get');
    expect(h['shortcuts']['available'], isFalse);
    expect(h['shortcuts']['ok'], isTrue);
    expect(h['helper']['ok'], isFalse);
    expect(Directory(env.paths.cosmicConfig).existsSync(), isFalse);
  });
}
