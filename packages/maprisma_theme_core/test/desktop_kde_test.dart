import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/desktop_kde.dart';
import 'package:maprisma_theme_core/src/desktops.dart';
import 'package:maprisma_theme_core/src/kde_formats.dart';
import 'package:maprisma_theme_core/src/workspace_state.dart';
import 'package:test/test.dart';

import 'support.dart';

/// KdeDesktop against fake Plasma tools in a temporary HOME: they log their
/// arguments and change kdeglobals the way the real ones do.
void main() {
  late Directory root;
  late Paths paths;
  late KdeDesktop kde;
  late String log, config;

  void tool(String name, String body) {
    final f = File('${root.path}/bin/$name')..writeAsStringSync('#!/bin/sh\necho "$name \$*" >> "$log"\n$body\n');
    chmodPath(f.path, 493);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-theme-kde-');
    Directory('${root.path}/bin').createSync();
    log = '${root.path}/log';
    final env = {'HOME': '${root.path}/home', 'PATH': '${root.path}/bin:/usr/bin:/bin', 'XDG_DATA_DIRS': '${root.path}/sys'};
    paths = Paths.fromEnvironment(env, share: '${root.path}/share');
    config = File(paths.cosmicConfig).parent.path;
    Directory(config).createSync(recursive: true);
    Directory(paths.templates).createSync(recursive: true);
    for (final t in ['kde.colors.tpl', 'konsole.colorscheme.tpl']) {
      File('../../templates/$t').copySync('${paths.templates}/$t');
    }
    // like the real tool: writes [General] ColorScheme=<name>
    tool('plasma-apply-colorscheme', 'printf "[General]\\nColorScheme=%s\\n" "\$1" > "$config/kdeglobals"');
    // plasmashell: a snapshot script gets two desktops, any other script one change
    tool('qdbus6', 'case "\$4" in *maprisma-snapshot*) echo \'maprisma-snapshot {"1":{"plugin":"org.kde.image","image":""},'
        '"7":{"plugin":"org.kde.color","image":null}}\';; *) echo "maprisma-done 1";; esac');
    tool('kwriteconfig6', '');
    tool('dbus-send', '');
    tool('konsole', '');
    kde = KdeDesktop(paths, env);
  });
  tearDown(() => root.deleteSync(recursive: true));

  String logText() => File(log).existsSync() ? File(log).readAsStringSync() : '';

  /// kwriteconfig6 that really edits the file under the config folder (any
  /// group); a `fail-<key>` file makes writing that key fail.
  void statefulKwriteconfig() {
    final kw = File('${root.path}/bin/kwriteconfig6')
      ..writeAsStringSync('#!/usr/bin/env python3\n'
          'import sys, os\n'
          'a = sys.argv[1:]\n'
          'open("$log", "a").write("kwriteconfig6 " + " ".join(a) + "\\n")\n'
          'f = a[a.index("--file") + 1]; g = a[a.index("--group") + 1]; k = a[a.index("--key") + 1]\n'
          'if os.path.exists("${root.path}/fail-" + k): sys.exit(1)\n'
          'p = "$config/" + f\n'
          'groups = {}; order = []; cur = None\n'
          'for l in (open(p).read().splitlines() if os.path.exists(p) else []):\n'
          '    if l.startswith("["): cur = l[1:-1]; order.append(cur); groups[cur] = []\n'
          '    elif cur is not None and l: groups[cur].append(l)\n'
          'if g not in groups: order.append(g); groups[g] = []\n'
          'groups[g] = [l for l in groups[g] if not l.startswith(k + "=")]\n'
          'if "--delete" not in a: groups[g].append(k + "=" + a[-1])\n'
          'open(p, "w").write("".join("[" + n + "]\\n" + "".join(l + "\\n" for l in groups[n]) + "\\n" for n in order))\n');
    chmodPath(kw.path, 493);
  }

  const colors = {
    'background': '#2e3440', 'foreground': '#d8dee9', 'accent': '#81a1c1', 'red': '#bf616a', 'green': '#a3be8c',
    'yellow': '#ebcb8b', 'blue': '#81a1c1', 'magenta': '#b48ead', 'cyan': '#88c0d0',
  };

  test('colors: alternating scheme names, applied and checked, the other file goes', () async {
    expect(await kde.applyColors(colors), isTrue);
    final schemes = '${paths.data}/color-schemes';
    expect(File('$schemes/MaprismaA.colors').existsSync(), isTrue);
    expect(iniValue(File('$schemes/MaprismaA.colors').readAsStringSync(), 'Colors:View', 'BackgroundNormal'), '46,52,64');
    expect(logText(), contains('plasma-apply-colorscheme MaprismaA'));
    // the same scheme in use: the next one gets the other name
    expect(await kde.applyColors(colors), isTrue);
    expect(logText(), contains('plasma-apply-colorscheme MaprismaB'));
    expect(File('$schemes/MaprismaA.colors').existsSync(), isFalse);
    expect(File('$schemes/MaprismaB.colors').existsSync(), isTrue);
  });

  test('a KDE Store scheme is applied as it is, under the alternating name', () async {
    final file = File('${root.path}/one.colors')
      ..writeAsStringSync('[Colors:Window]\nBackgroundNormal=40,44,52\nForegroundNormal=220,223,228\n\n[General]\nColorScheme=OneDark\nName=One Dark\n');
    expect(await kde.applyKdeScheme(file.path), isTrue);
    final applied = File('${paths.data}/color-schemes/MaprismaA.colors').readAsStringSync();
    expect(iniValue(applied, 'General', 'ColorScheme'), 'MaprismaA');
    expect(iniValue(applied, 'Colors:Window', 'BackgroundNormal'), '40,44,52');
    expect(file.readAsStringSync(), contains('ColorScheme=OneDark')); // the theme's own file stays as it came
  });

  test('colors: a tool that does not switch the scheme is a failure', () async {
    tool('plasma-apply-colorscheme', 'true');
    expect(await kde.applyColors(colors), isFalse);
  });

  test('current look from kdeglobals', () async {
    File('$config/kdeglobals').writeAsStringSync('[Colors:Window]\nBackgroundNormal=46,52,64\nForegroundNormal=216,222,233\n'
        '[General]\nAccentColor=129,161,193\n');
    expect(await kde.current(), {
      'colors': {'background': '#2e3440', 'foreground': '#d8dee9', 'accent': '#81a1c1'},
      'is_dark': true,
      'corner_radius': null,
    });
  });

  test('wallpaper: set through plasmashell, read and snapshot from its config', () async {
    final png = File('${root.path}/a b.png')..writeAsBytesSync(tinyPng);
    expect(await kde.setWallpaper(png.path), isTrue);
    expect(logText(), contains('org.kde.PlasmaShell.evaluateScript'));
    expect(logText(), contains('file:///'));
    expect(await kde.setWallpaper('relative.png'), isFalse);

    File('$config/plasma-org.kde.plasma.desktop-appletsrc').writeAsStringSync('[Containments][1]\nplugin=org.kde.plasma.folder\n'
        'wallpaperplugin=org.kde.image\n\n[Containments][1][Wallpaper][org.kde.image][General]\nImage=file:///pics/a%20b.png\n\n'
        '[Containments][2]\nplugin=org.kde.panel\n\n[Containments][7]\nwallpaperplugin=org.kde.color\n');
    expect(kde.wallpaper(), '/pics/a b.png');
    // the snapshot comes from plasmashell itself (its file lags behind)
    final snap = await kde.snapshotBackground();
    expect(snap, {'1': ('org.kde.image', ''), '7': ('org.kde.color', null)});
    File(log).deleteSync();
    expect(await kde.restoreBackground(snap), isTrue);
    expect(logText(), contains('org.kde.color'));
    expect(await kde.restoreBackground('nonsense'), isFalse);
  });

  test("Konsole: the user's default profile keeps its settings and gets the scheme", () async {
    final dir = Directory('${paths.data}/konsole')..createSync(recursive: true);
    File('${dir.path}/Mine.profile').writeAsStringSync('[Appearance]\nFont=Hack,12\n\n[General]\nName=Mine\n');
    File('$config/konsolerc').writeAsStringSync('[Desktop Entry]\nDefaultProfile=Mine.profile\n');
    expect(await kde.setTerminal(colors, 'Nord'), isTrue);
    final profile = File('${dir.path}/Mine.profile').readAsStringSync();
    expect(iniValue(profile, 'Appearance', 'ColorScheme'), 'Maprisma');
    expect(iniValue(profile, 'Appearance', 'Font'), 'Hack,12');
    expect(iniValue(profile, 'General', 'Name'), 'Mine');
    expect(File('${dir.path}/Maprisma.profile').existsSync(), isFalse);
    expect(iniValue(File('${dir.path}/Maprisma.colorscheme').readAsStringSync(), 'General', 'Description'), 'Maprisma: Nord');
  });

  test("Konsole: a system default profile is copied with its settings, the default stays", () async {
    final sys = Directory('${root.path}/sys/konsole')..createSync(recursive: true);
    File('${sys.path}/Work.profile').writeAsStringSync('[General]\nName=Work\nCommand=/bin/zsh\n\n[Appearance]\nFont=Iosevka,11\n');
    File('$config/konsolerc').writeAsStringSync('[Desktop Entry]\nDefaultProfile=Work.profile\n');
    expect(await kde.setTerminal(colors, 'Nord'), isTrue);
    final copy = File('${paths.data}/konsole/Work.profile').readAsStringSync();
    expect(iniValue(copy, 'General', 'Command'), '/bin/zsh');
    expect(iniValue(copy, 'Appearance', 'Font'), 'Iosevka,11');
    expect(iniValue(copy, 'Appearance', 'ColorScheme'), 'Maprisma');
    expect(iniValue(copy, 'General', 'Parent'), isNull);
    expect(iniValue(File('$config/konsolerc').readAsStringSync(), 'Desktop Entry', 'DefaultProfile'), 'Work.profile');
    expect(File('${sys.path}/Work.profile').readAsStringSync(), isNot(contains('Maprisma')));
  });

  test('Konsole: without a profile of the user a Maprisma profile becomes the default', () async {
    expect(await kde.setTerminal(colors, 'Nord'), isTrue);
    final dir = '${paths.data}/konsole';
    expect(iniValue(File('$dir/Maprisma.profile').readAsStringSync(), 'Appearance', 'ColorScheme'), 'Maprisma');
    expect(iniValue(File('$config/konsolerc').readAsStringSync(), 'Desktop Entry', 'DefaultProfile'), 'Maprisma.profile');
  });

  test('fonts: the QFont keeps its size; reset deletes the key', () async {
    File('$config/kdeglobals').writeAsStringSync('[General]\nfixed=Hack,12,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\n');
    expect(kde.monospaceFont(), 'Hack');
    final fonts = await kde.monospaceFonts();
    if (fonts.isNotEmpty) {
      expect(await kde.setMonospaceFont(fonts.first), isTrue);
      expect(logText(), contains('kwriteconfig6 --file kdeglobals --group General --key fixed ${fonts.first},12,-1,5,400'));
      expect(logText(), contains('notifyChange int32:1 int32:0'));
    }
    expect(await kde.setMonospaceFont('No Such Font 123'), isFalse);
    expect(await kde.resetMonospaceFont(), isTrue);
    expect(logText(), contains('--key fixed --delete'));
  });

  group('interface font', () {
    late String a, b;

    /// kwriteconfig6 that really edits kdeglobals; a `fail-<key>` file makes
    /// writing that key fail.
    setUp(() async {
      final fonts = await kde.interfaceFonts();
      a = fonts.isNotEmpty ? fonts.first : '';
      b = fonts.length > 1 ? fonts[1] : '';
      statefulKwriteconfig();
    });

    String? value(String group, String key) => iniValue(File('$config/kdeglobals').readAsStringSync(), group, key);

    test('menu and title fonts of the same family follow; a font of its own stays; back puts every key back', () async {
      if (b.isEmpty) return; // no fontconfig here
      final original = '[General]\nfont=Noto Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1,Regular\n'
          'menuFont=Noto Sans,9,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\ntoolBarFont=$b,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\n\n'
          '[WM]\nactiveFont=Noto Sans,11,-1,5,700,0,0,0,0,0,0,0,0,0,0,1\n';
      File('$config/kdeglobals').writeAsStringSync(original);
      expect(kde.interfaceFont(), 'Noto Sans');
      // the theme's font is the family the toolbar has of its own
      expect(await kde.setInterfaceFont(b), isTrue);
      expect(value('General', 'font'), '$b,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1,Regular');
      expect(value('General', 'menuFont'), '$b,9,-1,5,400,0,0,0,0,0,0,0,0,0,0,1');
      expect(value('WM', 'activeFont'), '$b,11,-1,5,700,0,0,0,0,0,0,0,0,0,0,1');
      expect(logText(), contains('notifyChange int32:1 int32:0'));
      // the next theme changes the same keys, and only those
      expect(await kde.setInterfaceFont(a), isTrue);
      expect(value('General', 'toolBarFont'), '$b,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1');
      expect(value('General', 'menuFont'), startsWith('$a,9'));
      // back to the user's own font: every key as it was
      expect(await kde.setInterfaceFont('No Such Font 123'), isFalse);
      expect(await kde.resetInterfaceFont(), isTrue);
      expect(value('General', 'font'), 'Noto Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1,Regular');
      expect(value('General', 'menuFont'), 'Noto Sans,9,-1,5,400,0,0,0,0,0,0,0,0,0,0,1');
      expect(value('General', 'toolBarFont'), '$b,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1');
      expect(value('WM', 'activeFont'), 'Noto Sans,11,-1,5,700,0,0,0,0,0,0,0,0,0,0,1');
    });

    test('without a font key, reset deletes what the theme wrote', () async {
      if (a.isEmpty) return;
      File('$config/kdeglobals').writeAsStringSync('[General]\nColorScheme=X\n');
      expect(kde.interfaceFont(), isNull);
      expect(await kde.setInterfaceFont(a), isTrue);
      expect(value('General', 'font'), startsWith('$a,10'));
      expect(await kde.resetInterfaceFont(), isTrue);
      expect(value('General', 'font'), isNull);
      expect(value('General', 'ColorScheme'), 'X');
      // no theme font in use: reset only deletes the font key
      expect(await kde.resetInterfaceFont(), isTrue);
    });

    test('a failed write puts the keys written before back, and nothing is kept', () async {
      if (a.isEmpty) return;
      final original = '[General]\nfont=Noto Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\nmenuFont=Noto Sans,9,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\n';
      File('$config/kdeglobals').writeAsStringSync(original);
      File('${root.path}/fail-menuFont').createSync();
      expect(await kde.setInterfaceFont(a), isFalse);
      expect(value('General', 'font'), 'Noto Sans,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1');
      expect(File('${paths.state}/kde-ui-font.json').existsSync(), isFalse);
    });
  });

  test('tiling through Maprisma Tiling: the cap while it is installed, each workspace by its ignore list', () {
    expect(kde.caps.contains(Cap.tiling), isFalse);
    final script = Directory('${paths.data}/kwin/scripts/maprisma-tiling')..createSync(recursive: true);
    File('${script.path}/metadata.json').writeAsStringSync('{}');
    expect(kde.caps.contains(Cap.tiling), isTrue);
    File('$config/kwinrc').writeAsStringSync('[Script-maprisma-tiling]\nuntiledDesktops=2, 4\n');
    final r = kde.withTiling({
      'workspaces': [for (var i = 1; i <= 4; i++) {'index': i, 'name': 'same, name', 'tiling': false}],
      'can_tile': false,
    });
    expect([for (final w in r['workspaces']) w['tiling']], [true, false, true, false]);
    expect(r['can_tile'], isTrue);
    // Empty exclusions: all workspaces tile
    File('$config/kwinrc').writeAsStringSync('[Script-maprisma-tiling]\nuntiledDesktops=\n');
    expect([for (final w in kde.withTiling(r)['workspaces']) w['tiling']], everyElement(isTrue));
  });

  test('automation changes publish workspace limits through the desktop hook', () async {
    final env = TestEnv.create();
    addTearDown(env.dispose);
    saveWorkspaces(env.core.ctx, {'active': true, 'maxWindows': 3, 'workspaceCaps': {'2': 1}});
    await Future<void>.delayed(Duration.zero);
    expect(env.desktop.lastTilingAutomation?['active'], isTrue);
    expect(env.desktop.lastTilingAutomation?['default_limit'], 3);
    expect(env.desktop.lastTilingAutomation?['limits'], {'2': 1});
  });

  test('system data directories also provide Maprisma Tiling', () {
    final dir = Directory('${root.path}/sys/kwin/scripts/maprisma-tiling')..createSync(recursive: true);
    expect(kde.enforcesWindowLimits, isFalse);
    File('${dir.path}/metadata.json').writeAsStringSync('{}');
    expect(kde.caps, contains(Cap.tiling));
    expect(kde.enforcesWindowLimits, isTrue);
  });

  test('limits are mirrored and cleared in order', () async {
    final dir = Directory('${paths.data}/kwin/scripts/maprisma-tiling')..createSync(recursive: true);
    File('${dir.path}/metadata.json').writeAsStringSync('{}');
    expect(kde.enforcesWindowLimits, isTrue);
    final first = kde.publishTilingAutomation({'active': true, 'default_limit': 2, 'limits': {'1': 2, '3': 3}});
    final second = kde.publishTilingAutomation({'active': false, 'default_limit': 4, 'limits': {}});
    await Future.wait([first, second]);
    final text = logText();
    expect(text, contains('--group Script-maprisma-tiling --key limitsActive true'));
    expect(text, contains('--key defaultLimit 2'));
    expect(text, contains('--key limits 1:2,3:3'));
    expect(text, contains('--key limitsActive false'));
    expect(text.indexOf('--key defaultLimit 4'), greaterThan(text.indexOf('--key defaultLimit 2')));
    expect(text.split('org.kde.KWin /KWin reconfigure').length - 1, 2);
  });

  test('caps and the rest of the contract', () async {
    expect(kde.caps, {Cap.appearance, Cap.kdeScheme, Cap.wallpaper, Cap.terminal, Cap.fonts, Cap.icons, Cap.workspaces, Cap.windows, Cap.shortcuts, Cap.animations, Cap.uiFont, Cap.blur});
    expect(await kde.applyRon('/x.ron'), isFalse);
    // no session bus in the test's environment: KWin is never reached
    expect((await kde.wm(['workspaces']))?['error'], 'unavailable');
    expect(kde.watch(), isNull);
    expect(kde.shortcutBinder(paths).available, isFalse);
    expect(kde.iconTheme(), 'breeze');
    expect((await kde.health(paths, const {}))['helper'], isA<Map>());
  });

  group('applying a theme by caps', () {
    test('without a backend only the app templates change; no apply_failed', () async {
      final env = TestEnv.create(desktop: FakeDesktop(id: 'generic', name: 'your desktop', terminalName: null, caps: const {}));
      addTearDown(env.dispose);
      env.addTheme('nord');
      final r = await env.core.call('themes.apply', {'slug': 'nord'});
      expect(r['done'], isNot(contains('generic')));
      expect(env.desktop.calls, isNot(contains('applyColors')));
      expect(env.core.ctx.current.slug, 'nord');
    });

    test('a RON theme is applied as colors where the desktop cannot take RON', () async {
      final env = TestEnv.create(desktop: FakeDesktop(id: 'kde', name: 'KDE Plasma', caps: {Cap.appearance}));
      addTearDown(env.dispose);
      final dir = Directory('${env.paths.userThemes}/ron-theme')..createSync(recursive: true);
      File('${dir.path}/cosmic.ron').writeAsStringSync('(palette: Dark(()))');
      final r = await env.core.call('themes.apply', {'slug': 'ron-theme'});
      expect(r['done'], contains('kde'));
      expect(env.desktop.calls, contains('applyColors'));
      expect(env.desktop.calls.where((c) => c.startsWith('applyRon')), isEmpty);
    });

    test('without a desktop look the window takes the applied theme\'s colors', () async {
      final env = TestEnv.create(desktop: FakeDesktop(id: 'generic', name: 'your desktop', terminalName: null, caps: const {}, hasLook: false));
      addTearDown(env.dispose);
      env.addTheme('nord');
      expect((await env.core.call('desktop.look'))['colors'], isEmpty);
      await env.core.call('themes.apply', {'slug': 'nord'});
      final look = await env.core.call('desktop.look');
      expect(look['colors'], {'background': '#2e3440', 'foreground': '#d8dee9', 'accent': '#81a1c1'});
      expect(look['is_dark'], isTrue);
    });

    test("a desktop without fonts neither changes nor forgets the user's font", () async {
      final env = TestEnv.create(desktop: FakeDesktop(id: 'generic', name: 'your desktop', terminalName: null, caps: const {}));
      addTearDown(env.dispose);
      env.addTheme('nord');
      env.core.ctx.settings.set('own_font', 'Fira Code');
      await env.core.call('themes.apply', {'slug': 'nord'});
      expect(env.core.ctx.settings.get('own_font'), 'Fira Code');
      expect(env.desktop.calls.where((c) => c.startsWith('font')), isEmpty);
    });

    test("the user's font stays saved while it cannot be put back", () async {
      final env = TestEnv.create();
      addTearDown(env.dispose);
      env.addTheme('nord');
      env.core.ctx.settings.set('own_font', 'Not Installed');
      await env.core.call('themes.apply', {'slug': 'nord'});
      expect(env.core.ctx.settings.get('own_font'), 'Not Installed');
    });

    test("each desktop remembers the user's own font apart", () async {
      expect(ownFontKey(FakeDesktop()), 'own_font');
      expect(ownFontKey(FakeDesktop(id: 'kde')), 'own_font_kde');
    });
  });

  test('the selector picks KDE for a Plasma session', () {
    expect(selectDesktop(paths, {'HOME': '${root.path}/home', 'XDG_CURRENT_DESKTOP': 'KDE'}), isA<KdeDesktop>());
  });

  test('colors: the frame colour is the accent, and KWin reloads it', () async {
    expect(await kde.applyColors(colors), isTrue);
    final text = logText();
    expect(text, contains('kwriteconfig6 --file kwinrc --group Script-maprisma-tiling --key borderColor #81a1c1'));
    expect(text.indexOf('org.kde.KWin /KWin reconfigure'), greaterThan(text.indexOf('borderColor')));
  });

  test('tile style reads every setting from the tiling script group', () {
    File('$config/kwinrc').writeAsStringSync('[Script-maprisma-tiling]\ngapTop=11\ngapRight=12\ngapBottom=13\ngapLeft=14\ngapBetween=15\nborderWidth=4\ncornerRadius=16\n');
    expect(kde.tileStyle(), {'top': 11, 'right': 12, 'bottom': 13, 'left': 14, 'between': 15, 'border': 4, 'radius': 16, 'can_tile': false});
  });

  test('tile style: a rejected request writes nothing', () async {
    Directory('${root.path}/home/.local/share/kwin/scripts/maprisma-tiling').createSync(recursive: true);
    File('${root.path}/home/.local/share/kwin/scripts/maprisma-tiling/metadata.json').writeAsStringSync('{}');
    expect((await kde.wm(['set-tile-style', '{"top":20,"radius":33}']))?['error'], 'bad_args');
    expect(logText(), isNot(contains('kwriteconfig6')));
    expect((await kde.wm(['set-tile-style', '{"top":20,"radius":12}']))?['done'], isTrue);
    expect(logText(), contains('--key gapTop 20'));
    expect(logText(), contains('--group Script-maprisma-tiling --key cornerRadius 12'));
    expect(logText().split('org.kde.KWin /KWin reconfigure').length - 1, 1);
    expect(kde.tileStyle(), {'top': 10, 'right': 10, 'bottom': 10, 'left': 10, 'between': 10, 'border': 3, 'radius': 10, 'can_tile': true});
    final result = await kde.wm(['set-tile-style', '{"border":0}']);
    expect((result?['previous'] as Map)['border'], 3);
  });

  group('animations', () {
    late String loaded;

    /// kwriteconfig6 that really edits kwinrc [Plugins], and a KWin whose
    /// effects load and unload (a `refuse` file makes it ignore loadEffect).
    setUp(() {
      loaded = '${root.path}/loaded';
      Directory(loaded).createSync();
      statefulKwriteconfig();
      tool('qdbus6', 'case "\$3" in '
          '*isEffectLoaded) [ -e "$loaded/\$4" ] && echo true || echo false;; '
          '*loadEffect) [ -e "$loaded/../refuse" ] || [ "\$3" != "\${3%unloadEffect}" ] || touch "$loaded/\$4"; '
          '[ "\$3" != "\${3%unloadEffect}" ] && rm -f "$loaded/\$4"; echo true;; '
          '*) ;; esac');
      for (final e in ['slide', 'scale']) {
        File('$loaded/$e').createSync();
      }
    });

    Set<String> live() => {for (final f in Directory(loaded).listSync()) f.uri.pathSegments.last};
    String? plugin(String key) => iniValue(File('$config/kwinrc').readAsStringSync(), 'Plugins', '${key}Enabled');

    test('read from kwinrc with KDE defaults for missing keys', () {
      expect(kde.animations(), {'workspace': true, 'window': true});
      File('$config/kwinrc').writeAsStringSync('[Plugins]\nslideEnabled=false\nscaleEnabled=false\nglideEnabled=true\n');
      expect(kde.animations(), {'workspace': false, 'window': true});
      File('$config/kwinrc').writeAsStringSync('[Plugins]\nslideEnabled=false\nfadedesktopEnabled=true\n');
      expect(kde.animations()['workspace'], isTrue);
    });

    test('off unloads every effect; on brings the user\'s own choice back', () async {
      File('$config/kwinrc').writeAsStringSync('[Plugins]\nscaleEnabled=false\nglideEnabled=true\n');
      File('$loaded/scale').deleteSync();
      File('$loaded/glide').createSync();

      final off = await kde.wm(['set-animations', '{"workspace":false,"window":false}']);
      expect(off, containsPair('done', true));
      expect(off?['previous'], {'workspace': true, 'window': true});
      expect(off, containsPair('window', false));
      expect(off, containsPair('workspace', false));
      expect(live(), isEmpty);
      for (final e in ['slide', 'fadedesktop', 'scale', 'glide', 'fade']) {
        expect(plugin(e), 'false');
      }

      final on = await kde.wm(['set-animations', '{"window":true}']);
      expect(on, containsPair('window', true));
      expect(on, containsPair('workspace', false));
      expect(live(), {'glide'}); // Glide as before, not Scale
      expect([plugin('scale'), plugin('glide'), plugin('fade')], ['false', 'true', null]);
    });

    test('on without a kept choice gives KDE\'s defaults', () async {
      File('$config/kwinrc').writeAsStringSync('[Plugins]\nslideEnabled=false\n');
      File('$loaded/slide').deleteSync();
      final on = await kde.wm(['set-animations', '{"workspace":true}']);
      expect(on, containsPair('workspace', true));
      expect(live(), containsAll(['slide']));
      expect(plugin('slide'), isNull);
    });

    test('KWin refusing the change: an error and kwinrc as it was', () async {
      File('$config/kwinrc').writeAsStringSync('[Plugins]\nslideEnabled=false\n');
      File('$loaded/slide').deleteSync();
      File('${root.path}/refuse').createSync();
      final r = await kde.wm(['set-animations', '{"workspace":true}']);
      expect(r?['error'], 'unavailable');
      expect(plugin('slide'), 'false');
      expect(plugin('fadedesktop'), isNull);
      expect(kde.animations()['workspace'], isFalse);
    });

    test('KWin out of reach: an error, nothing left changed', () async {
      tool('qdbus6', 'exit 1');
      final r = await kde.wm(['set-animations', '{"window":false}']);
      expect(r?['error'], 'unavailable');
      expect(kde.animations(), {'workspace': true, 'window': true});
    });

    test('blur: kwinrc keys as they are; a theme\'s blur and back again exactly', () async {
      File('$config/kwinrc').writeAsStringSync('[Effect-blur]\nNoiseStrength=3\n');
      File('$loaded/blur').createSync();
      final before = (await kde.blurState())!;
      expect(before, {'enabled': null, 'strength': null});
      expect(kde.blurAsLook(before), {'on': true, 'strength': 15});

      final target = kde.blurTarget(before, on: true, strength: 4);
      expect(await kde.restoreBlur(target), isTrue);
      expect(iniValue(File('$config/kwinrc').readAsStringSync(), 'Effect-blur', 'BlurStrength'), '4');
      expect(iniValue(File('$config/kwinrc').readAsStringSync(), 'Effect-blur', 'NoiseStrength'), '3');
      expect(logText(), contains('reconfigureEffect blur'));

      expect(await kde.restoreBlur(kde.blurTarget(target, on: false, strength: 4)), isTrue);
      expect(live(), isNot(contains('blur')));
      expect(plugin('blur'), 'false');

      expect(await kde.restoreBlur(before), isTrue);
      expect(plugin('blur'), isNull);
      expect(live(), contains('blur'));
      expect(iniValue(File('$config/kwinrc').readAsStringSync(), 'Effect-blur', 'BlurStrength'), isNull);
    });

    test('blur: KWin refusing puts both keys back', () async {
      File('$config/kwinrc').writeAsStringSync('[Plugins]\nblurEnabled=false\n[Effect-blur]\nBlurStrength=9\n');
      File('${root.path}/refuse').createSync();
      final before = (await kde.blurState())!;
      expect(await kde.restoreBlur(kde.blurTarget(before, on: true, strength: 2)), isFalse);
      expect(await kde.blurState(), before);
    });

    test('a bad request writes nothing', () async {
      for (final bad in ['{}', '{"window":1}', '{"other":true}', 'nope', '[]']) {
        expect((await kde.wm(['set-animations', bad]))?['error'], 'bad_args');
      }
      expect(logText(), isNot(contains('kwriteconfig6')));
    });
  });
}
