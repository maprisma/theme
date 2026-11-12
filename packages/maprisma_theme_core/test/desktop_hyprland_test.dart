import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/desktop_hyprland.dart';
import 'package:maprisma_theme_core/src/shell_scheme.dart';
import 'package:test/test.dart';

/// Every key Caelestia's scheme.json had: the Maprisma apps may read any of them.
const caelestiaKeys = [
  'background', 'onBackground', 'surface', 'surfaceDim', 'surfaceBright', 'surfaceContainerLowest',
  'surfaceContainerLow', 'surfaceContainer', 'surfaceContainerHigh', 'surfaceContainerHighest', 'onSurface',
  'surfaceVariant', 'onSurfaceVariant', 'outline', 'outlineVariant', 'inverseSurface', 'inverseOnSurface',
  'shadow', 'scrim', 'surfaceTint', 'primary', 'primaryDim', 'onPrimary', 'primaryContainer',
  'onPrimaryContainer', 'inversePrimary', 'primaryFixed', 'primaryFixedDim', 'onPrimaryFixed',
  'onPrimaryFixedVariant', 'secondary', 'secondaryDim', 'onSecondary', 'secondaryContainer',
  'onSecondaryContainer', 'secondaryFixed', 'secondaryFixedDim', 'onSecondaryFixed', 'onSecondaryFixedVariant',
  'tertiary', 'tertiaryDim', 'onTertiary', 'tertiaryContainer', 'onTertiaryContainer', 'tertiaryFixed',
  'tertiaryFixedDim', 'onTertiaryFixed', 'onTertiaryFixedVariant', 'error', 'errorDim', 'onError',
  'errorContainer', 'onErrorContainer', 'primaryPaletteKeyColor', 'secondaryPaletteKeyColor',
  'tertiaryPaletteKeyColor', 'neutralPaletteKeyColor', 'neutralVariantPaletteKeyColor', 'errorPaletteKeyColor',
  'primary_paletteKeyColor', 'secondary_paletteKeyColor', 'tertiary_paletteKeyColor', 'neutral_paletteKeyColor',
  'neutral_variant_paletteKeyColor', 'term0', 'term1', 'term2', 'term3', 'term4', 'term5', 'term6', 'term7',
  'term8', 'term9', 'term10', 'term11', 'term12', 'term13', 'term14', 'term15', 'rosewater', 'flamingo', 'pink',
  'mauve', 'red', 'maroon', 'peach', 'yellow', 'green', 'teal', 'sky', 'sapphire', 'blue', 'lavender', 'klink',
  'klinkSelection', 'kvisited', 'kvisitedSelection', 'knegative', 'knegativeSelection', 'kneutral',
  'kneutralSelection', 'kpositive', 'kpositiveSelection', 'text', 'subtext1', 'subtext0', 'overlay2', 'overlay1',
  'overlay0', 'surface2', 'surface1', 'surface0', 'base', 'mantle', 'crust', 'success', 'onSuccess',
  'successContainer', 'onSuccessContainer',
];

const dark = {
  'mode': 'dark', 'background': '#1e1e2e', 'foreground': '#cdd6f4', 'accent': '#89b4fa', 'muted': '#6c7086',
  'selection': '#45475a', 'selection_background': '#45475a', 'cursor': '#f5e0dc', 'black': '#1e1e2e',
  'red': '#f38ba8', 'green': '#a6e3a1', 'yellow': '#f9e2af', 'blue': '#89b4fa', 'magenta': '#f5c2e7',
  'cyan': '#94e2d5', 'white': '#cdd6f4', 'bright_black': '#6c7086', 'bright_red': '#f38ba8',
  'bright_green': '#a6e3a1', 'bright_yellow': '#f9e2af', 'bright_blue': '#89b4fa', 'bright_magenta': '#f5c2e7',
  'bright_cyan': '#94e2d5', 'bright_white': '#ffffff', 'orange': '#fab387',
};

