import 'proposals.dart';
import 'i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bounded.dart';
import 'posix.dart';
import 'context.dart';
import 'images.dart';
import 'store.dart';
import 'themes.dart';
import 'wallpapers.dart';

/// Search wallpapers on wallhaven.cc (wallpaper_search.py). Only Wallhaven's
/// fixed hosts are contacted (API on wallhaven.cc, thumbnails on
/// th.wallhaven.cc, images on w.wallhaven.cc); every URL in a reply must
/// match its exact expected shape; requests go through curl, HTTPS only, no
/// redirects, with a byte cap and a deadline; the search text is only a
/// URL-encoded query parameter.

const wallhavenApi = 'https://wallhaven.cc/api/v1/search';
const wallhavenSource = 'wallhaven.cc';
const maxQuery = 100;
const maxApiBytes = 1024 * 1024;
const maxThumbBytes = 1024 * 1024;
const maxThumbsCached = 400;
const maxPreviewsCached = 3;

final _idRe = RegExp(r'^[a-z0-9]{1,12}$');
final pageRe = RegExp(r'^https://wallhaven\.cc/w/([a-z0-9]{1,12})$');
final thumbRe = RegExp(r'^https://th\.wallhaven\.cc/(?:small|lg)/[a-z0-9]{2}/([a-z0-9]{1,12})\.(?:jpg|png)$');
final fullRe = RegExp(r'^https://w\.wallhaven\.cc/full/[a-z0-9]{2}/wallhaven-([a-z0-9]{1,12})\.(jpg|png)$');
final _resolutionRe = RegExp(r'^[0-9]{3,5}x[0-9]{3,5}$');

/// Fixed filters: safe for work only, general + anime, landscape, sharp enough.
const wallhavenFilters = {
  'purity': '100',
  'categories': '110',
  'atleast': '1920x1080',
  'ratios': 'landscape',
  'sorting': 'relevance',
};

final class WebWallpaper {
  WebWallpaper(this.id, this.page, this.thumb, this.full, this.resolution, this.fileSize);
  final String id, page, thumb, full, resolution;
  final int fileSize;

  String get fileName => 'wallhaven-$id${extOf(full)}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'page': page,
    'thumb': thumb,
    'full': full,
    'resolution': resolution,
    'file_size': fileSize,
    'file_name': fileName,
  };

  /// A result as the reply (or the GUI handing one back) has it; null when
  /// anything is not in the exact expected shape.
  static WebWallpaper? check(Object? item) {
    if (item is! Map) return null;
    final id = '${item['id'] ?? ''}';
    final page = '${item['url'] ?? item['page'] ?? ''}';
    final thumbs = item['thumbs'];
    final thumb = thumbs is Map ? '${thumbs['lg'] ?? thumbs['large'] ?? ''}' : '${item['thumb'] ?? ''}';
    final full = '${item['path'] ?? item['full'] ?? ''}';
    final resolution = '${item['resolution'] ?? ''}';
    final pm = pageRe.firstMatch(page), tm = thumbRe.firstMatch(thumb), fm = fullRe.firstMatch(full);
    if (!_idRe.hasMatch(id) || pm == null || tm == null || fm == null || !_resolutionRe.hasMatch(resolution)) return null;
    if (pm[1] != id || tm[1] != id || fm[1] != id) return null;
    if ('${item['purity'] ?? 'sfw'}' != 'sfw') return null;
    final size = item['file_size'];
    return WebWallpaper(id, page, thumb, full, resolution, size is int ? size : (size is num ? size.toInt() : 0));
  }
}

/// Plain text for the query: control characters flattened, spaces collapsed.
String cleanQuery(String text) {
  final flat = text.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
  final words = flat.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  return words.length > maxQuery ? words.substring(0, maxQuery).trim() : words;
}

String searchUrl(String query, {int page = 1}) => Uri.parse(wallhavenApi).replace(queryParameters: {
  'q': cleanQuery(query),
  ...wallhavenFilters,
  'page': '${page.clamp(1, 999)}',
}).toString();

/// (results, last page); anything not in the exact expected shape is dropped.
(List<WebWallpaper>, int) parseResults(String raw) {
  Object? data;
  try {
    data = jsonDecode(raw);
  } on FormatException {
    return (const [], 0);
  }
  if (data is! Map || data['data'] is! List) return (const [], 0);
  final meta = data['meta'];
  var last = 1;
  if (meta is Map) {
    final l = meta['last_page'];
    last = l is int ? l : (l is String ? int.tryParse(l) ?? 1 : 1);
  }
  final out = <WebWallpaper>[];
  for (final item in data['data'] as List) {
    final w = WebWallpaper.check(item);
    if (w != null) out.add(w);
  }
  return (out, last.clamp(1, 999));
}

