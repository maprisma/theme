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
    for (final p in ['kitty', 'btop', 'hx', 'foot', 'alacritty', 'ghostty', 'fuzzel']) {
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
    expect(ids, unorderedEquals(['alacritty', 'kitty', 'ghostty', 'foot', 'btop', 'fuzzel', 'helix']));
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
    expect(removed, unorderedEquals(['alacritty', 'kitty', 'ghostty', 'foot', 'btop', 'fuzzel', 'helix']));
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

  test('files of the user in the apps\' own folders are never overwritten or deleted', () async {
    write('helix/config.toml', 'theme = "onedark"\n');
    write('helix/themes/maprisma.toml', '# my own\n');
    write('btop/btop.conf', 'color_theme = "Default"\n');
    write('mine.theme', 'theme[main_bg]="#000000"\n');
    Directory('$cfg/btop/themes').createSync(recursive: true);
    Link('$cfg/btop/themes/maprisma.theme').createSync('$cfg/mine.theme');
    write('nvim/lua/plugins/maprisma-theme.lua', 'return { "mine" }\n');
    final nvimCtx = Ctx(paths: env.paths, desktop: env.desktop, environment: {'HOME': env.paths.home, 'PATH': '/nonexistent'});
    await applyAppTemplates(ctx, findTheme(env.paths, 'nord')!, colors);
    for (final id in ['helix', 'btop', 'neovim']) {
      expect(ensureInclude(nvimCtx, appSpec(id)!), 'manual', reason: id);
    }
    expect(read('helix/themes/maprisma.toml'), '# my own\n');
    expect(read('helix/config.toml'), 'theme = "onedark"\n');
    expect(FileSystemEntity.isLinkSync('$cfg/btop/themes/maprisma.theme'), isTrue);
    expect(read('mine.theme'), 'theme[main_bg]="#000000"\n');
    expect(read('btop/btop.conf'), 'color_theme = "Default"\n');
    removeAppIncludes(nvimCtx);
    expect(read('helix/themes/maprisma.toml'), '# my own\n');
    expect(FileSystemEntity.isLinkSync('$cfg/btop/themes/maprisma.theme'), isTrue);
    expect(read('nvim/lua/plugins/maprisma-theme.lua'), 'return { "mine" }\n');

    // our own (marked) files are updated, and go when the app is switched off
    File('$cfg/helix/themes/maprisma.toml').deleteSync();
    expect(ensureInclude(ctx, appSpec('helix')!), 'ok');
    expect(read('helix/themes/maprisma.toml'), startsWith('# $appMarker\n'));
    expect(ensureInclude(ctx, appSpec('helix')!), 'ok');
    setAppEnabled(ctx, 'helix', false, colors);
    expect(File('$cfg/helix/themes/maprisma.toml').existsSync(), isFalse);
    expect(read('helix/config.toml'), 'theme = "onedark"\n');
  });

  test('VS Code is listed as not supported and cannot be switched on', () async {
    Directory('$cfg/Code').createSync(recursive: true);
    final vscode = appsList(ctx).firstWhere((a) => a['id'] == 'vscode');
    expect(vscode['installed'], isTrue);
    expect(vscode['supported'], isFalse);
    expect(vscode['enabled'], isFalse);
    expect(vscode['note'], startsWith('Not supported'));
    expect(() => setAppEnabled(ctx, 'vscode', true, colors), throwsA(isA<RouteError>()));
    setAppEnabled(ctx, 'kitty', true, colors);
    expect(ctx.settings.get('apps'), isNot(contains('vscode')));
  });

  test('fuzzel: a marked [main] include at the end, after its own [colors]; removed cleanly', () async {
    const original = 'font=Mono:size=12\nlines=15\n\n[colors]\nbackground=282c34dd\n\n[border]\nwidth=2\n';
    write('fuzzel/fuzzel.ini', original);
    final a = appSpec('fuzzel')!;
    await applyAppTemplates(ctx, findTheme(env.paths, 'nord')!, colors);
    final out = '${currentAppsDir(ctx)}/fuzzel.ini';
    expect(File(out).readAsStringSync(), contains('[colors]\nbackground=${colors['background']!.substring(1)}f0'));
    final text = read('fuzzel/fuzzel.ini');
    expect(text, startsWith(original));
    expect(text, endsWith('# $appMarker\n[main]\ninclude=$out\n'));
    expect(includeActive(ctx, a), isTrue);
    // again: nothing changes
    expect(ensureInclude(ctx, a), 'ok');
    expect(read('fuzzel/fuzzel.ini'), text);
    // a section the user adds after ours: our block moves to the end again
    write('fuzzel/fuzzel.ini', '$text\n[colors]\ntext=ffffffff\n');
    expect(ensureInclude(ctx, a), 'ok');
    final moved = read('fuzzel/fuzzel.ini');
    expect('include=$out'.allMatches(moved), hasLength(1));
    expect(moved, endsWith('[colors]\ntext=ffffffff\n\n# $appMarker\n[main]\ninclude=$out\n'));
    // off: the user's file as it was (with their later section)
    write('fuzzel/fuzzel.ini', text);
    expect(removeInclude(ctx, a), isTrue);
    expect(read('fuzzel/fuzzel.ini'), original);
    expect(includeActive(ctx, a), isFalse);
  });
}
