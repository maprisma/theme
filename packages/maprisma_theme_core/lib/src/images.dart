import 'i18n.dart';
import 'dart:io';
import 'dart:typed_data';

/// Image checks before anything is decoded (theme_core.py): the size an
/// image header declares, PNG metadata budgets, the HEIC/HEIF canvas, and
/// the type of image bytes by their magic. Only headers and block lengths
/// are read, never pixel data.

const maxImageSide = 16384;
const maxImagePixels = 64000000; // width × height × frames, ~256 MiB RGBA
const maxBackgroundBytes = 50 * 1024 * 1024; // one wallpaper, whatever its source

const pngMaxTextChunks = 32;
const pngMaxCompressedMetadata = 32 * 1024; // zTXt + compressed iTXt + iCCP, in file bytes
const pngMaxChunks = 1000000;
const pngKeepChunks = {'IHDR', 'PLTE', 'IDAT', 'IEND', 'tRNS', 'gAMA', 'cHRM', 'sRGB', 'iCCP', 'sBIT', 'bKGD', 'pHYs'};
const pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
const heifMaxMetaBytes = 4 * 1024 * 1024;

String get unsupportedImage => tr("not a supported image (JPG, PNG, WebP, GIF, BMP)");

/// A seekable byte source: a file opened for reading or bytes in memory.
abstract class _Source {
  int get pos;
  set pos(int value);
  int get length;
  Uint8List read(int n);
  void skip(int n) => pos = pos + n;
}

final class _BytesSource extends _Source {
  _BytesSource(this.data);
  final Uint8List data;
  int _pos = 0;
  @override
  int get pos => _pos;
  @override
  set pos(int value) => _pos = value < 0 ? 0 : value;
  @override
  int get length => data.length;
  @override
  Uint8List read(int n) {
    if (_pos >= data.length || n <= 0) return Uint8List(0);
    final end = (_pos + n).clamp(0, data.length);
    final out = Uint8List.sublistView(data, _pos, end);
    _pos = end;
    return out;
  }
}

final class _FileSource extends _Source {
  _FileSource(this.raf) : length = raf.lengthSync();
  final RandomAccessFile raf;
  @override
  final int length;
  @override
  int get pos => raf.positionSync();
  @override
  set pos(int value) => raf.setPositionSync(value < 0 ? 0 : value);
  @override
  Uint8List read(int n) => n <= 0 ? Uint8List(0) : raf.readSync(n);
}

int _be(List<int> b, int start, int count) {
  var v = 0;
  for (var i = 0; i < count; i++) {
    v = (v << 8) | b[start + i];
  }
  return v;
}

int _le(List<int> b, int start, int count) {
  var v = 0;
  for (var i = count - 1; i >= 0; i--) {
    v = (v << 8) | b[start + i];
  }
  return v;
}

int _le32s(List<int> b, int start) {
  final v = _le(b, start, 4);
  return v >= 0x80000000 ? v - 0x100000000 : v;
}

bool _startsWith(List<int> data, List<int> prefix, [int offset = 0]) {
  if (data.length < offset + prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (data[offset + i] != prefix[i]) return false;
  }
  return true;
}

bool _ascii(List<int> data, int offset, String text) => _startsWith(data, text.codeUnits, offset);

bool isPng(List<int> data) => _startsWith(data, pngSignature);

/// WebP, PNG or JPEG by magic bytes (what Wallhaven serves).
bool isImageData(List<int> data) =>
    (_ascii(data, 0, 'RIFF') && _ascii(data, 8, 'WEBP')) || isPng(data) || _startsWith(data, const [0xff, 0xd8, 0xff]);

/// The wallpaper file extension for image bytes by their magic, else null.
String? imageExtension(List<int> data) {
  if (_startsWith(data, const [0xff, 0xd8, 0xff])) return '.jpg';
  if (isPng(data)) return '.png';
  if (_ascii(data, 0, 'RIFF') && _ascii(data, 8, 'WEBP')) return '.webp';
  if (_ascii(data, 0, 'GIF87a') || _ascii(data, 0, 'GIF89a')) return '.gif';
  if (_ascii(data, 0, 'BM')) return '.bmp';
  return null;
}

