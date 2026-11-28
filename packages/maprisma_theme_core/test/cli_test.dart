import 'dart:convert';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/workspace_state.dart' show loadWorkspaces;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestEnv e;
  setUp(() => e = TestEnv.create());
  tearDown(() => e.dispose());

  group('call <method> [<json>]', () {
    test('only the allowed methods', () {
      expect(cliCallMethods, containsAll(['workspaces.set', 'workspaces.undo', 'presets.undo', 'tiling.style.set', 'wallpapers.list']));
      for (final m in ['themes.apply', 'settings.set', 'backup.restore', 'ask.run', '', 'workspaces.set ']) {
        expect(cliCallRequest([m]).error, 'not_allowed', reason: m);
      }
      final ok = cliCallRequest(['workspaces.get']);
      expect(ok.method, 'workspaces.get');
      expect(ok.params, isEmpty);
      expect(ok.error, isNull);
    });

    test('params: a JSON object of at most 64 KiB', () {
      expect(cliCallRequest(['workspaces.set', '{"workspace": 1, "preset": "grid"}']).params, {'workspace': 1, 'preset': 'grid'});
      for (final bad in ['[1, 2]', '"x"', '3', 'null', '{oops', '']) {
        expect(cliCallRequest(['workspaces.set', bad]).error, 'bad_args', reason: bad);
      }
      final pad = 'x' * (cliCallMaxParams - '{"p":""}'.length);
      expect(utf8.encode('{"p":"$pad"}').length, cliCallMaxParams);
      expect(cliCallRequest(['workspaces.get', '{"p":"$pad"}']).error, isNull);
      expect(cliCallRequest(['workspaces.get', '{"p":"${pad}y"}']).error, 'too_large');
      // bytes, not characters
      expect(cliCallRequest(['workspaces.get', '{"p":"${'ä' * 40000}"}']).error, 'too_large');
      expect(cliCallRequest([]).error, 'bad_args');
      expect(cliCallRequest(['workspaces.get', '{}', 'more']).error, 'bad_args');
    });

    test('runs the route; refusals exit 2, route errors 1', () async {
      expect(await runCli(['call', 'workspaces.set', '{"workspace": 3, "preset": "master-right", "split": 0.25}'], service: e.core), 0);
      final s = loadWorkspaces(e.core.ctx);
      expect(s['workspacePresets'], {'3': 'master-right'});
      expect(s['workspaceSplits'], {'3': 0.25});
      expect(await runCli(['call', 'themes.apply', '{"slug": "x"}'], service: e.core), 2);
      expect(await runCli(['call', 'workspaces.set', '[]'], service: e.core), 2);
      expect(await runCli(['call', 'workspaces.set', '{"workspace": 3, "preset": "tabs"}'], service: e.core), 1);
      // undo from a later call: kept on disk
      expect(await runCli(['call', 'workspaces.undo'], service: CoreService(environment: e.core.ctx.environment, paths: e.paths, desktop: e.desktop)), 0);
      expect(loadWorkspaces(e.core.ctx)['workspacePresets'], isEmpty);
      expect(await runCli(['call', 'workspaces.undo'], service: e.core), 1); // nothing left
    });
  });
}
