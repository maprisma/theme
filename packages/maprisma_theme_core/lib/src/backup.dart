/// Backup export and restore of Maprisma Theme's preferences and lists (the
/// plugin's theme_backup.py), and the health card (theme_health.py on COSMIC:
/// the helper, the applet and the shortcut file instead of Omarchy's pickers).
library;

import 'dart:convert';
import 'dart:io';

import 'auto.dart';
import 'context.dart';
import 'desktop.dart';
import 'posix.dart';
import 'settings.dart';
import 'shortcuts.dart';
import 'store.dart';
import 'themes.dart';

const maxBackup = 4 * 1024 * 1024;
const backupFormat = 'maprisma-theme-backup';

/// The plugin's format is read too (a Theme Manager backup restores here).
const pluginBackupFormat = 'theme-manager-backup';

/// The files a backup holds, with the JSON type each must have.
const backupFiles = <String, Type>{
  'settings.json': Map,
  'hidden.json': List,
  'hidden-wallpapers.json': Map,
  'favorites.json': List,
  'recent.json': Map,
  'workspace-wallpapers.json': Map,
  'workspace-themes.json': Map,
  'presets.json': List,
  'shortcuts.json': Map,
  'workspaces.json': Map, // workspace presets and App Presets (presets module)
};

String _two(int n) => '$n'.padLeft(2, '0');

String defaultExportName(DateTime now) => 'maprisma-theme-backup-${now.year}-${_two(now.month)}-${_two(now.day)}.json';

bool _isType(Object? v, Type t) => t == Map ? v is Map : v is List;

/// The bytes of one of our files: a regular file of ours, at most [limit].
/// Null when missing; throws FormatException when unsafe or too large.
List<int>? _readPrivate(String path, {int limit = maxBackup}) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file || Posix.instance.ownerOf(path, follow: false) != Posix.instance.uid) {
    throw FormatException('unsafe backup input: ${baseName(path)}');
  }
  final bytes = Posix.instance.readRegular(path, limit, follow: false);
  if (bytes == null) throw FormatException('backup input too large: ${baseName(path)}');
  return bytes;
}

/// The state as a backup. With [broken], a damaged file does not stop it:
/// its raw bytes go there instead (kept for a restore's rollback).
Map<String, dynamic> collectBackup(Ctx ctx, {Map<String, List<int>>? broken}) {
  final files = <String, dynamic>{};
  for (final MapEntry(key: name, value: type) in backupFiles.entries) {
    final path = ctx.paths.file(name);
    List<int>? data;
    try {
      data = _readPrivate(path);
    } on FormatException {
      if (broken == null) rethrow;
      continue;
    }
    if (data == null) continue;
    try {
      final value = jsonDecode(utf8.decode(data));
      if (!_isType(value, type)) throw FormatException('invalid $name');
      files[name] = value;
    } on FormatException {
      if (broken == null) rethrow;
      broken[name] = data;
    }
  }
  return {'format': backupFormat, 'version': 1, 'files': files};
}

bool _slug(Object? v) => v is String && slugRe.hasMatch(v);

Map<String, dynamic> _validateSettings(Map value) {
  final out = <String, dynamic>{};
  for (final e in value.entries) {
    final key = '${e.key}';
    // the plugin's Omarchy-only keys (language, sync_omarchy, position) are dropped
    if (!defaultSettings.containsKey(key)) {
      if (key == 'screenshot_folder' && (e.value == null || Settings.check('screenshot_dir', e.value))) {
        out['screenshot_dir'] = e.value;
      }
      continue;
    }
    if (key == 'size') {
      if (Settings.check(key, e.value)) out[key] = e.value;
      continue; // a plugin popup size may not fit: dropped, not refused
    }
    if (key == 'ask_ai_helper') {
      if (Settings.check(key, e.value)) out[key] = e.value;
      continue;
    }
    if (key == 'schedule' && e.value is Map) {
      final plan = e.value as Map;
      for (final k in ['day', 'night']) {
        final d = plan[k];
        if (d != null && (d is! String || (d.isNotEmpty && !_slug(d)))) throw const FormatException('invalid settings');
      }
    }
    if (!Settings.check(key, e.value)) throw const FormatException('invalid settings');
    out[key] = e.value;
  }
  return out;
}

