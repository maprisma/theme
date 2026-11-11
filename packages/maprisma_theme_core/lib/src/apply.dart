import 'i18n.dart';
import 'dart:io';

import 'apps.dart';
import 'colors.dart';
import 'context.dart';
import 'desktop.dart';
import 'images.dart';
import 'looks.dart';
import 'store.dart';
import 'themes.dart';

/// The wallpaper last chosen per theme (Omarchy's theme-backgrounds state).
Map<String, String> chosenWallpapers(Ctx ctx) => {
  for (final e in readJsonMap('${ctx.paths.state}/theme-backgrounds.json').entries)
    if (e.value is String) e.key: e.value as String,
};

void rememberWallpaper(Ctx ctx, String slug, String name) {
  final m = chosenWallpapers(ctx)..[slug] = name;
  writeJson('${ctx.paths.state}/theme-backgrounds.json', m);
}

bool _sameFile(String a, String b) {
  if (a == b) return true;
  try {
    return File(a).resolveSymbolicLinksSync() == File(b).resolveSymbolicLinksSync();
  } on FileSystemException {
    return false;
  }
}

/// The visible wallpapers cycled on a theme card's 3D flip: rotated so the
/// active desktop wallpaper comes first when [isCurrent], or the theme's
/// remembered wallpaper comes first otherwise.
List<String> flipWallpapers(
  Ctx ctx,
  ThemeInfo theme, {
  required bool isCurrent,
  Map<String, Set<String>>? hidden,
  Map<String, String>? chosen,
  String? currentBg,
}) {
  var visible = [
    for (final w in listBackgrounds(ctx.paths, theme, hidden: hidden))
      if (!w.hidden && imageSizeProblem(w.path) == null) w.path,
  ];
  if (visible.isEmpty) return const [];
  if (isCurrent) {
    final bg = currentBg ?? ctx.desktop.wallpaper() ?? ctx.current.wallpaper;
    if (bg != null) {
      final index = visible.indexWhere((p) => p == bg || baseName(p) == baseName(bg));
      if (index > 0) visible = [...visible.sublist(index), ...visible.sublist(0, index)];
    }
  } else {
    final remembered = (chosen ?? chosenWallpapers(ctx))[theme.slug];
    if (remembered != null && remembered.isNotEmpty) {
      final index = visible.indexWhere((p) => baseName(p) == remembered);
      if (index > 0) visible = [...visible.sublist(index), ...visible.sublist(0, index)];
    }
  }
  if (visible.length == 1 && theme.preview != null && _sameFile(theme.preview!, visible.first)) {
    return const [];
  }
  return visible;
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
  // A look's text colour in place of the theme's foreground (theme files stay as they are).
  final textColor = lookTextColor(ctx, theme);
  var resolved = await themeColors(ctx, theme);
  if (textColor != null) resolved = {...resolved, 'foreground': textColor};
  if (!isHex(resolved['background']) || !isHex(resolved['foreground'])) {
    throw RouteError('bad_theme', tr("the theme has no usable colors"));
  }
  final object = colorsObject(resolved);
  final desktop = ctx.desktop;
  final done = <String>[];
  if (desktop.caps.contains(Cap.appearance)) {
    final ok = theme.kdeNative && desktop.caps.contains(Cap.kdeScheme)
        ? await desktop.applyKdeScheme('${theme.dir}/kde.colors', foreground: textColor)
        // a COSMIC RON theme with a text colour goes as its colours (the RON has no single text colour)
        : theme.cosmicNative && desktop.caps.contains(Cap.ron) && textColor == null
        ? await desktop.applyRon('${theme.dir}/cosmic.ron')
        : await desktop.applyColors(object);
    if (!ok) {
      throw RouteError(
        'apply_failed',
        desktop.id == 'cosmic'
            ? 'COSMIC did not take the theme (is maprisma-theme-helper installed?)'
            : trf("{0} did not take the theme", [desktop.name]),
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
  for (final key in await applyLook(ctx, theme)) {
    done.add(key == 'mono_font' ? 'font' : key);
  }
  if (await ctx.desktop.setTerminal(object, theme.name)) done.add('terminal');
  done.addAll(await applyAppTemplates(ctx, theme, resolved));
  markTextColorApplied(ctx, slug, textColor);

  if (remember) {
    ctx.lists.markUsed(slug, at: ctx.clock());
    final hidden = ctx.lists.hidden;
    if (hidden.remove(slug)) ctx.lists.hidden = hidden; // applying unhides
  }
  return {'applied': slug, 'done': done};
}

/// Sets the background of the theme in use (and remembers it for the theme).
Future<bool> setBackground(Ctx ctx, String path, {bool remember = true}) async {
  if (!await ctx.desktop.setWallpaper(path)) return false;
  final slug = ctx.current.slug;
  ctx.current.save(wallpaper: path);
  if (remember && slug.isNotEmpty) rememberWallpaper(ctx, slug, baseName(path));
  return true;
}
