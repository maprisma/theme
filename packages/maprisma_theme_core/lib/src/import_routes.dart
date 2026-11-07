import 'apply.dart';
import 'auto.dart';
import 'catalog_cosmic.dart';
import 'catalog_omarchy.dart';
import 'context.dart';
import 'import_net.dart';
import 'plugin_catalog.dart';

/// Applies a just installed theme; the error text when that failed (the
/// theme stays installed).
Future<Map<String, dynamic>> _maybeApply(Ctx ctx, String slug, bool apply) async {
  if (!apply) return {'slug': slug, 'applied': false};
  try {
    await autoLocked(ctx, () async {
      await applyTheme(ctx, slug);
      rememberBaseTheme(ctx, slug);
    });
    return {'slug': slug, 'applied': true};
  } on RouteError catch (e) {
    return {'slug': slug, 'applied': false, 'apply_error': e.message ?? e.code};
  }
}

Set<String> _installedSlugs(Ctx ctx) => {for (final t in ctx.themes()) t.slug};

/// Routes of the import module (docs/protocol.md) and the Information page.
Map<String, Handler> importRoutes(Ctx ctx) => {
  // omarchy.org
  'import.omarchy_list': (p) async {
    final (themes, fetchedAt) = await loadOmarchyCatalog(ctx, force: boolParam(p, 'force', fallback: false));
    final installed = _installedSlugs(ctx);
    return {
      'themes': [
        for (final t in themes)
          {
            ...t.toJson(),
            'preview': cachedOmarchyPreview(ctx, t),
            'installed': installed.contains(t.slug),
          },
      ],
      'fetched_at': fetchedAt.millisecondsSinceEpoch ~/ 1000,
      'gallery': omarchyCatalogUrl,
    };
  },
  'import.omarchy_preview': (p) async {
    final theme = await _omarchyTheme(ctx, str(p, 'slug'));
    return {'path': await omarchyPreview(ctx, theme)};
  },
  'import.omarchy_install': (p) async {
    final theme = await _omarchyTheme(ctx, str(p, 'name'));
    await installOmarchyTheme(ctx, theme);
    return _maybeApply(ctx, theme.slug, boolParam(p, 'apply', fallback: false));
  },

  // cosmic-themes.org
  'import.cosmic_list': (p) async {
    final page = p['page'] == null ? 1 : intParam(p, 'page', min: 1, max: 10000);
    final sort = optStr(p, 'sort');
    if (sort != null && !sortRe.hasMatch(sort)) throw RouteError('bad_params', 'sort');
    final search = optStr(p, 'search');
    if (search != null && search.length > 200) throw RouteError('bad_params', 'search');
    final result = await fetchCosmicList(search: search, sort: sort, page: page);
    final installed = installedCosmicIds(ctx);
    return {
      'themes': [
        for (final t in result.themes) {...t.toJson(), 'installed': installed.containsKey(t.id), 'slug': installed[t.id]},
      ],
      'next_page': result.nextPage,
      'sorts': result.sorts,
    };
  },
  'import.cosmic_install': (p) async {
    final id = intParam(p, 'id', min: 1, max: 999999999);
    if (installedCosmicIds(ctx)[id] case final slug?) {
      throw RouteError('exists', 'this theme is already installed as “$slug”');
    }
    final (ron, entry) = await downloadCosmicRon(id);
    final slug = await installCosmicRon(ctx, id, ron, entry: entry);
    return _maybeApply(ctx, slug, boolParam(p, 'apply', fallback: false));
  },

  // A theme's page (GitHub repository, cosmic-themes.org entry) in the browser.
  'import.open': (p) async {
    final url = str(p, 'url');
    if (!omarchyOpenable(url) && !cosmicOpenable(url)) throw RouteError('bad_url', url);
    return {'opened': await openInBrowser(url, ctx.environment)};
  },

  // Information page.
  'info.plugins': (p) async {
    final record = boolParam(p, 'cached', fallback: false) ? loadPluginCache(ctx) : await refreshPluginCatalog(ctx);
    final plugins = (record['plugins'] as List?)?.cast<Map<String, dynamic>>() ?? const <Map<String, dynamic>>[];
    return {'plugins': pluginCards(plugins), 'checked': record['checked'] ?? 0};
  },
  'info.open': (p) async {
    final id = str(p, 'id');
    if (!pluginIdRe.hasMatch(id)) throw RouteError('bad_params', 'id');
    return {'opened': await openInBrowser(marketplacePage(id), ctx.environment)};
  },
};

/// A gallery theme by slug or (case-insensitively) by name.
Future<OmarchyTheme> _omarchyTheme(Ctx ctx, String name) async {
  final (themes, _) = await loadOmarchyCatalog(ctx);
  for (final t in themes) {
    if (t.slug == name) return t;
  }
  final lower = name.toLowerCase();
  for (final t in themes) {
    if (t.name.toLowerCase() == lower) return t;
  }
  throw RouteError('not_found', 'omarchy.org has no theme $name');
}
