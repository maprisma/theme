import 'i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'apply.dart';
import 'auto.dart';
import 'context.dart';
import 'desktop.dart';
import 'launchers.dart';
import 'posix.dart';
import 'store.dart';
import 'themes.dart';
import 'workspace_state.dart';
import 'looks.dart';

String presetName(Object? value) {
  if (value is! String || value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw RouteError(
      'bad_params',
      tr("Preset name must be 1–60 printable characters"),
    );
  }
  final name = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (name.isEmpty || name.length > 60) {
    throw RouteError(
      'bad_params',
      tr("Preset name must be 1–60 printable characters"),
    );
  }
  return name;
}

List<Map<String, dynamic>> loadPresets(Ctx ctx) {
  final raw = readJson(ctx.paths.file('presets.json'));
  final out = <Map<String, dynamic>>[];
  if (raw is! List) return out;
  for (final p in raw.whereType<Map>().take(50)) {
    try {
      final name = presetName(p['name']);
      if (!validSlug(p['theme'])) continue;
      final wallpaper = p['wallpaper'];
      if (wallpaper != null && !validWallpaperName(wallpaper)) continue;
      final font = p['font'];
      if (font != null &&
          (font is! String ||
              font.length > 200 ||
              font.contains(RegExp(r'[\x00-\x1f]')))) {
        continue;
      }
      out.add({
        'name': name,
        'theme': p['theme'],
        'wallpaper': wallpaper,
        'font': font,
        if (p['workspaces'] is Map)
          'workspaces': cleanWorkspaceState(p['workspaces']),
      });
    } on RouteError {
      continue;
    }
  }
  return out;
}

void renamePresetTheme(Ctx ctx, String old, String renamed) {
  final list = loadPresets(ctx);
  for (final p in list) {
    if (p['theme'] == old) p['theme'] = renamed;
  }
  if (list.isNotEmpty) writeJson(ctx.paths.file('presets.json'), list);
}

Map<String, dynamic> namedPreset(Ctx ctx, String name) =>
    loadPresets(ctx).firstWhere(
      (p) => p['name'] == name,
      orElse: () => throw RouteError('not_found', tr("Preset not found")),
    );
String? presetWallpaper(Ctx ctx, Map p) {
  final name = p['wallpaper'];
  if (name == null) return null;
  final theme = ctx.theme(p['theme'] as String);
  for (final b in listBackgrounds(ctx.paths, theme)) {
    if (b.name == name && !b.hidden) return b.path;
  }
  throw RouteError('not_found', tr("Preset wallpaper is unavailable"));
}

// Reserve the entire snapshot before any window is moved or app launched.
Future<Map<String, dynamic>> restoreAppLayouts(
  Ctx ctx,
  Map layouts, {
  DateTime? until,
}) async {
  final windows = await desktopWindows(ctx);
  final launchers = scanLaunchers(ctx);
  final used = <String>{};
  final plans = <int, List<Map<String, dynamic>?>>{};
  for (final e in layouts.entries) {
    final ws = int.parse(e.key as String);
    plans[ws] = List.filled((e.value['apps'] as List).length, null);
  }
  // Keep windows already on their requested workspace before borrowing others.
  for (final localOnly in [true, false]) {
    for (final ws in plans.keys) {
      final apps = layouts['$ws']['apps'] as List;
      for (var i = 0; i < apps.length; i++) {
        if (plans[ws]![i] != null) continue;
        final matches = windows.where(
          (w) =>
              w['id'] is String &&
              !used.contains(w['id']) &&
              launcherMatchesApp(launchers, apps[i] as String, w['app_id']) &&
              (!localOnly || w['workspace'] == ws),
        );
        if (matches.isNotEmpty) {
          plans[ws]![i] = matches.first;
          used.add(matches.first['id'] as String);
        }
      }
    }
  }
  final results = <String, dynamic>{};
  final deadline = until ?? DateTime.now().add(const Duration(seconds: 35));
  for (final ws in plans.keys) {
    results['$ws'] = await restoreApps(
      ctx,
      ws,
      action: 'move',
      layout: layouts['$ws'] as Map,
      until: deadline,
      reserved: used,
      planned: plans[ws],
      initialWindows: windows,
      targetWorkspaces: plans.keys.toSet(),
    );
  }
  return results;
}

