/// Automation (the plugin's theme_auto.py): favorites cycling, recently
/// used, a wallpaper and a theme per workspace, the slideshow and day/night
/// themes, and the panel applet's right-click menu.
///
/// Workspace numbers are the 1-based presentation indices of
/// docs/cosmic-interface.md. Wallpapers are stored by file name and only ever
/// resolve to a visible wallpaper the theme already lists.
library;

import 'i18n.dart';
import 'proposals.dart';

import 'dart:async';
import 'dart:io';

import 'apply.dart';
import 'context.dart';
import 'images.dart';
import 'presets.dart' show renamePresetTheme;
import 'settings.dart';
import 'shortcuts.dart';
import 'store.dart';
import 'themes.dart';
import 'looks.dart' show Looks;

const maxWorkspace = 99;
const maxRecent = 50;
const maxFavoritesAuto = 100;
final timeRe = RegExp(r'^([01][0-9]|2[0-3]):([0-5][0-9])$');
const defaultSchedule = {'enabled': false, 'day': '', 'night': '', 'day_at': '07:00', 'night_at': '19:00'};

bool validSlug(Object? s) => s is String && slugRe.hasMatch(s);

/// A wallpaper file name: no folder, no control characters.
bool validWallpaperName(Object? n) =>
    n is String && n.isNotEmpty && n.length <= 255 && !n.contains('/') && n != '.' && n != '..' &&
    !n.contains(RegExp(r'[\x00-\x1f\x7f]'));

// --- files ---------------------------------------------------------------------

String _workspaceWallpapersFile(Ctx ctx) => ctx.paths.file('workspace-wallpapers.json');
String _workspaceThemesFile(Ctx ctx) => ctx.paths.file('workspace-themes.json');

/// The base theme must survive a reboot while an assigned workspace is active.
String _workspaceThemeStateFile(Ctx ctx) => ctx.paths.file('workspace-theme-state.json');

/// Short-lived state (the background before a workspace took over, the last
/// slideshow step, the day/night period). Losing it is harmless.
String _stateFile(Ctx ctx) => '${ctx.paths.cache}/auto-state.json';

Map<String, dynamic> _state(Ctx ctx) => readJsonMap(_stateFile(ctx));
void _saveState(Ctx ctx, Map<String, dynamic> s) => writeJson(_stateFile(ctx), s);
Map<String, dynamic> _wsState(Ctx ctx) => readJsonMap(_workspaceThemeStateFile(ctx));
void _saveWsState(Ctx ctx, Map<String, dynamic> s) => writeJson(_workspaceThemeStateFile(ctx), s);

// --- one step at a time ----------------------------------------------------------

Future<void> _queue = Future.value();

/// One automation step at a time: in this process (a queue) and across the
/// GUI and the applet's CLI calls (an fcntl lock on a private file).
Future<T> autoLocked<T>(Ctx ctx, Future<T> Function() body) {
  final run = _queue.then((_) async {
    final dir = Directory(ctx.paths.cache);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final path = '${ctx.paths.cache}/auto-state.lock';
    if (FileSystemEntity.isLinkSync(path)) throw RouteError('unsafe', tr("the automation lock is a link"));
    final raf = await File(path).open(mode: FileMode.append);
    try {
      await raf.lock(FileLock.blockingExclusive);
      return await body();
    } finally {
      await raf.close();
    }
  });
  _queue = run.then((_) {}, onError: (_) {});
  return run;
}

// --- settings --------------------------------------------------------------------

bool workspaceWallpapersEnabled(Ctx ctx) => ctx.settings.get('workspace_wallpapers') == true;
bool workspaceThemesEnabled(Ctx ctx) => ctx.settings.get('workspace_themes') == true;

int slideshowMinutes(Ctx ctx) {
  final v = ctx.settings.get('slideshow_minutes');
  return v is int && slideshowChoices.contains(v) ? v : 0;
}

/// Day/night themes: {enabled, day, night, day_at, night_at}.
Map<String, dynamic> schedule(Ctx ctx) {
  final raw = ctx.settings.get('schedule');
  final out = Map<String, dynamic>.of(defaultSchedule);
  if (raw is Map) {
    if (raw['enabled'] is bool) out['enabled'] = raw['enabled'];
    for (final k in ['day', 'night']) {
      if (validSlug(raw[k])) out[k] = raw[k];
    }
    for (final k in ['day_at', 'night_at']) {
      if (raw[k] is String && timeRe.hasMatch(raw[k])) out[k] = raw[k];
    }
  }
  return out;
}

