import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/apps.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestEnv env;
  late Ctx ctx;
  late String cfg;
  late Map<String, String> colors;

  setUp(() {
    env = TestEnv.create();
    // Omarchy's real templates from the source tree
    for (final f in Directory('../../templates').listSync()) {
      if (f.path.endsWith('.tpl')) File(f.path).copySync('${env.paths.templates}/${f.uri.pathSegments.last}');
    }
    final bin = Directory('${env.root.path}/bin')..createSync();
    for (final p in ['kitty', 'btop', 'hx', 'foot', 'alacritty', 'ghostty']) {
      File('${bin.path}/$p').writeAsStringSync('#!/bin/sh\n');
      chmodPath('${bin.path}/$p', 493);
    }
    // only the fake programs: the real ones on this computer do not count
    ctx = Ctx(paths: env.paths, desktop: env.desktop, environment: {'HOME': env.paths.home, 'PATH': bin.path});
    cfg = configHome(ctx);
    expect(cfg, startsWith(env.root.path));
    env.addTheme('nord');
    colors = findTheme(env.paths, 'nord')!.colors;
  });
  tearDown(() => env.dispose());

  String read(String p) => File('$cfg/$p').readAsStringSync();
  void write(String p, String text) {
    File('$cfg/$p').parent.createSync(recursive: true);
    File('$cfg/$p').writeAsStringSync(text);
  }

  test('renders every installed app and adds one marked include, with a backup', () async {
    write('kitty/kitty.conf', 'font_size 11\n');
    write('btop/btop.conf', 'color_theme = "Default"\ntheme_background = true\n');
    write('helix/config.toml', 'theme = "onedark"\n\n[editor]\nline-number = "relative"\n');
    write('alacritty/alacritty.toml', '[font]\nsize = 10\n');
    final ids = await applyAppTemplates(ctx, findTheme(env.paths, 'nord')!, colors);
    expect(ids, unorderedEquals(['alacritty', 'kitty', 'ghostty', 'foot', 'btop', 'helix']));
    final current = currentAppsDir(ctx);
    expect(File('$current/kitty.conf').readAsStringSync(), contains('background #2e3440'));
    expect(read('kitty/kitty.conf'), 'font_size 11\n\n# $appMarker\ninclude $current/kitty.conf\n');
    expect(File('$cfg/kitty/kitty.conf$backupSuffix').readAsStringSync(), 'font_size 11\n');
    expect(read('foot/foot.ini'), startsWith('# $appMarker\ninclude=$current/foot.ini\n'));
    expect(read('ghostty/config'), contains('config-file = ?"$current/ghostty.conf"'));
    expect(read('alacritty/alacritty.toml'), startsWith('# $appMarker\ngeneral.import = ["$current/alacritty.toml"]\n'));
    expect(read('btop/btop.conf'), contains('color_theme = "maprisma"'));
    expect(read('btop/themes/maprisma.theme'), contains('#2e3440'));
    expect(read('helix/config.toml'), startsWith('theme = "maprisma"\n'));
    expect(read('helix/themes/maprisma.toml'), contains('[palette]'));
    // a second apply adds nothing
    await applyAppTemplates(ctx, findTheme(env.paths, 'nord')!, colors);
    expect('include'.allMatches(read('kitty/kitty.conf')).length, 1);
    // neovim without a lazy.nvim config, vscode: never touched
    expect(Directory('$cfg/nvim').existsSync(), isFalse);

    final removed = removeAppIncludes(ctx);
    expect(removed, unorderedEquals(['alacritty', 'kitty', 'ghostty', 'foot', 'btop', 'helix']));
    expect(read('kitty/kitty.conf'), 'font_size 11\n');
    expect(read('alacritty/alacritty.toml'), '[font]\nsize = 10\n');
    expect(read('btop/btop.conf'), contains('color_theme = "Default"'));
    expect(read('helix/config.toml'), startsWith('theme = "onedark"'));
  });

  test('only the apps switched on; a config that cannot take a line is left alone', () async {
    write('alacritty/alacritty.toml', '[general]\nimport = ["~/mine.toml"]\n');
    await env.core.call('settings.set', {'key': 'apps', 'value': ['kitty', 'alacritty']});
    final ids = await applyAppTemplates(ctx, findTheme(env.paths, 'nord')!, colors);
    expect(ids, ['kitty']);
    expect(read('alacritty/alacritty.toml'), '[general]\nimport = ["~/mine.toml"]\n');
    expect(File('$cfg/foot/foot.ini').existsSync(), isFalse);
    // rendered anyway (our own folder), so switching it on later is instant
    expect(File('${currentAppsDir(ctx)}/foot.ini').existsSync(), isTrue);
    final list = appsList(ctx);
    expect(list.firstWhere((a) => a['id'] == 'kitty')['included'], isTrue);
    expect(list.firstWhere((a) => a['id'] == 'vscode')['installed'], isFalse);

    var r = setAppEnabled(ctx, 'kitty', false, colors);
    expect(File('$cfg/kitty/kitty.conf').readAsStringSync(), isNot(contains('include')));
    expect(ctx.settings.get('apps'), ['alacritty']);
    r = setAppEnabled(ctx, 'foot', true, colors);
    expect(r['result'], 'ok');
    expect(read('foot/foot.ini'), contains('include='));
    expect(setAppEnabled(ctx, 'alacritty', true, colors)['result'], 'manual');
  });

  test('neovim: a plugin spec of our own only in a lazy.nvim config', () async {
    write('nvim/lua/plugins/example.lua', 'return {}\n');
    final nvimCtx = Ctx(paths: env.paths, desktop: env.desktop, environment: {'HOME': env.paths.home, 'PATH': '/nonexistent'});
    final ids = await applyAppTemplates(nvimCtx, findTheme(env.paths, 'nord')!, colors);
    expect(ids, ['neovim']);
    expect(read('nvim/lua/plugins/maprisma-theme.lua'), startsWith('-- $appMarker\n'));
    expect(removeAppIncludes(nvimCtx, ['neovim']), ['neovim']);
    expect(File('$cfg/nvim/lua/plugins/maprisma-theme.lua').existsSync(), isFalse);
    expect(read('nvim/lua/plugins/example.lua'), 'return {}\n');
  });
}