void main() {
  late Directory root;
  late Paths paths;
  late Map<String, String> env;
  late String home;
  late Directory pts;
  late File log;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-theme-hypr-');
    home = '${root.path}/home';
    File('$home/.config/quickshell/maprisma-shell/shell.qml').createSync(recursive: true);
    Directory('$home/.config/hypr/scheme').createSync(recursive: true);
    pts = Directory('${root.path}/pts')..createSync();
    log = File('${root.path}/log');
    // A fake hyprctl: logs its arguments.
    final bin = Directory('${root.path}/bin')..createSync();
    File('${bin.path}/hyprctl').writeAsStringSync('#!/bin/sh\necho "\$@" >> "${log.path}"\n');
    Process.runSync('chmod', ['+x', '${bin.path}/hyprctl']);
    env = {
      'HOME': home,
      'PATH': '${bin.path}:${Platform.environment['PATH'] ?? '/usr/bin'}',
      'XDG_RUNTIME_DIR': '${root.path}/run',
      'HYPRLAND_INSTANCE_SIGNATURE': 'test',
    };
    paths = Paths.fromEnvironment(env, share: '${root.path}/share');
  });
  tearDown(() => root.deleteSync(recursive: true));

  HyprlandDesktop desktop([Map<String, String>? environment]) => HyprlandDesktop(paths, environment ?? env, ptsDir: pts.path);
  String scheme() => '$home/.local/state/maprisma-shell/scheme.json';
  String shellJson() => '$home/.config/maprisma-shell/shell.json';

  test('caps: appearance and wallpaper with Maprisma Shell installed', () {
    final d = desktop();
    expect(d.id, 'hyprland');
    expect(d.caps, {Cap.appearance, Cap.wallpaper});
  });

  test('caps: none without Maprisma Shell (plain Hyprland, Omarchy); nothing is written', () async {
    File('$home/.config/quickshell/maprisma-shell/shell.qml').deleteSync();
    final d = desktop();
    expect(d.caps, isEmpty);
    expect(await d.applyColors(dark), isFalse);
    final pic = File('${root.path}/p.png')..writeAsStringSync('x');
    expect(await d.setWallpaper(pic.path), isFalse);
    expect(File(scheme()).existsSync(), isFalse);
    expect(File(shellJson()).existsSync(), isFalse);
    expect((await d.health(paths, env))['helper']['ok'], isFalse);
  });

  group('shellScheme', () {
    test('every key Caelestia had, the theme\'s own surfaces, text and terminal colours', () {
      final s = shellScheme(dark)!;
      expect(s.mode, 'dark');
      expect(s.colours.keys.toSet(), caelestiaKeys.toSet());
      for (final v in s.colours.values) {
        expect(v, matches(RegExp(r'^[0-9a-f]{6}$')));
      }
      final c = s.colours;
      expect(c['background'], '1e1e2e');
      expect(c['surface'], '1e1e2e');
      expect(c['onSurface'], 'cdd6f4');
      expect(c['primary'], '89b4fa');
      expect(c['outline'], '6c7086');
      expect(c['secondary'], '45475a'); // the selection
      expect(c['secondaryContainer'], '45475a');
      expect(c['error'], 'f38ba8');
      expect(c['peach'], 'fab387');
      expect(c['term0'], '1e1e2e');
      expect(c['term1'], 'f38ba8');
      expect(c['term8'], '6c7086');
      expect(c['term15'], 'ffffff');
      // Surfaces step from the background toward the text.
      expect(luminance('#${c['surfaceContainer']}'), greaterThan(luminance('#1e1e2e')));
      expect(luminance('#${c['surfaceContainerHigh']}'), greaterThan(luminance('#${c['surfaceContainer']}')));
      expect(luminance('#${c['mantle']}'), lessThan(luminance('#1e1e2e')));
    });

    test('the on-colours read on what they are on', () {
      for (final colors in [
        dark,
        {...dark, 'mode': 'light', 'background': '#eff1f5', 'foreground': '#4c4f69', 'accent': '#1e66f5'},
        {...dark, 'accent': '#ffff00'},
        {...dark, 'accent': '#000080', 'red': '#800000'},
      ]) {
        final c = shellScheme(colors)!.colours;
        for (final role in ['primary', 'secondary', 'tertiary', 'error', 'success']) {
          final on = 'on${role[0].toUpperCase()}${role.substring(1)}';
          expect(contrast('#${c[on]}', '#${c[role]}'), greaterThanOrEqualTo(4.5), reason: '$on on $role in $colors');
          expect(contrast('#${c['${on}Container']}', '#${c['${role}Container']}'), greaterThanOrEqualTo(4.5));
        }
      }
    });

    test('light mode: containers stay light, inversePrimary lighter than the accent', () {
      final s = shellScheme({'background': '#ffffff', 'foreground': '#202020', 'accent': '#3366cc', 'mode': 'light'})!;
      expect(s.mode, 'light');
      expect(luminance('#${s.colours['primaryContainer']}'), greaterThan(0.5));
      expect(luminance('#${s.colours['inversePrimary']}'), greaterThan(luminance('#3366cc')));
    });

    test('mode from the background when not given; null without the essentials', () {
      expect(shellScheme({'background': '#fafafa', 'foreground': '#111111', 'accent': '#3366cc'})!.mode, 'light');
      expect(shellScheme({'background': '#101010', 'foreground': '#eeeeee', 'blue': '#3366cc'})!.mode, 'dark');
      expect(shellScheme({'background': '#101010', 'foreground': '#eeeeee'}), isNull);
    });
  });

  test('applyColors writes scheme.json and Hyprland\'s current.lua, reloads Hyprland, recolours terminals', () async {
    File('${pts.path}/0').writeAsStringSync('');
    File('${pts.path}/ptmx').writeAsStringSync('');
    final d = desktop();
    expect(await d.applyColors(dark), isTrue);
    final data = jsonDecode(File(scheme()).readAsStringSync()) as Map;
    expect(data['name'], 'maprisma-theme');
    expect(data['mode'], 'dark');
    expect(data['flavour'], 'default');
    expect(data['variant'], 'tonalspot');
    expect((data['colours'] as Map)['primary'], '89b4fa');
    expect(File(scheme()).statSync().mode & 511, 420);

    final lua = File('$home/.config/hypr/scheme/current.lua').readAsStringSync();
    expect(lua, startsWith('return {\n'));
    expect(lua, contains('  primary = "89b4fa",\n'));
    expect(lua, contains('  inversePrimary = "'));
    expect(lua.trimRight(), endsWith('}'));
    expect(log.readAsStringSync(), 'reload\n');

    final seq = File('${pts.path}/0').readAsStringSync();
    expect(seq, startsWith('\x1b]10;rgb:cd/d6/f4\x1b\\\x1b]11;rgb:1e/1e/2e\x1b\\'));
    expect(seq, contains('\x1b]12;rgb:f5/e0/dc\x1b\\')); // the theme's cursor
    expect(seq, contains('\x1b]17;rgb:45/47/5a\x1b\\')); // its selection
    expect(seq, contains('\x1b]4;15;rgb:ff/ff/ff\x1b\\'));
    expect(File('${pts.path}/ptmx').readAsStringSync(), isEmpty);
  });

  test('an existing file keeps its mode; without a Hyprland config only the scheme is written', () async {
    File(scheme()).createSync(recursive: true);
    Process.runSync('chmod', ['600', scheme()]);
    Directory('$home/.config/hypr').deleteSync(recursive: true);
    final d = desktop();
    expect(await d.applyColors(dark), isTrue);
    expect(File(scheme()).statSync().mode & 511, 384);
    expect(Directory('$home/.config/hypr').existsSync(), isFalse);
    expect(log.existsSync(), isFalse);
  });

  test('current reads scheme.json back as a colours object', () async {
    final d = desktop();
    expect(await d.current(), isNull);
    await d.applyColors(dark);
    final cur = (await d.current())!;
    final colors = cur['colors'] as Map;
    expect(cur['is_dark'], isTrue);
    expect(colors['background'], '#1e1e2e');
    expect(colors['foreground'], '#cdd6f4');
    expect(colors['accent'], '#89b4fa');
    expect(colors['selection'], '#45475a');
    expect(colors['red'], '#f38ba8');
    expect(colors['bright_white'], '#ffffff');
    expect(colors['orange'], '#fab387');
  });

  test('wallpaper: shell.json\'s key, every other key and the layout stay', () async {
    final d = desktop();
    expect(d.wallpaper(), isNull);
    File(shellJson())
      ..createSync(recursive: true)
      ..writeAsStringSync('{\n  "wallpaper": "/pics/a.jpg",\n  "idle": { "lock": 180, "wallpaper": "x" }\n}\n');
    expect(d.wallpaper(), '/pics/a.jpg');
    expect(await d.snapshotBackground(), {'path': '/pics/a.jpg'});

    final good = File('${root.path}/good "b".png')..writeAsStringSync('x');
    expect(await d.setWallpaper(good.path), isTrue);
    expect(
      File(shellJson()).readAsStringSync(),
      '{\n  "wallpaper": ${jsonEncode(good.path)},\n  "idle": { "lock": 180, "wallpaper": "x" }\n}\n',
    );
    expect(d.wallpaper(), good.path);
    expect(await d.setWallpaper('relative.png'), isFalse);
    expect(await d.setWallpaper('${root.path}/missing.png'), isFalse);
    expect(await d.restoreBackground(null), isFalse);

    // A link is followed to the picture itself.
    final link = Link('${root.path}/link.png')..createSync(good.path);
    expect(await d.setWallpaper(link.path), isTrue);
    expect(d.wallpaper(), good.path);
  });

  test('no shell.json yet: created with the key; a broken one is left alone', () async {
    final d = desktop();
    final pic = File('${root.path}/p.png')..writeAsStringSync('x');
    expect(await d.setWallpaper(pic.path), isTrue);
    expect(jsonDecode(File(shellJson()).readAsStringSync()), {'wallpaper': pic.path});

    File(shellJson()).writeAsStringSync('{"idle": ');
    expect(await d.setWallpaper(pic.path), isFalse);
    expect(File(shellJson()).readAsStringSync(), '{"idle": ');
  });

  test('a key added to shell.json without one: the other keys stay', () async {
    File(shellJson())
      ..createSync(recursive: true)
      ..writeAsStringSync('{"idle": {"lock": 180}}');
    final pic = File('${root.path}/p.png')..writeAsStringSync('x');
    expect(await desktop().setWallpaper(pic.path), isTrue);
    expect(jsonDecode(File(shellJson()).readAsStringSync()), {
      'idle': {'lock': 180},
      'wallpaper': pic.path,
    });
  });

  test('a preview from no wallpaper is undone with an empty wallpaper', () async {
    final d = desktop();
    final snap = await d.snapshotBackground();
    expect(snap, {'path': null});
    final pic = File('${root.path}/p.png')..writeAsStringSync('x');
    await d.setWallpaper(pic.path);
    expect(await d.restoreBackground(snap), isTrue);
    expect(jsonDecode(File(shellJson()).readAsStringSync()), {'wallpaper': ''});
    expect(d.wallpaper(), isNull);
  });

  test('health names Maprisma Shell', () async {
    final h = await desktop().health(paths, env);
    expect(h['helper'], {'ok': true, 'path': '$home/.config/quickshell/maprisma-shell/shell.qml', 'name': 'Maprisma Shell'});
  });

  test('GTK colours: Breeze\'s colors.css for GTK 3 and 4 from the theme; gtk.css imports it once', () async {
    // KDE's import is there already for GTK 3; GTK 4 has a gtk.css without it.
    File('$home/.config/gtk-3.0/gtk.css')
      ..createSync(recursive: true)
      ..writeAsStringSync("@import 'colors.css';");
    File('$home/.config/gtk-4.0/gtk.css')
      ..createSync(recursive: true)
      ..writeAsStringSync('window { }\n');
    expect(await desktop().applyColors(dark), isTrue);
    final colours = shellScheme(dark)!.colours;
    for (final v in ['3', '4']) {
      final css = File('$home/.config/gtk-$v.0/colors.css').readAsStringSync();
      expect(css, contains('@define-color theme_titlebar_background_breeze #${colours['surfaceContainer']};'));
      expect(css, contains('@define-color theme_base_color_breeze #${colours['surface']};'));
      expect(css, contains('@define-color theme_fg_color_breeze #${colours['onSurface']};'));
      expect(css, contains('@define-color theme_button_decoration_focus_breeze #${colours['primary']};'));
      expect(css, contains('@define-color error_color_breeze #f38ba8;'));
      // every Breeze name KDE writes is there, each once
      final names = RegExp(r'@define-color (\w+) ').allMatches(css).map((m) => m[1]).toList();
      expect(names.length, names.toSet().length);
      expect(names.length, greaterThanOrEqualTo(84));
      expect(names.every((n) => n!.endsWith('_breeze')), isTrue);
    }
    expect(File('$home/.config/gtk-3.0/gtk.css').readAsStringSync(), "@import 'colors.css';");
    expect(File('$home/.config/gtk-4.0/gtk.css').readAsStringSync(), "@import 'colors.css';\nwindow { }\n");
    // a second apply adds no second import
    expect(await desktop().applyColors(dark), isTrue);
    expect(RegExp('colors.css').allMatches(File('$home/.config/gtk-4.0/gtk.css').readAsStringSync()).length, 1);
  });

  group('window rounding (a fake hyprctl, never the session\'s)', () {
    void answer(String json, {int code = 0}) {
      File('${root.path}/bin/hyprctl')
          .writeAsStringSync('#!/bin/sh\necho "\$@" >> "${log.path}"\ncat <<\'EOF\'\n$json\nEOF\nexit $code\n');
    }

    test('hyprRounding: the int, clamped to 64; anything else is null', () {
      expect(hyprRounding('{"option": "decoration:rounding", "int": 15, "set": true }'), 15);
      expect(hyprRounding('{"int": 0}'), 0);
      expect(hyprRounding('{"int": 300}'), 64);
      expect(hyprRounding('{"int": -3}'), isNull);
      expect(hyprRounding('{"float": 2.5}'), isNull);
      expect(hyprRounding('no json'), isNull);
      expect(hyprRounding('[15]'), isNull);
      expect(hyprRounding(null), isNull);
    });

    test('asks hyprctl -j getoption decoration:rounding and goes in current()', () async {
      answer('{"option": "decoration:rounding", "int": 15, "set": true }');
      final d = desktop();
      expect(await d.windowRounding(), 15);
      expect(log.readAsStringSync(), '-j getoption decoration:rounding\n');
      await d.applyColors(dark);
      expect((await d.current())!['corner_radius'], 15);
    });

    test('asked at most every 30 s', () async {
      answer('{"int": 10}');
      var now = DateTime(2026, 11, 12, 10);
      final d = HyprlandDesktop(paths, env, ptsDir: pts.path, clock: () => now);
      expect(await d.windowRounding(), 10);
      answer('{"int": 20}');
      now = now.add(const Duration(seconds: 29));
      expect(await d.windowRounding(), 10);
      now = now.add(const Duration(seconds: 2));
      expect(await d.windowRounding(), 20);
      expect(log.readAsLinesSync().length, 2);
    });

    test('null outside a Hyprland session, without hyprctl, or when it fails', () async {
      answer('{"int": 15}');
      expect(await desktop({...env}..remove('HYPRLAND_INSTANCE_SIGNATURE')).windowRounding(), isNull);
      expect(log.existsSync(), isFalse);
      expect(await desktop({...env, 'PATH': '${root.path}/nothing'}).windowRounding(), isNull);
      answer('{"int": 15}', code: 1);
      expect(await desktop().windowRounding(), isNull);
      answer('garbage');
      expect(await desktop().windowRounding(), isNull);
    });

    test('a hyprctl that hangs is given up on', () async {
      File('${root.path}/bin/hyprctl').writeAsStringSync('#!/bin/sh\nexec sleep 30\n');
      final watch = Stopwatch()..start();
      expect(await desktop().windowRounding(), isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });
}