/// A changed plan takes effect at once, not at the next boundary.
Map<String, dynamic> saveSchedule(Ctx ctx, Map<String, dynamic> values) {
  final current = schedule(ctx)..addAll(values);
  ctx.settings.set('schedule', current);
  final s = _state(ctx)..remove('period');
  _saveState(ctx, s);
  return schedule(ctx);
}

// --- recent ------------------------------------------------------------------------

void recordRecent(Ctx ctx, String slug) {
  if (!validSlug(slug)) return;
  final recent = ctx.lists.recent..[slug] = ctx.clock().millisecondsSinceEpoch / 1000;
  final newest = recent.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  writeJson(ctx.paths.file('recent.json'), {for (final e in newest.take(maxRecent)) e.key: e.value});
}

// --- workspace themes ------------------------------------------------------------------

Map<int, String> loadWorkspaceThemes(Ctx ctx) {
  final out = <int, String>{};
  for (final e in readJsonMap(_workspaceThemesFile(ctx)).entries) {
    final ws = int.tryParse(e.key);
    if (ws != null && RegExp(r'^\d+$').hasMatch(e.key) && ws >= 1 && ws <= maxWorkspace && validSlug(e.value)) {
      out[ws] = e.value as String;
    }
  }
  return out;
}

void _saveWorkspaceThemes(Ctx ctx, Map<int, String> m) {
  final keys = m.keys.toList()..sort();
  writeJson(_workspaceThemesFile(ctx), {for (final k in keys) '$k': m[k]});
}

void _checkWorkspace(int workspace) {
  if (workspace < 1 || workspace > maxWorkspace) throw RouteError('bad_params', tr("workspace out of range"));
}

/// Gives [workspace] the theme [slug] (null: none of its own).
void setWorkspaceTheme(Ctx ctx, int workspace, String? slug) {
  _checkWorkspace(workspace);
  if (slug != null) ctx.theme(slug);
  final m = loadWorkspaceThemes(ctx);
  if (slug == null) {
    m.remove(workspace);
  } else {
    m[workspace] = slug;
  }
  _saveWorkspaceThemes(ctx, m);
}

/// A manual or scheduled choice becomes the theme restored on leaving an
/// assigned workspace.
void rememberBaseTheme(Ctx ctx, String slug) {
  final s = _wsState(ctx);
  if (s['assigned_workspace'] != null) {
    s['base_theme'] = slug;
    _saveWsState(ctx, s);
  }
}

/// "Use on all workspaces": no workspace keeps a theme of its own and the
/// theme in use is shown everywhere. Returns what Undo needs, or null.
Map<String, dynamic>? useEverywhere(Ctx ctx) {
  final mapping = loadWorkspaceThemes(ctx);
  final current = ctx.current.slug;
  if (mapping.isEmpty || current.isEmpty) return null;
  final state = _wsState(ctx);
  final newState = Map<String, dynamic>.of(state)
    ..['assigned_workspace'] = null
    ..remove('assigned_slug')
    ..['base_theme'] = current;
  _saveWorkspaceThemes(ctx, {});
  _saveWsState(ctx, newState);
  return {
    'mapping': {for (final e in mapping.entries) '${e.key}': e.value},
    'state': state,
    'new_state': newState,
    'theme': current,
  };
}

