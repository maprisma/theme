import 'i18n.dart';
import 'apply.dart';
import 'apps.dart';
import 'auto.dart';
import 'context.dart';

/// Routes of the auto module: the applet's CLI steps, workspace wallpapers
/// and themes, day and night, and the app colors of Settings › Themes.
Map<String, Handler> autoRoutes(Ctx ctx) {
  ctx.onAutomationChange = () {
    try {
      writeAutomation(ctx);
    } on Object {
      // never break the change that asked for it
    }
  };
  // automation.json is written once by CoreService, after every module set its hooks.

  int direction(Map<String, dynamic> p) {
    final d = p['direction'];
    if (d == 1 || d == -1) return d as int;
    if (d == 'next') return 1;
    if (d == 'prev') return -1;
    throw RouteError('bad_params', 'direction');
  }

  List<int> workspaces(Map<String, dynamic> p) {
    final v = p['workspaces'];
    if (v is! List || v.any((w) => w is! int || w < 1 || w > maxWorkspace)) throw RouteError('bad_params', 'workspaces');
    return v.cast<int>().toSet().toList()..sort();
  }

  /// After an assignment: the workspace in front may have just got (or lost) its own.
  Future<void> refreshFocused({int? only}) async {
    final active = await activeWorkspace(ctx);
    if (active == null || (only != null && active != only)) return;
    await applyWorkspace(ctx, active);
  }

  Map<String, dynamic> scheduleJson() => {'schedule': schedule(ctx)};

  return {
    'auto.step_background': (p) async {
      final d = direction(p);
      return {'wallpaper': await autoLocked(ctx, () => stepBackground(ctx, d))};
    },
    'auto.step_theme': (p) async {
      final d = direction(p);
      return {'theme': await autoLocked(ctx, () => stepTheme(ctx, d))};
    },
    'auto.workspace': (p) async {
      final ws = intParam(p, 'workspace', min: 1, max: maxWorkspace);
      final wallpaper = await autoLocked(ctx, () => applyWorkspace(ctx, ws));
      return {'workspace': ws, 'theme': ctx.current.slug, 'wallpaper': wallpaper};
    },
    'auto.tick': (p) async => autoLocked(ctx, () => tick(ctx)),
    'auto.menu': (p) async => menuData(ctx),

    'auto.schedule': (p) async => scheduleJson(),
    'auto.schedule_set': (p) async {
      final values = <String, dynamic>{};
      for (final k in ['day', 'night']) {
        if (!p.containsKey(k)) continue;
        final v = p[k];
        if (v == null || v == '') {
          values[k] = '';
        } else if (v is String) {
          values[k] = ctx.theme(v).slug;
        } else {
          throw RouteError('bad_params', k);
        }
      }
      for (final k in ['day_at', 'night_at']) {
        if (!p.containsKey(k)) continue;
        final v = p[k];
        if (v is! String || !timeRe.hasMatch(v)) throw RouteError('bad_params', k);
        values[k] = v;
      }
      if (p.containsKey('enabled')) values['enabled'] = boolParam(p, 'enabled');
      saveSchedule(ctx, values);
      ctx.automationChanged();
      return scheduleJson();
    },

    'auto.workspace_themes': (p) async => {
      'themes': {for (final e in loadWorkspaceThemes(ctx).entries) '${e.key}': e.value},
      'enabled': workspaceThemesEnabled(ctx),
    },
    /// The workspaces [slug] is used on (the others lose it).
    'auto.set_workspace_themes': (p) async {
      final slug = ctx.theme(str(p, 'slug')).slug;
      final wanted = workspaces(p);
      await autoLocked(ctx, () async {
        final now = loadWorkspaceThemes(ctx);
        for (final e in now.entries) {
          if (e.value == slug && !wanted.contains(e.key)) setWorkspaceTheme(ctx, e.key, null);
        }
        for (final ws in wanted) {
          setWorkspaceTheme(ctx, ws, slug);
        }
        if (wanted.isNotEmpty && !workspaceThemesEnabled(ctx)) ctx.settings.set('workspace_themes', true);
        ctx.automationChanged();
        await refreshFocused();
      });
      return {
        'themes': {for (final e in loadWorkspaceThemes(ctx).entries) '${e.key}': e.value},
        'enabled': workspaceThemesEnabled(ctx),
      };
    },
    'auto.use_everywhere': (p) async => {'saved': await autoLocked(ctx, () async => useEverywhere(ctx))},
    'auto.undo_use_everywhere': (p) async {
      final saved = p['saved'];
      if (saved is! Map) throw RouteError('bad_params', 'saved');
      final restored = await autoLocked(ctx, () async {
        final ok = undoUseEverywhere(ctx, saved);
        if (ok) await refreshFocused(); // its own theme again, if it has one
        return ok;
      });
      if (!restored) throw RouteError('changed', tr("The workspaces' themes changed meanwhile."));
      return {'restored': true};
    },

    'auto.workspace_wallpapers': (p) async {
      final slug = ctx.theme(str(p, 'slug')).slug;
      return {
        'map': {for (final e in (loadWorkspaceMap(ctx)[slug] ?? const <int, String>{}).entries) '${e.key}': e.value},
        'enabled': workspaceWallpapersEnabled(ctx),
      };
    },
    /// Wallpaper [name] of [slug] on exactly [workspaces] (empty: none).
    'auto.set_workspace_wallpaper': (p) async {
      final theme = ctx.theme(str(p, 'slug'));
      final name = str(p, 'name');
      if (!validWallpaperName(name)) throw RouteError('bad_params', 'name');
      final wanted = workspaces(p);
      var switchedOn = false;
      await autoLocked(ctx, () async {
        clearWallpaperWorkspaces(ctx, theme.slug, name);
        for (final ws in wanted) {
          setWorkspaceWallpaper(ctx, theme.slug, ws, name);
        }
        if (wanted.isNotEmpty && !workspaceWallpapersEnabled(ctx)) {
          ctx.settings.set('workspace_wallpapers', true);
          switchedOn = true;
        }
        ctx.automationChanged();
        if (ctx.current.slug == theme.slug) {
          final active = await activeWorkspace(ctx);
          if (active != null) await onWorkspace(ctx, active);
        }
      });
      return {
        'map': {for (final e in (loadWorkspaceMap(ctx)[theme.slug] ?? const <int, String>{}).entries) '${e.key}': e.value},
        'switched_on': switchedOn,
      };
    },

    'apps.list': (p) async => {'apps': appsList(ctx)},
    'apps.set': (p) async {
      final slug = ctx.current.slug;
      Map<String, String>? resolved;
      if (slug.isNotEmpty) {
        try {
          resolved = await themeColors(ctx, ctx.theme(slug));
        } on RouteError {
          resolved = null;
        }
      }
      return setAppEnabled(ctx, str(p, 'id'), boolParam(p, 'enabled'), resolved);
    },
  };
}
