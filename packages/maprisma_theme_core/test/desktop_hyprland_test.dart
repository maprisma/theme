import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/desktop_hyprland.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Paths paths;
  late Map<String, String> env;
  late File log;
  setUp(() {
    root = Directory.systemTemp.createTempSync('maprisma-theme-hypr-');
    final home = '${root.path}/home';
    Directory('$home/.local/state/caelestia/wallpaper').createSync(recursive: true);
    log = File('${root.path}/log');
    // A fake bridge: logs its arguments (and an apply's colours file), answers like the real one.
    final bridge = File('${root.path}/bridge')
      ..writeAsStringSync('''
import json, sys
args = sys.argv[1:]
with open(${jsonEncode(log.path)}, "a") as f:
    f.write(json.dumps(args) + "\\n")
    if args[0] == "apply":
        f.write(open(args[1]).read() + "\\n")
if args[0] == "apply":
    print(json.dumps({"applied": True, "mode": "dark"}))
elif args[0] == "current":
    print(json.dumps({"colors": {"background": "#000000"}, "is_dark": True, "corner_radius": None}))
elif args[0] == "wallpaper" and args[1].endswith("bad.png"):
    print(json.dumps({"error": "bad_image", "message": "no"}))
else:
    print(json.dumps({"set": True}))
''');
    env = {
      'HOME': home,
      'PATH': Platform.environment['PATH'] ?? '/usr/bin',
      'XDG_RUNTIME_DIR': '${root.path}/run',
      'MAPRISMA_THEME_CAELESTIA_BRIDGE': bridge.path,
    };
    paths = Paths.fromEnvironment(env, share: '${root.path}/share');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('caps: appearance and wallpaper only', () {
    final d = HyprlandDesktop(paths, env);
    expect(d.id, 'hyprland');
    expect(d.caps, {Cap.appearance, Cap.wallpaper});
  });

  test('applyColors hands the colours to the bridge in a temporary file it then deletes', () async {
    final d = HyprlandDesktop(paths, env);
    expect(await d.applyColors({'background': '#1e1e2e', 'accent': '#89b4fa'}), isTrue);
    final lines = log.readAsLinesSync();
    final args = (jsonDecode(lines[0]) as List).cast<String>();
    expect(args[0], 'apply');
    expect(jsonDecode(lines.skip(1).join('\n')), {'background': '#1e1e2e', 'accent': '#89b4fa'});
    expect(File(args[1]).existsSync(), isFalse);
  });

  test('current passes the bridge answer through', () async {
    final d = HyprlandDesktop(paths, env);
    expect((await d.current())!['colors'], {'background': '#000000'});
  });

  test('wallpaper: read from Caelestia state, set through the bridge, errors are false', () async {
    final d = HyprlandDesktop(paths, env);
    expect(d.wallpaper(), isNull);
    File('${env['HOME']}/.local/state/caelestia/wallpaper/path.txt').writeAsStringSync('/pics/a.jpg\n');
    expect(d.wallpaper(), '/pics/a.jpg');
    expect(await d.snapshotBackground(), {'path': '/pics/a.jpg'});

    final good = File('${root.path}/good.png')..writeAsStringSync('x');
    final bad = File('${root.path}/bad.png')..writeAsStringSync('x');
    expect(await d.setWallpaper(good.path), isTrue);
    expect(await d.setWallpaper(bad.path), isFalse);
    expect(await d.setWallpaper('relative.png'), isFalse);
    expect(await d.setWallpaper('${root.path}/missing.png'), isFalse);
    expect(await d.restoreBackground(null), isFalse);
  });

  test('a preview from no wallpaper is undone by clearing Caelestia\'s state', () async {
    final d = HyprlandDesktop(paths, env);
    final snap = await d.snapshotBackground();
    expect(snap, {'path': null});
    expect(await d.restoreBackground(snap), isTrue);
    expect(log.readAsLinesSync().last, '["wallpaper-clear"]');
  });

  test('no bridge: everything is false or null, nothing throws', () async {
    final d = HyprlandDesktop(paths, {...env, 'MAPRISMA_THEME_CAELESTIA_BRIDGE': '${root.path}/none', 'PATH': '/nonexistent'});
    expect(await d.applyColors({'background': '#000000'}), isFalse);
    expect(await d.current(), isNull);
  });
}
