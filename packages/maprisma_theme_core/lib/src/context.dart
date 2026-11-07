import 'desktop.dart';
import 'paths.dart';
import 'settings.dart';
import 'themes.dart';

/// A core route: params in, result out; throw [RouteError] for a refusal.
typedef Handler = Future<Map<String, dynamic>> Function(Map<String, dynamic> params);

final class RouteError implements Exception {
  RouteError(this.code, [this.message]);
  final String code;
  final String? message;
  @override
  String toString() => 'RouteError($code${message == null ? '' : ': $message'})';
}

/// What every feature module gets: where things are, the desktop, the
/// environment, and the shared lists.
final class Ctx {
  Ctx({required this.paths, required this.desktop, required this.environment, DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  final Paths paths;
  final Desktop desktop;
  final Map<String, String> environment;
  final DateTime Function() clock;

  late final settings = Settings(paths);
  late final lists = Lists(paths);
  late final current = Current(paths);

  /// Called after anything that changes what the applet's automation needs
  /// (settings, workspace assignments, presets): rewrites automation.json.
  void Function()? onAutomationChange;
  void automationChanged() => onAutomationChange?.call();

  List<ThemeInfo> themes() => discoverThemes(paths);
  ThemeInfo theme(String? slug) {
    if (slug == null) throw RouteError('bad_params', 'slug');
    final t = findTheme(paths, slug);
    if (t == null) throw RouteError('not_found', 'no theme $slug');
    return t;
  }
}

String str(Map<String, dynamic> p, String key) {
  final v = p[key];
  if (v is! String || v.isEmpty) throw RouteError('bad_params', key);
  return v;
}

String? optStr(Map<String, dynamic> p, String key) {
  final v = p[key];
  return v is String && v.isNotEmpty ? v : null;
}

int intParam(Map<String, dynamic> p, String key, {int? min, int? max}) {
  final v = p[key];
  if (v is! int || (min != null && v < min) || (max != null && v > max)) throw RouteError('bad_params', key);
  return v;
}

bool boolParam(Map<String, dynamic> p, String key, {bool? fallback}) {
  final v = p[key];
  if (v is bool) return v;
  if (fallback != null) return fallback;
  throw RouteError('bad_params', key);
}
