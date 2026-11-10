import 'i18n.dart';
import 'dart:convert';
import 'dart:io';

import 'context.dart';
import 'import_net.dart';
import 'posix.dart';
import 'store.dart';

/// The Information page (plugin_catalog.py, more_catalog.py,
/// more_plugins.py): the author's plugins in the Omarchy Plugin
/// Marketplace. The catalog is read at most once an hour, failed attempts
/// included, and only if it changed (its ETag). Only the author's own
/// entries (repositories under github.com/ubruckhaus or github.com/maprisma,
/// at most 60) are kept, in ~/.cache/maprisma-theme/plugin-catalog.json
/// (the folder must be ours, not a link, closed to others; the file 0600).
/// Offline, the cached list or the built-in one is shown.

const pluginCatalogUrl = 'https://raw.githubusercontent.com/omacom/omarchy-plugin-marketplace/main/site/catalog.json';
const _hosts = {'raw.githubusercontent.com'};
const catalogOwners = ['maprisma', 'ubruckhaus'];
const catalogMaxAge = Duration(hours: 1);
const catalogMaxBytes = 40 * 1024 * 1024;
const catalogCacheMax = 1024 * 1024;
const maxPlugins = 60;
const marketplaceUrl = 'https://plugins.omarchy.org/plugin.html?id=';

final _repo = RegExp(r'^https://github\.com/([A-Za-z0-9-]{1,39})/[A-Za-z0-9._-]{1,100}/?$');
final pluginIdRe = RegExp(r'^[a-z0-9][a-z0-9._-]{0,99}$');
final _etag = RegExp(r'^(?:W/)?"[\x21\x23-\x7e]{1,200}"$');

/// id, name, one-line explanation (more_plugins.PLUGINS, in that order).
List<(String, String, String)> get builtinPlugins => [
  ('ubruckhaus.wlan-monitor', 'WLAN Monitor', tr('Who is on your Wi-Fi, with a network map')),
  ('ubruckhaus.theme-manager', 'Theme Manager', tr('Every Omarchy theme in one place, with wallpapers')),
  ('ubruckhaus.bluetooth-monitor', 'Bluetooth Monitor', tr('Battery levels of mice, keyboards and headsets')),
  ('ubruckhaus.llm-usage', 'LLM Monitor', tr('Which local AI model holds your GPU memory')),
  ('ubruckhaus.ai-agents-map', 'AI Agents Map', tr('Your AI agents, models and MCP servers on one map')),
  ('ubruckhaus.simple-launcher-for-fools', 'App Manager', tr('Your apps in groups, with shortcuts and a dock')),
  ('ubruckhaus.maprisma-launcher', 'Maprisma Launcher', tr('Apps, shortcuts and updates, with AI package advice')),
  ('ubruckhaus.simple-tile', 'Workspace Presets', tr('Window limits and layouts per workspace')),
  ('ubruckhaus.hue-lights', 'Hue Lights', tr('Philips Hue rooms and lights from the bar')),
  ('ubruckhaus.video-trans', 'Video Trans', tr('Live translated captions for any video or call')),
  ('ubruckhaus.simple-reader', 'Screen Narrator', tr('Reads any window, PDF or Kindle page aloud')),
  ('ubruckhaus.simple-recipes', 'Simple Recipes', tr('Your recipes: import, translate and cook')),
  ('ubruckhaus.my-plugins', 'My Plugins', tr('For plugin authors: views, downloads, status')),
];

String marketplacePage(String id) => '$marketplaceUrl${Uri.encodeQueryComponent(id)}';

String ownerOf(Object? repo) {
  final m = repo is String ? _repo.firstMatch(repo) : null;
  return m == null ? '' : m[1]!.toLowerCase();
}

/// Plain text Flutter and the cache can take, at most [limit] characters.
String _text(Object? value, int limit) {
  final s = value is String ? value : '';
  final clean = String.fromCharCodes(s.runes.map((r) => r >= 0xD800 && r <= 0xDFFF ? 0x3F : r));
  return clean.length > limit ? clean.substring(0, limit) : clean;
}

/// One plugin as kept and shown, or null (the same limits for the network and the cache).
Map<String, dynamic>? _entry(Object? id, Object? name, Object? description, Object? version, Object? verified) {
  if (id is! String || !pluginIdRe.hasMatch(id) || name is! String) return null;
  final n = _text(name.trim(), 60);
  if (n.trim().isEmpty) return null;
  return {
    'id': id,
    'name': n,
    'description': _text(description, 600),
    'version': _text(version, 30),
    'verified': verified == true,
  };
}

/// The author's entries of a catalog.
List<Map<String, dynamic>> parsePluginCatalog(Object? data) {
  final items = data is Map ? data['plugins'] : null;
  final found = <Map<String, dynamic>>[];
  for (final e in items is List ? items : const []) {
    if (e is! Map || !catalogOwners.contains(ownerOf(e['repo']))) continue;
    final kept = _entry(e['id'], e['name'], e['description'], e['version'], e['verificationStatus'] == 'verified');
    if (kept != null) {
      found.add(kept);
      if (found.length >= maxPlugins) break;
    }
  }
  return found;
}

double _time(Object? v) => v is num && v.isFinite && v is! bool ? v.toDouble() : 0;

String _cachePath(Ctx ctx) => '${ctx.paths.cache}/plugin-catalog.json';

/// Whether [dir] is ours, not a link and closed to others (made 0700 if missing and [create]).
bool privateDir(String dir, {required bool create}) {
  if (create && FileSystemEntity.typeSync(dir, followLinks: false) == FileSystemEntityType.notFound) {
    try {
      Directory(dir).createSync(recursive: true);
      chmodPath(dir, 448);
    } on FileSystemException {
      return false;
    }
  }
  if (FileSystemEntity.typeSync(dir, followLinks: false) != FileSystemEntityType.directory) return false;
  if (Posix.instance.ownerOf(dir, follow: false) != Posix.instance.uid) return false;
  return FileStat.statSync(dir).mode & 63 == 0;
}

