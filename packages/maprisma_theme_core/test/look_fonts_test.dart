// desktop.look's fonts {ui, mono}: COSMIC's CosmicTk, KDE's kdeglobals (through the desktop
// backends), elsewhere GTK's gsettings (a fake on PATH, never the real one). Hyprland:
// desktop_hyprland_test.dart.
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/desktop_cosmic.dart';
import 'package:maprisma_theme_core/src/desktop_kde.dart';
import 'package:maprisma_theme_core/src/desktops.dart';
import 'package:maprisma_theme_core/src/settings_routes.dart' show pangoFamily;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Paths paths;
  late Map<String, String> env;
  late String bin;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-theme-fonts-');
    bin = (Directory('${root.path}/bin')..createSync()).path;
    env = {'HOME': '${root.path}/home', 'PATH': bin, 'XDG_RUNTIME_DIR': '${root.path}/run'};
    paths = Paths.fromEnvironment(env, share: '${root.path}/share');
  });
  tearDown(() => root.deleteSync(recursive: true));

  void put(String path, String text) => File('${root.path}/home/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  Future<Object?> fonts(Desktop d, {DateTime Function()? clock}) async =>
      (await CoreService(environment: env, paths: paths, desktop: d, clock: clock).call('desktop.look'))['fonts'];

  test('COSMIC: CosmicTk\'s interface_font / monospace_font family', () async {
    expect(await fonts(CosmicDesktop(paths, env)), isEmpty);
    put('.config/cosmic/com.system76.CosmicTk/v1/interface_font', '(\n    family: "Open Sans",\n    weight: Normal,\n)');
    put('.config/cosmic/com.system76.CosmicTk/v1/monospace_font', '(\n    family: "Hack",\n    weight: Normal,\n)');
    expect(await fonts(CosmicDesktop(paths, env)), {'ui': 'Open Sans', 'mono': 'Hack'});
  });

  test('KDE: kdeglobals [General] font / fixed, the family only', () async {
    expect(await fonts(KdeDesktop(paths, env)), isEmpty);
    put('.config/kdeglobals', '[General]\nfixed=Hack,10,-1,5,400,0,0,0,0,0\nfont=Noto Sans,10,-1,5,400,0,0,0,0,0\n');
    expect(await fonts(KdeDesktop(paths, env)), {'ui': 'Noto Sans', 'mono': 'Hack'});
  });

  test('any other desktop: GTK\'s gsettings without the size, asked at most every 30 s', () async {
    expect(await fonts(GenericDesktop(paths, env)), isEmpty); // no gsettings
    File('$bin/gsettings').writeAsStringSync('#!/bin/sh\necho "\$@" >> "$bin/gs.log"\n'
        'case "\$3" in font-name) echo "\'Noto Sans  10\'";; monospace-font-name) echo "\'Hack, 10.5\'";; esac\n');
    Process.runSync('/usr/bin/chmod', ['755', '$bin/gsettings']);
    var now = DateTime(2026, 1, 1);
    final core = CoreService(environment: env, paths: paths, desktop: GenericDesktop(paths, env), clock: () => now);
    expect((await core.call('desktop.look'))['fonts'], {'ui': 'Noto Sans', 'mono': 'Hack'});
    now = now.add(const Duration(seconds: 10));
    await core.call('desktop.look');
    expect(File('$bin/gs.log').readAsLinesSync(), hasLength(2));
    now = now.add(const Duration(seconds: 25));
    await core.call('desktop.look');
    expect(File('$bin/gs.log').readAsLinesSync(), hasLength(4));
    expect(pangoFamily('JetBrains Mono Nerd Font 12'), 'JetBrains Mono Nerd Font');
    expect(pangoFamily('Hack'), 'Hack');
  });

  test('the fake desktop: its fonts, none when unset', () async {
    final fake = FakeDesktop();
    expect(await fonts(fake), isEmpty);
  });
}
