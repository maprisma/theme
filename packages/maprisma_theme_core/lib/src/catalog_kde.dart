import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'catalog_cosmic.dart' show slugify;
import 'catalog_omarchy.dart' show maxPreviewBytes, previewTtl;
import 'colors.dart';
import 'context.dart';
import 'images.dart';
import 'import_net.dart';
import 'kde_formats.dart';
import 'plugin_catalog.dart' show privateDir;
import 'store.dart';
import 'themes.dart';

/// The KDE Store (docs/multi-desktop.md, step 2b): Plasma color schemes
/// (category 112) through its public OCS API. Only entries whose download
/// is one `.colors` file are listed. Installing keeps the file as
/// `kde.colors` in a new theme folder, with a `colors.toml` derived from it
/// (for the app templates and every other desktop) and `theme-manager.json`.
///
/// Trust rules as for the other catalogs: HTTPS only, exact hosts (the API,
/// the file servers `filesNN.pling.com` and their one redirect to the CDN,
/// the image server), bounded; names are plain text, the scheme is checked
/// before it is kept.

const kdeStoreSource = 'store.kde.org';
const kdeStoreCategory = 112;
const _apiHost = 'api.kde-look.org';
const _imageHost = 'images.pling.com';
final _filesHost = RegExp(r'^files\d{2}\.pling\.com$');
final _cdnHost = RegExp(r'^ocs-dl\.[a-z0-9-]{2,20}\.cdn\.digitaloceanspaces\.com$');
const maxKdeList = 4 * 1024 * 1024;
const maxKdeColors = 256 * 1024;
const kdePageSize = 20;
const kdeSorts = [
  {'value': 'high', 'label': 'Rating'},
  {'value': 'new', 'label': 'Newest'},
  {'value': 'down', 'label': 'Downloads'},
  {'value': 'alpha', 'label': 'Name'},
];

final class KdeStoreTheme {
  KdeStoreTheme({
    required this.id,
    required this.name,
    required this.author,
    required this.downloads,
    required this.score,
    required this.previewUrl,
    required this.download,
  });

  final int id;
  final String name, author;
  final int downloads, score;
  final Uri? previewUrl;
  final Uri download;

  String get page => 'https://store.kde.org/p/$id';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'author': author,
    'downloads': downloads,
    'score': score,
    'page': page,
  };
}

/// The entries the last lists showed (previews and installs look them up
/// here before asking the API again).
final _seen = <int, KdeStoreTheme>{};