/// The cache, checked like an answer from the network.
Map<String, dynamic> loadPluginCache(Ctx ctx) {
  final path = _cachePath(ctx);
  if (!privateDir(ctx.paths.cache, create: false)) return {};
  if (Posix.instance.ownerOf(path, follow: false) != Posix.instance.uid) return {};
  final bytes = Posix.instance.readRegular(path, catalogCacheMax, follow: false);
  if (bytes == null) return {};
  Object? data;
  try {
    data = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    return {};
  }
  if (data is! Map || data['plugins'] is! List) return {};
  final plugins = <Map<String, dynamic>>[];
  for (final p in data['plugins'] as List) {
    final kept = p is Map ? _entry(p['id'], p['name'], p['description'], p['version'], p['verified']) : null;
    if (kept != null) {
      plugins.add(kept);
      if (plugins.length >= maxPlugins) break;
    }
  }
  final etag = data['etag'];
  final owners = data['owners'];
  return {
    'plugins': plugins,
    'etag': etag is String && _etag.hasMatch(etag) ? etag : '',
    'checked': _time(data['checked']),
    'tried': _time(data['tried']),
    'owners': owners is List && owners.length == catalogOwners.length && owners.indexed.every((e) => e.$2 == catalogOwners[e.$1])
        ? [...catalogOwners]
        : null,
  };
}

void _savePluginCache(Ctx ctx, Map<String, dynamic> record) {
  if (!privateDir(ctx.paths.cache, create: true)) return;
  try {
    writeJson(_cachePath(ctx), record);
  } on FileSystemException {
    // only this run's guard then
  }
}

/// Cache path → last attempt, should the cache not be writable.
final _attempts = <String, double>{};

/// The cache record after reading the catalog again when the last attempt
/// is older than an hour. Errors and malformed answers keep the cached list.
Future<Map<String, dynamic>> refreshPluginCatalog(Ctx ctx) async {
  final now = ctx.clock().millisecondsSinceEpoch / 1000;
  final path = _cachePath(ctx);
  final cached = loadPluginCache(ctx);
  var plugins = (cached['plugins'] as List?)?.cast<Map<String, dynamic>>() ?? <Map<String, dynamic>>[];
  final current = cached['owners'] != null;
  final checked = current ? (cached['checked'] as double? ?? 0) : 0.0;
  final last = [checked, cached['tried'] as double? ?? 0, _attempts[path] ?? 0].reduce((a, b) => a > b ? a : b);
  if (last > 0 && now - last >= 0 && now - last < catalogMaxAge.inSeconds) return cached;
  _attempts[path] = now;
  Map<String, dynamic> record;
  try {
    final etag = current ? cached['etag'] as String? ?? '' : '';
    final reply = await netFetch(NetRequest(
      Uri.parse(pluginCatalogUrl),
      hosts: _hosts,
      headers: {if (etag.isNotEmpty && _etag.hasMatch(etag)) 'if-none-match': etag},
      maxBytes: catalogMaxBytes,
      timeout: const Duration(seconds: 45),
    ));
    if (reply == null) throw const FormatException('offline');
    if (reply.status == 304 && cached.isNotEmpty && current) {
      // unchanged
    } else if (reply.status == 200) {
      final data = jsonDecode(utf8.decode(reply.body, allowMalformed: true));
      if (data is! Map || data['plugins'] is! List) throw const FormatException('not a catalog');
      plugins = parsePluginCatalog(data);
    } else {
      throw FormatException('HTTP ${reply.status}');
    }
    final tag = reply.headers['etag'] ?? '';
    record = {'checked': now, 'etag': _etag.hasMatch(tag) ? tag : '', 'plugins': plugins, 'owners': catalogOwners};
  } catch (_) {
    record = {...cached, 'plugins': plugins, 'tried': now};
  }
  _savePluginCache(ctx, record);
  return record;
}

String firstSentence(String text, {int limit = 90}) {
  final flat = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  final m = RegExp(r'^.*?[.!?:](?=\s)').firstMatch(flat);
  final cut = m?[0] ?? flat;
  if (cut.length <= limit) return cut;
  final head = cut.substring(0, limit - 1);
  final space = head.lastIndexOf(' ');
  return '${space > 0 ? head.substring(0, space) : head}…';
}

/// The cards (more_catalog.cards): known plugins in the built-in order with
/// their one-liner, then new ones with their first sentence; the built-in
/// list when [plugins] is empty.
List<Map<String, dynamic>> pluginCards(List<Map<String, dynamic>> plugins) {
  Map<String, dynamic> card(String id, String name, String summary, bool known) =>
      {'id': id, 'name': name, 'summary': summary, 'url': marketplacePage(id), 'known': known};
  if (plugins.isEmpty) return [for (final (id, name, text) in builtinPlugins) card(id, name, text, true)];
  final listed = {for (final p in plugins) p['id'] as String: p};
  final known = {for (final p in builtinPlugins) p.$1};
  return [
    for (final (id, name, text) in builtinPlugins)
      if (listed.containsKey(id)) card(id, (listed[id]!['name'] as String).isEmpty ? name : listed[id]!['name'] as String, text, true),
    for (final p in plugins)
      if (!known.contains(p['id']))
        card(p['id'] as String, p['name'] as String,
            firstSentence(p['description'] as String).isEmpty ? p['name'] as String : firstSentence(p['description'] as String), false),
  ];
}