const _mimeExts = {
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/jpg': '.jpg',
  'image/webp': '.webp',
  'image/gif': '.gif',
  'image/bmp': '.bmp',
  'image/x-bmp': '.bmp',
};

/// The file extension for a clipboard image type, or null (SVG and the like
/// are not wallpapers).
String? extensionForMime(String mime) => _mimeExts[mime.split(';').first.trim().toLowerCase()];

// --- header sizes --------------------------------------------------------------

(int, int, int)? _headerSize(_Source s) {
  final head = s.read(32);
  if (isPng(head)) {
    if (head.length < 24 || !_ascii(head, 12, 'IHDR')) return null;
    return (_be(head, 16, 4), _be(head, 20, 4), 1);
  }
  if (_startsWith(head, const [0xff, 0xd8, 0xff])) return _jpegSize(s);
  if (_ascii(head, 0, 'GIF87a') || _ascii(head, 0, 'GIF89a')) return head.length < 13 ? null : _gifSize(s, head);
  if (_ascii(head, 0, 'RIFF') && _ascii(head, 8, 'WEBP')) return _webpSize(s);
  if (_ascii(head, 0, 'BM') && head.length >= 26) {
    if (_le(head, 14, 4) == 12) return (_le(head, 18, 2), _le(head, 20, 2), 1); // OS/2 core header
    return (_le32s(head, 18).abs(), _le32s(head, 22).abs(), 1); // negative height = top-down rows
  }
  return null;
}

(int, int, int)? _jpegSize(_Source s) {
  s.pos = 2;
  for (var i = 0; i < 10000; i++) {
    final byte = s.read(1);
    if (byte.isEmpty || byte[0] != 0xff) return null;
    var marker = s.read(1);
    while (marker.isNotEmpty && marker[0] == 0xff) {
      marker = s.read(1);
    }
    if (marker.isEmpty) return null;
    final code = marker[0];
    if (code == 0x01 || (code >= 0xD0 && code <= 0xD7)) continue;
    if (code == 0xD9 || code == 0xDA) return null;
    final lenBytes = s.read(2);
    if (lenBytes.length < 2) return null;
    final length = _be(lenBytes, 0, 2);
    if (length < 2) return null;
    if (code >= 0xC0 && code <= 0xCF && code != 0xC4 && code != 0xC8 && code != 0xCC) {
      final data = s.read(5);
      if (data.length < 5) return null;
      return (_be(data, 3, 2), _be(data, 1, 2), 1);
    }
    s.skip(length - 2);
  }
  return null;
}

(int, int, int)? _gifSize(_Source s, Uint8List head) {
  var width = _le(head, 6, 2), height = _le(head, 8, 2);
  var pos = 13;
  if (head[10] & 0x80 != 0) pos += 3 << ((head[10] & 0x07) + 1);
  s.pos = pos;
  var frames = 0;
  bool skipSubBlocks() {
    while (true) {
      final size = s.read(1);
      if (size.isEmpty) return false;
      if (size[0] == 0) return true;
      s.skip(size[0]);
    }
  }

  while (true) {
    final block = s.read(1);
    if (block.isEmpty) break;
    if (block[0] == 0x2c) {
      final desc = s.read(9);
      if (desc.length < 9) break;
      frames++;
      width = width > _le(desc, 0, 2) + _le(desc, 4, 2) ? width : _le(desc, 0, 2) + _le(desc, 4, 2);
      height = height > _le(desc, 2, 2) + _le(desc, 6, 2) ? height : _le(desc, 2, 2) + _le(desc, 6, 2);
      if (desc[8] & 0x80 != 0) s.skip(3 << ((desc[8] & 0x07) + 1));
      s.read(1); // LZW minimum code size
      if (!skipSubBlocks()) break;
      if (width * height * frames > maxImagePixels) break;
    } else if (block[0] == 0x21) {
      s.read(1);
      if (!skipSubBlocks()) break;
    } else {
      break;
    }
  }
  return frames > 0 ? (width, height, frames) : null;
}

