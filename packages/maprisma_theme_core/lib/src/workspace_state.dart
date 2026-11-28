import 'i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'context.dart';
import 'desktop.dart';
import 'posix.dart';
import 'store.dart';

/// workspaces.json's schema: 2 adds presets and splits (Hyprland); a file
/// without the field (schema 1) reads the same, its new maps empty.
const workspaceSchema = 2;

Map<String, dynamic> cleanWorkspaceState(Object? value) {
  final raw = value is Map ? value : const {};
  final out = <String, dynamic>{
    'schema': workspaceSchema,
    'active': raw['active'] == true,
    'autoMoveOnRestore': raw['autoMoveOnRestore'] == true,
    'maxWindows':
        raw['maxWindows'] is int &&
            raw['maxWindows'] >= 1 &&
            raw['maxWindows'] <= 4
        ? raw['maxWindows']
        : 2,
  };
  for (final key in [
    'workspaceCaps',
    'workspaceModes',
    'workspaceLayouts',
    'defaultModes',
  ]) {
    final map = <String, dynamic>{};
    final source = raw[key];
    if (source is Map) {
      for (var ws = 1; ws <= 10; ws++) {
        final v = source['$ws'];
        if (key == 'workspaceCaps' && v is int && v >= 1 && v <= 4) {
          map['$ws'] = v;
        }
        if ((key == 'workspaceModes' || key == 'defaultModes' && ws <= 4) &&
            workspaceModeNames.contains(v)) {
          map['$ws'] = v;
        }
        if (key == 'workspaceLayouts' && v is Map) {
          final apps = v['apps'];
          map['$ws'] = {
            'autostart': v['autostart'] == true,
            'apps': apps is List
                ? apps
                      .whereType<String>()
                      .where(
                        (s) =>
                            s.isNotEmpty &&
                            s.length <= 255 &&
                            !s.contains(RegExp(r'[\x00-\x1f]')),
                      )
                      .take(64)
                      .toList()
                : <String>[],
          };
        }
      }
    }
    out[key] = map;
  }
  final presets = <String, dynamic>{}, defaults = <String, dynamic>{}, splits = <String, dynamic>{};
  final rawPresets = raw['workspacePresets'], rawDefaults = raw['defaultPresets'], rawSplits = raw['workspaceSplits'];
  for (var ws = 1; ws <= 10; ws++) {
    if (rawPresets is Map && presetNames.contains(rawPresets['$ws'])) presets['$ws'] = rawPresets['$ws'];
    if (ws <= 4 && rawDefaults is Map && presetNames.contains(rawDefaults['$ws'])) defaults['$ws'] = rawDefaults['$ws'];
    final split = rawSplits is Map ? cleanSplit(rawSplits['$ws']) : null;
    if (split != null) splits['$ws'] = split;
  }
  out['workspacePresets'] = presets;
  out['defaultPresets'] = defaults;
  out['workspaceSplits'] = splits;
  final defaultSplit = cleanSplit(raw['defaultSplit']);
  if (defaultSplit != null) out['defaultSplit'] = defaultSplit;
  return out;
}

// --- layout presets (Hyprland: Cap.presetLayouts) -----------------------------------------

/// Every layout preset: the tiling ones, then those without a window limit.
const presetNames = ['side-by-side', 'stacked', 'master-left', 'master-right', 'columns', 'grid', 'floating', 'scrolling', 'none'];

/// The smallest and largest split share (the first/master window's part).
const splitMin = 0.20, splitMax = 0.80;

/// Columns' largest middle column.
const columnsSplitMax = 0.60;

/// A split share [splitMin]..[max] rounded to 2 decimals; null for anything
/// that is not a finite number.
double? cleanSplit(Object? value, {double max = splitMax}) {
  if (value is! num) return null;
  final d = value.toDouble();
  if (!d.isFinite) return null;
  return (d.clamp(splitMin, max) * 100).round() / 100;
}

