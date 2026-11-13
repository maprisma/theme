import 'apply.dart';
import 'auto.dart';
import 'colors.dart';
import 'context.dart';
import 'i18n.dart';
import 'images.dart';
import 'themes.dart';
import 'looks.dart';

const maxFavorites = 50;

/// Favorites first (in the order they were added), then the rest by name or
/// by last use (theme_auto.order_themes).
List<ThemeInfo> orderThemes(List<ThemeInfo> themes, List<String> favorites, Map<String, double> recent, String sort) {
  final pos = {for (var i = 0; i < favorites.length; i++) favorites[i]: i};
  final favs = themes.where((t) => pos.containsKey(t.slug)).toList()..sort((a, b) => pos[a.slug]!.compareTo(pos[b.slug]!));
  final rest = themes.where((t) => !pos.containsKey(t.slug)).toList();
  if (sort == 'recent') {
    rest.sort((a, b) {
      final c = (recent[b.slug] ?? 0).compareTo(recent[a.slug] ?? 0);
      return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }
  return [...favs, ...rest];
}

/// The colors a list tile shows (the swatches and the tile's own look).
Map<String, String> swatches(Map<String, String> resolved) => {
  for (final k in ['mode', 'background', 'foreground', 'accent', 'selection', 'muted', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan'])
    if (resolved[k] != null) k: resolved[k]!,
};

Map<String, dynamic> themeJson(
  Ctx ctx,
  ThemeInfo t, {
  required String current,
  required Set<String> hidden,
  required List<String> favorites,
  required Map<String, double> recent,
  Map<String, Set<String>>? hiddenWallpapers,
  Map<String, String>? chosen,
  String? currentBg,
}) {
  final preview = t.preview != null && imageSizeProblem(t.preview!) == null ? t.preview : null;
  final isCurrent = t.slug == current;
  return {
    'slug': t.slug,
    'name': t.name,
    'scope': t.scope,
    'current': isCurrent,
    'hidden': hidden.contains(t.slug),
    'favorite': favorites.contains(t.slug),
    'last_used': recent[t.slug],
    'preview': preview,
    // The wallpaper remembered for it (a card shows it pinned only then).
    'chosen_wallpaper': (chosen ?? chosenWallpapers(ctx))[t.slug],
    ...(() {
      final walls = preview == null
          ? const <String>[]
          : flipWallpapers(ctx, t, isCurrent: isCurrent, hidden: hiddenWallpapers, chosen: chosen, currentBg: currentBg);
      return {
        'wallpapers': walls,
        // The theme in use: the one of its wallpapers the desktop really shows (same file), or null.
        'pinned_wallpaper': isCurrent ? pinnedOfCurrent(ctx, walls, currentBg: currentBg) : null,
      };
    })(),
    'custom': t.custom,
    'git': t.fromGit,
    'cosmic': t.cosmicNative,
    'kde': t.kdeNative,
    'deletable': !t.system,
    'colors': swatches(t.colors),
    'font': t.font,
  };
}

Map<String, Handler> themeRoutes(Ctx ctx) => {
  'themes.list': (p) async {
    final s = ctx.settings.load();
    final favorites = ctx.lists.favorites, recent = ctx.lists.recent, hidden = ctx.lists.hidden;
    final hiddenWalls = loadHiddenWallpapers(ctx.paths);
    final chosen = chosenWallpapers(ctx);
    final current = ctx.current.slug;
    final activeBg = currentBackground(ctx);
    final ordered = orderThemes(ctx.themes(), favorites, recent, s['sort'] as String);
    // the theme in use: which of its fonts and blur aren't on the desktop now (Reapply)
    final inUse = ordered.where((t) => t.slug == current).firstOrNull;
    final pending = inUse == null ? const <String>[] : await lookPending(ctx, inUse);
    return {
      'themes': [
        for (final t in ordered)
          {
            ...themeJson(
              ctx,
              t,
              current: current,
              hidden: hidden,
              favorites: favorites,
              recent: recent,
              hiddenWallpapers: hiddenWalls,
              chosen: chosen,
              currentBg: activeBg,
            ),
            if (t.slug == current) 'pending': pending,
          },
      ],
      'current': current,
      'current_wallpaper': activeBg,
      'show_hidden': s['show_hidden'],
    };
  },
  // A short list for other apps (Maprisma Manager's Theme page; CLI `list`): the order of
  // themes.list, each with its name, preview picture, swatch colours, marks and the wallpapers
  // its card flips to (as themes.list, the one in use first by Theme's own record of it), and the
  // preview settings, so the other app turns its cards as Theme does. Nothing asks the desktop
  // (no pending looks, no desktop wallpaper query), so it is quick.
  'themes.brief': (p) async {
    final s = ctx.settings.load();
    final favorites = ctx.lists.favorites, hidden = ctx.lists.hidden;
    final current = ctx.current.slug;
    final hiddenWalls = loadHiddenWallpapers(ctx.paths);
    final chosen = chosenWallpapers(ctx);
    final recordedBg = ctx.current.wallpaper ?? '';
    return {
      'current': current,
      'themes': [
        for (final t in orderThemes(ctx.themes(), favorites, ctx.lists.recent, s['sort'] as String))
          (() {
            final preview = t.preview != null && imageSizeProblem(t.preview!) == null ? t.preview : null;
            return {
              'slug': t.slug,
              'name': t.name,
              'current': t.slug == current,
              'favorite': favorites.contains(t.slug),
              'hidden': hidden.contains(t.slug),
              'preview': preview,
              'wallpapers': preview == null
                  ? const <String>[]
                  : flipWallpapers(ctx, t, isCurrent: t.slug == current, hidden: hiddenWalls, chosen: chosen, currentBg: recordedBg),
              'colors': swatches(t.colors),
            };
          })(),
      ],
      'settings': {
        for (final k in ['preview_flip_3d', 'preview_flip_delay', 'preview_big_auto_rotate']) k: s[k],
      },
    };
  },
  'themes.get': (p) async {
    final t = ctx.theme(str(p, 'slug'));
    return {
      ...themeJson(ctx, t, current: ctx.current.slug, hidden: ctx.lists.hidden, favorites: ctx.lists.favorites, recent: ctx.lists.recent),
      'colors_all': colorsObject(await themeColors(ctx, t)),
      'icon_theme': t.iconTheme,
      'dir': t.dir,
    };
  },
  'themes.apply': (p) async {
    // One apply at a time, also against the applet's automation (CLI) runs.
    return autoLocked(ctx, () async {
      final slug = str(p, 'slug');
      final wp = optStr(p, 'wallpaper');
      String? wpName;
      if (wp != null) {
        final theme = ctx.theme(slug);
        final w = listBackgrounds(ctx.paths, theme).where((x) => x.path == wp && !x.hidden).firstOrNull;
        if (w == null) throw RouteError('not_found', trf("not a visible wallpaper of {0}", [theme.name]));
        final problem = imageSizeProblem(wp);
        if (problem != null) throw RouteError('bad_image', problem);
        wpName = w.name;
      }
      // The wallpaper goes to applyTheme directly; it is remembered for the theme only once it really
      // is on the desktop (nothing remembered in advance, so nothing to put back after a failure).
      final r = await applyTheme(ctx, slug, wallpaper: wp);
      final applied = r['applied'] as String;
      rememberBaseTheme(ctx, applied); // a manual pick is the base for workspace themes
      final wallpaperSet = (r['done'] as List).contains('wallpaper');
      if (wp != null && wallpaperSet) {
        rememberWallpaper(ctx, slug, wpName!);
        rememberBaseWallpaper(ctx, applied, wp);
      }
      return {...r, if (wp != null) 'wallpaper_set': wallpaperSet};
    });
  },
  // After a delete's Undo expired: favorites, keys, workspace and day/night entries go too.
  'themes.forget': (p) async {
    final slug = str(p, 'slug');
    if (!slugRe.hasMatch(slug)) throw RouteError('bad_params', 'slug');
    if (findTheme(ctx.paths, slug) != null) return {'forgotten': false};
    forgetThemeState(ctx, slug);
    ctx.automationChanged();
    return {'forgotten': true};
  },
  'themes.hide': (p) async {
    final slug = ctx.theme(str(p, 'slug')).slug;
    final hidden = ctx.lists.hidden;
    if (boolParam(p, 'hidden')) {
      hidden.add(slug);
    } else {
      hidden.remove(slug);
    }
    ctx.lists.hidden = hidden;
    return {'hidden': hidden.contains(slug)};
  },
  'themes.favorite': (p) async {
    final slug = ctx.theme(str(p, 'slug')).slug;
    final favs = ctx.lists.favorites..remove(slug);
    if (boolParam(p, 'favorite')) favs.add(slug);
    ctx.lists.favorites = favs.take(maxFavorites).toList();
    return {'favorites': ctx.lists.favorites};
  },
};
