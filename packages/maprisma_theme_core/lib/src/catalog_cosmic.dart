import 'proposals.dart';
import 'i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'colors.dart';
import 'context.dart';
import 'import_net.dart';
import 'store.dart';
import 'themes.dart';

/// cosmic-themes.org (new on COSMIC): the community's native COSMIC themes.
///
/// The site is Django + htmx. `GET /` lists 20 themes per page (`search`,
/// `sort`, `page` as query parameters); every entry carries its colors as
/// CSS variables, so the list is drawn without downloading anything. A
/// download is `POST /<id>/download/` with the page's CSRF token (the form's
/// hidden field plus the `csrftoken` cookie and a same-site Referer) and
/// answers a ThemeBuilder in RON (about 7 KB). Installing stores it as a
/// theme folder with `cosmic.ron`, a `colors.toml` derived from it (for the
/// terminals and editors) and `theme-manager.json`.
///
/// Trust rules as for omarchy.org: one fixed host, HTTPS only, no
/// redirects, bounded; the page and the RON are untrusted data, names are
/// plain text.

const cosmicSite = 'https://cosmic-themes.org';
const _hosts = {'cosmic-themes.org'};
const maxCosmicPage = 4 * 1024 * 1024;
const maxRonBytes = 1024 * 1024;
const cosmicSource = 'cosmic-themes.org';
List<Map<String, String>> get defaultSorts => [
  {'value': 'popular', 'label': tr('Popular')},
  {'value': 'new', 'label': tr('New')},
  {'value': 'name', 'label': tr("Name")},
];

final class CosmicTheme {
  CosmicTheme({
    required this.id,
    required this.name,
    required this.author,
    required this.homepage,
    required this.downloads,
    required this.dark,
    required this.colors,
  });

  final int id;
  final String name, author;
  final String? homepage;
  final int downloads;
  final bool dark;

  /// The entry's CSS variables (`bg-color`, `accent-color`, …) as #rrggbb,
  /// translucent ones laid over the background.
  final Map<String, String> colors;

  String get page => '$cosmicSite/$id/';

  /// Omarchy-style keys for a ColorPreview tile.
  Map<String, String> get preview {
    final out = <String, String>{'mode': dark ? 'dark' : 'light'};
    void put(String key, List<String> vars) {
      for (final v in vars) {
        final c = colors[v];
        if (c != null) {
          out[key] = c;
          return;
        }
      }
    }

    put('background', ['bg-color']);
    put('foreground', ['on-bg-color', 'on-bg-component-color']);
    put('accent', ['accent-color', 'accent-text-color']);
    put('red', ['destructive-color']);
    put('green', ['success-color']);
    put('yellow', ['warning-color']);
    put('blue', ['accent-text-color', 'accent-color']);
    put('magenta', ['primary-component-color', 'bg-component-color']);
    put('cyan', ['secondary-component-color', 'primary-container-color']);
    return out;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'author': author,
    'homepage': homepage,
    'downloads': downloads,
    'dark': dark,
    'page': page,
    'colors': colors,
    'preview': preview,
  };
}

final class CosmicPage {
  CosmicPage(this.themes, this.nextPage, this.sorts, this.csrf);
  final List<CosmicTheme> themes;
  final int? nextPage;
  final List<Map<String, String>> sorts;
  final String? csrf;
}