int _int(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;

Uri? _uri(Object? v, bool Function(String host) ok) {
  if (v is! String || v.length > 4096) return null;
  final u = Uri.tryParse(v);
  if (u == null || urlProblem(u, {u.host}) != null || !ok(u.host)) return null;
  return u;
}

/// One entry of the API's `data` list, or null when it is not a single
/// `.colors` file from the store's file servers.
KdeStoreTheme? parseKdeEntry(Object? raw) {
  if (raw is! Map) return null;
  final id = _int(raw['id']);
  if (id < 1 || id > 999999999) return null;
  final file = raw['downloadname1'];
  if (file is! String || !file.toLowerCase().endsWith('.colors')) return null;
  final download = _uri(raw['downloadlink1'], _filesHost.hasMatch);
  if (download == null) return null;
  final name = plainText('${raw['name'] ?? ''}', limit: 80).trim();
  return KdeStoreTheme(
    id: id,
    name: name.isEmpty ? 'KDE color scheme $id' : name,
    author: plainText('${raw['personid'] ?? ''}', limit: 60).trim(),
    downloads: _int(raw['downloads']),
    score: _int(raw['score']).clamp(0, 100),
    previewUrl: _uri(raw['previewpic1'], (h) => h == _imageHost),
    download: download,
  );
}

Uri kdeListUri({String? search, String? sort, int page = 1}) => Uri.https(_apiHost, '/ocs/v1/content/data', {
  'categories': '$kdeStoreCategory',
  'format': 'json',
  'pagesize': '$kdePageSize',
  'page': '${page - 1}', // the API counts from 0
  'sortmode': kdeSorts.any((s) => s['value'] == sort) ? sort! : 'high',
  if (search != null && search.isNotEmpty) 'search': search,
});

/// (themes, next page or null). A page whose entries are all filtered out
/// (archives, other files) is skipped, up to five, so a list never ends early
/// with nothing to show and no way on.
Future<(List<KdeStoreTheme>, int?)> fetchKdeList({String? search, String? sort, int page = 1}) async {
  var (themes, next) = await _fetchKdePage(search: search, sort: sort, page: page);
  for (var skipped = 0; themes.isEmpty && next != null && skipped < 5; skipped++) {
    (themes, next) = await _fetchKdePage(search: search, sort: sort, page: next);
  }
  return (themes, next);
}

Future<(List<KdeStoreTheme>, int?)> _fetchKdePage({String? search, String? sort, required int page}) async {
  final reply = await netFetch(NetRequest(kdeListUri(search: search, sort: sort, page: page),
      hosts: {_apiHost}, maxBytes: maxKdeList, timeout: const Duration(seconds: 20)));
  if (reply == null || reply.status != 200) throw RouteError('offline', 'could not load the theme list from the KDE Store');
  final Map data;
  try {
    final v = jsonDecode(reply.text);
    if (v is! Map || v['status'] != 'ok') throw const FormatException('not ok');
    data = v;
  } on FormatException {
    throw RouteError('offline', 'the KDE Store sent no theme list');
  }
  final themes = [for (final e in (data['data'] is List ? data['data'] as List : const [])) ?parseKdeEntry(e)];
  for (final t in themes) {
    _seen[t.id] = t;
  }
  final total = _int(data['totalitems']);
  return (themes, page * kdePageSize < total ? page + 1 : null);
}

/// Theme [id] from the last lists, else from the API; [fresh]: from the API
/// always (download links carry a token that expires).
Future<KdeStoreTheme> kdeEntry(int id, {bool fresh = false}) async {
  if (!fresh) {
    if (_seen[id] case final t?) return t;
  }
  final reply = await netFetch(NetRequest(Uri.https(_apiHost, '/ocs/v1/content/data/$id', {'format': 'json'}),
      hosts: {_apiHost}, maxBytes: maxKdeList, timeout: const Duration(seconds: 20)));
  if (reply == null || reply.status != 200) throw RouteError('offline', 'could not reach the KDE Store');
  try {
    final v = jsonDecode(reply.text);
    final list = v is Map ? v['data'] : null;
    final t = list is List && list.isNotEmpty ? parseKdeEntry(list.first) : null;
    if (t != null && t.id == id) return _seen[id] = t;
  } on FormatException {
    // below
  }
  throw RouteError('not_found', 'the KDE Store has no color scheme $id');
}

// --- previews -------------------------------------------------------------------------------

String _previewPath(Ctx ctx, int id) => '${ctx.paths.cache}/previews/kde-store-$id';

String? cachedKdePreview(Ctx ctx, int id) {
  final path = _previewPath(ctx, id);
  return FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file ? path : null;
}

/// The cached preview of theme [id], downloaded when missing or older than a
/// day (a stale one is kept when that fails); only checked image data is kept.
Future<String?> kdePreview(Ctx ctx, int id) async {
  final path = _previewPath(ctx, id);
  final have = FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file;
  if (have) {
    final age = ctx.clock().difference(File(path).lastModifiedSync());
    if (!age.isNegative && age < previewTtl) return path;
  }
  final url = (await kdeEntry(id)).previewUrl;
  if (url == null) return have ? path : null;
  final reply = await netFetch(NetRequest(url, hosts: {_imageHost}, maxBytes: maxPreviewBytes));
  final data = reply?.status == 200 ? reply!.body : null;
  if (data == null || !isImageData(data) || imageBytesProblem(data) != null) return have ? path : null;
  try {
    privateDir(ctx.paths.cache, create: true);
    writeAtomic(path, data);
  } on FileSystemException {
    return have ? path : null;
  }
  return path;
}

// --- download and install -----------------------------------------------------------------------

/// The scheme text when [bytes] are a Plasma color scheme with a usable
/// window background and text color; else null.
String? checkKdeColors(List<int> bytes) {
  if (bytes.isEmpty || bytes.length > maxKdeColors) return null;
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return null;
  }
  if (text.contains('\x00')) return null;
  if (kdeRgb(iniValue(text, 'Colors:Window', 'BackgroundNormal')) == null) return null;
  if (kdeRgb(iniValue(text, 'Colors:Window', 'ForegroundNormal')) == null) return null;
  return text;
}

/// Downloads theme [id]'s `.colors` (the file server answers with one
/// redirect to the CDN, which is followed only to the CDN).
Future<(String, KdeStoreTheme)> downloadKdeColors(int id) async {
  final entry = await kdeEntry(id, fresh: true);
  var reply = await netFetch(NetRequest(entry.download, hosts: {entry.download.host}, maxBytes: maxKdeColors,
      timeout: const Duration(seconds: 20)));
  if (reply != null && (reply.status == 301 || reply.status == 302 || reply.status == 303 || reply.status == 307)) {
    final next = _uri(reply.headers['location'], _cdnHost.hasMatch);
    if (next == null) throw RouteError('download_failed', 'the KDE Store sent the file from an unexpected place');
    reply = await netFetch(NetRequest(next, hosts: {next.host}, maxBytes: maxKdeColors, timeout: const Duration(seconds: 20)));
  }
  if (reply == null || reply.status != 200) throw RouteError('download_failed', 'the KDE Store did not send the color scheme');
  final text = checkKdeColors(reply.body);
  if (text == null) throw RouteError('bad_theme', 'the download is not a Plasma color scheme');
  return (text, entry);
}

