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

  test('launcher ignores inherited output and checks exit status', () async {
    final bin = Directory('${e.root.path}/bin')..createSync();
    final gtk = File('${bin.path}/gtk-launch');
    e.core.ctx.environment['PATH'] = bin.path;
    final launcher = Launcher('editor.desktop', '/unused', '');
    gtk.writeAsStringSync('#!/bin/sh\n/bin/sleep 3 &\nexit 0\n');
    chmodPath(gtk.path, 448);
    final watch = Stopwatch()..start();
    expect(await launchApp(e.core.ctx, launcher), isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    gtk.writeAsStringSync('#!/bin/sh\nexit 7\n');
    expect(await launchApp(e.core.ctx, launcher), isFalse);
    gtk.deleteSync();
    final gio = File('${bin.path}/gio')
      ..writeAsStringSync('#!/bin/sh\n/bin/sleep 3 &\nexit 0\n');
    chmodPath(gio.path, 448);
    watch.reset();
    expect(await launchApp(e.core.ctx, launcher), isTrue);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test(
    'preset keeps approval only for unchanged apps on the same workspace',
    () async {
      windows();
      final dir = e.addTheme('one');
      e.core.ctx.current.save(slug: 'one', wallpaper: '$dir/backgrounds/1.png');
      saveWorkspaces(e.core.ctx, {
        'workspaceLayouts': {
          '1': {
            'apps': ['editor'],
            'autostart': true,
          },
          '2': {
            'apps': ['browser'],
            'autostart': true,
          },
        },
      });
      await call('presets.save', {'name': 'Keep', 'includeWorkspaces': true});
      await call('presets.apply', {'name': 'Keep', 'confirmed': true});
      expect(
        readJsonMap('${e.paths.state}/autostart.json').keys,
        containsAll(['1', '2']),
      );
      final preset = namedPreset(e.core.ctx, 'Keep');
      preset['workspaces']['workspaceLayouts']['2']['apps'] = <String>[];
      preset['workspaces']['workspaceLayouts']['3'] = {
        'apps': <String>[],
        'autostart': true,
      };
      await applySavedPreset(e.core.ctx, preset, confirmed: true);
      expect(
        loadWorkspaces(e.core.ctx)['workspaceLayouts']['1']['autostart'],
        isTrue,
      );
      expect(
        loadWorkspaces(e.core.ctx)['workspaceLayouts']['2']['autostart'],
        isFalse,
      );
      expect(
        loadWorkspaces(e.core.ctx)['workspaceLayouts']['3']['autostart'],
        isFalse,
      );
      expect(readJsonMap('${e.paths.state}/autostart.json').keys, ['1']);
    },
  );

  test('autostart without session ID uses boot and uid once', () async {
    e.core.ctx.environment.remove('XDG_SESSION_ID');
    saveWorkspaces(e.core.ctx, {'workspaceLayouts': <String, dynamic>{}});
    expect((await autostartPresets(e.core.ctx))['results'], isEmpty);
    expect((await autostartPresets(e.core.ctx))['status'], 'already_started');
  });

  test(
    'launcher chooser saves installed apps only, supports duplicates and undo',
    () async {
      final d = Directory('${e.paths.data}/applications')
        ..createSync(recursive: true);
      File('${d.path}/browser.desktop').writeAsStringSync(
        '[Desktop Entry]\nType=Application\nName=Browser\nIcon=web-browser\nExec=browser\nStartupWMClass=Browser\n',
      );
      e.core.ctx.environment['XDG_DATA_DIRS'] = '${e.root.path}/empty';
      expect((await call('apppresets.launchers'))['launchers'], [
        {
          'desktop_id': 'browser.desktop',
          'name': 'Browser',
          'icon': 'web-browser',
        },
      ]);
      final r = await call('apppresets.add', {
        'workspace': 2,
        'desktop_id': 'browser.desktop',
      });
      await call('apppresets.add', {
        'workspace': 2,
        'desktop_id': 'browser.desktop',
      });
      expect(loadWorkspaces(e.core.ctx)['workspaceLayouts']['2']['apps'], [
        'browser.desktop',
        'browser.desktop',
      ]);
      expect(
        e.desktop.calls.where((c) => c.startsWith('helper move')),
        isEmpty,
      );
      await expectLater(
        call('apppresets.add', {'workspace': 2, 'desktop_id': '../bad'}),
        throwsA(isA<RouteError>()),
      );
      await call('presets.undo', {'receipt': r['receipt']});
      expect(loadWorkspaces(e.core.ctx)['workspaceLayouts'], isEmpty);
    },
  );

  test('launcher metadata and saved app counts are bounded', () async {
    final d = Directory('${e.paths.data}/applications')
      ..createSync(recursive: true);
    File('${d.path}/bounded.desktop').writeAsStringSync(
      '[Desktop Entry]\nType=Application\nExec=bounded\nName=${'n' * 300}\nIcon=${'i' * 300}\nStartupWMClass=BoundedApp\n',
    );
    e.core.ctx.environment['XDG_DATA_DIRS'] = '${e.root.path}/empty';
    final listed =
        ((await call('apppresets.launchers'))['launchers'] as List).single;
    expect((listed['name'] as String).length, 255);
    expect((listed['icon'] as String).length, 255);
    saveWorkspaces(e.core.ctx, {
      'workspaceLayouts': {
        '1': {'apps': List.filled(64, 'bounded.desktop')},
      },
    });
    await expectLater(
      call('apppresets.add', {'workspace': 1, 'desktop_id': 'bounded.desktop'}),
      throwsA(isA<RouteError>()),
    );
    expect(
      loadWorkspaces(e.core.ctx)['workspaceLayouts']['1']['apps'],
      hasLength(64),
    );
    saveWorkspaces(e.core.ctx, {
      'workspaceLayouts': {
        '1': {
          'apps': ['bounded.desktop'],
        },
      },
    });
    e.desktop.windows = {
      'windows': [
        {'id': 'bounded', 'app_id': 'BoundedApp', 'workspace': 1},
      ],
    };
    final restored = await call('apppresets.restore', {'workspace': 1});
    expect(restored['status'], 'restored');
    expect(restored['launched'], isEmpty);
  });

  for (final autostart in [false, true]) {
    test(
      'whole restore reserves windows across workspaces (autostart=$autostart)',
      () async {
        windows();
        e.core.ctx.environment['XDG_DATA_DIRS'] = '${e.root.path}/empty';
        final d = Directory('${e.paths.data}/applications')
          ..createSync(recursive: true);
        File('${d.path}/browser.desktop').writeAsStringSync(
          '[Desktop Entry]\nType=Application\nExec=browser\n',
        );
        final bin = Directory('${e.root.path}/bin')..createSync();
        final out = '${e.root.path}/launch-count';
        final gtk = File('${bin.path}/gtk-launch')
          ..writeAsStringSync('#!/bin/sh\nprintf "%s\\n" "\$1" >> "$out"\n');
        chmodPath(gtk.path, 448);
        e.core.ctx.environment['PATH'] = bin.path;
        final timer = Timer.periodic(const Duration(milliseconds: 20), (t) {
          if (File(out).existsSync()) {
            (e.desktop.windows['windows'] as List).add({
              'id': 'new',
              'app_id': 'browser',
              'workspace': 3,
            });
            t.cancel();
          }
        });
        addTearDown(timer.cancel);
        saveWorkspaces(e.core.ctx, {
          'workspaceLayouts': {
            '1': {
              'apps': ['browser'],
              'autostart': autostart,
            },
            '2': {
              'apps': ['browser'],
              'autostart': autostart,
            },
          },
        });
        Map results;
        if (autostart) {
          e.core.ctx.environment['XDG_SESSION_ID'] = 'multi';
          results = (await call('presets.autostart'))['results'] as Map;
          expect(results['1']['failed'], isEmpty);
          expect(results['2']['failed'], isEmpty);
        } else {
          final dir = e.addTheme('one');
          e.core.ctx.current.save(
            slug: 'one',
            wallpaper: '$dir/backgrounds/1.png',
          );
          await call('presets.save', {
            'name': 'Multi',
            'includeWorkspaces': true,
          });
          results = await call('presets.apply', {
            'name': 'Multi',
            'confirmed': true,
          });
          expect(results['failed'], isEmpty);
        }
        expect(File(out).readAsLinesSync(), ['browser.desktop']);
        expect(e.desktop.calls, contains('helper move new 1'));
        expect(
          e.desktop.calls.where((c) => c.startsWith('helper move b ')),
          isEmpty,
        );
      },
    );
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

  test('default layout per limit fills workspaces without their own', () async {
    await call('workspaces.set', {'maxWindows': 3});
    await call('workspaces.set', {'defaultLimit': 3, 'defaultMode': 'tiled'});
    await call('workspaces.set', {'workspace': 2, 'mode': 'floating'});
    await call('workspaces.set', {'workspace': 4, 'limit': 1});
    final s = loadWorkspaces(e.core.ctx);
    expect(effectiveMode(s, 1), 'tiled');
    expect(effectiveMode(s, 2), 'floating');
    expect(effectiveMode(s, 4), 'default');
    expect(effectiveMode(s, 0), 'tiled');
    expect(effectiveLimit(s, 4), 1);
    final tiling = readJsonMap(e.paths.automationFile)['tiling'] as Map;
    expect(tiling['floating'], [2]);
    expect(tiling['tiled'], [1, 3, 5, 6, 7, 8, 9, 10]);
    // mode null: back to the default layout; defaultMode null: Native.
    await call('workspaces.set', {'workspace': 2, 'mode': null});
    expect(effectiveMode(loadWorkspaces(e.core.ctx), 2), 'tiled');
    await call('workspaces.set', {'defaultLimit': 3, 'defaultMode': null});
    expect(effectiveMode(loadWorkspaces(e.core.ctx), 2), 'default');
    await expectLater(
      call('workspaces.set', {'defaultLimit': 5, 'defaultMode': 'tiled'}),
      throwsA(isA<RouteError>()),
    );
    await expectLater(
      call('workspaces.set', {'defaultLimit': 2, 'defaultMode': 'columns'}),
      throwsA(isA<RouteError>()),
    );
  });

  test('bulk actions keep App Presets and undo', () async {
    saveWorkspaces(e.core.ctx, {
      'maxWindows': 2,
      'workspaceCaps': {'1': 3},
      'workspaceModes': {'1': 'tiled', '2': 'floating'},
      'workspaceLayouts': {
        '1': {
          'apps': ['editor'],
          'autostart': false,
        },
      },
    });
    await call('workspaces.bulk', {'action': 'reset_all'});
    var s = loadWorkspaces(e.core.ctx);
    expect(s['workspaceCaps'], isEmpty);
    expect(s['workspaceModes'], isEmpty);
    expect((s['workspaceLayouts'] as Map).keys, ['1']);
    final r = await call('workspaces.bulk', {'action': 'remove_all'});
    s = loadWorkspaces(e.core.ctx);
    expect((s['workspaceModes'] as Map).values.toSet(), {'default'});
    expect((s['workspaceModes'] as Map).length, 10);
    await call('presets.undo', {'receipt': r['receipt']});
    expect(loadWorkspaces(e.core.ctx)['workspaceModes'], isEmpty);
    await expectLater(
      call('workspaces.bulk', {'action': 'swap'}),
      throwsA(isA<RouteError>()),
    );
    await call('apppresets.remove_all');
    expect(loadWorkspaces(e.core.ctx)['workspaceLayouts'], isEmpty);
  });

  test('looks: theme, colours and wallpaper per workspace', () async {
    final one = e.addTheme('one', accent: '#111111');
    final two = e.addTheme(
      'two',
      accent: '#222222',
      wallpapers: ['a.png', 'b.png'],
    );
    e.core.ctx.current.save(slug: 'one', wallpaper: '$one/backgrounds/1.png');
    await call('workspaces.set', {'workspace': 3, 'limit': 4, 'mode': 'tiled'});
    var r = await call('workspaces.set_look', {'workspace': 3, 'theme': 'two'});
    expect(r['receipt'], isNotNull);
    await call('workspaces.set_look', {'workspace': 3, 'wallpaper': 'b.png'});
    final looks = (await call('workspaces.looks'))['workspaces'] as Map;
    expect(looks.keys.length, 11);
    expect(looks['1']['theme'], 'one');
    expect(looks['1']['colors']['accent'], '#111111');
    expect(looks['3']['theme'], 'two');
    expect(looks['3']['own_theme'], 'two');
    expect(looks['3']['colors']['accent'], '#222222');
    expect(looks['3']['wallpaper'], '$two/backgrounds/b.png');
    expect(looks['3']['limit'], 4);
    expect(looks['3']['mode'], 'tiled');
    expect(looks['3']['own_mode'], true);
    expect(looks['0']['own_theme'], isNull);
    await expectLater(
      call('workspaces.set_look', {'workspace': 3, 'wallpaper': 'zz.png'}),
      throwsA(isA<RouteError>()),
    );
    await expectLater(
      call('workspaces.set_look', {'workspace': 3, 'wallpaper': '../x.png'}),
      throwsA(isA<RouteError>()),
    );
    // Clearing the theme, then Undo brings it back.
    r = await call('workspaces.set_look', {'workspace': 3, 'theme': null});
    expect((await call('auto.workspace_themes'))['themes'], isEmpty);
    await call('presets.undo', {'receipt': r['receipt'], 'appearance': true});
    expect((await call('auto.workspace_themes'))['themes'], {'3': 'two'});
  });
}
