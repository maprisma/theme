import 'dart:async';
import 'dart:io';
import 'package:maprisma_theme_core/src/auto.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/launchers.dart';
import 'package:maprisma_theme_core/src/presets.dart';
import 'package:maprisma_theme_core/src/workspace_state.dart';
import 'package:test/test.dart';
import 'support.dart';

void main() {
  late TestEnv e;
  setUp(() => e = TestEnv.create());
  tearDown(() => e.dispose());
  Future<Map<String, dynamic>> call(
    String r, [
    Map<String, dynamic> p = const {},
  ]) => e.core.call(r, p);
  void windows() {
    e.desktop.workspaces = {
      'workspaces': [
        {'index': 1},
        {'index': 2},
        {'index': 3},
      ],
      'can_tile': true,
    };
    e.desktop.windows = {
      'windows': [
        {'id': 'a', 'app_id': 'editor', 'workspace': 1},
        {'id': 'b', 'app_id': 'browser', 'workspace': 2},
      ],
    };
  }

  test('workspace automation and undo', () async {
    final r = await call('workspaces.set', {
      'active': true,
      'maxWindows': 3,
      'workspace': 2,
      'limit': 1,
      'mode': 'floating',
    });
    expect(readJsonMap(e.paths.automationFile)['tiling'], {
      'active': true,
      'default_limit': 3,
      'limits': {'2': 1},
      'floating': [2],
      'tiled': [],
    });
    await call('presets.undo', {'receipt': r['receipt']});
    expect(loadWorkspaces(e.core.ctx)['maxWindows'], 2);
  });
  test('invalid workspace rules rejected', () async {
    for (final p in [
      {'maxWindows': 5},
      {'workspace': 11},
      {'workspace': 1, 'mode': 'master-left'},
    ]) {
      await expectLater(call('workspaces.set', p), throwsA(isA<RouteError>()));
    }
  });
  test('apply now sends explicit modes to existing workspaces', () async {
    windows();
    await call('workspaces.set', {'workspace': 1, 'mode': 'tiled'});
    await call('workspaces.set', {'workspace': 2, 'mode': 'floating'});
    await call('workspaces.apply');
    expect(
      e.desktop.calls,
      containsAll(['helper set-tiling 1 on', 'helper set-tiling 2 off']),
    );
  });
  test('restore asks before mutations and undo reverses moves', () async {
    windows();
    await call('apppresets.save', {'workspace': 1});
    e.desktop.windows['windows'] = [
      {'id': 'a', 'app_id': 'editor', 'workspace': 2},
      {'id': 'x', 'app_id': 'other', 'workspace': 1},
    ];
    expect(
      (await call('apppresets.restore', {'workspace': 1}))['status'],
      'conflict',
    );
    expect(e.desktop.calls.where((s) => s.startsWith('helper move')), isEmpty);
    final r = await call('apppresets.restore', {
      'workspace': 1,
      'action': 'move',
    });
    expect(
      e.desktop.calls,
      containsAll(['helper move x 3', 'helper move a 1']),
    );
    await call('presets.undo', {'receipt': r['receipt']});
    expect(
      e.desktop.calls,
      containsAll(['helper move x 1', 'helper move a 2']),
    );
  });
  test('keep and close policies', () async {
    windows();
    await call('apppresets.save', {'workspace': 1});
    (e.desktop.windows['windows'] as List).add({
      'id': 'x',
      'app_id': 'other',
      'workspace': 1,
    });
    await call('apppresets.restore', {'workspace': 1, 'action': 'keep'});
    expect(e.desktop.calls, isNot(contains('helper close x')));
    await call('apppresets.restore', {'workspace': 1, 'action': 'close'});
    expect(e.desktop.calls, contains('helper close x'));
  });
  test('no empty workspace refuses before moving', () async {
    windows();
    await call('apppresets.save', {'workspace': 1});
    e.desktop.workspaces['workspaces'] = [
      {'index': 1},
      {'index': 2},
    ];
    (e.desktop.windows['windows'] as List).add({
      'id': 'x',
      'app_id': 'other',
      'workspace': 1,
    });
    await expectLater(
      call('apppresets.restore', {'workspace': 1, 'action': 'move'}),
      throwsA(isA<RouteError>()),
    );
    expect(e.desktop.calls.where((s) => s.startsWith('helper move')), isEmpty);
  });
  test('unknown apps return partial without running saved commands', () async {
    saveWorkspaces(e.core.ctx, {
      'workspaceLayouts': {
        '1': {
          'apps': ['uninstalled-app'],
          'argv': ['touch', '/tmp/unwanted'],
        },
      },
    });
    final r = await call('apppresets.restore', {'workspace': 1});
    expect(r['failed'], ['uninstalled-app']);
    expect(r['status'], 'partial');
  });
  test('private autostart copy and removal undo', () async {
    windows();
    await call('apppresets.save', {'workspace': 1});
    await call('apppresets.autostart', {'workspace': 1, 'enabled': true});
    final f = File('${e.paths.state}/autostart.json');
    expect(f.statSync().mode & 511, 384);
    expect(readJsonMap(e.paths.automationFile)['autostart'], true);
    final r = await call('apppresets.remove', {'workspace': 1, 'index': 0});
    expect(readJsonMap(f.path)['1']['apps'], isEmpty);
    await call('presets.undo', {'receipt': r['receipt']});
    expect(readJsonMap(f.path)['1']['apps'], ['editor']);
    await call('apppresets.save', {'workspace': 1});
    expect(readJsonMap(f.path), isEmpty);
  });
  test('autostart uses approved copy once per login', () async {
    windows();
    await call('apppresets.save', {'workspace': 1});
    await call('apppresets.autostart', {'workspace': 1, 'enabled': true});
    e.core.ctx.environment['XDG_SESSION_ID'] = 'test-session';
    final s = loadWorkspaces(e.core.ctx);
    s['workspaceLayouts']['1']['apps'] = ['uninstalled-app'];
    saveWorkspaces(e.core.ctx, s, approveAutostart: false);
    expect(
      (await call('presets.autostart'))['results']['1']['failed'],
      isEmpty,
    );
    expect((await call('presets.autostart'))['status'], 'already_started');
  });
  test(
    'named presets confirm apply, follow renames, delete and undo',
    () async {
      final dir = e.addTheme('one');
      e.addTheme('two');
      e.core.ctx.current.save(slug: 'one', wallpaper: '$dir/backgrounds/1.png');
      await e.desktop.setMonospaceFont('Fira Code');
      await call('presets.save', {
        'name': ' My   preset ',
        'includeWorkspaces': true,
      });
      expect(loadPresets(e.core.ctx).single['name'], 'My preset');
      await expectLater(
        call('presets.apply', {'name': 'My preset'}),
        throwsA(isA<RouteError>()),
      );
      await call('presets.apply', {'name': 'My preset', 'confirmed': true});
      expect(e.desktop.monospaceFont(), 'Fira Code');
      renameThemeState(e.core.ctx, 'one', 'two');
      expect(loadPresets(e.core.ctx).single['theme'], 'two');
      final r = await call('presets.delete', {'name': 'My preset'});
      expect(loadPresets(e.core.ctx), isEmpty);
      await call('presets.undo', {'receipt': r['receipt']});
      expect(loadPresets(e.core.ctx), hasLength(1));
    },
  );
  test('assignment uses module C maps', () async {
    final dir = e.addTheme('one');
    e.core.ctx.current.save(slug: 'one', wallpaper: '$dir/backgrounds/1.png');
    await call('presets.save', {'name': 'One'});
    await call('presets.assign', {
      'name': 'One',
      'workspaces': [2, 4],
    });
    expect((await call('auto.workspace_themes'))['themes'], {
      '2': 'one',
      '4': 'one',
    });
    expect(readJsonMap(e.paths.automationFile)['workspace_events'], true);
  });
  test('bounded XDG launcher lookup by ID and StartupWMClass', () {
    final d = Directory('${e.paths.data}/applications')
      ..createSync(recursive: true);
    File('${d.path}/editor.desktop').writeAsStringSync(
      '[Desktop Entry]\nType=Application\nExec=editor %U\nStartupWMClass=MyEditor\n',
    );
    File('${d.path}/hidden.desktop').writeAsStringSync(
      '[Desktop Entry]\nType=Application\nExec=hidden\nHidden=true\n',
    );
    File('${d.path}/huge.desktop').writeAsStringSync('x' * (256 * 1024 + 1));
    e.core.ctx.environment['XDG_DATA_DIRS'] = '${e.root.path}/empty';
    final l = scanLaunchers(e.core.ctx);
    expect(l, hasLength(1));
    expect(findLauncher(l, 'MyEditor')?.id, 'editor.desktop');
    expect(findLauncher(l, 'editor')?.id, 'editor.desktop');
    expect(findLauncher(l, '../../bad'), isNull);
  });
  test('apply now undo restores live tiling', () async {
    e.desktop.workspaces = {
      'workspaces': [
        {'index': 1, 'tiling': false},
      ],
    };
    await call('workspaces.set', {'workspace': 1, 'mode': 'tiled'});
    final r = await call('workspaces.apply');
    await call('presets.undo', {'receipt': r['receipt']});
    expect(
      e.desktop.calls,
      containsAllInOrder(['helper set-tiling 1 on', 'helper set-tiling 1 off']),
    );
  });
  test('assignment undo restores module C assignments', () async {
    final dir = e.addTheme('one');
    e.core.ctx.current.save(slug: 'one', wallpaper: '$dir/backgrounds/1.png');
    await call('presets.save', {'name': 'One'});
    final r = await call('presets.assign', {
      'name': 'One',
      'workspaces': [2],
    });
    await call('presets.undo', {'receipt': r['receipt'], 'appearance': true});
    expect(loadWorkspaceThemes(e.core.ctx), isEmpty);
    expect(loadWorkspaceMap(e.core.ctx), isEmpty);
  });
  test('corrupt stores and unsafe autostart fail closed', () async {
    writeJson(e.paths.file('presets.json'), [
      {'name': 'Bad', 'theme': '../bad'},
      {'name': 'Bad wall', 'theme': 'one', 'wallpaper': '../bad.png'},
    ]);
    expect(loadPresets(e.core.ctx), isEmpty);
    windows();
    await call('apppresets.save', {'workspace': 1});
    await call('apppresets.autostart', {'workspace': 1, 'enabled': true});
    chmodPath('${e.paths.state}/autostart.json', 420);
    e.core.ctx.environment['XDG_SESSION_ID'] = 'unsafe';
    expect((await call('presets.autostart'))['status'], 'unsafe_snapshot');
  });
  test('missing wallpaper prevents appearance mutation', () async {
    final dir = e.addTheme('one');
    e.core.ctx.current.save(slug: 'one', wallpaper: '$dir/backgrounds/1.png');
    await call('presets.save', {'name': 'One'});
    File('$dir/backgrounds/1.png').deleteSync();
    e.desktop.calls.clear();
    await expectLater(
      call('presets.apply', {'name': 'One'}),
      throwsA(isA<RouteError>()),
    );
    expect(e.desktop.calls, isNot(contains('applyColors')));
  });
  test(
    'gtk-launch receives installed desktop ID and new window moves',
    () async {
      final d = Directory('${e.paths.data}/applications')
        ..createSync(recursive: true);
      File('${d.path}/editor.desktop').writeAsStringSync(
        '[Desktop Entry]\nType=Application\nExec=never-run-this-command\n',
      );
      final bin = Directory('${e.root.path}/bin')..createSync();
      final out = '${e.root.path}/launched';
      final gtk = File('${bin.path}/gtk-launch')
        ..writeAsStringSync('#!/bin/sh\nprintf "%s" "\$1" > "$out"\n');
      chmodPath(gtk.path, 448);
      e.core.ctx.environment['PATH'] = bin.path;
      saveWorkspaces(e.core.ctx, {
        'workspaceLayouts': {
          '1': {
            'apps': ['editor'],
          },
        },
      });
      final timer = Timer(const Duration(milliseconds: 100), () {
        e.desktop.windows = {
          'windows': [
            {'id': 'new', 'app_id': 'editor', 'workspace': 2},
          ],
        };
      });
      try {
        final r = await call('apppresets.restore', {'workspace': 1});
        expect(r['status'], 'restored');
        expect(File(out).readAsStringSync(), 'editor.desktop');
        expect(e.desktop.calls, contains('helper move new 1'));
      } finally {
        timer.cancel();
      }
    },
  );
}