/// Omarchy colors from a Plasma color scheme: the window for background and
/// text, the selection (or the scheme's accent) for the accent, the view's
/// negative/positive/neutral/link/visited/hover colors for the palette.
Map<String, String> kdeSchemeColors(String text) {
  String? c(String group, String key) => kdeRgb(iniValue(text, group, key));
  final bg = c('Colors:Window', 'BackgroundNormal')!, fg = c('Colors:Window', 'ForegroundNormal')!;
  final out = <String, String>{
    'background': bg,
    'foreground': fg,
    'accent': c('General', 'AccentColor') ?? c('Colors:Selection', 'BackgroundNormal') ?? c('Colors:View', 'DecorationFocus') ?? fg,
    'mode': luminance(bg) < 0.5 ? 'dark' : 'light',
  };
  void put(String key, String group, String k) {
    final v = c(group, k);
    if (v != null) out[key] = v;
  }

  put('selection', 'Colors:Selection', 'BackgroundNormal');
  put('selection_background', 'Colors:Selection', 'BackgroundNormal');
  put('selection_foreground', 'Colors:Selection', 'ForegroundNormal');
  put('muted', 'Colors:Window', 'ForegroundInactive');
  put('red', 'Colors:View', 'ForegroundNegative');
  put('green', 'Colors:View', 'ForegroundPositive');
  put('yellow', 'Colors:View', 'ForegroundNeutral');
  put('blue', 'Colors:View', 'ForegroundLink');
  put('magenta', 'Colors:View', 'ForegroundVisited');
  put('cyan', 'Colors:View', 'DecorationHover');
  // A scheme without them still gives every app template its six colors:
  // Breeze's (what Plasma itself falls back to).
  const breeze = {'red': '#da4453', 'green': '#27ae60', 'yellow': '#f67400', 'blue': '#3daee9', 'magenta': '#9b59b6', 'cyan': '#1abc9c'};
  for (final e in breeze.entries) {
    out.putIfAbsent(e.key, () => e.value);
  }
  return out;
}

/// The slug of an installed KDE Store theme by its id.
Map<int, String> installedKdeIds(Ctx ctx) => {
  for (final t in ctx.themes())
    if (!t.system && t.meta['source'] == kdeStoreSource && t.meta['id'] is int) t.meta['id'] as int: t.slug,
};

/// Stores a downloaded scheme as a new theme folder (never replacing one).
/// Returns the slug.
String installKdeColors(Ctx ctx, KdeStoreTheme entry, String text) {
  final installed = installedKdeIds(ctx)[entry.id];
  if (installed != null) throw RouteError('exists', 'this theme is already installed as “$installed”');
  var base = slugify(entry.name);
  if (base.isEmpty || !slugRe.hasMatch(base)) base = 'kde-scheme-${entry.id}';
  final root = ctx.paths.userThemes;
  Directory(root).createSync(recursive: true);
  final tmp = '$root/.import-kde-${entry.id}-$pid-${Random().nextInt(1 << 32)}';
  Directory(tmp).createSync();
  try {
    writeText('$tmp/kde.colors', text, mode: 420);
    writeText('$tmp/colors.toml', writeColorsToml(kdeSchemeColors(text)), mode: 420);
    writeJson('$tmp/theme-manager.json', {
      'name': entry.name,
      'source': kdeStoreSource,
      'id': entry.id,
      if (entry.author.isNotEmpty) 'author': entry.author,
      'homepage': entry.page,
    }, mode: 420);
    for (var n = 1; n < 100; n++) {
      final slug = n == 1 ? base : '$base-$n';
      final dest = '$root/$slug';
      if (findTheme(ctx.paths, slug) != null ||
          FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound) {
        continue;
      }
      try {
        Directory(tmp).renameSync(dest);
      } on FileSystemException {
        continue;
      }
      return slug;
    }
    throw RouteError('exists', 'no free folder name for “${entry.name}”');
  } finally {
    try {
      if (FileSystemEntity.typeSync(tmp, followLinks: false) == FileSystemEntityType.directory) {
        Directory(tmp).deleteSync(recursive: true);
      }
    } on FileSystemException {
      // hidden leftover
    }
  }
}

/// Whether [url] is a KDE Store product page (the tile menu's link).
bool kdeOpenable(String url) => RegExp(r'^https://store\.kde\.org/p/\d{1,9}$').hasMatch(url);
