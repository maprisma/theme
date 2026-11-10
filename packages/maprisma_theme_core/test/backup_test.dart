import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/src/shortcuts.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestEnv env;
  var now = DateTime(2026, 11, 7, 9, 30, 15);
  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic> p = const {}]) => env.core.call(m, p);

  setUp(() {
    env = TestEnv.create(clock: () => now);
    env.addTheme('nord');
    env.addTheme('gruvbox', bg: '#282828');
    cosmicShortcutDefaults = '${env.root.path}/no-defaults';
  });
  tearDown(() => env.dispose());

  test('export, change, restore: everything back, with a safety copy', () async {
    await call('themes.favorite', {'slug': 'nord', 'favorite': true});
    await call('settings.set', {'key': 'sort', 'value': 'recent'});
    await call('auto.set_workspace_themes', {'slug': 'gruvbox', 'workspaces': [3]});
    expect((await call('backup.default_name'))['name'], 'maprisma-theme-backup-2026-11-07.json');
    final file = '${env.root.path}/backup.json';
    await call('backup.export', {'path': file});
    final data = jsonDecode(File(file).readAsStringSync());
    expect(data['format'], 'maprisma-theme-backup');
    expect((data['files'] as Map).keys, containsAll(['settings.json', 'favorites.json', 'workspace-themes.json']));
    expect(File(file).statSync().mode & 0x1ff, 384);

    await call('themes.favorite', {'slug': 'nord', 'favorite': false});
    await call('themes.hide', {'slug': 'gruvbox', 'hidden': true});
    await call('settings.set', {'key': 'sort', 'value': 'name'});
    final preview = await call('backup.preview', {'path': file});
    expect(preview['files'], contains('favorites.json'));
    expect(preview['removes'], ['hidden.json']);
    final r = await call('backup.restore', {'path': file});
    expect(r['safety_copy'], endsWith('/backups/maprisma-theme.before-restore-2026-11-07-09-30-15.json'));
    expect(env.core.ctx.lists.favorites, ['nord']);
    expect(env.core.ctx.lists.hidden, isEmpty);
    expect(env.core.ctx.settings.get('sort'), 'recent');
    final safety = jsonDecode(File(r['safety_copy'] as String).readAsStringSync());
    expect(safety['files']['hidden.json'], ['gruvbox']);
    // the second restore in the same second gets its own copy
    final again = await call('backup.restore', {'path': file});
    expect(again['safety_copy'], endsWith('-2.json'));
  });

  test("a plugin backup restores; Omarchy's keys are dropped, bad ones refused", () async {
    final file = '${env.root.path}/plugin.json';
    File(file).writeAsStringSync(jsonEncode({
      'format': 'theme-manager-backup',
      'version': 1,
      'files': {
        'settings.json': {'language': 'de', 'sync_omarchy': true, 'corners': 'square', 'position': [1, 2]},
        'shortcuts.json': {'next-favorite': {'mods': ['SUPER', 'CTRL'], 'key': 'T'}},
        'presets.json': [
          {'name': 'Work', 'workspaces': {'1': {'apps': [{'id': 'kitty', 'command': 'rm -rf ~'}]}}},
        ],
      },
    }));
    await call('backup.restore', {'path': file});
    expect(env.core.ctx.settings.get('corners'), 'square');
    expect(jsonDecode(File(env.paths.file('settings.json')).readAsStringSync())['language'], 'de');
    expect(jsonDecode(File(env.paths.file('shortcuts.json')).readAsStringSync()).keys, ['theme:next']);
    expect(File(env.paths.file('presets.json')).readAsStringSync(), isNot(contains('rm -rf')));

    for (final bad in [
      {'format': 'other', 'version': 1, 'files': {}},
      {'format': 'maprisma-theme-backup', 'version': 1, 'files': {'evil.json': {}}},
      {'format': 'maprisma-theme-backup', 'version': 1, 'files': {'favorites.json': ['../x']}},
      {'format': 'maprisma-theme-backup', 'version': 1, 'files': {'settings.json': {'corners': 'wavy'}}},
      {'format': 'maprisma-theme-backup', 'version': 1, 'files': {'workspace-wallpapers.json': {'nord': {'1': '../../etc/passwd'}}}},
    ]) {
      File(file).writeAsStringSync(jsonEncode(bad));
      expect(() => call('backup.preview', {'path': file}), throwsA(isA<Object>()), reason: '$bad');
    }
    expect(() => call('backup.export', {'path': 'relative.json'}), throwsA(isA<Object>()));
  });

  test('health: helper, core, applet, shortcut file', () async {
    final h = await call('health.get');
    expect(h['helper']['ok'], isTrue); // FakeDesktop answers
    expect(h['applet']['in_panel'], isFalse);
    expect(h['shortcuts']['available'], isFalse);
    expect(h['shortcuts']['ok'], isTrue);
    final panel = Directory('${env.paths.cosmicConfig}/com.system76.CosmicPanel.Panel/v1')..createSync(recursive: true);
    File('${panel.path}/plugins_wings').writeAsStringSync('Some(([], ["io.github.ubruckhaus.CosmicMaprismaTheme"]))');
    expect((await call('health.get'))['applet']['in_panel'], isTrue);
  });
}
