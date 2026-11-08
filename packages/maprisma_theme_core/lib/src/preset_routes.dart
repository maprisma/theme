import 'dart:convert';

import 'apply.dart';
import 'auto.dart';
import 'context.dart';
import 'images.dart';
import 'themes.dart';
import 'presets.dart';
import 'launchers.dart';
import 'workspace_state.dart';

Map<String, Handler> presetRoutes(Ctx ctx) {
  tilingAutomationHook = tilingAutomation;
  final undo = PresetUndo();
  int workspace(Map<String, dynamic> p) =>
      intParam(p, 'workspace', min: 1, max: 10);
  String modeParam(Map<String, dynamic> p, String key) {
    final mode = str(p, key);
    if (!workspaceModeNames.contains(mode)) throw RouteError('bad_params', key);
    return mode;
  }

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
      'desktop': await ctx.desktop.wm(['workspaces']),
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
          if (p['mode'] == null) {
            (s['workspaceModes'] as Map).remove(ws);
          } else {
            s['workspaceModes'][ws] = modeParam(p, 'mode');
          }
        }
      } else if (p.containsKey('defaultMode')) {
        // All Workspaces: the layout for workspaces of this limit.
        final limit = '${intParam(p, 'defaultLimit', min: 1, max: 4)}';
        if (p['defaultMode'] == null) {
          (s['defaultModes'] as Map).remove(limit);
        } else {
          s['defaultModes'][limit] = modeParam(p, 'defaultMode');
        }
      }
    }),

    /// All Workspaces' bulk actions. reset_all: every workspace back to the
    /// default limit and layout; remove_all: every workspace Native (COSMIC's
    /// own tiling, no limit of its own). App Presets stay.
    'workspaces.bulk': (p) {
      final action = str(p, 'action');
      if (!['reset_all', 'remove_all'].contains(action)) {
        throw RouteError('bad_params', 'action');
      }
      return change((s) {
        (s['workspaceCaps'] as Map).clear();
        (s['workspaceModes'] as Map).clear();
        if (action == 'remove_all') {
          for (var ws = 1; ws <= 10; ws++) {
            s['workspaceModes']['$ws'] = 'default';
          }
        }
      });
    },

    /// Every workspace (0 = All Workspaces) as it looks: the theme it shows
    /// (its own or the current one) with the colours the pictures use, the
    /// wallpaper (only a file whose header is sane) and its limit and layout.
    'workspaces.looks': (_) async {
      final s = loadWorkspaces(ctx);
      final current = ctx.current.slug;
      final themesOn = workspaceThemesEnabled(ctx);
      final wallsOn = workspaceWallpapersEnabled(ctx);
      final assigned = loadWorkspaceThemes(ctx);
      final walls = loadWorkspaceMap(ctx);
      final colors = <String, Map<String, String>>{};
      final out = <String, dynamic>{};
      for (var ws = 0; ws <= 10; ws++) {
        final own = ws > 0 ? assigned[ws] : null;
        final slug = themesOn && own != null ? own : current;
        final theme = slug.isEmpty ? null : findTheme(ctx.paths, slug);
        final ownWall = ws > 0 && theme != null
            ? (walls[theme.slug] ?? const <int, String>{})[ws]
            : null;
        String? wallpaper;
        if (theme != null && wallsOn && ownWall != null) {
          wallpaper = wallpaperNamed(ctx, theme, ownWall);
        }
        if (wallpaper == null && theme != null && slug == current) {
          wallpaper = currentBackground(ctx);
        }
        if (wallpaper != null && imageSizeProblem(wallpaper) != null) {
          wallpaper = null;
        }
        var preview = theme?.preview;
        if (preview != null && imageSizeProblem(preview) != null) {
          preview = null;
        }
        if (theme != null && !colors.containsKey(theme.slug)) {
          final all = await themeColors(ctx, theme);
          colors[theme.slug] = {
            for (final k in ['background', 'foreground', 'accent'])
              if (all[k] != null) k: all[k]!,
          };
        }
        out['$ws'] = {
          'theme': theme?.slug,
          'name': theme == null ? null : plainText(theme.name, 40),
          'own_theme': own,
          'own_wallpaper': ownWall,
          'colors': theme == null ? const {} : colors[theme.slug],
          'wallpaper': wallpaper,
          'preview': preview,
          'limit': effectiveLimit(s, ws),
          'mode': effectiveMode(s, ws),
          'own_limit': ws > 0 && (s['workspaceCaps'] as Map).containsKey('$ws'),
          'own_mode': ws > 0 && (s['workspaceModes'] as Map).containsKey('$ws'),
        };
      }
      int? active;
      try {
        active = await activeWorkspace(ctx);
      } on Object {
        active = null;
      }
      return {
        'workspaces': out,
        'current': current,
        'workspace_themes': themesOn,
        'workspace_wallpapers': wallsOn,
        'active_workspace': active,
      };
    },

    /// A workspace's own theme and/or wallpaper (null: none of its own).
    /// The wallpaper belongs to the theme the workspace shows.
    'workspaces.set_look': (p) async {
      final ws = workspace(p);
      final hasTheme = p.containsKey('theme');
      final hasWall = p.containsKey('wallpaper');
      if (!hasTheme && !hasWall) {
        throw RouteError('bad_params', 'theme or wallpaper');
      }
      final slug = hasTheme && p['theme'] != null
          ? ctx.theme(str(p, 'theme')).slug
          : null;
      final name = hasWall && p['wallpaper'] != null
          ? str(p, 'wallpaper')
          : null;
      if (name != null && !validWallpaperName(name)) {
        throw RouteError('bad_params', 'wallpaper');
      }
      final receipt = undo.capture(ctx);
      undo.captureAssignments(ctx, receipt);
      await autoLocked(ctx, () async {
        if (hasTheme) {
          setWorkspaceTheme(ctx, ws, slug);
          if (slug != null) ctx.settings.set('workspace_themes', true);
        }
        if (hasWall) {
          final shown = workspaceThemesEnabled(ctx)
              ? loadWorkspaceThemes(ctx)[ws] ?? ctx.current.slug
              : ctx.current.slug;
          final theme = ctx.theme(shown);
          if (name != null && wallpaperNamed(ctx, theme, name) == null) {
            throw RouteError('not_found', 'Wallpaper missing');
          }
          setWorkspaceWallpaper(ctx, theme.slug, ws, name);
          if (name != null) ctx.settings.set('workspace_wallpapers', true);
        }
        ctx.automationChanged();
        if (await activeWorkspace(ctx) == ws) await applyWorkspace(ctx, ws);
      });
      return {'receipt': receipt, 'appearance': true};
    },
    'workspaces.reset': (_) => change((s) {
      s.clear();
    }),
    /// Gaps of tiled windows and the active window's frame width (KDE:
    /// Krohnkite and the maprisma-active-frame script; wm `tile-style`).
    'tiling.style': (_) async => _wmOrThrow(await ctx.desktop.wm(['tile-style'])),
    /// {top, right, bottom, left, between, border, radius}: any subset; returns
    /// {done, previous} (previous: the values before, for Undo).
    'tiling.style.set': (p) async => _wmOrThrow(await ctx.desktop.wm(['set-tile-style', jsonEncode(p)])),
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
    'apppresets.remove_all': (_) => change((s) {
      (s['workspaceLayouts'] as Map).clear();
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

Map<String, dynamic> _wmOrThrow(Map<String, dynamic>? r) {
  if (r == null) throw RouteError('unavailable', 'the desktop did not answer');
  final e = r['error'];
  if (e != null) throw RouteError('$e', '${r['message'] ?? e}');
  return r;
}
