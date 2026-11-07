import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'colors.dart';
import 'posix.dart';

/// Pictures read by the custom module (colors from a wallpaper, the
/// preview's background): a regular file of at most [maxImageBytes], its
/// header checked before anything is decoded (theme_core.image_size_problem),
/// and the colors a theme takes from it (theme_custom.palette_from_pixels).

const maxImageBytes = 50 * 1024 * 1024;
const maxImageSide = 16384;
const maxImagePixels = 64000000;
const _pngMaxTextChunks = 32;
const _pngMaxCompressedMetadata = 32 * 1024;
const _pngMaxChunks = 1000000;

/// The kind of picture by its first bytes: png, jpeg, gif, bmp, webp; else null.
String? imageKind(Uint8List b) {
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'jpeg';
  if (at(0, 'GIF87a'.codeUnits) || at(0, 'GIF89a'.codeUnits)) return 'gif';
  if (at(0, 'BM'.codeUnits)) return 'bmp';
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'webp';
  return null;
}

int _be32(Uint8List b, int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
int _be16(Uint8List b, int i) => (b[i] << 8) | b[i + 1];
int _le16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);
int _le24(Uint8List b, int i) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
int _le32s(Uint8List b, int i) => ByteData.sublistView(b, i, i + 4).getInt32(0, Endian.little);

/// (width, height) the header declares, or null when it cannot be read.
(int, int)? _headerSize(Uint8List b, String kind) {
  try {
    switch (kind) {
      case 'png':
        if (b.length < 24 || String.fromCharCodes(b.sublist(12, 16)) != 'IHDR') return null;
        return (_be32(b, 16), _be32(b, 20));
      case 'gif':
        return b.length < 10 ? null : (_le16(b, 6), _le16(b, 8));
      case 'bmp':
        return b.length < 26 ? null : (_le32s(b, 18).abs(), _le32s(b, 22).abs());
      case 'webp':
        if (b.length < 30) return null;
        final chunk = String.fromCharCodes(b.sublist(12, 16));
        if (chunk == 'VP8 ') return (_le16(b, 26) & 0x3fff, _le16(b, 28) & 0x3fff);
        if (chunk == 'VP8L') {
          final b0 = b[21], b1 = b[22], b2 = b[23], b3 = b[24];
          return (1 + (b0 | ((b1 & 0x3f) << 8)), 1 + ((b1 >> 6) | (b2 << 2) | ((b3 & 0x0f) << 10)));
        }
        if (chunk == 'VP8X') return (1 + _le24(b, 24), 1 + _le24(b, 27));
        return null;
      case 'jpeg':
        var i = 2;
        while (i + 9 < b.length) {
          if (b[i] != 0xFF) return null;
          final marker = b[i + 1];
          if (marker == 0xFF) {
            i++;
            continue;
          }
          if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
            i += 2;
            continue;
          }
          final length = _be16(b, i + 2);
          if (length < 2) return null;
          if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) {
            return (_be16(b, i + 7), _be16(b, i + 5));
          }
          i += 2 + length;
        }
        return null;
    }
  } on RangeError {
    return null;
  }
  return null;
}

/// Why a PNG's metadata must not reach a decoder, or null (chunk headers only).
String? _pngMetadataProblem(Uint8List b) {
  var i = 8, chunks = 0, texts = 0, compressed = 0;
  while (true) {
    if (++chunks > _pngMaxChunks) return 'PNG has too many chunks';
    if (i + 8 > b.length) return 'damaged PNG';
    final length = _be32(b, i);
    final kind = String.fromCharCodes(b.sublist(i + 4, i + 8));
    if (length > 0x7FFFFFFF) return 'damaged PNG';
    final start = i + 8;
    if (kind == 'tEXt' || kind == 'zTXt' || kind == 'iTXt') {
      texts++;
      if (kind == 'zTXt') {
        compressed += length;
      } else if (kind == 'iTXt') {
        final int end = math.min<int>(b.length, start + math.min<int>(length, 81));
        final keyword = b.sublist(math.min<int>(start, end), end);
        final nul = keyword.indexOf(0);
        if (nul >= 0 && nul + 1 < keyword.length && keyword[nul + 1] == 1) compressed += length;
      }
    } else if (kind == 'iCCP') {
      compressed += length;
    }
    if (texts > _pngMaxTextChunks) return 'PNG has too many text chunks';
    if (compressed > _pngMaxCompressedMetadata) return 'PNG has too much compressed metadata';
    if (kind == 'IEND') return null;
    i = start + length + 4;
  }
}

/// Why these image bytes must not be decoded, or null when the header
/// declares a sane size (16384 px per side, 64 MP).
String? headerSizeProblem(Uint8List bytes) {
  final kind = imageKind(bytes);
  if (kind == null) return 'not a supported image (JPG, PNG, WebP, GIF, BMP)';
  final size = _headerSize(bytes, kind);
  if (size == null) return 'unreadable image';
  final (w, h) = size;
  if (w <= 0 || h <= 0) return 'image has no size';
  if (w > maxImageSide || h > maxImageSide || w * h > maxImagePixels) return 'image too large to show ($w×$h)';
  if (kind == 'png') return _pngMetadataProblem(bytes);
  return null;
}

