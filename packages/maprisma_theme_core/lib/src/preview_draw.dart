import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'colors.dart';
import 'extract.dart';

/// preview.png for a theme made here (theme_custom.make_preview): a small
/// desktop in the theme's colors — the wallpaper (or the darkest
/// background), a bar, and a terminal window with an accent border, colored
/// code lines, a selected line and the palette — so the theme can be told
/// apart in every list.

const previewWidth = 1280, previewHeight = 720;

/// (x, y, w, h) of the centred part of a srcW×srcH image that, scaled to
/// width×height, covers it with the aspect kept (cropped before scaling).
(int, int, int, int)? coverCrop(int srcW, int srcH, int width, int height) {
  if (srcW < 1 || srcH < 1) return null;
  final scale = math.max(width / srcW, height / srcH);
  final w = math.max(1, math.min(srcW, (width / scale).round()));
  final h = math.max(1, math.min(srcH, (height / scale).round()));
  return ((srcW - w) ~/ 2, (srcH - h) ~/ 2, w, h);
}

img.ColorRgba8 _c(Map<String, String> colors, String key, [String fallback = '#808080']) {
  final v = colors[key];
  final (r, g, b) = rgbOf(isHex(v) ? v! : fallback);
  return img.ColorRgba8(r, g, b, 255);
}

Uint8List _draw(Map<String, String> colors, Uint8List? wallpaper) {
  const width = previewWidth, height = previewHeight;
  final canvas = img.Image(width: width, height: height, numChannels: 4);
  final bgKey = isHex(colors['darker_background']) ? 'darker_background' : 'background';
  img.fill(canvas, color: _c(colors, bgKey, '#000000'));
  if (wallpaper != null) {
    final image = decodeChecked(wallpaper);
    if (image != null) {
      final crop = coverCrop(image.width, image.height, width, height);
      if (crop != null) {
        final (x, y, w, h) = crop;
        final part = img.copyCrop(image, x: x, y: y, width: w, height: h);
        final scaled = img.copyResize(part, width: width, height: height, interpolation: img.Interpolation.linear);
        img.compositeImage(canvas, scaled, dstX: 0, dstY: 0);
      }
    }
  }

  void box(int x, int y, int w, int h, String key, [int alpha = 255]) {
    final c = _c(colors, key);
    img.fillRect(canvas, x1: x, y1: y, x2: x + w - 1, y2: y + h - 1,
        color: img.ColorRgba8(c.r.toInt(), c.g.toInt(), c.b.toInt(), alpha));
  }

  void rounded(int x, int y, int w, int h, String key, num radius) {
    img.fillRect(canvas, x1: x, y1: y, x2: x + w - 1, y2: y + h - 1, color: _c(colors, key), radius: radius);
  }

  // The bar along the top: workspaces (the active one in the accent) and a clock.
  box(0, 0, width, 34, 'background', 240);
  rounded(18, 11, 12, 12, 'accent', 6);
  for (var i = 0; i < 3; i++) {
    rounded(42 + i * 24, 11, 12, 12, 'muted', 6);
  }
  box(width - 92, 13, 66, 8, 'foreground');

  // A terminal window in the theme's colors, with a border in the accent.
  const x = 300, y = 150, w = 680, h = 420;
  rounded(x - 4, y - 4, w + 8, h + 8, 'accent', 14);
  rounded(x, y, w, h, 'background', 10);
  box(x, y + 10, w, 36, 'dark_background');
  rounded(x, y, w, 20, 'dark_background', 10);
  for (final (i, key) in ['red', 'yellow', 'green'].indexed) {
    rounded(x + 20 + i * 30, y + 16, 16, 16, key, 8);
  }
  box(x + 120, y + 20, 200, 8, 'muted');

  // Code lines: `def greet(name):`, a comment, `print("hello", 42, True)`.
  void line(int ly, List<(int, String)> tokens, {int height = 14, int indent = 0}) {
    var lx = x + 40 + indent;
    for (final (len, key) in tokens) {
      box(lx, ly, len, height, key);
      lx += len + 12;
    }
  }

  line(y + 80, [(60, 'magenta'), (110, 'blue'), (90, 'foreground')], height: 18);
  line(y + 118, [(330, 'muted')], indent: 48);
  line(y + 148, [(80, 'yellow'), (100, 'green'), (40, 'orange'), (70, 'cyan')], indent: 48);
  box(x + 30, y + 184, w - 60, 36, 'selection');
  box(x + 40, y + 196, 300, 12, 'foreground');
  line(y + 240, [(90, 'cyan'), (18, 'accent'), (200, 'foreground'), (110, 'red')]);
  const keys = ['red', 'yellow', 'orange', 'green', 'cyan', 'blue', 'magenta', 'brown'];
  for (final (i, key) in keys.indexed) {
    rounded(x + 40 + i * 76, y + 300, 64, 64, key, 8);
  }
  return img.encodePng(canvas, level: 6);
}

/// The preview as PNG bytes; [wallpaper] (a file, header-checked) fills the
/// background when it can be read. Drawn in a separate isolate.
Future<Uint8List> drawPreview(Map<String, String> colors, [String? wallpaper]) async {
  Uint8List? bytes;
  if (wallpaper != null) {
    try {
      bytes = readCheckedImage(wallpaper);
    } on FormatException {
      bytes = null;
    }
  }
  final c = Map<String, String>.of(colors);
  return Isolate.run(() => _draw(c, bytes));
}
