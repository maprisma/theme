import 'context.dart';
import 'custom.dart';
import 'looks.dart';

/// Routes of the custom module (docs/agents.md, module B).
Map<String, Handler> customRoutes(Ctx ctx) => {
  'custom.editor': (p) async =>
      editorData(ctx, base: optStr(p, 'base'), edit: optStr(p, 'edit'), wallpaper: optStr(p, 'wallpaper')),
  'custom.save': (p) async => saveCustom(ctx, p),
  'custom.from_wallpaper': (p) async => fromWallpaper(ctx, str(p, 'path')),
  'fonts.list': (p) async => {
    'fonts': (await ctx.desktop.monospaceFonts()).where(fontRe.hasMatch).take(200).toList(),
    'current': ctx.desktop.monospaceFont(),
  },
  /// {slug}: a theme's look with what the theme brings, the fonts in use and the choices.
  'looks.get': (p) async => lookData(ctx, str(p, 'slug')),
  /// {slug, look}: replaces the look ({} removes it); the theme in use gets it at once.
  'looks.set': (p) async => setLook(ctx, str(p, 'slug'), p['look']),
};
