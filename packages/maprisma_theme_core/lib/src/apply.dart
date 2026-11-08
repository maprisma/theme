import 'dart:io';

import 'apps.dart';
import 'colors.dart';
import 'context.dart';
import 'desktop.dart';
import 'store.dart';
import 'themes.dart';

/// `own_font` when the user had COSMIC's default monospace font.
const defaultFontMark = '(default)';

/// The wallpaper last chosen per theme (Omarchy's theme-backgrounds state).
Map<String, String> chosenWallpapers(Ctx ctx) => {
  for (final e in readJsonMap('${ctx.paths.state}/theme-backgrounds.json').entries)
    if (e.value is String) e.key: e.value as String,
};

void rememberWallpaper(Ctx ctx, String slug, String name) {
  final m = chosenWallpapers(ctx)..[slug] = name;
  writeJson('${ctx.paths.state}/theme-backgrounds.json', m);
}

/// The wallpaper a theme starts with: the one chosen last, else the first visible.
WallpaperInfo? startWallpaper(Ctx ctx, ThemeInfo theme) {
  final visible = visibleBackgrounds(ctx.paths, theme);
  if (visible.isEmpty) return null;
  final name = chosenWallpapers(ctx)[theme.slug];
  return visible.firstWhere((w) => w.name == name, orElse: () => visible.first);
}

/// The colors object for a theme (its cosmic.ron's colors when it is native
/// and has no colors.toml of its own).
Future<Map<String, String>> themeColors(Ctx ctx, ThemeInfo theme) async {
  var resolved = theme.colors;
  if (!isHex(resolved['background']) && theme.cosmicNative) {
    final fromRon = await ctx.desktop.ronColors('${theme.dir}/cosmic.ron');
    if (fromRon != null) resolved = resolveColors(fromRon);
  }
  return resolved;
}

/// Applies a theme everywhere (docs/plan.md, "Apply theme"): the desktop's
/// own theme, the wallpaper, icons, font, the desktop's terminal and the app
/// templates; whatever the desktop backend cannot do is left out
/// (docs/multi-desktop.md), so on a desktop without a backend only the app
/// templates change. A COSMIC RON theme is applied as its colors where the
/// desktop cannot take RON files.
/// [wallpaper]: a file to show instead of the theme's start wallpaper.
Future<Map<String, dynamic>> applyTheme(Ctx ctx, String slug, {String? wallpaper, bool remember = true}) async {
  final theme = ctx.theme(slug);
  final resolved = await themeColors(ctx, theme);
  if (!isHex(resolved['background']) || !isHex(resolved['foreground'])) {
    throw RouteError('bad_theme', 'the theme has no usable colors');
  }
  final object = colorsObject(resolved);
  final desktop = ctx.desktop;
  final done = <String>[];
  if (desktop.caps.contains(Cap.appearance)) {
    final ok = theme.kdeNative && desktop.caps.contains(Cap.kdeScheme)
        ? await desktop.applyKdeScheme('${theme.dir}/kde.colors')
        : theme.cosmicNative && desktop.caps.contains(Cap.ron)
        ? await desktop.applyRon('${theme.dir}/cosmic.ron')
        : await desktop.applyColors(object);
    if (!ok) {
      throw RouteError(
        'apply_failed',
        desktop.id == 'cosmic'
            ? 'COSMIC did not take the theme (is maprisma-theme-helper installed?)'
            : '${desktop.name} did not take the theme',
      );
    }
    done.add(desktop.id);
  }
  final wp = wallpaper ?? startWallpaper(ctx, theme)?.path;
  if (wp != null && File(wp).existsSync() && await ctx.desktop.setWallpaper(wp)) {
    done.add('wallpaper');
    ctx.current.save(slug: slug, wallpaper: wp);
  } else {
    ctx.current.save(slug: slug, clearWallpaper: true);
  }
  final icons = theme.iconTheme;
  if (icons != null && await ctx.desktop.setIconTheme(icons)) done.add('icons');
  if (desktop.caps.contains(Cap.fonts) && await _applyFont(ctx, theme)) done.add('font');
  if (await ctx.desktop.setTerminal(object, theme.name)) done.add('terminal');
  done.addAll(await applyAppTemplates(ctx, theme, resolved));

  if (remember) {
    ctx.lists.markUsed(slug, at: ctx.clock());
    final hidden = ctx.lists.hidden;
    if (hidden.remove(slug)) ctx.lists.hidden = hidden; // applying unhides
  }
  return {'applied': slug, 'done': done};
}

/// The setting that keeps the user's own font: one per desktop, as each has
/// its own monospace font (COSMIC keeps the old name).
String ownFontKey(Desktop d) => d.id == 'kde' ? 'own_font_kde' : 'own_font';

/// A theme's own font, and the user's own font back for any other theme.
Future<bool> _applyFont(Ctx ctx, ThemeInfo theme) async {
  final key = ownFontKey(ctx.desktop);
  final own = ctx.settings.get(key) as String?;
  final themed = theme.font;
  if (themed != null) {
    final now = ctx.desktop.monospaceFont();
    if (now == themed) return false;
    if (!await ctx.desktop.setMonospaceFont(themed)) return false;
    // The font to go back to; COSMIC's default when none was set.
    if (own == null) ctx.settings.set(key, now ?? defaultFontMark);
    return true;
  }
  if (own != null) {
    final ok = own == defaultFontMark ? await ctx.desktop.resetMonospaceFont() : await ctx.desktop.setMonospaceFont(own);
    if (ok) ctx.settings.set(key, null); // kept until the user's font is really back
    return ok;
  }
  return false;
}

/// Sets the background of the theme in use (and remembers it for the theme).
Future<bool> setBackground(Ctx ctx, String path, {bool remember = true}) async {
  if (!await ctx.desktop.setWallpaper(path)) return false;
  final slug = ctx.current.slug;
  ctx.current.save(wallpaper: path);
  if (remember && slug.isNotEmpty) rememberWallpaper(ctx, slug, baseName(path));
  return true;
}