/// The COSMIC/KDE layout a preset stands for.
String modeForPreset(String preset) => switch (preset) {
  'floating' => 'floating',
  'none' || 'scrolling' => 'default',
  _ => 'tiled',
};

/// The preset a COSMIC/KDE layout stands for on a workspace of [cap] windows.
String presetForMode(String mode, {int cap = 2}) => switch (mode) {
  'floating' => 'floating',
  'default' => 'none',
  _ => builtinDefaultPreset(cap),
};

/// The tiling preset a workspace of [cap] windows gets when nothing says otherwise.
String builtinDefaultPreset(int cap) => switch (cap) {
  3 => 'master-left',
  4 => 'grid',
  _ => 'side-by-side',
};

/// The tiling presets that fit [cap] windows (the unlimited ones fit any).
List<String> validPresetsForCap(int cap) => switch (cap) {
  1 => const ['side-by-side'],
  2 => const ['side-by-side', 'stacked'],
  3 => const ['columns', 'master-left', 'master-right'],
  _ => const ['columns', 'master-left', 'master-right', 'grid'],
};

/// Presets without a window limit (no overflow from them).
bool isUnlimitedPreset(String preset) => preset == 'floating' || preset == 'scrolling' || preset == 'none';

Map _map(Map s, String key) => s[key] is Map ? s[key] as Map : const {};

/// The preset in effect on [ws] (0 = All Workspaces' default): its own, else
/// its own layout's (Native is `none`), else the default preset for its
/// limit, else the default layout's, else the built-in one for its limit.
String effectivePreset(Map s, int ws) {
  final limit = effectiveLimit(s, ws);
  final own = ws > 0 ? _map(s, 'workspacePresets')['$ws'] : null;
  if (own is String && presetNames.contains(own)) return own;
  final mode = ws > 0 ? _map(s, 'workspaceModes')['$ws'] : null;
  if (mode is String) return presetForMode(mode, cap: limit);
  final preset = _map(s, 'defaultPresets')['$limit'];
  if (preset is String && presetNames.contains(preset)) return preset;
  final defaultMode = _map(s, 'defaultModes')['$limit'];
  if (defaultMode is String) return presetForMode(defaultMode, cap: limit);
  return builtinDefaultPreset(limit);
}

/// Whether [ws]'s preset was chosen (its own, its layout or its limit's
/// default) rather than the built-in fallback; the fallback counts only
/// while window limits are on.
bool presetConfigured(Map s, int ws) {
  if (s['active'] == true) return true;
  final limit = '${effectiveLimit(s, ws)}';
  return _map(s, 'workspacePresets').containsKey('$ws') ||
      _map(s, 'workspaceModes').containsKey('$ws') ||
      _map(s, 'defaultPresets').containsKey(limit) ||
      _map(s, 'defaultModes').containsKey(limit);
}

/// The split share on [ws]: its own, else the default, else null (even).
double? effectiveSplit(Map s, int ws) {
  final own = ws > 0 ? cleanSplit(_map(s, 'workspaceSplits')['$ws']) : null;
  return own ?? cleanSplit(s['defaultSplit']);
}

// --- one-step Undo across processes (`maprisma-theme-core call`) ------------------------------

/// The largest snapshot kept for workspaces.undo.
const lastUndoMax = 512 * 1024;

String lastUndoFile(Ctx ctx) => '${ctx.paths.state}/last-undo.json';