/// One GET through curl: HTTPS only, no redirects, size- and time-bounded.
typedef Fetch = Future<Uint8List?> Function(String url, int maxBytes, Duration timeout);

Future<Uint8List?> fetchHttps(String url, int maxBytes, Duration timeout) async {
  if (!url.startsWith('https://')) throw ArgumentError(tr("not an https URL"));
  final data = await readBoundedBytes([
    'curl', '--silent', '--fail', '--proto', '=https', '--max-redirs', '0',
    '--max-time', '${timeout.inSeconds}', '--max-filesize', '$maxBytes', '--', url,
  ], maxBytes: maxBytes, timeout: timeout + const Duration(seconds: 2));
  return data == null || data.isEmpty ? null : data;
}

final class Wallhaven {
  Wallhaven(this.ctx, {Fetch? fetch}) : fetch = fetch ?? fetchHttps;
  final Ctx ctx;
  final Fetch fetch;

  String get cacheDir => '${ctx.paths.cache}/wallhaven';

  Future<(List<WebWallpaper>, int)> search(String query, {int page = 1}) async {
    if (cleanQuery(query).isEmpty) return (const <WebWallpaper>[], 0);
    final raw = await fetch(searchUrl(query, page: page), maxApiBytes, const Duration(seconds: 15));
    if (raw == null) throw RouteError('network', tr("wallhaven.cc did not answer"));
    return parseResults(utf8.decode(raw, allowMalformed: true));
  }

  bool alreadyAdded(String slug, WebWallpaper w) {
    final folder = '${ctx.paths.backgrounds}/$slug';
    return File('$folder/${w.fileName}').existsSync() || File('$folder/$hiddenDir/${w.fileName}').existsSync();
  }

  String thumbPath(WebWallpaper w) => '$cacheDir/thumbs/${w.id}${extOf(w.thumb)}';

  /// The cached thumbnail (fetched when missing), header-checked; null when it failed.
  Future<String?> thumb(WebWallpaper w) async {
    final path = thumbPath(w);
    if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file) {
      return imageSizeProblem(path) == null ? path : null;
    }
    if (!thumbRe.hasMatch(w.thumb)) return null;
    final data = await fetch(w.thumb, maxThumbBytes, const Duration(seconds: 15));
    if (data == null || !isImageData(data) || imageBytesProblem(data) != null) return null;
    writeAtomic(path, data);
    _prune('$cacheDir/thumbs', maxThumbsCached);
    return path;
  }

  Future<Uint8List> _download(WebWallpaper w) async {
    if (!fullRe.hasMatch(w.full)) throw RouteError('bad_params', tr("unexpected image address"));
    if (w.fileSize > maxBackgroundBytes) throw RouteError('too_large', tooLarge);
    final data = await fetch(w.full, maxBackgroundBytes, const Duration(seconds: 60));
    if (data == null || !isImageData(data)) throw RouteError('network', tr("the image could not be downloaded"));
    return data;
  }

  /// The full image for a desktop preview, kept in a cache of the last three.
  Future<String?> preview(WebWallpaper w) async {
    final path = '$cacheDir/preview/${w.fileName}';
    if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file) {
      return imageSizeProblem(path) == null ? path : null;
    }
    final Uint8List data;
    try {
      data = await _download(w);
    } on RouteError {
      return null;
    }
    if (imageBytesProblem(data) != null) return null;
    writeAtomic(path, data);
    _prune('$cacheDir/preview', maxPreviewsCached);
    return path;
  }

  /// Downloads the full image into the theme's added-wallpaper folder.
  Future<String> add(String slug, WebWallpaper w) async {
    slug = ctx.theme(validSlug(slug)).slug;
    if (alreadyAdded(slug, w)) throw RouteError('exists', trf("{0} is already in this theme", [w.fileName]));
    final data = await _download(w);
    checkAskAiBoundary();
    return addBackgroundBytes(ctx, slug, data, w.fileName);
  }

  void _prune(String dir, int keep) {
    try {
      final files = Directory(dir)
          .listSync(followLinks: false)
          .whereType<File>()
          .map((f) => (f, f.statSync().modified))
          .toList()
        ..sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < files.length - keep; i++) {
        files[i].$1.deleteSync();
      }
    } on FileSystemException {
      // best effort
    }
  }
}

/// Opens a Wallhaven page in the default browser (xdg-open, detached).
Future<bool> openWallhavenPage(Ctx ctx, String page) async {
  if (!pageRe.hasMatch(page)) throw RouteError('bad_params', tr("not a wallhaven.cc page"));
  final opener = which('xdg-open', ctx.environment);
  if (opener == null) return false;
  try {
    await Process.start(opener, [page], mode: ProcessStartMode.detached);
    return true;
  } on ProcessException {
    return false;
  }
}
