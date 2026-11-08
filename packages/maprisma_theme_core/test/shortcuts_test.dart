import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/auto.dart';
import 'package:maprisma_theme_core/src/shortcuts.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestEnv env;
  late String custom;
  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => env.core.call(m, p);
  String text() => File(custom).readAsStringSync();

  setUp(() {
    env = TestEnv.create();
    env.addTheme('nord');
    env.addTheme('gruvbox', bg: '#282828');
    // only the temporary XDG config: never COSMIC's real one
    expect(env.paths.cosmicConfig, startsWith(env.root.path));
    final defaults = '${env.root.path}/defaults';
    File(defaults).writeAsStringSync('{\n'
        '    (modifiers: [Super], key: "q"): Close,\n'
        '    (modifiers: [Super, Ctrl], key: "t"): System(Terminal),\n'
        '    (modifiers: [Super, Ctrl], key: "l"): System(LockScreen),\n'
        '}\n');
    cosmicShortcutDefaults = defaults;
    custom = '${env.paths.cosmicConfig}/com.system76.CosmicSettings.Shortcuts/v1/custom';
    Directory(File(custom).parent.path).createSync(recursive: true);
    File(custom).writeAsStringSync('{\n'
        '    // mine\n'
        '    (modifiers: [Super, Ctrl], key: "b"): Spawn("firefox"),\n'
        '    (modifiers: [Super, Ctrl], key: "l"): Disable,\n'
        '}\n');
    final bin = Directory('${env.paths.home}/.local/bin')..createSync(recursive: true);
    for (final name in ['maprisma-theme-core', 'maprisma-theme']) {
      File('${bin.path}/$name').writeAsStringSync('#!/bin/sh\n');
      chmodPath('${bin.path}/$name', 493);
    }
  });
  tearDown(() => env.dispose());

  test('keys are coloured: free, ours, the user\'s own, COSMIC default', () async {
    final view = await call('shortcuts.state', {'target': 'bg:next', 'mods': ['SUPER', 'CTRL']});
    expect(view['available'], isTrue);
    expect(view['current'], isNull);
    Map key(String k) => (view['keys'] as List).firstWhere((e) => e['key'] == k) as Map;
    expect(key('T')['level'], 'desktop');
    expect(key('T')['owner'], 'Terminal');
    expect(key('B')['level'], 'custom');
    expect(key('B')['owner'], 'firefox');
    expect(key('L')['level'], 'free'); // the user turned COSMIC's off
    expect(key('X')['level'], 'free');
    expect(view['title'], 'Next wallpaper');
  });

  test('assign writes a Spawn entry; rebind takes a key and remove gives it back', () async {
    final home = env.paths.home;
    var r = await call('shortcuts.set', {'target': 'apply:nord', 'mods': ['SUPER', 'ALT'], 'combo_key': 'U'});
    expect(r['level'], 'free');
    expect(text(), contains('(modifiers: [Super, Alt], key: "u", description: Some("Maprisma Theme: Apply Nord (Maprisma Theme)")): '
        'Spawn("$home/.local/bin/maprisma-theme-core apply nord")'));
    expect(jsonDecode(File(env.paths.file('shortcuts.json')).readAsStringSync()), {
      'apply:nord': {'mods': ['SUPER', 'ALT'], 'key': 'U'},
    });
    expect((await call('shortcuts.labels'))['labels'], {'apply:nord': ['Super + Alt + U']});

    // the user's own key: shadowed while ours exists
    r = await call('shortcuts.set', {'target': 'open', 'mods': ['SUPER', 'CTRL'], 'combo_key': 'b'});
    expect(r['level'], 'custom');
    expect(text(), isNot(contains('Spawn("firefox")')));
    expect(text(), contains('Spawn("$home/.local/bin/maprisma-theme --toggle")'));
    expect(text(), contains('// mine'));
    // a COSMIC default: overridden by the custom entry
    r = await call('shortcuts.set', {'target': 'bg:next', 'mods': ['SUPER', 'CTRL'], 'combo_key': 'T'});
    expect(r['level'], 'desktop');
    expect(r['owner'], 'Terminal');
    // another target's key moves
    r = await call('shortcuts.set', {'target': 'bg:prev', 'mods': ['SUPER', 'ALT'], 'combo_key': 'U'});
    expect(r['level'], 'ours');
    expect(env.core.ctx.lists.hidden, isEmpty);
    final state = jsonDecode(File(env.paths.file('shortcuts.json')).readAsStringSync()) as Map;
    expect(state.keys.toSet(), {'open', 'bg:next', 'bg:prev'});
    expect(state['open']['replaces'], 'firefox');
    expect(() => call('shortcuts.set', {'target': 'bg:prev', 'mods': ['SUPER', 'ALT'], 'combo_key': 'U'}),
        throwsA(isA<RouteError>()));

    r = await call('shortcuts.remove', {'target': 'open'});
    expect(r, {'removed': true, 'replaces': 'firefox'});
    expect(text(), contains('(modifiers: [Super, Ctrl], key: "b"): Spawn("firefox")'));
    await call('shortcuts.remove', {'target': 'bg:next'});
    await call('shortcuts.remove', {'target': 'bg:prev'});
    expect(text(), isNot(contains('Maprisma Theme')));
    expect(text(), contains('Disable'));
    parseCosmicShortcuts(text());
  });

  test('when COSMIC\'s file cannot be written, a shadowed key of the user is not lost', () async {
    await call('shortcuts.set', {'target': 'open', 'mods': ['SUPER', 'CTRL'], 'combo_key': 'b'});
    final shadow = env.paths.file('cosmic-shadowed.json');
    final stateBefore = File(env.paths.file('shortcuts.json')).readAsStringSync();
    final shadowBefore = File(shadow).readAsStringSync();
    expect(shadowBefore, contains('firefox'));
    final folder = File(custom).parent.path;
    chmodPath(folder, 320 /* 0500: no new files */);
    try {
      await expectLater(call('shortcuts.remove', {'target': 'open'}), throwsA(anything));
    } finally {
      chmodPath(folder, 448);
    }
    expect(File(env.paths.file('shortcuts.json')).readAsStringSync(), stateBefore);
    expect(File(shadow).readAsStringSync(), shadowBefore);
    expect(text(), isNot(contains('Spawn("firefox")')));
    // the next try gives it back
    expect((await call('shortcuts.remove', {'target': 'open'}))['removed'], isTrue);
    expect(text(), contains('(modifiers: [Super, Ctrl], key: "b"): Spawn("firefox")'));
  });

  test('an unreadable COSMIC file is reported before a missing program', () async {
    await call('shortcuts.set', {'target': 'bg:next', 'mods': ['SUPER', 'ALT'], 'combo_key': 'N'});
    File(custom).writeAsStringSync('not a map');
    File('${env.paths.home}/.local/bin/maprisma-theme-core').deleteSync();
    await expectLater(
      call('health.repair'),
      throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_available')),
    );
  });

  test('a deleted theme gives its key back; a renamed one keeps it', () async {
    await call('shortcuts.set', {'target': 'apply:nord', 'mods': ['SUPER', 'ALT'], 'combo_key': 'N'});
    await call('shortcuts.set', {'target': 'apply:gruvbox', 'mods': ['SUPER', 'ALT'], 'combo_key': 'G'});
    renameThemeState(env.core.ctx, 'gruvbox', 'gruvbox-2');
    expect((await call('shortcuts.list'))['themes'].map((t) => t['target']), contains('apply:gruvbox-2'));
    forgetThemeState(env.core.ctx, 'nord');
    expect(text(), isNot(contains('apply nord')));
    expect(ThemeShortcuts(env.core.ctx).load().keys, ['apply:gruvbox-2']);
    // the renamed theme's folder is not there in this test: its key does nothing until it is
    expect(text(), isNot(contains('apply gruvbox-2')));
  });

  test('legacy names, bad targets, missing programs, unreadable files', () async {
    expect(ThemeShortcuts.cleanShortcuts({
      'next-wallpaper': {'mods': ['SUPER'], 'key': 'n'},
      'bogus': {'mods': ['SUPER'], 'key': 'x'},
      'apply:../x': {'mods': ['SUPER'], 'key': 'y'},
    }), {'bg:next': {'mods': ['SUPER'], 'key': 'N'}});
    expect(() => call('shortcuts.state', {'target': 'rm -rf'}), throwsA(isA<RouteError>()));
    expect(() => call('shortcuts.set', {'target': 'open', 'mods': ['SUPER'], 'combo_key': 'Escape'}), throwsA(isA<RouteError>()));
    File('${env.paths.home}/.local/bin/maprisma-theme-core').deleteSync();
    final noPath = Ctx(paths: env.paths, desktop: env.desktop, environment: {'HOME': env.paths.home, 'PATH': '/nonexistent'});
    expect(() => ThemeShortcuts(noPath).assign('bg:next', makeCombo(['SUPER'], 'K')!),
        throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_installed')));
    File(custom).writeAsStringSync('not ron');
    expect(() => call('shortcuts.set', {'target': 'open', 'mods': ['SUPER'], 'combo_key': 'K'}), throwsA(isA<RouteError>()));
    expect(File(custom).readAsStringSync(), 'not ron');
  });
}
