import 'context.dart';
import 'settings_routes.dart';
import 'theme_routes.dart';

/// Every module's routes. Each feature module adds its `xRoutes(ctx)` here
/// (one line each, so parallel work does not collide).
Map<String, Handler> allRoutes(Ctx ctx) => {
  ...themeRoutes(ctx),
  ...settingsRoutes(ctx),
};
