import 'ask_routes.dart';
import 'auto_routes.dart';
import 'backup_routes.dart';
import 'context.dart';
import 'custom_routes.dart';
import 'import_routes.dart';
import 'preset_routes.dart';
import 'settings_routes.dart';
import 'shortcut_routes.dart';
import 'theme_routes.dart';
import 'wallpaper_routes.dart';

/// Every module's routes; each module owns its own `*_routes.dart`.
Map<String, Handler> allRoutes(Ctx ctx) => {
  ...themeRoutes(ctx),
  ...settingsRoutes(ctx),
  ...wallpaperRoutes(ctx),
  ...customRoutes(ctx),
  ...autoRoutes(ctx),
  ...shortcutRoutes(ctx),
  ...importRoutes(ctx),
  ...presetRoutes(ctx),
  ...askRoutes(ctx),
  ...backupRoutes(ctx),
};