/// Keeps workspaces.json as it is now (data only) for one workspaces.undo.
void snapshotWorkspaces(Ctx ctx) {
  final data = {'version': 1, 'workspaces': loadWorkspaces(ctx)};
  final bytes = utf8.encode('${const JsonEncoder.withIndent('  ').convert(data)}\n');
  if (bytes.length > lastUndoMax) {
    dropWorkspaceSnapshot(ctx);
    return;
  }
  final dir = ctx.paths.state;
  final path = lastUndoFile(ctx);
  try {
    if (FileSystemEntity.typeSync(dir, followLinks: false) == FileSystemEntityType.notFound) {
      Directory(dir).createSync(recursive: true);
    }
    if (!FileSystemEntity.isDirectorySync(dir)) return;
    chmodPath(dir, 448 /* 0700 */);
    // A planted link in place of the snapshot is never written through.
    if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.link) return;
  } on FileSystemException {
    return;
  }
  // 0600 from creation (O_CREAT|O_EXCL|O_NOFOLLOW), whatever the umask; then rename over.
  final tmp = '$dir/.last-undo.json.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp';
  if (!Posix.instance.writeNewPrivate(tmp, bytes)) return;
  try {
    File(tmp).renameSync(path);
  } on FileSystemException {
    try {
      File(tmp).deleteSync();
    } on FileSystemException {
      // gone
    }
  }
}

void dropWorkspaceSnapshot(Ctx ctx) {
  try {
    File(lastUndoFile(ctx)).deleteSync();
  } on FileSystemException {
    // none
  }
}

/// workspaces.json back as it was before the last change; false when there
/// is nothing to go back to.
bool undoWorkspaces(Ctx ctx) {
  final bytes = Posix.instance.readRegular(lastUndoFile(ctx), lastUndoMax, follow: false);
  if (bytes == null) return false;
  final text = utf8.decode(bytes, allowMalformed: true);
  Object? data;
  try {
    data = jsonDecode(text);
  } on FormatException {
    data = null;
  }
  dropWorkspaceSnapshot(ctx);
  if (data is! Map || data['workspaces'] is! Map) return false;
  saveWorkspaces(ctx, cleanWorkspaceState(data['workspaces']), approveAutostart: false);
  return true;
}

/// COSMIC's real layout choices: tiling on, tiling off, or COSMIC's own
/// setting left alone ("default", shown as Native).
const workspaceModeNames = ['tiled', 'floating', 'default'];

/// The window limit in effect on [ws] (1–10); 0 = All Workspaces' default.
int effectiveLimit(Map s, int ws) {
  final caps = s['workspaceCaps'] is Map ? s['workspaceCaps'] as Map : const {};
  final own = ws > 0 ? caps['$ws'] : null;
  return own is int ? own : (s['maxWindows'] as int? ?? 2);
}

/// The layout in effect on [ws]: its own, else the default layout for its
/// limit, else Native ("default"). 0 = All Workspaces' default.
String effectiveMode(Map s, int ws) {
  final modes = s['workspaceModes'] is Map
      ? s['workspaceModes'] as Map
      : const {};
  final defaults = s['defaultModes'] is Map
      ? s['defaultModes'] as Map
      : const {};
  final own = ws > 0 ? modes['$ws'] : null;
  if (own is String) return own;
  final fallback = defaults['${effectiveLimit(s, ws)}'];
  return fallback is String ? fallback : 'default';
}

Map<String, dynamic> loadWorkspaces(Ctx ctx) =>
    cleanWorkspaceState(readJson(ctx.paths.file('workspaces.json')));
void saveWorkspaces(
  Ctx ctx,
  Map<String, dynamic> state, {
  bool approveAutostart = true,
}) {
  final clean = cleanWorkspaceState(state);
  final previous = loadWorkspaces(ctx)['workspaceLayouts'] as Map;
  writeJson(ctx.paths.file('workspaces.json'), clean);
  if (approveAutostart) {
    final approved = readJsonMap('${ctx.paths.state}/autostart.json');
    final layouts = clean['workspaceLayouts'] as Map;
    approved.removeWhere((ws, _) => layouts[ws]?['autostart'] != true);
    for (final e in layouts.entries) {
      if (e.value['autostart'] == true &&
          jsonEncode(previous[e.key]) != jsonEncode(e.value)) {
        approved[e.key as String] = e.value;
      }
    }
    writeJson('${ctx.paths.state}/autostart.json', approved);
  }
  ctx.automationChanged();
}

