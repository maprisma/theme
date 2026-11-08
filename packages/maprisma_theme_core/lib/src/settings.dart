import 'paths.dart';
import 'store.dart';

/// settings.json: the plugin's keys (Theme Manager 2.0.0), minus Omarchy's
/// picker sync and the language, plus `apps` (which app templates are used).
const defaultSettings = <String, dynamic>{
  'size': null,
  'workspace_wallpapers': true,
  'workspace_themes': false,
  'corners': 'windows', // windows, rounded, square
  'sort': 'name', // name, recent
  'slideshow_minutes': 0, // 0 = never, else 5..120
  'schedule': {'enabled': false, 'day': '', 'night': '', 'day_at': '07:00', 'night_at': '19:00'},
  'screenshot_key': true,
  'screenshot_dir': null,
  'ask_ai': false,
  'ask_ai_helper': null,
  'ask_prompts': null,
  'maprisma_hints': true,
  'header_order': ['import', 'hidden', 'presets', 'ask', 'info'], // the plugin's header_order.DEFAULT
  'own_font': null,
  'apps': null, // null = every installed app; else a list of app ids (apps.dart)
  'show_hidden': false,
};

const slideshowChoices = [0, 5, 10, 15, 30, 60, 120];
final _time = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

/// The settings with defaults filled in and every value checked.
final class Settings {
  Settings(this.paths);
  final Paths paths;

  Map<String, dynamic> load() {
    final raw = readJsonMap(paths.settingsFile);
    final out = <String, dynamic>{};
    for (final e in defaultSettings.entries) {
      final v = raw.containsKey(e.key) ? raw[e.key] : e.value;
      out[e.key] = check(e.key, v) ? v : e.value;
    }
    if (out['schedule'] is Map) {
      final s = Map<String, dynamic>.from(defaultSettings['schedule'] as Map)..addAll(Map<String, dynamic>.from(out['schedule']));
      out['schedule'] = s;
    }
    return out;
  }

  dynamic get(String key) => load()[key];

  /// Sets one key (refuses values that do not fit); returns the settings.
  Map<String, dynamic> set(String key, dynamic value) {
    if (!defaultSettings.containsKey(key) || !check(key, value)) {
      throw ArgumentError.value(value, key);
    }
    final raw = readJsonMap(paths.settingsFile);
    raw[key] = value;
    writeJson(paths.settingsFile, raw);
    return load();
  }

  /// Reset to defaults keeps shortcuts, favorites, hidden themes, the day
  /// and night themes (as the plugin); the header button order and the
  /// screenshot key and folder go back to their defaults too.
  Map<String, dynamic> reset() {
    final raw = readJsonMap(paths.settingsFile);
    final keep = <String, dynamic>{
      for (final k in ['size', 'ask_ai', 'ask_ai_helper', 'ask_prompts', 'own_font', 'apps'])
        if (raw.containsKey(k)) k: raw[k],
    };
    final old = raw['schedule'] is Map ? Map<String, dynamic>.from(raw['schedule']) : <String, dynamic>{};
    keep['schedule'] = {
      ...Map<String, dynamic>.from(defaultSettings['schedule'] as Map),
      if (old['day'] is String) 'day': old['day'],
      if (old['night'] is String) 'night': old['night'],
    };
    keep['workspace_wallpapers'] = true;
    writeJson(paths.settingsFile, keep);
    return load();
  }

  static bool check(String key, dynamic v) => switch (key) {
    'size' => v == null || (v is List && v.length == 2 && v.every((e) => e is int && e >= 320 && e <= 10000)),
    'workspace_wallpapers' || 'workspace_themes' || 'screenshot_key' || 'ask_ai' || 'maprisma_hints' || 'show_hidden' =>
      v is bool,
    'corners' => v is String && const {'windows', 'rounded', 'square'}.contains(v),
    'sort' => v is String && const {'name', 'recent'}.contains(v),
    'slideshow_minutes' => v is int && slideshowChoices.contains(v),
    'schedule' => v is Map &&
        (v['enabled'] == null || v['enabled'] is bool) &&
        (v['day'] == null || v['day'] is String) &&
        (v['night'] == null || v['night'] is String) &&
        (v['day_at'] == null || (v['day_at'] is String && _time.hasMatch(v['day_at']))) &&
        (v['night_at'] == null || (v['night_at'] is String && _time.hasMatch(v['night_at']))),
    'screenshot_dir' => v == null || (v is String && v.startsWith('/') && v.length < 1024),
    'ask_ai_helper' => v == null || (v is String && v.length < 200),
    'ask_prompts' => v == null || (v is List && v.length <= 12 && v.every((e) => e is String && e.length <= 600)),
    'header_order' => v is List && v.every((e) => e is String) && v.toSet().length == v.length,
    'own_font' => v == null || (v is String && v.length < 100),
    'apps' => v == null || (v is List && v.every((e) => e is String)),
    _ => false,
  };
}