/// The bytes of a picture that is safe to decode, or throws [FormatException]
/// with the reason (missing, not a regular file, too large, bad header).
Uint8List readCheckedImage(String path) {
  final bytes = Posix.instance.readRegular(path, maxImageBytes);
  if (bytes == null) throw const FormatException('cannot read the image (missing, not a file, or over 50 MiB)');
  final problem = headerSizeProblem(bytes);
  if (problem != null) throw FormatException(problem);
  return bytes;
}

/// Decodes checked bytes (the first frame only) as 8-bit RGBA; null when the
/// decoder fails. Call it on bytes [readCheckedImage] returned.
img.Image? decodeChecked(Uint8List bytes) {
  final img.Decoder decoder = switch (imageKind(bytes)) {
    'png' => img.PngDecoder(),
    'jpeg' => img.JpegDecoder(),
    'gif' => img.GifDecoder(),
    'bmp' => img.BmpDecoder(),
    'webp' => img.WebPDecoder(),
    _ => throw const FormatException('not a supported image'),
  };
  try {
    final image = decoder.decode(bytes, frame: 0);
    if (image == null || image.width < 1 || image.height < 1) return null;
    return image.convert(format: img.Format.uint8, numChannels: 4);
  } catch (_) {
    return null;
  }
}

// --- HLS (Python's colorsys) ------------------------------------------------------

(double, double, double) rgbToHls(double r, double g, double b) {
  final maxc = math.max(r, math.max(g, b)), minc = math.min(r, math.min(g, b));
  final l = (minc + maxc) / 2;
  if (minc == maxc) return (0, l, 0);
  final d = maxc - minc;
  final s = l <= 0.5 ? d / (maxc + minc) : d / (2 - maxc - minc);
  final rc = (maxc - r) / d, gc = (maxc - g) / d, bc = (maxc - b) / d;
  double h;
  if (r == maxc) {
    h = bc - gc;
  } else if (g == maxc) {
    h = 2 + rc - bc;
  } else {
    h = 4 + gc - rc;
  }
  return ((h / 6) % 1.0, l, s);
}

(double, double, double) hlsToRgb(double h, double l, double s) {
  if (s == 0) return (l, l, l);
  final m2 = l <= 0.5 ? l * (1 + s) : l + s - l * s;
  final m1 = 2 * l - m2;
  double v(double hue) {
    hue %= 1.0;
    if (hue < 1 / 6) return m1 + (m2 - m1) * hue * 6;
    if (hue < 0.5) return m2;
    if (hue < 2 / 3) return m1 + (m2 - m1) * (2 / 3 - hue) * 6;
    return m1;
  }

  return (v(h + 1 / 3), v(h), v(h - 1 / 3));
}

String _hex01(double r, double g, double b) =>
    hexOf((r * 255).round().clamp(0, 255), (g * 255).round().clamp(0, 255), (b * 255).round().clamp(0, 255));

/// A color from hue (0..1, wraps), lightness and saturation (clamped).
String fromHls(double h, double l, double s) {
  final (r, g, b) = hlsToRgb(h % 1.0, l.clamp(0.0, 1.0), s.clamp(0.0, 1.0));
  return _hex01(r, g, b);
}

(double, double, double) hlsOf(String hex) {
  final (r, g, b) = rgbOf(hex);
  return rgbToHls(r / 255, g / 255, b / 255);
}

// --- colors from a picture ------------------------------------------------------------

/// Where each terminal color sits on the color wheel (degrees) when the
/// picture offers nothing close to it.
const ansiHues = {
  'red': 355, 'orange': 25, 'yellow': 48, 'green': 120, 'cyan': 180, 'blue': 215, 'magenta': 295, 'brown': 25,
};

/// The picture scaled down to fit about [size]×[size], as RGB triples 0..1
/// (transparent pixels left out).
List<(double, double, double)> imagePixels(img.Image image, {int size = 64}) {
  final scale = math.min(1.0, size / math.max(image.width, image.height));
  final w = math.max(1, (image.width * scale).round()), h = math.max(1, (image.height * scale).round());
  final small = (w == image.width && h == image.height)
      ? image
      : img.copyResize(image, width: w, height: h, interpolation: img.Interpolation.average);
  final out = <(double, double, double)>[];
  for (final p in small) {
    if (p.a < 128) continue;
    out.add((p.r / 255, p.g / 255, p.b / 255));
  }
  return out;
}

double _meanHue(List<(double, double, double)> items) {
  var x = 0.0, y = 0.0;
  for (final (h, _, _) in items) {
    x += math.cos(h * 2 * math.pi);
    y += math.sin(h * 2 * math.pi);
  }
  return (math.atan2(y, x) / (2 * math.pi)) % 1.0;
}