Map<String, dynamic> tilingAutomation(Ctx ctx) {
  final s = loadWorkspaces(ctx);
  return {
    'tiling': {
      'active': s['active'],
      'default_limit': s['maxWindows'],
      'limits': s['workspaceCaps'],
      'floating': [
        for (var i = 1; i <= 10; i++)
          if (effectiveMode(s, i) == 'floating') i,
      ],
      'tiled': [
        for (var i = 1; i <= 10; i++)
          if (effectiveMode(s, i) == 'tiled') i,
      ],
      'presets': {
        for (var i = 1; i <= 10; i++)
          if (presetConfigured(s, i)) '$i': effectivePreset(s, i),
      },
      'splits': s['workspaceSplits'],
      'default_split': s['defaultSplit'],
      'unlimited': [
        for (var i = 1; i <= 10; i++)
          if (isUnlimitedPreset(effectivePreset(s, i))) i,
      ],
    },
    'autostart': (s['workspaceLayouts'] as Map).values.any(
      (v) => v['autostart'] == true,
    ),
  };
}

Future<Map<String, dynamic>> helper(Ctx ctx, List<String> args) async {
  final result = await ctx.desktop.wm(args);
  if (result == null || result['error'] != null) {
    throw RouteError(
      'desktop_unavailable',
      result?['message']?.toString() ?? tr("COSMIC helper unavailable"),
    );
  }
  return result;
}

Future<List<Map<String, dynamic>>> desktopWindows(Ctx ctx) async =>
    ((await helper(ctx, ['windows']))['windows'] as List? ?? [])
        .whereType<Map>()
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
/// Per-workspace tiling as the layouts say (only where the desktop can
/// switch it: [Cap.tiling]). With [Cap.presetLayouts] every workspace 1–10
/// whose preset was chosen gets it (wm `set-preset`, with its split).
Future<void> applyTiling(Ctx ctx) async {
  if (!ctx.desktop.caps.contains(Cap.tiling)) return;
  final s = loadWorkspaces(ctx);
  if (ctx.desktop.caps.contains(Cap.presetLayouts)) {
    for (var ws = 1; ws <= 10; ws++) {
      if (!presetConfigured(s, ws)) continue;
      final split = effectiveSplit(s, ws);
      await helper(ctx, ['set-preset', '$ws', effectivePreset(s, ws), if (split != null) split.toStringAsFixed(2)]);
    }
    return;
  }
  final existing =
      (await helper(ctx, ['workspaces']))['workspaces'] as List? ?? [];
  await _applyModes(ctx, s, existing);
}

/// After an undo ([Cap.presetLayouts]): a workspace whose preset was chosen
/// in [before] and is not any more gets `none` (so the windows the Floating
/// preset floated are tiled again rather than left floating), then every
/// chosen preset is applied again.
Future<void> applyTilingAfterUndo(Ctx ctx, Map before) async {
  if (!ctx.desktop.caps.contains(Cap.presetLayouts)) return;
  final after = loadWorkspaces(ctx);
  for (var ws = 1; ws <= 10; ws++) {
    if (presetConfigured(before, ws) && !presetConfigured(after, ws)) {
      await helper(ctx, ['set-preset', '$ws', 'none']);
    }
  }
  await applyTiling(ctx);
}

Future<void> _applyModes(Ctx ctx, Map s, List existing) async {
  for (final w in existing.whereType<Map>()) {
    final index = w['index'];
    if (index is! int || index < 1 || index > 10) continue;
    final mode = effectiveMode(s, index);
    if (mode == 'tiled' || mode == 'floating') {
      await helper(ctx, [
        'set-tiling',
        '${w['index']}',
        mode == 'tiled' ? 'on' : 'off',
      ]);
    }
  }
}
