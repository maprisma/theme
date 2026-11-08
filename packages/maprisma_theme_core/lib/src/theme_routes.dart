import 'apply.dart';
import 'auto.dart';
import 'colors.dart';
import 'context.dart';
import 'images.dart';
import 'themes.dart';

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

Map<String, dynamic> themeJson(Ctx ctx, ThemeInfo t, {required String current, required Set<String> hidden,
    required List<String> favorites, required Map<String, double> recent}) => {
  'slug': t.slug,
  'name': t.name,
  'scope': t.scope,
  'current': t.slug == current,
  'hidden': hidden.contains(t.slug),
  'favorite': favorites.contains(t.slug),
  'last_used': recent[t.slug],
  'preview': t.preview != null && imageSizeProblem(t.preview!) == null ? t.preview : null,
  'custom': t.custom,
  'git': t.fromGit,
  'cosmic': t.cosmicNative,
  'kde': t.kdeNative,
  'deletable': !t.system,
  'colors': swatches(t.colors),
  'font': t.font,
};

Map<String, Handler> themeRoutes(Ctx ctx) => {
  'themes.list': (p) async {
    final s = ctx.settings.load();
    final favorites = ctx.lists.favorites, recent = ctx.lists.recent, hidden = ctx.lists.hidden;
    final current = ctx.current.slug;
    final ordered = orderThemes(ctx.themes(), favorites, recent, s['sort'] as String);
    return {
      'themes': [
        for (final t in ordered)
          themeJson(ctx, t, current: current, hidden: hidden, favorites: favorites, recent: recent),
      ],
      'current': current,
      'show_hidden': s['show_hidden'],
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
      final r = await applyTheme(ctx, str(p, 'slug'));
      rememberBaseTheme(ctx, r['applied'] as String); // a manual pick is the base for workspace themes
      return r;
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