/// Moves [color]'s lightness away from [bg] until it has at least
/// [minimum] contrast (or the end of the scale is reached).
String _readable(String color, String bg, double minimum) {
  if (contrast(color, bg) >= minimum) return color;
  final (h, l0, s) = hlsOf(color);
  final up = luminance(bg) < 0.5;
  var l = l0;
  var out = color;
  for (var i = 0; i < 50 && contrast(out, bg) < minimum; i++) {
    l = (l + (up ? 0.02 : -0.02)).clamp(0.0, 1.0);
    out = fromHls(h, l, s);
    if (l == 0.0 || l == 1.0) break;
  }
  return out;
}

/// The main colors of a theme that matches a picture: the background takes
/// the picture's main hue (very dark, or very light for bright pictures),
/// the accent its most vivid frequent color, and every terminal color the
/// picture's own shade of that hue where it has one, all at one lightness so
/// they stay readable on the background. Returns background, foreground,
/// accent, selection, muted and the eight palette colors (derive the rest).
Map<String, String> colorsFromPixels(List<(double, double, double)> pixels) {
  if (pixels.isEmpty) throw const FormatException('the image has no visible pixels');
  final hls = [for (final (r, g, b) in pixels) rgbToHls(r, g, b)];
  final brightness = hls.fold(0.0, (a, p) => a + p.$2) / hls.length;
  final dark = brightness < 0.6;
  // Group colors into hue slices of 15°; greys go into their own group.
  final groups = <int, List<(double, double, double)>>{};
  for (final p in hls) {
    final (h, l, s) = p;
    final key = (s < 0.12 || l < 0.06 || l > 0.96) ? -1 : (h * 24).floor();
    groups.putIfAbsent(key, () => []).add(p);
  }
  final colored = {for (final e in groups.entries) if (e.key >= 0) e.key: e.value};
  final total = hls.length;
  double meanSat(List<(double, double, double)> items) => items.fold(0.0, (a, p) => a + p.$3) / items.length;

  // The main hue: the biggest colored group (none: a neutral grey).
  double mainHue = 0.6, mainSat = 0.0;
  if (colored.isNotEmpty) {
    final mainItems = colored.values.reduce((a, b) => b.length > a.length ? b : a);
    mainHue = _meanHue(mainItems);
    mainSat = math.min(0.35, meanSat(mainItems));
  }
  // The accent: vivid and not rare. Weighted by chroma (how colorful a
  // color really looks) and by its share of the picture.
  double vividness(List<(double, double, double)> items) {
    final chroma = items.fold(0.0, (a, p) => a + p.$3 * (1 - (2 * p.$2 - 1).abs())) / items.length;
    return chroma * math.sqrt(items.length / total);
  }

  List<(double, double, double)>? accentItems;
  for (final items in colored.values) {
    if (accentItems == null || vividness(items) > vividness(accentItems)) accentItems = items;
  }
  final accentHue = accentItems != null ? _meanHue(accentItems) : mainHue;
  final accentSat = accentItems != null ? meanSat(accentItems).clamp(0.55, 0.85) : 0.0;

  String bg, fg, accent;
  double lightness, saturation;
  if (dark) {
    bg = fromHls(mainHue, 0.11, mainSat * 0.6);
    fg = fromHls(mainHue, 0.88, math.min(0.15, mainSat));
    accent = fromHls(accentHue, 0.66, accentSat);
    lightness = 0.68;
    saturation = 0.62;
  } else {
    bg = fromHls(mainHue, 0.95, mainSat * 0.5);
    fg = fromHls(mainHue, 0.16, math.min(0.2, mainSat));
    accent = fromHls(accentHue, 0.42, accentSat);
    lightness = 0.42;
    saturation = 0.65;
  }
  fg = _readable(fg, bg, 7.0);
  accent = _readable(accent, bg, 3.0);
  final colors = <String, String>{
    'background': bg,
    'foreground': fg,
    'accent': accent,
    'selection': mixColor(bg, accent, 0.28),
    'muted': mixColor(fg, bg, 0.5),
  };
  final hues = {for (final e in colored.entries) e.key: _meanHue(e.value)};
  for (final MapEntry(key: key, value: deg) in ansiHues.entries) {
    var hue = deg / 360;
    // The picture's own version of this hue, if it has a fair amount of it.
    (double, int)? best;
    for (final e in colored.entries) {
      final h = hues[e.key]!;
      final distance = math.min((h - hue).abs(), 1 - (h - hue).abs()) * 360;
      if (distance <= 20 && e.value.length >= total * 0.01 && (best == null || e.value.length > best.$2)) {
        best = (h, e.value.length);
      }
    }
    if (best != null) hue = best.$1;
    colors[key] = key == 'brown'
        ? fromHls(hue, dark ? 0.35 : 0.3, 0.45)
        : _readable(fromHls(hue, lightness, saturation), bg, 3.0);
  }
  return colors;
}

Map<String, String> _colorsFromBytes(Uint8List bytes) {
  final image = decodeChecked(bytes);
  if (image == null) throw const FormatException('cannot read the image');
  return colorsFromPixels(imagePixels(image));
}

/// The main colors for a picture file (decoded in a separate isolate).
/// Throws [FormatException] with a reason.
Future<Map<String, String>> colorsFromImageFile(String path) async {
  final bytes = readCheckedImage(path);
  return Isolate.run(() => _colorsFromBytes(bytes));
}
