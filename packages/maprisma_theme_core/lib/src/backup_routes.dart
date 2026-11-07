import 'backup.dart';
import 'context.dart';

/// Routes of the backup module: export, preview and restore of the settings
/// and lists, and the health card of Settings › Integration and backup.
Map<String, Handler> backupRoutes(Ctx ctx) {
  String path(Map<String, dynamic> p) {
    final v = str(p, 'path');
    if (!v.startsWith('/') || v.contains('\x00') || v.length > 4096) throw RouteError('bad_params', 'path');
    return v;
  }

  return {
    'backup.default_name': (p) async => {'name': defaultExportName(ctx.clock()), 'folder': ctx.paths.home},
    'backup.export': (p) async {
      final target = path(p);
      exportBackup(ctx, target);
      return {'path': target};
    },
    /// What a restore would replace: the files in the backup and those it removes.
    'backup.preview': (p) async {
      final files = previewBackup(ctx, path(p));
      final current = collectBackup(ctx, broken: {})['files'] as Map;
      return {
        'files': files.keys.toList()..sort(),
        'removes': [for (final k in current.keys) if (!files.containsKey(k)) k]..sort(),
      };
    },
    'backup.restore': (p) async => {'safety_copy': restoreBackup(ctx, path(p))},
    'health.get': (p) async => health(ctx),
    'health.repair': (p) async => repairHealth(ctx),
  };
}