Object? _validateValue(Ctx ctx, String name, Object? value) {
  if (!_isType(value, backupFiles[name]!)) throw FormatException('invalid $name');
  switch (name) {
    case 'settings.json':
      return _validateSettings(value as Map);
    case 'hidden.json':
      final list = value as List;
      if (list.any((s) => !_slug(s))) throw const FormatException('invalid hidden themes');
      return [for (final s in list) if (s != ctx.current.slug) s];
    case 'hidden-wallpapers.json':
      final m = value as Map;
      for (final e in m.entries) {
        if (!_slug(e.key) || e.value is! List || (e.value as List).any((w) => !validWallpaperName(w) || !imageExts.contains(extOf(w as String)))) {
          throw const FormatException('invalid hidden wallpapers');
        }
      }
      return value;
    case 'favorites.json':
      final list = value as List;
      if (list.length > maxFavoritesAuto || list.any((s) => !_slug(s))) throw const FormatException('invalid favorites');
      return value;
    case 'recent.json':
      final m = value as Map;
      if (m.length > maxRecent || m.entries.any((e) => !_slug(e.key) || e.value is! num || !(e.value as num).isFinite)) {
        throw const FormatException('invalid recent themes');
      }
      return value;
    case 'workspace-wallpapers.json':
      for (final e in (value as Map).entries) {
        if (!_slug(e.key) || e.value is! Map) throw const FormatException('invalid workspace wallpapers');
        for (final a in (e.value as Map).entries) {
          final ws = int.tryParse('${a.key}');
          if (ws == null || ws < 1 || ws > maxWorkspace || !validWallpaperName(a.value)) {
            throw const FormatException('invalid workspace wallpapers');
          }
        }
      }
      return value;
    case 'workspace-themes.json':
      for (final e in (value as Map).entries) {
        final ws = int.tryParse('${e.key}');
        if (ws == null || ws < 1 || ws > maxWorkspace || !_slug(e.value)) throw const FormatException('invalid workspace themes');
      }
      return value;
    case 'shortcuts.json':
      final raw = value as Map;
      final cleaned = ThemeShortcuts.cleanShortcuts(raw);
      if (cleaned.length != raw.length) throw const FormatException('invalid shortcuts');
      return {
        for (final e in cleaned.entries)
          e.key: {'mods': e.value['mods'], 'key': e.value['key'], if (e.value['replaces'] != null) 'replaces': e.value['replaces']},
      };
    case 'presets.json':
      final list = value as List;
      final names = [for (final p in list) if (p is Map && p['name'] is String) (p['name'] as String).toLowerCase()];
      if (list.length > 200 || names.length != list.length || names.toSet().length != names.length) {
        throw const FormatException('invalid presets');
      }
      return _withoutCommands(list);
    case 'workspaces.json':
      return _withoutCommands(value);
  }
  return value;
}

/// Saved terminal commands of App Presets are dropped (those apps start from
/// their launcher), as the plugin's restore does.
Object? _withoutCommands(Object? v) {
  if (v is Map) {
    return {
      for (final e in v.entries)
        if (e.key != 'command' && e.key != 'commandline' && e.key != 'cmdline') '${e.key}': _withoutCommands(e.value),
    };
  }
  if (v is List) return [for (final x in v) _withoutCommands(x)];
  return v;
}

String _encode(Object? value) => '${const JsonEncoder.withIndent('  ').convert(value)}\n';

/// Writes a backup to [path] (0600).
void exportBackup(Ctx ctx, String path) {
  final payload = _encode(collectBackup(ctx));
  if (utf8.encode(payload).length > maxBackup) throw RouteError('too_large', 'backup is too large');
  writeText(path, payload);
}

/// The checked files of the backup at [path].
Map<String, dynamic> previewBackup(Ctx ctx, String path) {
  final List<int>? data;
  try {
    data = _readPrivate(path);
  } on FormatException catch (e) {
    throw RouteError('bad_backup', e.message);
  }
  if (data == null) throw RouteError('not_found', path);
  try {
    final payload = jsonDecode(utf8.decode(data));
    if (payload is! Map || (payload['format'] != backupFormat && payload['format'] != pluginBackupFormat) || payload['version'] != 1) {
      throw const FormatException('unsupported backup format');
    }
    final files = payload['files'];
    if (files is! Map || files.keys.any((k) => !backupFiles.containsKey(k))) throw const FormatException('invalid backup files');
    final checked = {for (final e in files.entries) e.key as String: _validateValue(ctx, e.key as String, e.value)};
    for (final e in checked.entries) {
      final limit = e.key == 'presets.json' ? 1024 * 1024 : e.key == 'workspaces.json' ? 512 * 1024 : maxBackup;
      if (utf8.encode(_encode(e.value)).length > limit) throw FormatException('backup file too large: ${e.key}');
    }
    return checked;
  } on FormatException catch (e) {
    throw RouteError('bad_backup', e.message);
  }
}

/// A new rollback file in ~/.config/maprisma-theme/backups/.
String safetyCopyPath(Ctx ctx, DateTime now) {
  final folder = ctx.paths.backups;
  final dir = Directory(folder);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
    chmodPath(folder, 448);
  }
  final stat = FileStat.statSync(folder);
  if (FileSystemEntity.isLinkSync(folder) || stat.type != FileSystemEntityType.directory ||
      Posix.instance.ownerOf(folder) != Posix.instance.uid || stat.mode & 0x12 != 0) {
    throw RouteError('unsafe', 'unsafe backup folder');
  }
  final stem = 'maprisma-theme.before-restore-${now.year}-${_two(now.month)}-${_two(now.day)}-'
      '${_two(now.hour)}-${_two(now.minute)}-${_two(now.second)}';
  var path = '$folder/$stem.json';
  for (var n = 2; FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound; n++) {
    path = '$folder/$stem-$n.json';
  }
  return path;
}

