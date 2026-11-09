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
  /// {slug, look, restore?}: replaces the look ({} removes it); the theme in
  /// use gets it at once. restore (Undo) may put back a font no longer installed.
  /// apply: false only stores it (the theme in use then has a pending change, see `pending`).
  'looks.set': (p) async => setLook(ctx, str(p, 'slug'), p['look'], restore: p['restore'] == true, apply: p['apply'] != false),
  /// {slug}: the theme in use gets its stored look now (Reapply).
  'looks.apply': (p) async => reapplyLook(ctx, str(p, 'slug')),
};