(int, int, int)? _webpSize(_Source s) {
  s.pos = 12;
  (int, int)? size;
  var frames = 0;
  for (var i = 0; i < 100000; i++) {
    final header = s.read(8);
    if (header.length < 8) break;
    final kind = String.fromCharCodes(header.sublist(0, 4));
    final length = _le(header, 4, 4);
    final data = s.read(length < 10 ? length : 10);
    if (kind == 'VP8X' && data.length >= 10) {
      size = (1 + _le(data, 4, 3), 1 + _le(data, 7, 3));
    } else if (kind == 'VP8 ' && data.length >= 10 && size == null) {
      size = (_le(data, 6, 2) & 0x3FFF, _le(data, 8, 2) & 0x3FFF);
    } else if (kind == 'VP8L' && data.length >= 5 && size == null) {
      final bits = _le(data, 1, 4);
      size = (1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF));
    } else if (kind == 'ANMF') {
      frames++;
      if (size != null && size.$1 * size.$2 * frames > maxImagePixels) break;
    }
    s.skip(length + (length & 1) - data.length);
    if (s.pos >= s.length) break;
  }
  return size == null ? null : (size.$1, size.$2, frames > 1 ? frames : 1);
}

// --- PNG metadata ----------------------------------------------------------------

/// Why a PNG's metadata chunks must not reach a decoder, or null: COSMIC's
/// and Flutter's decoders inflate text chunks before pixels, so repeated
/// compressed chunks are a memory bomb the pixel cap does not see.
String? pngMetadataProblem(List<int> data) => _pngMetadataProblem(_BytesSource(Uint8List.fromList(data)));

String? _pngMetadataProblem(_Source s) {
  s.pos = 8;
  var texts = 0, compressed = 0, chunks = 0;
  while (true) {
    chunks++;
    if (chunks > pngMaxChunks) return tr("PNG has too many chunks");
    final head = s.read(8);
    if (head.length < 8) return tr("damaged PNG");
    final length = _be(head, 0, 4);
    final kind = String.fromCharCodes(head.sublist(4));
    if (length > 0x7FFFFFFF) return tr("damaged PNG");
    final start = s.pos;
    if (kind == 'tEXt' || kind == 'zTXt' || kind == 'iTXt') {
      texts++;
      if (kind == 'zTXt') {
        compressed += length;
      } else if (kind == 'iTXt') {
        final keyword = s.read(length < 81 ? length : 81);
        final nul = keyword.indexOf(0);
        if (nul >= 0 && nul + 1 < keyword.length && keyword[nul + 1] == 1) compressed += length;
      }
    } else if (kind == 'iCCP') {
      compressed += length;
    }
    if (texts > pngMaxTextChunks) return tr("PNG has too many text chunks");
    if (compressed > pngMaxCompressedMetadata) return tr("PNG has too much compressed metadata");
    if (kind == 'IEND') return null;
    s.pos = start + length + 4;
    if (s.pos > s.length) return tr("damaged PNG");
  }
}

/// The PNG with only pixel, palette and colour chunks ([pngKeepChunks], at
/// most one small iCCP); text, EXIF and unknown chunks and anything after
/// IEND are dropped. Pixels are copied byte for byte, never decoded.
/// Throws [FormatException] for a damaged chunk list.
Uint8List stripPngMetadata(Uint8List data) {
  if (!isPng(data)) throw FormatException(tr("not a PNG"));
  final out = BytesBuilder(copy: false)..add(pngSignature);
  var pos = 8, count = 0, haveIccp = false;
  while (true) {
    count++;
    if (count > pngMaxChunks || pos + 8 > data.length) throw FormatException(tr("damaged PNG"));
    final length = _be(data, pos, 4);
    final kind = String.fromCharCodes(data.sublist(pos + 4, pos + 8));
    final end = pos + 12 + length;
    if (length > 0x7FFFFFFF || end > data.length) throw FormatException(tr("damaged PNG"));
    var keep = pngKeepChunks.contains(kind);
    if (keep && kind == 'iCCP') {
      if (haveIccp || length > pngMaxCompressedMetadata) {
        keep = false;
      } else {
        haveIccp = true;
      }
    }
    if (keep) out.add(Uint8List.sublistView(data, pos, end));
    if (kind == 'IEND') break;
    pos = end;
  }
  return out.takeBytes();
}

