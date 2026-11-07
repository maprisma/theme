import 'auto.dart';
import 'context.dart';
import 'presets.dart';
import 'launchers.dart';
import 'workspace_state.dart';

Map<String, Handler> presetRoutes(Ctx ctx) {
  tilingAutomationHook = tilingAutomation;
  ctx.automationChanged();
  final undo = PresetUndo();
  int workspace(Map<String, dynamic> p) =>
      intParam(p, 'workspace', min: 1, max: 10);
  Future<Map<String, dynamic>> change(
    void Function(Map<String, dynamic>) edit,
  ) async {
    final receipt = undo.capture(ctx);
    final s = loadWorkspaces(ctx);
    edit(s);
    saveWorkspaces(ctx, s);
    return {'receipt': receipt};
  }

  return {
    'workspaces.get': (_) async => {
      'state': loadWorkspaces(ctx),
      'desktop': await ctx.desktop.helperJson(['workspaces']),
    },
    'workspaces.set': (p) => change((s) {
      for (final k in ['active', 'autoMoveOnRestore']) {
        if (p.containsKey(k)) s[k] = boolParam(p, k);
      }
      if (p.containsKey('maxWindows')) {
        s['maxWindows'] = intParam(p, 'maxWindows', min: 1, max: 4);
      }
      if (p.containsKey('workspace')) {
        final ws = '${workspace(p)}';
        if (p.containsKey('limit')) {
          if (p['limit'] == null) {
            (s['workspaceCaps'] as Map).remove(ws);
          } else {
            s['workspaceCaps'][ws] = intParam(p, 'limit', min: 1, max: 4);
          }
        }
        if (p.containsKey('mode')) {
          final mode = str(p, 'mode');
          if (!['tiled', 'floating', 'default'].contains(mode)) {
            throw RouteError('bad_params', 'mode');
          }
          s['workspaceModes'][ws] = mode;
        }
      }
    }),
    'workspaces.reset': (_) => change((s) {
      s.clear();
    }),
    'workspaces.apply': (_) async {
      final receipt = undo.capture(ctx);
      await undo.captureDesktop(ctx, receipt);
      await applyTiling(ctx);
      return {'applied': true, 'receipt': receipt};
    },
    'apppresets.launchers': (_) async => {
      'launchers': [
        for (final l in (scanLaunchers(
          ctx,
        )..sort((a, b) => a.name.compareTo(b.name))))
          {'desktop_id': l.id, 'name': l.name, 'icon': l.icon},
      ],
    },
    'apppresets.add': (p) async {
      final ws = workspace(p);
      final id = str(p, 'desktop_id');
      if (!scanLaunchers(ctx).any((l) => l.id == id)) {
        throw RouteError('not_found', 'Installed launcher not found');
      }
      return change((s) {
        final layout = s['workspaceLayouts']['$ws'] ??= {
          'apps': <String>[],
          'autostart': false,
        };
        final apps = layout['apps'] as List;
        if (apps.length >= 64) throw RouteError('limit', 'Too many apps');
        apps.add(id);
      });
    },
    'apppresets.list': (_) async => {
      'layouts': loadWorkspaces(ctx)['workspaceLayouts'],
      'autoMoveOnRestore': loadWorkspaces(ctx)['autoMoveOnRestore'],
    },
    'apppresets.save': (p) async {
      final ws = workspace(p);
      final windows = await desktopWindows(ctx);
      final apps = windows
          .where((w) => w['workspace'] == ws)
          .map((w) => w['app_id'])
          .whereType<String>()
          .toList();
      return change((s) {
        s['workspaceLayouts']['$ws'] = {'apps': apps, 'autostart': false};
      });
    },
    'apppresets.remove': (p) => change((s) {
      final ws = '${workspace(p)}';
      final layout = s['workspaceLayouts'][ws];
      if (p.containsKey('index') && layout is Map) {
        final apps = layout['apps'] as List;
        apps.removeAt(intParam(p, 'index', min: 0, max: apps.length - 1));
      } else {
        (s['workspaceLayouts'] as Map).remove(ws);
      }
    }),
    'apppresets.autostart': (p) => change((s) {
      final layout = s['workspaceLayouts']['${workspace(p)}'];
      if (layout is! Map) throw RouteError('not_found', 'Save apps first');
      layout['autostart'] = boolParam(p, 'enabled');
    }),
    'apppresets.restore': (p) async {
      final receipt = undo.capture(ctx);
      final result = await restoreApps(
        ctx,
        workspace(p),
        action: optStr(p, 'action') ?? 'ask',
      );
      undo.attach(receipt, result);
      return {
        ...result,
        if (result['status'] != 'conflict') 'receipt': receipt,
      };
    },
    'presets.list': (_) async => {'presets': loadPresets(ctx)},
    'presets.save': (p) async {
      final name = presetName(p['name']);
      final theme = ctx.theme(ctx.current.slug);
      final receipt = undo.capture(ctx);
      final list = loadPresets(ctx);
      list.removeWhere(
        (v) => (v['name'] as String).toLowerCase() == name.toLowerCase(),
      );
      final wallpaper = ctx.current.wallpaper;
      final entry = <String, dynamic>{
        'name': name,
        'theme': theme.slug,
        'wallpaper': wallpaper?.split('/').last,
        'font': ctx.desktop.monospaceFont(),
      };
      if (boolParam(p, 'includeWorkspaces', fallback: false)) {
        entry['workspaces'] = loadWorkspaces(ctx);
      }
      list.add(entry);
      savePresetList(ctx, list);
      return {'receipt': receipt};
    },
    'presets.delete': (p) async {
      final name = str(p, 'name');
      namedPreset(ctx, name);
      final receipt = undo.capture(ctx);
      final list = loadPresets(ctx)..removeWhere((v) => v['name'] == name);
      savePresetList(ctx, list);
      return {'receipt': receipt};
    },
    'presets.apply': (p) async {
      final receipt = undo.capture(ctx);
      final preset = namedPreset(ctx, str(p, 'name'));
      if (preset['workspaces'] != null) await undo.captureDesktop(ctx, receipt);
      final result = await applySavedPreset(
        ctx,
        preset,
        confirmed: boolParam(p, 'confirmed', fallback: false),
      );
      undo.attach(receipt, result);
      return {...result, 'receipt': receipt, 'appearance': true};
    },
    'presets.assign': (p) async {
      final preset = namedPreset(ctx, str(p, 'name'));
      final slug = preset['theme'] as String;
      ctx.theme(slug);
      final part = optStr(p, 'part') ?? 'both';
      if (!['theme', 'wallpaper', 'both'].contains(part)) {
        throw RouteError('bad_params', 'part');
      }
      final raw = p['workspaces'];
      if (raw is! List || raw.any((w) => w is! int || w < 1 || w > 10)) {
        throw RouteError('bad_params', 'workspaces');
      }
      if (part != 'theme') presetWallpaper(ctx, preset);
      final receipt = undo.capture(ctx);
      undo.captureAssignments(ctx, receipt);
      for (final ws in raw.cast<int>()) {
        if (part != 'wallpaper') setWorkspaceTheme(ctx, ws, slug);
        if (part != 'theme') {
          setWorkspaceWallpaper(ctx, slug, ws, preset['wallpaper'] as String?);
        }
      }
      if (part != 'wallpaper') ctx.settings.set('workspace_themes', true);
      if (part != 'theme') ctx.settings.set('workspace_wallpapers', true);
      ctx.automationChanged();
      final workspaces =
          (await helper(ctx, ['workspaces']))['workspaces'] as List? ?? [];
      for (final w in workspaces.whereType<Map>()) {
        if (w['active'] == true) await applyWorkspace(ctx, w['index'] as int);
      }
      return {'assigned': true, 'receipt': receipt, 'appearance': true};
    },
    'presets.undo': (p) async {
      await undo.restore(
        ctx,
        str(p, 'receipt'),
        appearance: boolParam(p, 'appearance', fallback: false),
      );
      return {'undone': true};
    },
    'presets.autostart': (_) => autostartPresets(ctx),
  };
}
