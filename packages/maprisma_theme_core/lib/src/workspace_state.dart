import 'dart:convert';
import 'context.dart';
import 'store.dart';

Map<String, dynamic> cleanWorkspaceState(Object? value) {
  final raw = value is Map ? value : const {};
  final out = <String, dynamic>{
    'active': raw['active'] == true,
    'autoMoveOnRestore': raw['autoMoveOnRestore'] == true,
    'maxWindows':
        raw['maxWindows'] is int &&
            raw['maxWindows'] >= 1 &&
            raw['maxWindows'] <= 4
        ? raw['maxWindows']
        : 2,
  };
  for (final key in ['workspaceCaps', 'workspaceModes', 'workspaceLayouts']) {
    final map = <String, dynamic>{};
    final source = raw[key];
    if (source is Map) {
      for (var ws = 1; ws <= 10; ws++) {
        final v = source['$ws'];
        if (key == 'workspaceCaps' && v is int && v >= 1 && v <= 4) {
          map['$ws'] = v;
        }
        if (key == 'workspaceModes' &&
            ['tiled', 'floating', 'default'].contains(v)) {
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
  return out;
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
  final modes = s['workspaceModes'] as Map;
  return {
    'tiling': {
      'active': s['active'],
      'default_limit': s['maxWindows'],
      'limits': s['workspaceCaps'],
      'floating': [
        for (var i = 1; i <= 10; i++)
          if (modes['$i'] == 'floating') i,
      ],
      'tiled': [
        for (var i = 1; i <= 10; i++)
          if (modes['$i'] == 'tiled') i,
      ],
    },
    'autostart': (s['workspaceLayouts'] as Map).values.any(
      (v) => v['autostart'] == true,
    ),
  };
}

Future<Map<String, dynamic>> helper(Ctx ctx, List<String> args) async {
  final result = await ctx.desktop.helperJson(args);
  if (result == null || result['error'] != null) {
    throw RouteError(
      'desktop_unavailable',
      result?['message']?.toString() ?? 'COSMIC helper unavailable',
    );
  }
  return result;
}

Future<List<Map<String, dynamic>>> desktopWindows(Ctx ctx) async =>
    ((await helper(ctx, ['windows']))['windows'] as List? ?? [])
        .whereType<Map>()
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
Future<void> applyTiling(Ctx ctx) async {
  final modes = loadWorkspaces(ctx)['workspaceModes'] as Map;
  final existing =
      (await helper(ctx, ['workspaces']))['workspaces'] as List? ?? [];
  for (final w in existing.whereType<Map>()) {
    final mode = modes['${w['index']}'];
    if (mode == 'tiled' || mode == 'floating') {
      await helper(ctx, [
        'set-tiling',
        '${w['index']}',
        mode == 'tiled' ? 'on' : 'off',
      ]);
    }
  }
}
