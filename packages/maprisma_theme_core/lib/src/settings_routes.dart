import 'apply.dart';
import 'colors.dart';
import 'context.dart';
import 'themes.dart';

Map<String, Handler> settingsRoutes(Ctx ctx) => {
  'settings.get': (p) async => {'settings': ctx.settings.load()},
  'settings.set': (p) async {
    final key = str(p, 'key');
    try {
      final s = ctx.settings.set(key, p['value']);
      ctx.automationChanged();
      return {'settings': s};
    } on ArgumentError {
      throw RouteError('bad_params', key);
    }
  },
  'settings.reset': (p) async {
    final s = ctx.settings.reset();
    ctx.automationChanged();
    return {'settings': s};
  },
  /// The desktop's look; where the desktop has none to tell (no backend),
  /// the applied theme's colors.
  'desktop.look': (p) async {
    var cur = await ctx.desktop.current();
    if (cur == null && ctx.current.slug.isNotEmpty) {
      final theme = findTheme(ctx.paths, ctx.current.slug);
      if (theme != null) {
        final c = colorsObject(await themeColors(ctx, theme));
        if (isHex(c['background']) && isHex(c['foreground'])) {
          cur = {
            'colors': {'background': c['background'], 'foreground': c['foreground'], 'accent': c['accent'] ?? c['foreground']},
            'is_dark': luminance(c['background']!) < 0.5,
          };
        }
      }
    }
    return {
      'desktop': ctx.desktop.id,
      'colors': cur?['colors'] ?? const {},
      'is_dark': cur?['is_dark'] ?? true,
      'corner_radius': cur?['corner_radius'],
      'theme': ctx.current.slug,
    };
  },
};