Future<Map<String, dynamic>> restoreApps(
  Ctx ctx,
  int ws, {
  String action = 'ask',
  Map? layout,
  DateTime? until,
  Set<String>? reserved,
  List<Map<String, dynamic>?>? planned,
  List<Map<String, dynamic>>? initialWindows,
  Set<int> targetWorkspaces = const {},
}) async {
  if (!['ask', 'move', 'close', 'keep'].contains(action)) {
    throw RouteError('bad_params', 'action');
  }
  final state = loadWorkspaces(ctx);
  layout ??= (state['workspaceLayouts'] as Map)['$ws'] as Map?;
  if (layout == null) throw RouteError('not_found', tr("No saved apps"));
  final apps = (layout['apps'] as List).cast<String>();
  if (apps.isEmpty) {
    return {
      'status': 'no_apps',
      'moves': <dynamic>[],
      'failed': <String>[],
      'launched': <String>[],
    };
  }
  final launchers = scanLaunchers(ctx);
  final windows = initialWindows ?? await desktopWindows(ctx);
  final used = reserved ?? <String>{};
  final pairs = <Map<String, dynamic>>[];
  final missing = <String>[];
  for (var i = 0; i < apps.length; i++) {
    final app = apps[i];
    if (planned != null) {
      final window = planned[i];
      if (window == null) {
        missing.add(app);
      } else {
        pairs.add(window);
      }
      continue;
    }
    final matches =
        windows
            .where(
              (w) =>
                  launcherMatchesApp(launchers, app, w['app_id']) &&
                  w['id'] is String &&
                  !used.contains(w['id']),
            )
            .toList()
          ..sort(
            (a, b) => (a['workspace'] == ws ? 0 : 1).compareTo(
              b['workspace'] == ws ? 0 : 1,
            ),
          );
    if (matches.isEmpty) {
      missing.add(app);
    } else {
      pairs.add(matches.first);
      used.add(matches.first['id'] as String);
    }
  }
  final extras = windows
      .where((w) => w['workspace'] == ws && !used.contains(w['id']))
      .toList();
  if (state['autoMoveOnRestore'] == true && action == 'ask') action = 'move';
  if (extras.isNotEmpty && action == 'ask') {
    return {'status': 'conflict', 'conflict_count': extras.length};
  }
  int? target;
  if (extras.isNotEmpty && action == 'move') {
    final existing =
        (await helper(ctx, ['workspaces']))['workspaces'] as List? ?? [];
    for (final w in existing.whereType<Map>()) {
      final index = w['index'];
      if (index is int &&
          index != ws &&
          !targetWorkspaces.contains(index) &&
          !windows.any((v) => v['workspace'] == index)) {
        target = index;
        break;
      }
    }
    if (target == null) {
      throw RouteError('no_room', tr("No empty workspace for other windows"));
    }
  }
  final moves = <Map<String, dynamic>>[];
  for (final w in extras) {
    if (action == 'close') await helper(ctx, ['close', w['id'] as String]);
    if (action == 'move') {
      await helper(ctx, ['move', w['id'] as String, '$target']);
      moves.add({'id': w['id'], 'workspace': ws});
    }
  }
  for (final w in pairs) {
    if (w['workspace'] != ws) {
      await helper(ctx, ['move', w['id'] as String, '$ws']);
      if (w['workspace'] is int) {
        moves.add({'id': w['id'], 'workspace': w['workspace']});
      }
    }
  }
  final failed = <String>[];
  final launched = <String>[];
  final restoreDeadline =
      until ?? DateTime.now().add(const Duration(seconds: 35));
  for (final app in missing) {
    if (DateTime.now().isAfter(restoreDeadline)) {
      failed.add(app);
      continue;
    }
    final launcher = findLauncher(launchers, app);
    if (launcher == null || !await launchApp(ctx, launcher)) {
      failed.add(app);
      continue;
    }
    launched.add(app);
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    var found = false;
    while (DateTime.now().isBefore(deadline) &&
        DateTime.now().isBefore(restoreDeadline)) {
      final now = await desktopWindows(ctx);
      final matches = now.where(
        (w) =>
            launcherMatchesApp(launchers, app, w['app_id']) &&
            w['id'] is String &&
            !used.contains(w['id']) &&
            !windows.any((old) => old['id'] == w['id']),
      );
      if (matches.isNotEmpty) {
        final w = matches.first;
        used.add(w['id'] as String);
        await helper(ctx, ['move', w['id'] as String, '$ws']);
        found = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!found) failed.add(app);
  }
  return {
    'status': failed.isEmpty ? 'restored' : 'partial',
    'failed': failed,
    'launched': launched,
    'moves': moves,
    'closed': action == 'close' ? extras.length : 0,
  };
}

Future<Map<String, dynamic>> applySavedPreset(
  Ctx ctx,
  Map<String, dynamic> p, {
  bool confirmed = false,
}) async {
  final moves = <dynamic>[];
  final failed = <dynamic>[];
  final snapshot = p['workspaces'];
  if (snapshot != null && !confirmed) {
    throw RouteError(
      'confirmation_required',
      tr("This preset restores apps and moves windows"),
    );
  }
  final wallpaper = presetWallpaper(ctx, p);
  final font = p['font'];
  if (font != null && !(await ctx.desktop.monospaceFonts()).contains(font)) {
    throw RouteError('not_found', tr("Preset font is unavailable"));
  }
  await applyTheme(ctx, p['theme'] as String, wallpaper: wallpaper);
  if (font is String) await applyFontOverride(ctx, FontRole.mono, font);
  if (snapshot != null) {
    final clean = cleanWorkspaceState(snapshot);
    final current = loadWorkspaces(ctx);
    clean['active'] = current['active'];
    clean['autoMoveOnRestore'] = current['autoMoveOnRestore'];
    final previous = current['workspaceLayouts'] as Map;
    for (final entry in (clean['workspaceLayouts'] as Map).entries) {
      final old = previous[entry.key];
      entry.value['autostart'] =
          old is Map &&
          old['autostart'] == true &&
          jsonEncode(old['apps']) == jsonEncode(entry.value['apps']);
    }
    saveWorkspaces(ctx, clean);
    await applyTiling(ctx);
    final deadline = DateTime.now().add(const Duration(seconds: 35));
    final results = await restoreAppLayouts(
      ctx,
      clean['workspaceLayouts'] as Map,
      until: deadline,
    );
    for (final result in results.values) {
      moves.addAll(result['moves'] as List);
      failed.addAll(result['failed'] as List);
    }
  }
  return {'moves': moves, 'failed': failed};
}

/// In-memory receipts cannot be supplied as executable or arbitrary file data.
class PresetUndo {
  final Map<String, Map<String, dynamic>> _receipts = {};
  int _serial = 0;
  Future<String> capture(Ctx ctx) async {
    final id = '${++_serial}';
    _receipts[id] = {
      'workspaces': loadWorkspaces(ctx),
      'presets': loadPresets(ctx),
      'theme': ctx.current.slug,
      'wallpaper': ctx.current.wallpaper,
      'look': await captureLook(ctx),
      'autostart': readJsonMap('${ctx.paths.state}/autostart.json'),
    };
    if (_receipts.length > 30) _receipts.remove(_receipts.keys.first);
    return id;
  }

  void attach(String id, Map result) {
    _receipts[id]?['moves'] = result['moves'];
  }

  Future<void> captureDesktop(Ctx ctx, String id) async {
    final desktop = await helper(ctx, ['workspaces']);
    _receipts[id]?['tiling'] = [
      for (final w in (desktop['workspaces'] as List? ?? []).whereType<Map>())
        if (w['index'] is int && w['tiling'] is bool)
          {'workspace': w['index'], 'tiling': w['tiling']},
    ];
  }

  void captureAssignments(Ctx ctx, String id) {
    _receipts[id]?['assignments'] = {
      'themes': loadWorkspaceThemes(ctx),
      'wallpapers': loadWorkspaceMap(ctx),
      'workspace_themes': ctx.settings.get('workspace_themes'),
      'workspace_wallpapers': ctx.settings.get('workspace_wallpapers'),
    };
  }

  Future<void> restore(Ctx ctx, String id, {bool appearance = false}) async {
    final s = _receipts.remove(id);
    if (s == null) throw RouteError('not_found', tr("Undo expired"));
    saveWorkspaces(
      ctx,
      Map<String, dynamic>.from(s['workspaces'] as Map),
      approveAutostart: false,
    );
    writeJson('${ctx.paths.state}/autostart.json', s['autostart']);
    writeJson(ctx.paths.file('presets.json'), s['presets']);
    final assignments = s['assignments'];
    if (assignments is Map) {
      final before = assignments['themes'] as Map<int, String>;
      final current = loadWorkspaceThemes(ctx);
      for (final ws in {...before.keys, ...current.keys}) {
        setWorkspaceTheme(ctx, ws, before[ws]);
      }
      saveWorkspaceMap(
        ctx,
        assignments['wallpapers'] as Map<String, Map<int, String>>,
      );
      for (final key in ['workspace_themes', 'workspace_wallpapers']) {
        ctx.settings.set(key, assignments[key]);
      }
      ctx.automationChanged();
    }
    for (final w in ctx.desktop.caps.contains(Cap.tiling) ? s['tiling'] as List? ?? [] : const []) {
      await helper(ctx, [
        'set-tiling',
        '${w['workspace']}',
        w['tiling'] == true ? 'on' : 'off',
      ]);
    }
    for (final m in (s['moves'] as List? ?? []).reversed) {
      await helper(ctx, ['move', m['id'] as String, '${m['workspace']}']);
    }
    if (appearance && s['theme'] != '') {
      await applyTheme(
        ctx,
        s['theme'] as String,
        wallpaper: s['wallpaper'] as String?,
      );
      if (s['look'] is Map) await restoreLook(ctx, Map<String, dynamic>.from(s['look'] as Map));
    }
  }
}

void savePresetList(Ctx ctx, List<Map<String, dynamic>> list) {
  if (list.length > 50 || utf8.encode(jsonEncode(list)).length > 1024 * 1024) {
    throw RouteError('limit', tr("Too many presets"));
  }
  writeJson(ctx.paths.file('presets.json'), list);
}

Future<Map<String, dynamic>> autostartPresets(Ctx ctx) async {
  var session = ctx.environment['XDG_SESSION_ID'];
  if (session == null || session.isEmpty) {
    final boot = File(
      '/proc/sys/kernel/random/boot_id',
    ).readAsStringSync().trim();
    session = '$boot-${Posix.instance.uid}';
  }
  final marker =
      '${ctx.paths.runtime}/presets-autostart-${base64Url.encode(utf8.encode(session))}';
  Directory(ctx.paths.runtime).createSync(recursive: true);
  chmodPath(ctx.paths.runtime, 448);
  try {
    File(marker).createSync(exclusive: true);
  } on FileSystemException {
    return {'status': 'already_started'};
  }
  chmodPath(marker, 384);
  final path = '${ctx.paths.state}/autostart.json';
  final stat = File(path).statSync();
  if (stat.type != FileSystemEntityType.file ||
      stat.mode & 63 != 0 ||
      Posix.instance.ownerOf(path, follow: false) != Posix.instance.uid) {
    return {'status': 'unsafe_snapshot'};
  }
  final bytes = Posix.instance.readRegular(path, 1024 * 1024, follow: false);
  Object? snapshot;
  try {
    snapshot = bytes == null ? null : jsonDecode(utf8.decode(bytes));
  } on FormatException {
    snapshot = null;
  }
  final approved =
      cleanWorkspaceState({'workspaceLayouts': snapshot})['workspaceLayouts']
          as Map;
  final current = loadWorkspaces(ctx)['workspaceLayouts'] as Map;
  final layouts = {
    for (final e in approved.entries)
      if (current[e.key]?['autostart'] == true) e.key: e.value,
  };
  return {'results': await restoreAppLayouts(ctx, layouts)};
}