final _entryStart = RegExp(r'#theme-preview-(\d{1,9})\s*\{');
final _cssVar = RegExp(r'--([a-z][a-z0-9-]{0,60})\s*:\s*rgba\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*\)\s*;');
final _h3 = RegExp(r'<h3>([^<]{1,200})</h3>');
final _author = RegExp(r'<div>\s*Author\s*</div>\s*<div class="text-end">([^<]{0,200})</div>');
final _homepage = RegExp(r'<div>\s*Homepage\s*</div>\s*<div class="text-end">\s*<a href="([^"]{1,500})"');
final _downloads = RegExp(r'<div>\s*Downloads\s*</div>\s*<div class="text-end">\s*(\d{1,12})\s*</div>');
final _dark = RegExp(r'Is Dark\s*</div>[\s\S]{0,400}?class="toggle-switch\s*(active)?\s*"');
final _download = RegExp(r'action="/(\d{1,9})/download/"');
final _next = RegExp(r'hx-get="/\?page=(\d{1,6})"');
final _csrf = RegExp(r'name="csrfmiddlewaretoken"\s+value="([A-Za-z0-9]{16,128})"');
final _select = RegExp(r'<select name="sort"[^>]*>([\s\S]{0,4000}?)</select>');
final _option = RegExp(r'<option value="([a-z_-]{1,20})"[^>]*>\s*([^<]{1,40}?)\s*</option>');
final sortRe = RegExp(r'^[a-z_-]{1,20}$');

int _channel(String v) => (double.tryParse(v) ?? 0).round().clamp(0, 255);

/// A CSS rgba (alpha 0–255 as the site writes it) as #rrggbb over [under].
String _flatten(List<String> rgba, (int, int, int) under) {
  final r = _channel(rgba[0]), g = _channel(rgba[1]), b = _channel(rgba[2]);
  final a = _channel(rgba[3]) / 255;
  int mix(int c, int u) => (c * a + u * (1 - a)).round().clamp(0, 255);
  return hexOf(mix(r, under.$1), mix(g, under.$2), mix(b, under.$3));
}

String? _safeHomepage(String? raw) {
  if (raw == null) return null;
  final url = htmlUnescape(raw).trim();
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  if (url.length > 300 || url.contains(RegExp(r'[\s\x00-\x1f<>"]'))) return null;
  return url;
}

/// The themes, next page, sort choices and CSRF token of a cosmic-themes.org
/// page (the list or a single theme's page).
CosmicPage parseCosmicPage(String page) {
  final starts = _entryStart.allMatches(page).toList();
  final themes = <CosmicTheme>[];
  final seen = <int>{};
  for (var i = 0; i < starts.length; i++) {
    final id = int.parse(starts[i][1]!);
    final end = i + 1 < starts.length ? starts[i + 1].start : page.length;
    final chunk = page.substring(starts[i].start, end);
    final download = _download.firstMatch(chunk);
    final title = _h3.firstMatch(chunk);
    if (id <= 0 || seen.contains(id) || download == null || int.parse(download[1]!) != id || title == null) continue;
    final name = plainText(htmlUnescape(title[1]!), limit: 80).trim();
    if (name.isEmpty) continue;
    final raw = <String, List<String>>{};
    for (final m in _cssVar.allMatches(chunk)) {
      raw.putIfAbsent(m[1]!, () => [m[2]!, m[3]!, m[4]!, m[5]!]);
      if (raw.length >= 120) break;
    }
    final bgRaw = raw['bg-color'];
    final dark = _dark.firstMatch(chunk)?[1] != null;
    final bg = bgRaw == null
        ? (dark ? (0, 0, 0) : (255, 255, 255))
        : (_channel(bgRaw[0]), _channel(bgRaw[1]), _channel(bgRaw[2]));
    final colors = {for (final e in raw.entries) e.key: _flatten(e.value, bg)};
    if (!isHex(colors['bg-color'])) continue;
    seen.add(id);
    themes.add(CosmicTheme(
      id: id,
      name: name,
      author: plainText(htmlUnescape(_author.firstMatch(chunk)?[1] ?? ''), limit: 80).trim(),
      homepage: _safeHomepage(_homepage.firstMatch(chunk)?[1]),
      downloads: int.tryParse(_downloads.firstMatch(chunk)?[1] ?? '') ?? 0,
      dark: dark,
      colors: colors,
    ));
    if (themes.length >= 100) break;
  }
  final sorts = <Map<String, String>>[];
  final select = _select.firstMatch(page);
  if (select != null) {
    for (final m in _option.allMatches(select[1]!)) {
      sorts.add({'value': m[1]!, 'label': plainText(m[2]!, limit: 30)});
    }
  }
  final next = int.tryParse(_next.firstMatch(page)?[1] ?? '');
  return CosmicPage(themes, next, sorts.isEmpty ? [...defaultSorts] : sorts, _csrf.firstMatch(page)?[1]);
}