/// Replaces the state with a backup's, after saving a rollback copy; on a
/// failure the previous files come back. Returns the rollback copy's path.
String restoreBackup(Ctx ctx, String path) {
  final files = previewBackup(ctx, path);
  final broken = <String, List<int>>{};
  final prior = collectBackup(ctx, broken: broken)['files'] as Map<String, dynamic>;
  final safety = safetyCopyPath(ctx, ctx.clock());
  final payload = utf8.encode(_encode({'format': backupFormat, 'version': 1, 'files': prior}));
  if (!Posix.instance.writeNewPrivate(safety, payload)) throw RouteError('failed', 'could not write $safety');
  final shortcuts = ThemeShortcuts(ctx);
  final shortcutChanged = files.containsKey('shortcuts.json') || prior.containsKey('shortcuts.json');
  void put(Map<String, dynamic> source, Map<String, List<int>> raw) {
    for (final name in backupFiles.keys) {
      final target = ctx.paths.file(name);
      if (source.containsKey(name)) {
        writeJson(target, source[name]);
      } else if (raw.containsKey(name)) {
        writeAtomic(target, raw[name]!);
      } else if (File(target).existsSync()) {
        File(target).deleteSync();
      }
    }
    if (shortcutChanged && shortcuts.available) {
      shortcuts.save(ThemeShortcuts.cleanShortcuts(source['shortcuts.json'] ?? const {}));
      if (!source.containsKey('shortcuts.json') && File(shortcuts.stateFile).existsSync()) File(shortcuts.stateFile).deleteSync();
    }
  }

  try {
    put(files, const {});
  } on Object catch (original) {
    try {
      put(prior, broken);
    } on Object catch (rollback) {
      throw RouteError('failed', 'restore failed: $original; rollback failed: $rollback');
    }
    if (original is RouteError) rethrow;
    throw RouteError('failed', 'restore failed: $original');
  }
  ctx.automationChanged();
  return safety;
}

// --- health -------------------------------------------------------------------------

/// The applet's id in COSMIC's panels.
const appletId = 'io.github.ubruckhaus.CosmicMaprismaTheme';

/// Is the helper there, is the applet installed and in a panel, and is the
/// shortcut file in order?
Future<Map<String, dynamic>> health(Ctx ctx) async {
  final desktop = ctx.desktop;
  String? helperPath;
  bool helperOk;
  if (desktop is CosmicDesktop) {
    helperPath = desktop.helper;
    helperOk = helperPath != null && await desktop.current() != null;
  } else {
    helperOk = await desktop.helperJson(['current']) != null;
  }

  final local = '${ctx.paths.home}/.local/bin';
  String? find(String name) =>
      Posix.instance.executable('$local/$name') && FileSystemEntity.isFileSync('$local/$name') ? '$local/$name' : which(name, ctx.environment);
  final applet = find('maprisma-theme-applet');
  final desktopFile = [
    '${ctx.paths.data}/applications/$appletId.desktop',
    '/usr/local/share/applications/$appletId.desktop',
    '/usr/share/applications/$appletId.desktop',
  ].where((p) => File(p).existsSync()).firstOrNull;
  var inPanel = false;
  try {
    for (final panel in Directory(ctx.paths.cosmicConfig).listSync()) {
      if (!baseName(panel.path).startsWith('com.system76.CosmicPanel')) continue;
      for (final f in ['plugins_center', 'plugins_wings']) {
        if ((readSmall('${panel.path}/v1/$f', limit: 64 * 1024) ?? '').contains('"$appletId"')) inPanel = true;
      }
    }
  } on FileSystemException {
    // no COSMIC config
  }

  final shortcuts = ThemeShortcuts(ctx);
  final state = shortcuts.load();
  var fileOk = true;
  var written = 0;
  String note = '';
  try {
    final text = readSmall(shortcuts.customFile, limit: 1024 * 1024);
    if (text != null) {
      final entries = parseCosmicShortcuts(text).$2;
      written = entries.where((e) => e['combo'] != null && (e['description'] as String).endsWith(ownTag)).length;
    }
  } on FormatException catch (e) {
    fileOk = false;
    note = "COSMIC's custom shortcuts file cannot be read: ${e.message}";
  }
  final installed = {for (final t in ctx.themes()) t.slug};
  final expected = state.keys.where((t) => themeOfTarget(t) == null || installed.contains(themeOfTarget(t))).length;
  if (fileOk && written != expected) {
    fileOk = false;
    note = '$expected key(s) set, $written in COSMIC\'s file: Repair writes them again';
  }
  final core = find('maprisma-theme-core');
  return {
    'helper': {'ok': helperOk, 'path': helperPath},
    'core': {'ok': core != null, 'path': core},
    'applet': {'ok': applet != null || desktopFile != null, 'path': applet, 'in_panel': inPanel},
    'shortcuts': {'ok': fileOk, 'available': shortcuts.available, 'keys': state.length, 'written': written, 'note': note},
  };
}

/// Writes the shortcut file again from shortcuts.json and automation.json.
Future<Map<String, dynamic>> repairHealth(Ctx ctx) async {
  final shortcuts = ThemeShortcuts(ctx);
  if (shortcuts.available) shortcuts.save(shortcuts.load());
  ctx.automationChanged();
  return health(ctx);
}
