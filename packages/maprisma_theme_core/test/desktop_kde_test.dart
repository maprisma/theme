import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/desktop_kde.dart';
import 'package:maprisma_theme_core/src/desktops.dart';
import 'package:maprisma_theme_core/src/kde_formats.dart';
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

  test('caps and the rest of the contract', () async {
    expect(kde.caps, {Cap.appearance, Cap.kdeScheme, Cap.wallpaper, Cap.terminal, Cap.fonts, Cap.icons});
    expect(await kde.applyRon('/x.ron'), isFalse);
    expect((await kde.wm(['workspaces']))?['error'], 'not_available');
    expect(kde.shortcutBinder(paths), isNull);
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
}

