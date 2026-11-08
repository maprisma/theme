import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Offscreen pictures of a page for the visual check (docs/ui-parity.md):
/// only when MAPRISMA_SHOTS names a folder; then real fonts are loaded so
/// the text is readable (the test font draws boxes).
final shotsDir = Platform.environment['MAPRISMA_SHOTS'];

Future<void> loadShotFonts() async {
  if (shotsDir == null) return;
  final fonts = '${Platform.environment['FLUTTER_ROOT'] ?? '/mnt/Data/flutter'}/bin/cache/artifacts/material_fonts';
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    var any = false;
    for (final f in files) {
      final file = File(f.startsWith('/') ? f : '$fonts/$f');
      if (!file.existsSync()) continue;
      any = true;
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    if (any) await loader.load();
  }

  await family('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  // Text without a family falls back to the test font: real letters there too.
  await family('FlutterTest', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await family('MaterialIcons', ['MaterialIcons-Regular.otf']);
  await family('monospace', ['/usr/share/fonts/noto/NotoSansMono-Regular.ttf']);
}

/// Saves what [boundary] shows as `<MAPRISMA_SHOTS>/<name>.png` (nothing
/// without MAPRISMA_SHOTS). Call it inside `tester.runAsync`.
Future<void> saveShot(RenderRepaintBoundary boundary, String name) async {
  final dir = shotsDir;
  if (dir == null) return;
  final image = await boundary.toImage();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  Directory(dir).createSync(recursive: true);
  File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}
