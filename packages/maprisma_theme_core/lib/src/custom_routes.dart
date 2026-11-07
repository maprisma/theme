import 'context.dart';
import 'custom.dart';

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
};
