import 'dart:convert';

import 'paths.dart';
import 'store.dart';

/// settings.json: the plugin's keys (Theme Manager 2.0.0), minus Omarchy's
/// picker sync, plus `apps` (which app templates are used).
const defaultSettings = <String, dynamic>{
  'language': 'auto',
  'size': null,
  'workspace_wallpapers': true,
  'workspace_themes': false,
  'corners': 'windows', // windows, slight (6 px), rounded (12 px), square
  'sort': 'name', // name, recent
  'preview_flip_3d': true,
  'preview_flip_delay': 2,
  'preview_pin_apply_theme': true,
  'preview_big_card': true, // click / Enter opens the big preview (off: the wallpapers page)
  'preview_big_auto_rotate': true, // the big preview turns to its wallpaper after the delay
  'slideshow_minutes': 0, // 0 = never, else 5..120
  'schedule': {'enabled': false, 'day': '', 'night': '', 'day_at': '07:00', 'night_at': '19:00'},
  'screenshot_key': true,
  'screenshot_dir': null,
  'ask_ai': false,
  'ask_ai_helper': null,
  'ask_ai_web': true, // a helper with web tools also searches the web for wallpapers
  'wallpaper_count': 10, // pictures per batch: web, created and wallhaven results (Next for more)
  'ask_prompts': null,
  'maprisma_hints': true,
  'header_order': ['import', 'hidden', 'presets', 'ask', 'info'], // the plugin's header_order.DEFAULT
  'own_font': null,
  'own_font_kde': null,
  'own_ui_font': null, // the user's interface font while a theme's look is in use
  'own_ui_font_kde': null,
  'own_blur': null, // the user's blur (the desktop's own state) while a theme's look is in use
  'own_blur_kde': null,
  'apps': null, // null = every installed app; else a list of app ids (apps.dart)
  'show_hidden': false,
};

const slideshowChoices = [0, 5, 10, 15, 30, 60, 120];
const flipDelayChoices = <num>[0, 0.5, 1, 1.5, 2, 3, 5, 10];
final _time = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

num normalizeFlipDelay(num v) => v == v.roundToDouble() ? v.round() : v.toDouble();

/// The settings with defaults filled in and every value checked.
final class Settings {
  Settings(this.paths);
  final Paths paths;

  Map<String, dynamic> load() {
    final raw = readJsonMap(paths.settingsFile);
    final out = <String, dynamic>{};
    for (final e in defaultSettings.entries) {
      final v = raw.containsKey(e.key) ? raw[e.key] : e.value;
      final checked = check(e.key, v) ? v : e.value;
      out[e.key] = e.key == 'preview_flip_delay' && checked is num ? normalizeFlipDelay(checked) : checked;
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
    raw[key] = key == 'preview_flip_delay' && value is num ? normalizeFlipDelay(value) : value;
    writeJson(paths.settingsFile, raw);
    return load();
  }

  /// Reset to defaults keeps shortcuts, favorites, hidden themes, the day
  /// and night themes (as the plugin); the header button order and the
  /// screenshot key and folder go back to their defaults too.
  Map<String, dynamic> reset() {
    final raw = readJsonMap(paths.settingsFile);
    final keep = <String, dynamic>{
      for (final k in ['language', 'size', 'ask_ai', 'ask_ai_helper', 'ask_ai_web', 'wallpaper_count', 'ask_prompts', 'own_font', 'own_font_kde', 'own_ui_font', 'own_ui_font_kde', 'own_blur', 'own_blur_kde', 'apps'])
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
    'language' => v is String && const {'auto', 'en', 'de', 'fr', 'es', 'it', 'pt', 'nl', 'pl'}.contains(v),
    'size' => v == null || (v is List && v.length == 2 && v.every((e) => e is int && e >= 320 && e <= 10000)),
    'workspace_wallpapers' ||
    'workspace_themes' ||
    'screenshot_key' ||
    'ask_ai' ||
    'ask_ai_web' ||
    'maprisma_hints' ||
    'show_hidden' ||
    'preview_flip_3d' ||
    'preview_pin_apply_theme' ||
    'preview_big_card' ||
    'preview_big_auto_rotate' =>
      v is bool,
    'preview_flip_delay' => v is num && !v.isNaN && flipDelayChoices.any((c) => c.toDouble() == v.toDouble()),
    'wallpaper_count' => v is int && const {5, 10, 20}.contains(v),
    'corners' => v is String && const {'windows', 'slight', 'rounded', 'square'}.contains(v),
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
    'own_font' || 'own_font_kde' || 'own_ui_font' || 'own_ui_font_kde' => v == null || (v is String && v.length < 100),
    'own_blur' || 'own_blur_kde' => v == null || (v is Map && v.length <= 16 && jsonEncode(v).length < 4096),
    'apps' => v == null || (v is List && v.every((e) => e is String)),
    _ => false,
  };
}