bool _jsonEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_jsonEqual(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

/// Puts the workspaces' own themes back, only while nothing changed since.
bool undoUseEverywhere(Ctx ctx, Map saved) {
  final mapping = saved['mapping'], state = saved['state'], newState = saved['new_state'];
  if (mapping is! Map || state is! Map || newState is! Map) throw RouteError('bad_params', 'saved');
  if (loadWorkspaceThemes(ctx).isNotEmpty || !_jsonEqual(_wsState(ctx), newState) || ctx.current.slug != saved['theme']) {
    return false;
  }
  final m = <int, String>{};
  for (final e in mapping.entries) {
    final ws = int.tryParse('${e.key}');
    if (ws != null && ws >= 1 && ws <= maxWorkspace && validSlug(e.value)) m[ws] = e.value as String;
  }
  _saveWorkspaceThemes(ctx, m);
  _saveWsState(ctx, Map<String, dynamic>.from(state));
  return true;
}

/// Applies a theme the way the window does (unhides it, counts it as
/// recently used); [trackBase]: a manual or scheduled choice.
Future<bool> autoApplyTheme(Ctx ctx, String slug, {bool trackBase = true}) async {
  await applyTheme(ctx, slug);
  recordRecent(ctx, slug);
  if (trackBase) rememberBaseTheme(ctx, slug);
  return true;
}

/// The focused workspace changed: its theme (or back to the base theme),
/// then its wallpaper.
Future<String?> applyWorkspace(Ctx ctx, int workspace) async {
  final state = _wsState(ctx);
  String? slug = workspaceThemesEnabled(ctx) ? loadWorkspaceThemes(ctx)[workspace] : null;
  final current = ctx.current.slug;
  if (slug != null) {
    if (state['assigned_workspace'] == null) {
      state['base_theme'] = current;
    } else if (current != state['assigned_slug'] && current != state['base_theme']) {
      state['base_theme'] = current;
    }
    if (slug != current) {
      try {
        await autoApplyTheme(ctx, slug, trackBase: false);
      } on RouteError {
        slug = null; // a removed theme must not break workspace events
      }
    }
    if (slug != null) {
      state['assigned_workspace'] = workspace;
      state['assigned_slug'] = slug;
    }
  }
  if (slug == null) {
    final base = state['base_theme'];
    final assigned = state['assigned_slug'];
    if (state['assigned_workspace'] != null) {
      if (current != assigned && current != base) {
        // a manual choice or the schedule supersedes the workspace's theme
      } else if (base is String && base.isNotEmpty && base != current) {
        try {
          await autoApplyTheme(ctx, base, trackBase: false);
        } on RouteError {
          // gone: stay
        }
      }
    }
    state['assigned_workspace'] = null;
    state.remove('assigned_slug');
    state['base_theme'] = ctx.current.slug;
  }
  _saveWsState(ctx, state);
  return onWorkspace(ctx, workspace);
}

// --- workspace wallpapers ---------------------------------------------------------------

/// {theme slug: {workspace: wallpaper file name}}.
Map<String, Map<int, String>> loadWorkspaceMap(Ctx ctx) {
  final out = <String, Map<int, String>>{};
  for (final e in readJsonMap(_workspaceWallpapersFile(ctx)).entries) {
    if (!validSlug(e.key) || e.value is! Map) continue;
    for (final a in (e.value as Map).entries) {
      final ws = int.tryParse('${a.key}');
      if (ws != null && RegExp(r'^\d+$').hasMatch('${a.key}') && ws >= 1 && ws <= maxWorkspace &&
          validWallpaperName(a.value)) {
        out.putIfAbsent(e.key, () => {})[ws] = a.value as String;
      }
    }
  }
  return out;
}

void saveWorkspaceMap(Ctx ctx, Map<String, Map<int, String>> m) {
  final out = <String, dynamic>{};
  for (final e in m.entries) {
    if (e.value.isEmpty) continue;
    final keys = e.value.keys.toList()..sort();
    out[e.key] = {for (final k in keys) '$k': e.value[k]};
  }
  writeJson(_workspaceWallpapersFile(ctx), out);
}

/// Shows wallpaper [name] of theme [slug] on [workspace] (null: clears it).
void setWorkspaceWallpaper(Ctx ctx, String slug, int workspace, String? name) {
  if (!validSlug(slug)) throw RouteError('bad_params', 'slug');
  _checkWorkspace(workspace);
  final m = loadWorkspaceMap(ctx);
  final a = m.putIfAbsent(slug, () => {});
  if (name == null) {
    a.remove(workspace);
  } else {
    if (!validWallpaperName(name)) throw RouteError('bad_params', tr("bad wallpaper name"));
    a[workspace] = name;
  }
  saveWorkspaceMap(ctx, m);
}

void clearWallpaperWorkspaces(Ctx ctx, String slug, String name) {
  final m = loadWorkspaceMap(ctx);
  m[slug]?.removeWhere((_, n) => n == name);
  saveWorkspaceMap(ctx, m);
}

List<int> workspacesOf(Ctx ctx, String slug, String name, [Map<String, Map<int, String>>? mapping]) {
  final m = mapping ?? loadWorkspaceMap(ctx);
  return [for (final e in (m[slug] ?? const <int, String>{}).entries) if (e.value == name) e.key]..sort();
}

/// The active workspace's presentation index, from maprisma-theme-helper.
Future<int?> activeWorkspace(Ctx ctx) async {
  final r = await ctx.desktop.wm(['workspaces'], timeout: const Duration(seconds: 3));
  final list = r?['workspaces'];
  if (list is! List) return null;
  for (final w in list) {
    if (w is Map && w['active'] == true && w['index'] is int && (w['index'] as int) >= 1) return w['index'] as int;
  }
  return null;
}

// --- backgrounds ------------------------------------------------------------------------

ThemeInfo? currentThemeInfo(Ctx ctx) {
  final slug = ctx.current.slug;
  return slug.isEmpty ? null : findTheme(ctx.paths, slug);
}

String? currentBackground(Ctx ctx) => ctx.desktop.wallpaper() ?? ctx.current.wallpaper;

List<String> visibleWallpapers(Ctx ctx, ThemeInfo theme) => [for (final w in visibleBackgrounds(ctx.paths, theme)) w.path];

String? wallpaperNamed(Ctx ctx, ThemeInfo theme, String name) {
  for (final p in visibleWallpapers(ctx, theme)) {
    if (baseName(p) == name) return p;
  }
  return null;
}

bool _same(String? a, String? b) => a != null && b != null && baseName(a) == baseName(b);

/// Sets [path] as the desktop background unless it is shown already.
/// [remember]: the theme starts with it next time (a choice, not a workspace's).
Future<bool> _show(Ctx ctx, String path, {bool remember = false}) async {
  final current = currentBackground(ctx);
  if (current == path && File(current!).existsSync()) return true;
  // never hand the desktop an image it would have to decode at a huge size
  if (imageSizeProblem(path) != null) return false;
  return setBackground(ctx, path, remember: remember);
}

/// The focused workspace changed: show its wallpaper, or go back to the
/// background in use before a workspace wallpaper took over.
Future<String?> onWorkspace(Ctx ctx, int workspace) async {
  if (!workspaceWallpapersEnabled(ctx) || workspace < 1) return null;
  final theme = currentThemeInfo(ctx);
  if (theme == null) return null;
  final assignments = loadWorkspaceMap(ctx)[theme.slug] ?? const <int, String>{};
  var state = _state(ctx);
  if (state['theme'] != theme.slug) {
    state = {for (final k in ['period', 'slide_at']) if (state.containsKey(k)) k: state[k]};
    state['theme'] = theme.slug; // a new theme brings its own background
  }
  final left = state['workspace'];
  if (!(left is int && assignments.containsKey(left))) {
    // leaving a workspace without its own wallpaper: remember what it showed
    final bg = currentBackground(ctx);
    if (bg != null) state['base'] = bg;
  }
  state['workspace'] = workspace;
  String? target = assignments.containsKey(workspace) ? wallpaperNamed(ctx, theme, assignments[workspace]!) : null;
  if (target == null) {
    final base = state['base'];
    target = base is String && base.startsWith('/') && File(base).existsSync() ? base : null;
  }
  _saveState(ctx, state);
  if (target != null) await _show(ctx, target);
  return target;
}

/// The next (+1) or previous (-1) visible wallpaper of the current theme.
/// On a workspace with its own wallpaper, that workspace gets the new one.
Future<String?> stepBackground(Ctx ctx, int direction) async {
  final theme = currentThemeInfo(ctx);
  if (theme == null) return null;
  final walls = visibleWallpapers(ctx, theme);
  if (walls.isEmpty) return null;
  final current = currentBackground(ctx);
  final index = walls.indexWhere((p) => _same(p, current));
  final target = index >= 0 || direction > 0 ? walls[(index + direction) % walls.length] : walls.last;
  return await showChosenBackground(ctx, theme, target) ? target : null;
}

/// Shows [target] as the user's pick for the current [theme]: on a workspace
/// with its own wallpaper that workspace gets it, else it becomes the base the
/// workspace switches return to (and the theme's remembered wallpaper).
Future<bool> showChosenBackground(Ctx ctx, ThemeInfo theme, String target) async {
  var own = false;
  if (workspaceWallpapersEnabled(ctx)) {
    final ws = await activeWorkspace(ctx);
    checkAskAiBoundary();
    final assignments = loadWorkspaceMap(ctx)[theme.slug] ?? const <int, String>{};
    if (ws != null && assignments.containsKey(ws)) {
      setWorkspaceWallpaper(ctx, theme.slug, ws, baseName(target));
      own = true;
    } else {
      final state = _state(ctx);
      if (state['theme'] == theme.slug) {
        state['base'] = target;
        _saveState(ctx, state);
      }
    }
  }
  return _show(ctx, target, remember: !own);
}

/// Records [target] as the base wallpaper restored on leaving an assigned
/// workspace when [slug] is the active theme.
void rememberBaseWallpaper(Ctx ctx, String slug, String target) {
  final state = _state(ctx);
  if (state['theme'] == slug) {
    state['base'] = target;
    _saveState(ctx, state);
  }
}

// --- slideshow and day/night ---------------------------------------------------------------

int _minutes(String hhmm) => int.parse(hhmm.substring(0, 2)) * 60 + int.parse(hhmm.substring(3));

String periodAt(DateTime now, String dayAt, String nightAt) {
  final minutes = now.hour * 60 + now.minute;
  final day = _minutes(dayAt), night = _minutes(nightAt);
  if (day == night) return 'day';
  final inside = day < night ? (day <= minutes && minutes < night) : !(night <= minutes && minutes < day);
  return inside ? 'day' : 'night';
}

/// Once a minute: day/night at the set times, and the slideshow.
Future<Map<String, dynamic>> tick(Ctx ctx) async {
  final nowTime = ctx.clock();
  final now = nowTime.millisecondsSinceEpoch / 1000;
  final done = <String, dynamic>{};
  var state = _state(ctx);
  final plan = schedule(ctx);
  final day = plan['day'] as String, night = plan['night'] as String;
  if (plan['enabled'] == true && day.isNotEmpty && night.isNotEmpty) {
    final period = periodAt(nowTime, plan['day_at'] as String, plan['night_at'] as String);
    // only at a boundary: a theme picked by hand stays until the next one
    if (state['period'] != period) {
      state['period'] = period;
      _saveState(ctx, state);
      final wanted = period == 'day' ? day : night;
      final active = workspaceThemesEnabled(ctx) ? await activeWorkspace(ctx) : null;
      final assigned = active != null && loadWorkspaceThemes(ctx).containsKey(active);
      if (assigned) {
        rememberBaseTheme(ctx, wanted);
      } else if (wanted != ctx.current.slug) {
        try {
          await autoApplyTheme(ctx, wanted);
          done['theme'] = wanted;
        } on RouteError catch (e) {
          done['theme_error'] = e.code;
          if (e.code == 'apply_failed') {
            // COSMIC did not take it (helper missing, a glitch): try again next minute
            // instead of waiting for the next boundary.
            final retry = _state(ctx)..remove('period');
            _saveState(ctx, retry);
          }
        }
        state = _state(ctx);
      }
    }
  }
  final minutes = slideshowMinutes(ctx);
  if (minutes > 0) {
    final last = state['slide_at'];
    if (last is! num || now - last >= minutes * 60 - 5) {
      state['slide_at'] = now;
      _saveState(ctx, state);
      final theme = currentThemeInfo(ctx);
      final ws = workspaceWallpapersEnabled(ctx) ? await activeWorkspace(ctx) : null;
      final onOwn = theme != null && ws != null && (loadWorkspaceMap(ctx)[theme.slug]?.containsKey(ws) ?? false);
      // a workspace with its own wallpaper keeps it
      if (last is num && !onOwn) done['background'] = await stepBackground(ctx, 1);
    }
  }
  return done;
}

/// The next (or previous) favorite theme; without favorites, the next theme
/// that is not hidden.
Future<String?> stepTheme(Ctx ctx, int direction) async {
  final themes = [for (final t in ctx.themes()) t.slug];
  var pool = [for (final s in ctx.lists.favorites) if (themes.contains(s)) s];
  if (pool.isEmpty) {
    final hidden = ctx.lists.hidden;
    pool = [for (final s in themes) if (!hidden.contains(s)) s];
  }
  if (pool.isEmpty) return null;
  final current = ctx.current.slug;
  final index = pool.contains(current) ? pool.indexOf(current) : (direction > 0 ? -1 : 0);
  final target = pool[(index + direction) % pool.length];
  if (target != current) await autoApplyTheme(ctx, target);
  return target;
}

// --- the applet's menu ------------------------------------------------------------------------

String plainText(String s, int max) {
  final flat = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  final runes = flat.runes.toList();
  return runes.length <= max ? flat : '${String.fromCharCodes(runes.take(max - 1))}…';
}

/// Favorite themes for the applet's right-click popup; the five most
/// recently used when there are no favorites yet (docs/cosmic-interface.md).
Map<String, dynamic> menuData(Ctx ctx) {
  final themes = {for (final t in ctx.themes()) t.slug: t};
  final current = ctx.current.slug;
  var list = [for (final s in ctx.lists.favorites) if (themes.containsKey(s)) s];
  var source = 'favorites';
  if (list.isEmpty) {
    final recent = ctx.lists.recent;
    final sorted = recent.keys.toList()..sort((a, b) => recent[b]!.compareTo(recent[a]!));
    list = [for (final s in sorted) if (themes.containsKey(s)) s].take(5).toList();
    source = 'recent';
  }
  return {
    'title': source == 'favorites' ? tr('Favorite themes') : tr('Recently used'),
    'source': source,
    'themes': [
      for (final s in list) {'slug': s, 'name': plainText(themes[s]!.name, 60), 'current': s == current},
    ],
    'empty_note': tr('No favorites yet: ★ a theme in Maprisma Theme'),
    'items': [
      {'id': 'next_wallpaper', 'label': tr('Next wallpaper')},
      {'id': 'open', 'label': tr('Open Maprisma Theme')},
    ],
  };
}

// --- rename and forget ------------------------------------------------------------------------

/// Everything remembered about theme [old] now belongs to [renamed]:
/// favorites, recently used, workspace wallpapers and themes, day/night.
void renameAutoState(Ctx ctx, String old, String renamed) {
  final favs = ctx.lists.favorites;
  if (favs.contains(old)) ctx.lists.favorites = [for (final s in favs) s == old ? renamed : s];
  final recent = ctx.lists.recent;
  if (recent.containsKey(old)) {
    recent[renamed] = recent.remove(old)!;
    writeJson(ctx.paths.file('recent.json'), recent);
  }
  final hidden = ctx.lists.hidden;
  if (hidden.remove(old)) ctx.lists.hidden = hidden..add(renamed);
  final wsThemes = loadWorkspaceThemes(ctx);
  if (wsThemes.containsValue(old)) {
    _saveWorkspaceThemes(ctx, {for (final e in wsThemes.entries) e.key: e.value == old ? renamed : e.value});
  }
  final map = loadWorkspaceMap(ctx);
  if (map.containsKey(old)) {
    map[renamed] = map.remove(old)!;
    saveWorkspaceMap(ctx, map);
  }
  final hiddenWalls = loadHiddenWallpapers(ctx.paths);
  if (hiddenWalls.containsKey(old)) {
    hiddenWalls[renamed] = hiddenWalls.remove(old)!;
    saveHiddenWallpapers(ctx.paths, hiddenWalls);
  }
  final chosen = chosenWallpapers(ctx);
  if (chosen.containsKey(old)) {
    chosen[renamed] = chosen.remove(old)!;
    writeJson('${ctx.paths.state}/theme-backgrounds.json', chosen);
  }
  final plan = schedule(ctx);
  final changed = {for (final k in ['day', 'night']) if (plan[k] == old) k: renamed};
  if (changed.isNotEmpty) saveSchedule(ctx, changed);
  final ws = _wsState(ctx);
  var wsChanged = false;
  for (final k in ['base_theme', 'assigned_slug']) {
    if (ws[k] == old) {
      ws[k] = renamed;
      wsChanged = true;
    }
  }
  if (wsChanged) _saveWsState(ctx, ws);
}

/// A deleted theme leaves the lists: favorites, recent, hidden, workspace
/// themes and wallpapers, day/night.
void forgetAutoState(Ctx ctx, String slug) {
  ctx.lists.forget(slug);
  final wsThemes = loadWorkspaceThemes(ctx);
  if (wsThemes.containsValue(slug)) {
    _saveWorkspaceThemes(ctx, {for (final e in wsThemes.entries) if (e.value != slug) e.key: e.value});
  }
  final map = loadWorkspaceMap(ctx);
  if (map.remove(slug) != null) saveWorkspaceMap(ctx, map);
  final hiddenWalls = loadHiddenWallpapers(ctx.paths);
  if (hiddenWalls.remove(slug) != null) saveHiddenWallpapers(ctx.paths, hiddenWalls);
  final chosen = chosenWallpapers(ctx);
  if (chosen.remove(slug) != null) writeJson('${ctx.paths.state}/theme-backgrounds.json', chosen);
  final plan = schedule(ctx);
  final changed = {for (final k in ['day', 'night']) if (plan[k] == slug) k: ''};
  if (changed.isNotEmpty) saveSchedule(ctx, changed);
}

/// Everything Maprisma Theme remembers about theme [old] now belongs to
/// [renamed] (the editor's rename): lists, workspace assignments, day/night
/// and its key.
void renameThemeState(Ctx ctx, String old, String renamed) {
  if (!validSlug(old) || !validSlug(renamed) || old == renamed) return;
  renameAutoState(ctx, old, renamed);
  renamePresetTheme(ctx, old, renamed);
  Looks(ctx).rename(old, renamed);
  try {
    ThemeShortcuts(ctx).renameTheme(old, renamed);
  } on RouteError {
    // COSMIC's file cannot be written now; the key follows on the next save
  }
  ctx.automationChanged();
}

/// A deleted theme (once Undo is no longer offered) leaves every list, and
/// its key is given back.
void forgetThemeState(Ctx ctx, String slug) {
  if (!validSlug(slug)) return;
  forgetAutoState(ctx, slug);
  Looks(ctx).forget(slug);
  try {
    ThemeShortcuts(ctx).dropTheme(slug);
  } on RouteError {
    // the key does nothing while its theme is gone; pruned later
  }
  ctx.automationChanged();
}

// --- automation.json for the applet --------------------------------------------------------

const _noTiling = {'active': false, 'default_limit': 2, 'limits': <String, int>{}, 'floating': <int>[], 'tiled': <int>[]};

/// What the presets module says about tiling and autostart; null: nothing.
Map<String, dynamic>? Function(Ctx ctx)? tilingAutomationHook;

/// ~/.config/maprisma-theme/automation.json (docs/cosmic-interface.md);
/// written only when it changes, so the applet re-reads it only then.
void writeAutomation(Ctx ctx) {
  final s = ctx.settings.load();
  final plan = s['schedule'] is Map ? s['schedule'] as Map : const {};
  final minutes = s['slideshow_minutes'];
  Map<String, dynamic> tiling = Map<String, dynamic>.of(_noTiling);
  var autostart = false;
  final fromPresets = tilingAutomationHook?.call(ctx);
  if (fromPresets != null) {
    final t = fromPresets['tiling'] is Map ? fromPresets['tiling'] as Map : fromPresets;
    tiling = {
      'active': t['active'] == true,
      'default_limit': t['default_limit'] is int ? t['default_limit'] : 2,
      'limits': t['limits'] is Map ? t['limits'] : const {},
      'floating': t['floating'] is List ? t['floating'] : const [],
      'tiled': t['tiled'] is List ? t['tiled'] : const [],
    };
    autostart = fromPresets['autostart'] == true || t['autostart'] == true;
  }
  final data = {
    'workspace_events': s['workspace_wallpapers'] == true || s['workspace_themes'] == true,
    'tick': (minutes is int && minutes > 0) || plan['enabled'] == true,
    'tiling': tiling,
    'autostart': autostart,
  };
  unawaited(Future<void>.sync(() => ctx.desktop.publishTilingAutomation(tiling)).catchError((Object _) {}));
  if (_jsonEqual(readJson(ctx.paths.automationFile), data)) return;
  writeJson(ctx.paths.automationFile, data);
}