// --- the checks ------------------------------------------------------------------

String? _sizeVerdict((int, int, int)? size, String? meta) {
  if (meta != null) return meta;
  if (size == null) return unsupportedImage;
  final (w, h, frames) = size;
  if (w == 0 || h == 0) return tr("image has no size");
  if (w > maxImageSide || h > maxImageSide || w * h * frames > maxImagePixels) {
    return frames > 1 ? 'image too large to show ($w×$h × $frames frames)' : trf("image too large to show ({0}×{1})", [w, h]);
  }
  return null;
}

String? _check(_Source s) {
  final size = _headerSize(s);
  s.pos = 0;
  final png = isPng(s.read(8));
  final meta = size != null && png ? _pngMetadataProblem(s) : null;
  return _sizeVerdict(size, meta);
}

/// Why the image at [path] must not be decoded, or null when its header
/// declares a sane size (and, for a PNG, its metadata is within budget).
/// Only a regular file is read (a FIFO or device named as an image is refused).
String? imageSizeProblem(String path) {
  RandomAccessFile? raf;
  try {
    if (FileStat.statSync(path).type != FileSystemEntityType.file) return tr("unreadable image");
    raf = File(path).openSync();
    return _check(_FileSource(raf));
  } on FileSystemException {
    return tr("unreadable image");
  } on RangeError {
    return tr("unreadable image");
  } finally {
    raf?.closeSync();
  }
}

/// [imageSizeProblem] for image bytes.
String? imageBytesProblem(Uint8List data) {
  try {
    return _check(_BytesSource(data));
  } on RangeError {
    return tr("unreadable image");
  }
}

// --- HEIC / HEIF -----------------------------------------------------------------

Iterable<(String, int, int)> _bmffBoxes(Uint8List data, [int start = 0, int? end]) sync* {
  final stop = end ?? data.length;
  var pos = start;
  for (var i = 0; i < 10000; i++) {
    if (pos + 8 > stop) return;
    var size = _be(data, pos, 4);
    final kind = String.fromCharCodes(data.sublist(pos + 4, pos + 8));
    var header = 8;
    if (size == 1) {
      if (pos + 16 > stop) return;
      size = _be(data, pos + 8, 8);
      header = 16;
    } else if (size == 0) {
      size = stop - pos;
    }
    if (size < header || pos + size > stop) return;
    yield (kind, pos + header, pos + size);
    pos += size;
  }
}

Uint8List? _heifMeta(Uint8List file) {
  var pos = 0;
  for (var i = 0; i < 64; i++) {
    if (pos + 8 > file.length) return null;
    var size = _be(file, pos, 4);
    final kind = String.fromCharCodes(file.sublist(pos + 4, pos + 8));
    var offset = 8;
    if (size == 1) {
      if (pos + 16 > file.length) return null;
      size = _be(file, pos + 8, 8);
      offset = 16;
    }
    if (kind == 'meta') {
      if (!(offset < size && size <= heifMaxMetaBytes + offset)) return null;
      if (pos + size > file.length) return null;
      return Uint8List.sublistView(file, pos + offset, pos + size);
    }
    if (size < offset) return null;
    pos += size;
  }
  return null;
}

Map<int, String> _heifItemTypes(Uint8List meta, (int, int)? iinf) {
  final types = <int, String>{};
  if (iinf == null) return types;
  final (a, b) = iinf;
  final version = meta[a];
  final first = a + 4 + (version == 0 ? 2 : 4);
  for (final (kind, ea, eb) in _bmffBoxes(meta, first, b)) {
    if (kind != 'infe' || eb - ea < 4) continue;
    final v = meta[ea];
    if (v == 2 && eb - ea >= 12) {
      types[_be(meta, ea + 4, 2)] = String.fromCharCodes(meta.sublist(ea + 8, ea + 12));
    } else if (v == 3 && eb - ea >= 14) {
      types[_be(meta, ea + 4, 4)] = String.fromCharCodes(meta.sublist(ea + 10, ea + 14));
    }
  }
  return types;
}