/// The list URL for these choices (only the parameters given).
Uri cosmicListUri({String? search, String? sort, int page = 1}) {
  final q = <String, String>{};
  final s = search == null ? '' : plainText(search, limit: 100).trim();
  if (s.isNotEmpty) q['search'] = s;
  if (sort != null && sortRe.hasMatch(sort)) q['sort'] = sort;
  if (page > 1) q['page'] = '$page';
  return Uri.https('cosmic-themes.org', '/', q.isEmpty ? null : q);
}

Future<CosmicPage> fetchCosmicList({String? search, String? sort, int page = 1}) async {
  final reply = await netFetch(NetRequest(cosmicListUri(search: search, sort: sort, page: page),
      hosts: _hosts, maxBytes: maxCosmicPage, timeout: const Duration(seconds: 20)));
  if (reply == null || reply.status != 200) {
    if (reply?.status == 404 && page > 1) return CosmicPage(const [], null, [...defaultSorts], null);
    throw RouteError('offline', tr("could not load the theme list from cosmic-themes.org"));
  }
  return parseCosmicPage(reply.text);
}

/// The RON text when [bytes] look like a ThemeBuilder: UTF-8, no NUL,
/// starting with "(" and naming a palette; else null.
String? checkThemeRon(List<int> bytes) {
  if (bytes.isEmpty || bytes.length > maxRonBytes) return null;
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return null;
  }
  if (text.contains('\x00')) return null;
  final t = text.trimLeft();
  if (!t.startsWith('(') || !t.contains('palette:')) return null;
  if (!RegExp(r'palette:\s*(Dark|Light|HighContrastDark|HighContrastLight)\s*\(').hasMatch(t)) return null;
  return text;
}

/// The palette's name in a ThemeBuilder RON, as plain text.
String? ronName(String ron) {
  final m = RegExp(r'name:\s*"([^"\\]{1,120})"').firstMatch(ron);
  final n = m == null ? '' : plainText(m[1]!, limit: 80).trim();
  return n.isEmpty ? null : n;
}

bool ronIsDark(String ron) => RegExp(r'palette:\s*(Dark|HighContrastDark)\s*\(').hasMatch(ron);

/// A theme folder name from a display name: lower case, dashes, at most 60.
String slugify(String name) {
  var s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.length > 60) s = s.substring(0, 60).replaceAll(RegExp(r'-+$'), '');
  return s;
}

/// The slug of an installed cosmic-themes.org theme by its id.
Map<int, String> installedCosmicIds(Ctx ctx) {
  final out = <int, String>{};
  for (final t in ctx.themes()) {
    if (t.system) continue;
    final meta = t.meta;
    final id = meta['id'];
    if (meta['source'] == cosmicSource && id is int) out[id] = t.slug;
  }
  return out;
}

/// The page of one theme (its name, author, the CSRF token and cookie).
Future<(CosmicTheme?, String, String)> _themePage(int id) async {
  final reply = await netFetch(NetRequest(Uri.https('cosmic-themes.org', '/$id/'), hosts: _hosts,
      maxBytes: maxCosmicPage, timeout: const Duration(seconds: 20)));
  if (reply == null || reply.status != 200) {
    if (reply?.status == 404) throw RouteError('not_found', trf("cosmic-themes.org has no theme {0}", [id]));
    throw RouteError('offline', tr("could not reach cosmic-themes.org"));
  }
  final page = parseCosmicPage(reply.text);
  final cookie = reply.cookies['csrftoken'];
  if (page.csrf == null || cookie == null || !RegExp(r'^[A-Za-z0-9]{16,128}$').hasMatch(cookie)) {
    throw RouteError('download_failed', tr("cosmic-themes.org sent no download token"));
  }
  CosmicTheme? entry;
  for (final t in page.themes) {
    if (t.id == id) entry = t;
  }
  return (entry, page.csrf!, cookie);
}

