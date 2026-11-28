import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/workspace_state.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestEnv e;
  setUp(() => e = TestEnv.create());
  tearDown(() => e.dispose());
  Future<Map<String, dynamic>> call(String r, [Map<String, dynamic> p = const {}]) => e.core.call(r, p);
  Map<String, dynamic> state() => loadWorkspaces(e.core.ctx);
  String file() => e.paths.file('workspaces.json');

  group('workspaces.json schema 2', () {
    test('a v1 file reads as it was: every COSMIC/KDE key kept, the new maps empty', () {
      final v1 = {
        'active': true,
        'autoMoveOnRestore': true,
        'maxWindows': 3,
        'workspaceCaps': {'2': 1},
        'workspaceModes': {'1': 'tiled', '2': 'floating', '3': 'default'},
        'defaultModes': {'3': 'tiled'},
        'workspaceLayouts': {
          '1': {
            'apps': ['editor.desktop'],
            'autostart': true,
          },
        },
      };
      writeJson(file(), v1);
      final s = state();
      expect(s['schema'], 2);
      for (final k in v1.keys) {
        expect(s[k], v1[k], reason: k);
      }
      expect(s['workspacePresets'], isEmpty);
      expect(s['defaultPresets'], isEmpty);
      expect(s['workspaceSplits'], isEmpty);
      expect(s.containsKey('defaultSplit'), isFalse);
      // written back: still every v1 key the applet and KWin read, as they were
      saveWorkspaces(e.core.ctx, s);
      final again = jsonDecode(File(file()).readAsStringSync()) as Map;
      for (final k in v1.keys) {
        expect(again[k], v1[k], reason: k);
      }
      expect(cleanWorkspaceState(again), s); // round trip
    });

    test('presets and splits are cleaned: names whitelisted, splits clamped and rounded', () {
      writeJson(file(), {
        'schema': 7,
        'workspacePresets': {'1': 'grid', '2': 'tabs', '3': 'none', '11': 'grid', '4': 3},
        'defaultPresets': {'1': 'stacked', '4': 'columns', '5': 'grid'},
        'workspaceSplits': {'1': 0.1, '2': 0.95, '3': 0.333, '4': 'half', '5': 0.5, '12': 0.5},
        'defaultSplit': 0.456,
      });
      final s = state();
      expect(s['schema'], 2);
      expect(s['workspacePresets'], {'1': 'grid', '3': 'none'});
      expect(s['defaultPresets'], {'1': 'stacked', '4': 'columns'});
      expect(s['workspaceSplits'], {'1': 0.2, '2': 0.8, '3': 0.33, '5': 0.5});
      expect(s['defaultSplit'], 0.46);
      expect(cleanSplit(double.nan), isNull);
      expect(cleanSplit(double.infinity), isNull);
      expect(cleanSplit(0.7, max: columnsSplitMax), 0.6);
      expect(cleanSplit(1), 0.8);
    });
  });

  group('mapping', () {
    test('presets and COSMIC/KDE layouts', () {
      expect(modeForPreset('floating'), 'floating');
      expect(modeForPreset('none'), 'default');
      expect(modeForPreset('scrolling'), 'default');
      for (final p in ['side-by-side', 'stacked', 'master-left', 'master-right', 'columns', 'grid']) {
        expect(modeForPreset(p), 'tiled');
      }
      expect(presetForMode('floating'), 'floating');
      expect(presetForMode('default'), 'none');
      expect(presetForMode('tiled'), 'side-by-side');
      expect(presetForMode('tiled', cap: 1), 'side-by-side');
      expect(presetForMode('tiled', cap: 3), 'master-left');
      expect(presetForMode('tiled', cap: 4), 'grid');
      expect([for (var c = 1; c <= 4; c++) builtinDefaultPreset(c)], ['side-by-side', 'side-by-side', 'master-left', 'grid']);
      expect(builtinDefaultPreset(9), 'side-by-side');
      expect(validPresetsForCap(1), ['side-by-side']);
      expect(validPresetsForCap(2), ['side-by-side', 'stacked']);
      expect(validPresetsForCap(3), ['columns', 'master-left', 'master-right']);
      expect(validPresetsForCap(4), ['columns', 'master-left', 'master-right', 'grid']);
      expect(presetNames.where(isUnlimitedPreset), ['floating', 'scrolling', 'none']);
    });

    test('effective preset: own, own layout, limit default preset, limit default layout, built-in', () {
      final s = cleanWorkspaceState({
        'maxWindows': 3,
        'workspaceCaps': {'5': 4, '6': 2, '7': 4},
        'workspacePresets': {'1': 'columns'},
        'workspaceModes': {'1': 'tiled', '2': 'floating', '3': 'default', '4': 'tiled'},
        'defaultPresets': {'3': 'master-right'},
        'defaultModes': {'4': 'floating', '3': 'tiled'},
      });
      expect(effectivePreset(s, 1), 'columns');
      expect(effectivePreset(s, 2), 'floating');
      expect(effectivePreset(s, 3), 'none'); // Native chosen explicitly
      expect(effectivePreset(s, 4), 'master-left'); // tiled at limit 3: the built-in tiling preset
      expect(effectivePreset(s, 8), 'master-right'); // limit 3's default preset
      expect(effectivePreset(s, 0), 'master-right');
      expect(effectivePreset(s, 5), 'floating'); // limit 4's default layout
      expect(effectivePreset(s, 6), 'side-by-side'); // nothing for limit 2: built-in
      expect(presetConfigured(s, 6), isFalse); // … which counts only while limits are on
      expect(presetConfigured({...s, 'active': true}, 6), isTrue);
      expect(presetConfigured(s, 3), isTrue);
      final empty = cleanWorkspaceState(null);
      expect(effectivePreset(empty, 1), 'side-by-side');
      expect(effectiveMode(empty, 1), 'default'); // COSMIC/KDE: Native, as before
    });

    test('effective split: own, then the default, then even', () {
      final s = cleanWorkspaceState({'workspaceSplits': {'2': 0.3}, 'defaultSplit': 0.6});
      expect(effectiveSplit(s, 2), 0.3);
      expect(effectiveSplit(s, 3), 0.6);
      expect(effectiveSplit(s, 0), 0.6);
      expect(effectiveSplit(cleanWorkspaceState(null), 1), isNull);
    });
  });

  group('workspaces.set', () {
    test('a preset sets the layout it stands for; a layout drops a preset it no longer matches', () async {
      await call('workspaces.set', {'workspace': 2, 'preset': 'master-right'});
      var s = state();
      expect(s['workspacePresets'], {'2': 'master-right'});
      expect(s['workspaceModes'], {'2': 'tiled'});
      await call('workspaces.set', {'workspace': 2, 'mode': 'tiled'}); // still matches: kept
      expect(state()['workspacePresets'], {'2': 'master-right'});
      await call('workspaces.set', {'workspace': 2, 'mode': 'floating'});
      s = state();
      expect(s['workspacePresets'], isEmpty);
      expect(effectivePreset(s, 2), 'floating');
      await call('workspaces.set', {'workspace': 3, 'preset': 'scrolling'});
      expect(state()['workspaceModes']['3'], 'default');
      await call('workspaces.set', {'workspace': 3, 'preset': null}); // back to the defaults
      s = state();
      expect(s['workspacePresets'], isEmpty);
      expect((s['workspaceModes'] as Map).containsKey('3'), isFalse);
      await call('workspaces.set', {'workspace': 4, 'preset': 'grid'});
      await call('workspaces.set', {'workspace': 4, 'mode': null});
      expect(state()['workspacePresets'], isEmpty);
    });

    test('default presets per limit keep the default layouts in step', () async {
      await call('workspaces.set', {'defaultLimit': 3, 'defaultPreset': 'columns'});
      var s = state();
      expect(s['defaultPresets'], {'3': 'columns'});
      expect(s['defaultModes'], {'3': 'tiled'});
      await call('workspaces.set', {'defaultLimit': 3, 'defaultMode': 'floating'});
      s = state();
      expect(s['defaultPresets'], isEmpty);
      expect(s['defaultModes'], {'3': 'floating'});
      await call('workspaces.set', {'defaultLimit': 2, 'defaultPreset': 'stacked'});
      await call('workspaces.set', {'defaultLimit': 2, 'defaultPreset': null});
      s = state();
      expect((s['defaultModes'] as Map).containsKey('2'), isFalse);
      for (final p in [
        {'defaultLimit': 5, 'defaultPreset': 'grid'},
        {'defaultLimit': 2, 'defaultPreset': 'tabs'},
        {'workspace': 1, 'preset': 'tabs'},
        {'workspace': 1, 'preset': 3},
      ]) {
        await expectLater(call('workspaces.set', p), throwsA(isA<RouteError>()), reason: '$p');
      }
    });

    test('splits: clamped, rounded, Columns at most 0.60, null removes, bad ones refused', () async {
      await call('workspaces.set', {'workspace': 1, 'split': 0.95});
      expect(state()['workspaceSplits'], {'1': 0.8});
      await call('workspaces.set', {'workspace': 1, 'split': 0.12});
      expect(state()['workspaceSplits'], {'1': 0.2});
      await call('workspaces.set', {'workspace': 2, 'preset': 'columns', 'split': 0.75});
      expect(state()['workspaceSplits']['2'], 0.6);
      await call('workspaces.set', {'workspace': 3, 'split': 0.444});
      expect(state()['workspaceSplits']['3'], 0.44);
      await call('workspaces.set', {'split': 0.7}); // no workspace: the default
      expect(state()['defaultSplit'], 0.7);
      await call('workspaces.set', {'workspace': 1, 'split': null});
      await call('workspaces.set', {'split': null});
      final s = state();
      expect((s['workspaceSplits'] as Map).keys, ['2', '3']);
      expect(s.containsKey('defaultSplit'), isFalse);
      for (final bad in ['half', true, double.nan, double.infinity]) {
        await expectLater(call('workspaces.set', {'workspace': 1, 'split': bad}), throwsA(isA<RouteError>()), reason: '$bad');
      }
    });
  });

  test('bulk: reset_all clears presets and splits, remove_all makes every workspace Native', () async {
    await call('workspaces.set', {'workspace': 1, 'preset': 'grid', 'split': 0.3, 'limit': 4});
    await call('workspaces.bulk', {'action': 'reset_all'});
    var s = state();
    for (final k in ['workspaceCaps', 'workspaceModes', 'workspacePresets', 'workspaceSplits']) {
      expect(s[k], isEmpty, reason: k);
    }
    await call('workspaces.bulk', {'action': 'remove_all'});
    s = state();
    expect((s['workspacePresets'] as Map).length, 10);
    expect((s['workspacePresets'] as Map).values.toSet(), {'none'});
    expect((s['workspaceModes'] as Map).values.toSet(), {'default'});
    expect(effectivePreset(s, 7), 'none');
  });

  test('looks: each workspace\'s preset and split, and whether they are its own', () async {
    final dir = e.addTheme('one');
    e.core.ctx.current.save(slug: 'one', wallpaper: '$dir/backgrounds/1.png');
    await call('workspaces.set', {'workspace': 2, 'preset': 'master-left', 'split': 0.65});
    await call('workspaces.set', {'split': 0.4});
    final looks = (await call('workspaces.looks'))['workspaces'] as Map;
    expect(looks['2']['preset'], 'master-left');
    expect(looks['2']['own_preset'], isTrue);
    expect(looks['2']['split'], 0.65);
    expect(looks['2']['own_split'], isTrue);
    expect(looks['3']['preset'], 'side-by-side');
    expect(looks['3']['own_preset'], isFalse);
    expect(looks['3']['split'], 0.4);
    expect(looks['3']['own_split'], isFalse);
    expect(looks['0']['own_preset'], isFalse);
    expect(looks['0']['split'], 0.4);
  });

  test('automation: presets of the workspaces that chose one, splits and the unlimited ones', () async {
    await call('workspaces.set', {'workspace': 2, 'preset': 'scrolling'});
    await call('workspaces.set', {'workspace': 3, 'preset': 'master-left', 'split': 0.3});
    await call('workspaces.set', {'workspace': 4, 'mode': 'default'});
    await call('workspaces.set', {'split': 0.55});
    final t = tilingAutomation(e.core.ctx)['tiling'] as Map;
    expect(t['presets'], {'2': 'scrolling', '3': 'master-left', '4': 'none'});
    expect(t['splits'], {'3': 0.3});
    expect(t['default_split'], 0.55);
    expect(t['unlimited'], [2, 4]);
    for (final k in ['active', 'default_limit', 'limits', 'floating', 'tiled']) {
      expect(t.containsKey(k), isTrue, reason: k);
    }
    final written = readJsonMap(e.paths.automationFile)['tiling'] as Map;
    expect(written['presets'], t['presets']);
    expect(written['default_split'], 0.55);
    expect(e.desktop.lastTilingAutomation?['unlimited'], [2, 4]);
  });

  group('apply', () {
    test('a desktop with presets gets set-preset (with the split) for every workspace that chose one', () async {
      final env = TestEnv.create(desktop: FakeDesktop(id: 'hyprland', name: 'Hyprland', caps: Cap.values.toSet()));
      addTearDown(env.dispose);
      await env.core.call('workspaces.set', {'workspace': 2, 'preset': 'master-left', 'split': 0.4});
      await env.core.call('workspaces.set', {'workspace': 5, 'preset': 'floating'});
      env.desktop.calls.clear();
      await env.core.call('workspaces.apply');
      expect(env.desktop.calls.where((c) => c.startsWith('helper set-')), ['helper set-preset 2 master-left 0.40', 'helper set-preset 5 floating']);
      // limits on: the built-in presets too
      await env.core.call('workspaces.set', {'active': true});
      env.desktop.calls.clear();
      await env.core.call('workspaces.apply');
      expect(env.desktop.calls.where((c) => c.startsWith('helper set-')), hasLength(10));
      expect(env.desktop.calls, contains('helper set-preset 1 side-by-side'));
    });

    test('COSMIC/KDE keep set-tiling (no set-preset)', () async {
      await call('workspaces.set', {'workspace': 1, 'preset': 'grid'});
      await call('workspaces.apply');
      expect(e.desktop.calls, contains('helper set-tiling 1 on'));
      expect(e.desktop.calls.where((c) => c.contains('set-preset')), isEmpty);
    });
  });

  group('workspaces.undo (on disk: works across CLI calls)', () {
    test('one step back, also from a new process; private, then gone', () async {
      await call('workspaces.set', {'workspace': 1, 'preset': 'grid'});
      await call('workspaces.set', {'workspace': 1, 'preset': 'stacked', 'split': 0.3});
      final undoFile = '${e.paths.state}/last-undo.json';
      expect(File(undoFile).statSync().mode & 511, 384); // 0600
      final saved = jsonDecode(File(undoFile).readAsStringSync()) as Map;
      expect(saved.keys.toSet(), {'version', 'workspaces'});
      // another process (maprisma-theme-core call): the in-memory receipts are gone, the file is not
      final other = CoreService(environment: e.core.ctx.environment, paths: e.paths, desktop: e.desktop);
      final r = await other.call('workspaces.undo');
      expect(r['undone'], isTrue);
      expect(state()['workspacePresets'], {'1': 'grid'});
      expect(state()['workspaceSplits'], isEmpty);
      expect(File(undoFile).existsSync(), isFalse);
      await expectLater(other.call('workspaces.undo'), throwsA(isA<RouteError>().having((x) => x.code, 'code', 'not_found')));
    });

    test('a broken or oversized snapshot is never applied', () async {
      final undoFile = '${e.paths.state}/last-undo.json';
      writeJson(undoFile, ['not', 'a', 'map']);
      await expectLater(call('workspaces.undo'), throwsA(isA<RouteError>()));
      File(undoFile).writeAsStringSync('{"workspaces": {"maxWindows": 4}, "pad": "${'x' * (lastUndoMax + 10)}"}');
      await expectLater(call('workspaces.undo'), throwsA(isA<RouteError>()));
      expect(state()['maxWindows'], 2);
      // a snapshot's values are cleaned like workspaces.json
      writeJson(undoFile, {
        'version': 1,
        'workspaces': {'maxWindows': 3, 'workspacePresets': {'1': 'rm -rf'}},
      });
      await call('workspaces.undo');
      expect(state()['maxWindows'], 3);
      expect(state()['workspacePresets'], isEmpty);
    });

    test('presets.undo still works with receipts', () async {
      final r = await call('workspaces.set', {'workspace': 6, 'preset': 'columns'});
      await call('presets.undo', {'receipt': r['receipt']});
      expect(state()['workspacePresets'], isEmpty);
    });

    test('a link in place of last-undo.json is neither written through nor read', () async {
      final undoFile = '${e.paths.state}/last-undo.json';
      Directory(e.paths.state).createSync(recursive: true);
      final elsewhere = File('${e.root.path}/elsewhere.json')..writeAsStringSync('{"keep": true}');
      Link(undoFile).createSync(elsewhere.path);
      await call('workspaces.set', {'workspace': 1, 'preset': 'grid'});
      expect(elsewhere.readAsStringSync(), '{"keep": true}');
      expect(FileSystemEntity.isLinkSync(undoFile), isTrue);
      // a link to a valid snapshot is not followed either
      elsewhere.writeAsStringSync(jsonEncode({'version': 1, 'workspaces': {'maxWindows': 4}}));
      await expectLater(call('workspaces.undo'), throwsA(isA<RouteError>().having((x) => x.code, 'code', 'not_found')));
      expect(state()['maxWindows'], 2);
      expect(Directory(e.paths.state).listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('the snapshot is private from creation and its folder closed (0700)', () async {
      Directory(e.paths.state).createSync(recursive: true);
      chmodPath(e.paths.state, 493 /* 0755 */);
      await call('workspaces.set', {'workspace': 1, 'preset': 'grid'});
      final undoFile = '${e.paths.state}/last-undo.json';
      expect(FileSystemEntity.typeSync(undoFile, followLinks: false), FileSystemEntityType.file);
      expect(File(undoFile).statSync().mode & 511, 384);
      expect(Directory(e.paths.state).statSync().mode & 511, 448);
    });

    test('presets.apply with workspaces keeps a workspaces.undo step', () async {
      final dir = e.addTheme('one');
      e.core.ctx.current.save(slug: 'one', wallpaper: '$dir/backgrounds/1.png');
      await call('workspaces.set', {'workspace': 2, 'preset': 'grid'});
      await call('presets.save', {'name': 'Grid', 'includeWorkspaces': true});
      await call('workspaces.set', {'workspace': 2, 'preset': null});
      File('${e.paths.state}/last-undo.json').deleteSync();
      await call('presets.apply', {'name': 'Grid', 'confirmed': true});
      expect(state()['workspacePresets'], {'2': 'grid'});
      await call('workspaces.undo');
      expect(state()['workspacePresets'], isEmpty);
    });
  });

  group('workspaces.set: clearing a preset clears the v1 layout it came from', () {
    test('per workspace', () async {
      writeJson(file(), {
        'workspaceModes': {'2': 'floating', '3': 'tiled'},
      });
      expect(effectivePreset(state(), 2), 'floating');
      await call('workspaces.set', {'workspace': 2, 'preset': null});
      final s = state();
      expect((s['workspaceModes'] as Map).containsKey('2'), isFalse);
      expect(effectivePreset(s, 2), 'side-by-side'); // back to the defaults
      expect(s['workspaceModes']['3'], 'tiled'); // the others kept
      // a mode in the same call still wins
      await call('workspaces.set', {'workspace': 3, 'preset': null, 'mode': 'floating'});
      expect(state()['workspaceModes']['3'], 'floating');
    });

    test('per limit', () async {
      writeJson(file(), {
        'defaultModes': {'3': 'floating', '2': 'tiled'},
      });
      await call('workspaces.set', {'defaultLimit': 3, 'defaultPreset': null});
      final s = state();
      expect((s['defaultModes'] as Map).containsKey('3'), isFalse);
      expect(s['defaultModes']['2'], 'tiled');
    });
  });

  group('undo on Hyprland', () {
    TestEnv hypr() {
      final env = TestEnv.create(desktop: FakeDesktop(id: 'hyprland', name: 'Hyprland', caps: Cap.values.toSet()));
      addTearDown(env.dispose);
      return env;
    }

    List<String> setCalls(TestEnv env) => env.desktop.calls.where((c) => c.startsWith('helper set-')).toList();

    test('workspaces.undo: a workspace no longer configured goes back to none (its floated windows tiled again)', () async {
      final env = hypr();
      await env.core.call('workspaces.set', {'workspace': 5, 'preset': 'floating'});
      await env.core.call('workspaces.set', {'workspace': 2, 'preset': 'grid'});
      env.desktop.calls.clear();
      await env.core.call('workspaces.undo'); // 2 loses grid; 5 keeps floating
      expect(setCalls(env), ['helper set-preset 2 none', 'helper set-preset 5 floating']);
    });

    test('presets.undo: no tiling touched unless the change captured it', () async {
      final env = hypr();
      final r = await env.core.call('workspaces.set', {'workspace': 4, 'preset': 'grid'});
      env.desktop.calls.clear();
      await env.core.call('presets.undo', {'receipt': r['receipt']});
      expect(setCalls(env), isEmpty);
      expect(loadWorkspaces(env.core.ctx)['workspacePresets'], isEmpty);
    });

    test('presets.undo of an applied preset: a workspace it floated goes back to none', () async {
      final env = hypr();
      final dir = env.addTheme('one');
      env.core.ctx.current.save(slug: 'one', wallpaper: '$dir/backgrounds/1.png');
      await env.core.call('workspaces.set', {'workspace': 5, 'preset': 'floating'});
      await env.core.call('presets.save', {'name': 'Float', 'includeWorkspaces': true});
      await env.core.call('workspaces.set', {'workspace': 5, 'preset': null});
      final r = await env.core.call('presets.apply', {'name': 'Float', 'confirmed': true});
      expect(env.desktop.calls, contains('helper set-preset 5 floating'));
      env.desktop.calls.clear();
      await env.core.call('presets.undo', {'receipt': r['receipt']});
      expect(setCalls(env), ['helper set-preset 5 none']);
      expect(loadWorkspaces(env.core.ctx)['workspacePresets'], isEmpty);
    });
  });
}