Map<int, Uint8List?> _heifItemData(Uint8List file, Uint8List meta, Map<String, (int, int)> boxes, List<int> items) {
  final out = <int, Uint8List?>{for (final i in items) i: null};
  final iloc = boxes['iloc'];
  if (iloc == null) return out;
  final (a, b) = iloc;
  final version = meta[a];
  var pos = a + 4;
  final offsetSize = meta[pos] >> 4, lengthSize = meta[pos] & 15;
  final baseSize = meta[pos + 1] >> 4;
  final indexSize = (version == 1 || version == 2) ? meta[pos + 1] & 15 : 0;
  pos += 2;
  int take(int n) {
    if (pos + n > b) throw FormatException(tr("truncated iloc"));
    final v = n == 0 ? 0 : _be(meta, pos, n);
    pos += n;
    return v;
  }

  final count = take(version < 2 ? 2 : 4);
  final idat = boxes['idat'];
  for (var n = 0; n < count && n < 65535; n++) {
    final item = take(version < 2 ? 2 : 4);
    final method = (version == 1 || version == 2) ? take(2) & 15 : 0;
    take(2); // data reference index
    final base = take(baseSize);
    final extents = take(2);
    int? first;
    for (var e = 0; e < extents; e++) {
      if (indexSize > 0) take(indexSize);
      final extentOffset = take(offsetSize);
      take(lengthSize);
      if (e == 0) first = base + extentOffset;
    }
    if (!out.containsKey(item) || first == null) continue;
    if (method == 1 && idat != null) {
      final start = idat.$1 + first;
      final end = start + 12 < idat.$2 ? start + 12 : idat.$2;
      out[item] = start < end ? Uint8List.sublistView(meta, start, end) : Uint8List(0);
    } else if (method == 0) {
      final end = first + 12 < file.length ? first + 12 : file.length;
      out[item] = first < end ? Uint8List.sublistView(file, first, end) : Uint8List(0);
    }
  }
  return out;
}

/// Why a HEIC/HEIF file (its bytes) must not be handed to the decoder, or
/// null. Reads only the 'meta' box: every image extent ('ispe') and the
/// canvas of every grid item; overlay images are refused.
String? heifSizeProblem(Uint8List file) {
  final sizes = <(int, int)>[];
  try {
    final meta = _heifMeta(file);
    if (meta == null || meta.length < 4) return tr("not a readable HEIC/HEIF photo");
    final boxes = <String, (int, int)>{};
    for (final (kind, a, b) in _bmffBoxes(meta, 4)) {
      boxes.putIfAbsent(kind, () => (a, b));
    }
    final iprp = boxes['iprp'];
    if (iprp != null) {
      for (final (kind, a, b) in _bmffBoxes(meta, iprp.$1, iprp.$2)) {
        if (kind != 'ipco') continue;
        for (final (prop, pa, pb) in _bmffBoxes(meta, a, b)) {
          if (prop == 'ispe' && pb - pa >= 12) sizes.add((_be(meta, pa + 4, 4), _be(meta, pa + 8, 4)));
        }
      }
    }
    if (sizes.isEmpty) return tr("HEIC/HEIF photo declares no image size");
    final types = _heifItemTypes(meta, boxes['iinf']);
    if (types.values.contains('iovl')) return tr("HEIC/HEIF overlay images are not supported");
    final grids = [for (final e in types.entries) if (e.value == 'grid') e.key];
    if (grids.isNotEmpty) {
      for (final data in _heifItemData(file, meta, boxes, grids).values) {
        if (data == null || data.length < 8) return tr("unreadable HEIC/HEIF grid");
        if (data[1] & 1 != 0) {
          if (data.length < 12) return tr("unreadable HEIC/HEIF grid");
          sizes.add((_be(data, 4, 4), _be(data, 8, 4)));
        } else {
          sizes.add((_be(data, 4, 2), _be(data, 6, 2)));
        }
      }
    }
  } on RangeError {
    return tr("not a readable HEIC/HEIF photo");
  } on FormatException {
    return tr("not a readable HEIC/HEIF photo");
  }
  for (final (w, h) in sizes) {
    if (w == 0 || h == 0) return tr("image has no size");
    if (w > maxImageSide || h > maxImageSide || w * h > maxImagePixels) return trf("image too large to convert ({0}×{1})", [w, h]);
  }
  return null;
}