/// Downloads theme [id]'s ThemeBuilder RON (bounded, checked).
Future<(String, CosmicTheme?)> downloadCosmicRon(int id) async {
  final (entry, token, cookie) = await _themePage(id);
  final reply = await netFetch(NetRequest(
    Uri.https('cosmic-themes.org', '/$id/download/'),
    hosts: _hosts,
    method: 'POST',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      'cookie': 'csrftoken=$cookie',
      'referer': '$cosmicSite/',
      'origin': cosmicSite,
    },
    body: utf8.encode('csrfmiddlewaretoken=${Uri.encodeQueryComponent(token)}'),
    maxBytes: maxRonBytes,
    timeout: const Duration(seconds: 20),
  ));
  if (reply == null || reply.status != 200) throw RouteError('download_failed', tr("cosmic-themes.org did not send the theme"));
  final ron = checkThemeRon(reply.body);
  if (ron == null) throw RouteError('bad_theme', tr("the download is not a COSMIC theme"));
  return (ron, entry);
}

/// Stores a downloaded theme as a new folder (never replacing one): the
/// RON as cosmic.ron, colors.toml derived from it, theme-manager.json.
/// Returns the slug.
Future<String> installCosmicRon(Ctx ctx, int id, String ron, {CosmicTheme? entry}) async {
  final installed = installedCosmicIds(ctx)[id];
  if (installed != null) throw RouteError('exists', trf("this theme is already installed as “{0}”", [installed]));
  final name = entry?.name ?? ronName(ron) ?? 'COSMIC theme $id';
  var base = slugify(name);
  if (base.isEmpty || !slugRe.hasMatch(base)) base = 'cosmic-theme-$id';
  final root = ctx.paths.userThemes;
  checkAskAiBoundary();
  Directory(root).createSync(recursive: true);
  final tmp = '$root/.import-cosmic-$id-$pid-${Random().nextInt(1 << 32)}';
  Directory(tmp).createSync();
  void cleanup() {
    try {
      if (FileSystemEntity.typeSync(tmp, followLinks: false) == FileSystemEntityType.directory) {
        Directory(tmp).deleteSync(recursive: true);
      }
    } on FileSystemException {
      // hidden leftover
    }
  }

  try {
    writeText('$tmp/cosmic.ron', ron, mode: 420);
    final derived = await ctx.desktop.ronColors('$tmp/cosmic.ron');
    if (derived == null || !isHex(derived['background']) || !isHex(derived['foreground'])) {
      throw RouteError('bad_theme', tr("the theme has no usable colors"));
    }
    final colors = {...derived};
    colors['mode'] = colors['mode'] == 'light' || colors['mode'] == 'dark' ? colors['mode']! : (ronIsDark(ron) ? 'dark' : 'light');
    writeText('$tmp/colors.toml', writeColorsToml(colors), mode: 420);
    writeJson('$tmp/theme-manager.json', {
      'name': name,
      'source': cosmicSource,
      'id': id,
      if (entry != null && entry.author.isNotEmpty) 'author': entry.author,
      if (entry?.homepage != null) 'homepage': entry!.homepage,
    }, mode: 420);
    // A free folder name: the name, else name-2, name-3, …
    for (var n = 1; n < 100; n++) {
      final slug = n == 1 ? base : '$base-$n';
      final dest = '$root/$slug';
      if (findTheme(ctx.paths, slug) != null ||
          FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound) {
        continue;
      }
      try {
        checkAskAiBoundary();
        Directory(tmp).renameSync(dest);
      } on FileSystemException {
        continue;
      }
      return slug;
    }
    throw RouteError('exists', trf("no free folder name for “{0}”", [name]));
  } finally {
    cleanup();
  }
}

/// Whether [url] is a theme page on cosmic-themes.org (the ☰ menu's link).
bool cosmicOpenable(String url) => RegExp(r'^https://cosmic-themes\.org/(\d{1,9}/)?$').hasMatch(url);
