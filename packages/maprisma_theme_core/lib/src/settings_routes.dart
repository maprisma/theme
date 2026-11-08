import 'context.dart';

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
  'desktop.look': (p) async {
    final cur = await ctx.desktop.current();
    return {
      'desktop': ctx.desktop.id,
      'colors': cur?['colors'] ?? const {},
      'is_dark': cur?['is_dark'] ?? true,
      'corner_radius': cur?['corner_radius'],
      'theme': ctx.current.slug,
    };
  },
};
