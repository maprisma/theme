/// KDE Plasma 6 (docs/multi-desktop.md, "KDE backend"): colors as a Plasma
/// color scheme from templates/kde.colors.tpl, the wallpaper through
/// plasmashell's scripting API, Konsole's color scheme, the fixed font in
/// kdeglobals and the icon theme. Workspaces, windows and shortcuts come in
/// step 4; until then their caps are missing.
library;

import 'dart:convert';
import 'dart:io';


import 'bounded.dart';
import 'colors.dart';
import 'desktop.dart';
import 'images.dart';
import 'kde_formats.dart';
import 'kwin_bridge.dart';
import 'paths.dart';
import 'posix.dart';
import 'shortcuts.dart';
import 'shortcuts_kde.dart';
import 'store.dart';

/// The two scheme names Maprisma Theme alternates between:
/// plasma-apply-colorscheme skips the scheme already in use, so a changed
/// file under the same name would never be applied.
const kdeSchemeNames = ['MaprismaA', 'MaprismaB'];
const konsoleSchemeName = 'Maprisma';
const konsoleProfileName = 'Maprisma';

final class KdeDesktop extends DesktopBase {
  KdeDesktop(super.paths, super.environment);

  @override
  String get id => 'kde';
  @override
  String get name => 'KDE Plasma';
  @override
  String get terminalName => 'Konsole';
  /// Per-workspace tiling when Maprisma Tiling is installed.
  @override
  Set<Cap> get caps => {
    Cap.appearance, Cap.kdeScheme, Cap.wallpaper, Cap.terminal, Cap.fonts, Cap.icons,
    Cap.workspaces, Cap.windows, Cap.shortcuts, Cap.animations, Cap.uiFont, Cap.blur,
    if (maprismaTilingInstalled) Cap.tiling,
  };

  String get _kwinrc => '$_configHome/kwinrc';

  bool get maprismaTilingInstalled => [
    '${paths.data}/kwin/scripts/maprisma-tiling',
    for (final d in _dataDirs) '$d/kwin/scripts/maprisma-tiling',
  ].any((d) => File('$d/metadata.json').existsSync());

  @override
  bool get enforcesWindowLimits => maprismaTilingInstalled;

  Set<int> get untiledDesktops => {
    for (final n in (iniValue(_text(_kwinrc), 'Script-maprisma-tiling', 'untiledDesktops') ?? '').split(','))
      if (int.tryParse(n.trim()) case final int index when index > 0) index,
  };

  Future<void> _limitsPending = Future<void>.value();

  @override
  Future<void> publishTilingAutomation(Map<String, dynamic> tiling) {
    final limits = tiling['limits'] as Map? ?? const {};
    final values = {
      'limitsActive': '${tiling['active'] == true}',
      'defaultLimit': '${tiling['default_limit'] ?? 2}',
      'limits': limits.entries.map((e) => '${e.key}:${e.value}').join(','),
    };
    return _limitsPending = _limitsPending.then((_) async {
      if (!maprismaTilingInstalled) return;
      // Every core start publishes: KWin only reloads when something changed.
      final text = _text(_kwinrc);
      if (values.entries.every((e) => iniValue(text, 'Script-maprisma-tiling', e.key) == e.value)) return;
      for (final e in values.entries) {
        if (!await _run(['kwriteconfig6', '--file', 'kwinrc', '--group', 'Script-maprisma-tiling', '--key', e.key, e.value])) return;
      }
      await _run(['qdbus6', 'org.kde.KWin', '/KWin', 'reconfigure']);
    }).catchError((Object _) {});
  }

  /// "r,g,b" (a KDE colour) as #rrggbb, or null.
  static String? kdeRgbHex(String? v) {
    final p = (v ?? '').split(',').map((s) => int.tryParse(s.trim())).toList();
    if (p.length < 3 || p.take(3).any((c) => c == null || c < 0 || c > 255)) return null;
    return '#${p.take(3).map((c) => c!.toRadixString(16).padLeft(2, '0')).join()}';
  }

  /// The wm contract's workspaces with each one's real tiling state.
  Map<String, dynamic> withTiling(Map<String, dynamic> r) {
    if (r['workspaces'] is! List) return r;
    final on = maprismaTilingInstalled;
    final ignored = untiledDesktops;
    return {
      ...r,
      'workspaces': [
        for (final w in r['workspaces'] as List)
          if (w is Map) {...w, 'tiling': on && !ignored.contains(w['index'])},
      ],
      'can_tile': maprismaTilingInstalled,
    };
  }

  /// Tile gaps and active window frame, in pixels.
  static const tileStyleKeys = {
    'top': ('Script-maprisma-tiling', 'gapTop', 10),
    'right': ('Script-maprisma-tiling', 'gapRight', 10),
    'bottom': ('Script-maprisma-tiling', 'gapBottom', 10),
    'left': ('Script-maprisma-tiling', 'gapLeft', 10),
    'between': ('Script-maprisma-tiling', 'gapBetween', 10),
    'border': ('Script-maprisma-tiling', 'borderWidth', 3),
    'radius': ('Script-maprisma-tiling', 'cornerRadius', 10),
  };

  Map<String, dynamic> tileStyle() {
    final text = _text(_kwinrc);
    return {
      for (final e in tileStyleKeys.entries)
        e.key: int.tryParse(iniValue(text, e.value.$1, e.value.$2) ?? '') ?? e.value.$3,
      'can_tile': maprismaTilingInstalled,
    };
  }

  /// Validates the entire style before writing and reconfigures once.
  Future<Map<String, dynamic>> _setTileStyle(String json) async {
    if (!maprismaTilingInstalled) return {'error': 'not_available', 'message': 'Maprisma Tiling is not installed'};
    final Object? v;
    try {
      v = jsonDecode(json);
    } on FormatException {
      return {'error': 'bad_args'};
    }
    if (v is! Map) return {'error': 'bad_args'};
    final old = tileStyle();
    // Every value checked first: a rejected request changes nothing.
    for (final e in tileStyleKeys.entries) {
      final n = v[e.key];
      if (n == null) continue;
      if (n is! int || n < 0 || n > (switch (e.key) { 'border' => 16, 'radius' => 32, _ => 200 })) return {'error': 'bad_args', 'message': e.key};
    }
    for (final e in tileStyleKeys.entries) {
      final n = v[e.key];
      if (n == null || n == old[e.key]) continue;
      if (!await _run(['kwriteconfig6', '--file', 'kwinrc', '--group', e.value.$1, '--key', e.value.$2, '$n'])) {
        return {'error': 'unavailable', 'message': 'kwinrc could not be written'};
      }
    }
    await _run(['qdbus6', 'org.kde.KWin', '/KWin', 'reconfigure']);
    return {'done': true, 'previous': old};
  }

  /// The KWin effects behind each animation switch, with KDE's default
  /// (an effect key missing from kwinrc [Plugins] means the default).
  static const animationEffects = {
    'workspace': {'slide': true, 'fadedesktop': false},
    'window': {'scale': true, 'glide': false, 'fade': false},
  };

  /// {workspace, window}: true while one of its effects is on.
  Map<String, dynamic> animations() {
    final text = _text(_kwinrc);
    bool on(String effect, bool byDefault) => switch (iniValue(text, 'Plugins', '${effect}Enabled')) {
      'true' => true,
      'false' => false,
      _ => byDefault,
    };
    return {
      for (final e in animationEffects.entries) e.key: e.value.entries.any((x) => on(x.key, x.value)),
    };
  }

  /// Where an Off switch keeps the user's own effect choice (the raw kwinrc
  /// values, null for a missing key), so On brings that choice back and not
  /// just KDE's defaults.
  String get _animationsFile => '${paths.state}/kde-animations.json';

  Map<String, dynamic> _savedAnimations() {
    try {
      final v = jsonDecode(readSmall(_animationsFile, limit: 64 * 1024) ?? '{}');
      return v is Map<String, dynamic> ? v : {};
    } on FormatException {
      return {};
    }
  }

  /// The qdbus tool KDE ships (qdbus6, or qdbus on older installs).
  String? get _qdbus => which('qdbus6', environment) ?? which('qdbus', environment);

  /// Whether KWin has [effect] loaded right now, or null when KWin can't be asked.
  Future<bool?> _effectLoaded(String qdbus, String effect) async {
    final (code, out) = await runBounded(
      [qdbus, 'org.kde.KWin', '/Effects', 'org.kde.kwin.Effects.isEffectLoaded', effect],
      timeout: const Duration(seconds: 5),
    );
    if (code != 0) return null;
    return switch (out.trim()) { 'true' => true, 'false' => false, _ => null };
  }

  /// Writes the raw kwinrc values ({effect: 'true'|'false'|null}) and makes
  /// KWin load or unload each effect to match; false when KWin ends up
  /// differently or can't be reached.
  Future<bool> _writeEffects(String qdbus, Map<String, String?> values) async {
    for (final e in values.entries) {
      final key = ['--file', 'kwinrc', '--group', 'Plugins', '--key', '${e.key}Enabled'];
      if (!await _run(['kwriteconfig6', ...key, e.value ?? '--delete'])) return false;
    }
    final defaults = {for (final m in animationEffects.values) ...m};
    for (final e in values.entries) {
      final want = e.value == null ? defaults[e.key]! : e.value == 'true';
      final now = await _effectLoaded(qdbus, e.key);
      if (now == null) return false;
      if (now == want) continue;
      await runBounded([qdbus, 'org.kde.KWin', '/Effects', 'org.kde.kwin.Effects.${want ? 'loadEffect' : 'unloadEffect'}', e.key],
          timeout: const Duration(seconds: 5));
      if (await _effectLoaded(qdbus, e.key) != want) return false;
    }
    return true;
  }

  /// {workspace?, window?}: Off writes every effect of the switch off and
  /// keeps the user's choice; On brings that choice back (KDE's defaults when
  /// there is none, or when it had them all off). KWin follows at once; when
  /// it can't, every value goes back as it was and the result is an error.
  Future<Map<String, dynamic>> _setAnimations(String json) async {
    final Object? v;
    try {
      v = jsonDecode(json);
    } on FormatException {
      return {'error': 'bad_args'};
    }
    if (v is! Map || v.isEmpty || v.entries.any((e) => !animationEffects.containsKey(e.key) || e.value is! bool)) {
      return {'error': 'bad_args'};
    }
    final qdbus = _qdbus;
    if (qdbus == null) return {'error': 'unavailable', 'message': 'qdbus6 is not installed'};
    final old = animations();
    final text = _text(_kwinrc);
    final saved = _savedAnimations();
    final before = <String, String?>{}, after = <String, String?>{};
    for (final e in v.entries) {
      final effects = animationEffects[e.key]!;
      for (final x in effects.keys) {
        before[x] = iniValue(text, 'Plugins', '${x}Enabled');
      }
      if (e.value == false) {
        if (old[e.key] == true) saved[e.key] = {for (final x in effects.keys) x: before[x]};
        for (final x in effects.keys) {
          after[x] = 'false';
        }
      } else {
        final mine = saved.remove(e.key);
        final back = {for (final x in effects.keys) x: mine is Map && mine[x] is String ? mine[x] as String : null};
        // a kept choice with every effect off would turn nothing on: KDE's defaults instead
        final anyOn = back.entries.any((x) => x.value == 'true' || (x.value == null && effects[x.key]!));
        for (final x in effects.keys) {
          after[x] = old[e.key] == true ? before[x] : (anyOn ? back[x] : null);
        }
      }
    }
    if (!await _writeEffects(qdbus, after)) {
      await _writeEffects(qdbus, before);
      return {'error': 'unavailable', 'message': 'KWin did not take the change'};
    }
    writeJson(_animationsFile, saved);
    return {'done': true, 'previous': old, ...animations()};
  }

  // --- blur: KWin's Blur effect ------------------------------------------------

  /// KWin's default strength when kwinrc has none (blur.kcfg).
  static const kwinBlurDefault = 15;

  /// {enabled, strength, loaded}: kwinrc's raw values ([Plugins]
  /// blurEnabled, [Effect-blur] BlurStrength; null where missing) and
  /// whether KWin runs the effect now (its default depends on the GPU, so a
  /// missing key alone doesn't tell). Null when KWin can't blur here (no
  /// OpenGL compositing) or can't be asked.
  @override
  Future<Map<String, dynamic>?> blurState() async {
    final qdbus = _qdbus;
    if (qdbus == null) return null;
    final (code, out) = await runBounded(
      [qdbus, 'org.kde.KWin', '/Effects', 'org.kde.kwin.Effects.isEffectSupported', 'blur'],
      timeout: const Duration(seconds: 5),
    );
    if (code != 0 || out.trim() != 'true') return null;
    final loaded = await _effectLoaded(qdbus, 'blur');
    if (loaded == null) return null;
    final text = _text(_kwinrc);
    return {
      'enabled': iniValue(text, 'Plugins', 'blurEnabled'),
      'strength': iniValue(text, 'Effect-blur', 'BlurStrength'),
      'loaded': loaded,
    };
  }

  @override
  Map<String, dynamic> blurTarget(Map<String, dynamic> now, {required bool on, required int strength}) =>
      {'enabled': on ? 'true' : 'false', 'strength': '${strength.clamp(1, 15)}', 'loaded': on};

  @override
  Map<String, dynamic> blurAsLook(Map<String, dynamic> state) => {
    'on': state['loaded'] is bool ? state['loaded'] : state['enabled'] != 'false',
    'strength': (int.tryParse('${state['strength']}') ?? kwinBlurDefault).clamp(1, 15),
  };

  /// Writes both keys, makes KWin run the effect or not as [state] has it
  /// and read its strength again; when KWin doesn't follow, both keys and
  /// the effect go back as they were and the result is false.
  @override
  Future<bool> restoreBlur(Map<String, dynamic> state) async {
    final enabled = state['enabled'], strength = state['strength'], loaded = state['loaded'];
    if ((enabled != null && enabled is! String) || (strength != null && strength is! String) || loaded is! bool) return false;
    final qdbus = _qdbus;
    final before = await blurState();
    if (qdbus == null || before == null) return false;
    Future<bool> write(String? enabled, String? strength, bool loaded) async {
      if (!await _run(['kwriteconfig6', '--file', 'kwinrc', '--group', 'Effect-blur', '--key', 'BlurStrength', strength ?? '--delete'])) return false;
      if (!await _run(['kwriteconfig6', '--file', 'kwinrc', '--group', 'Plugins', '--key', 'blurEnabled', enabled ?? '--delete'])) return false;
      if (await _effectLoaded(qdbus, 'blur') != loaded) {
        await runBounded([qdbus, 'org.kde.KWin', '/Effects', 'org.kde.kwin.Effects.${loaded ? 'loadEffect' : 'unloadEffect'}', 'blur'],
            timeout: const Duration(seconds: 5));
        if (await _effectLoaded(qdbus, 'blur') != loaded) return false;
      }
      if (!loaded) return true;
      final (code, _) = await runBounded([qdbus, 'org.kde.KWin', '/Effects', 'org.kde.kwin.Effects.reconfigureEffect', 'blur'],
          timeout: const Duration(seconds: 5));
      return code == 0;
    }
    if (!await write(enabled as String?, strength as String?, loaded)) {
      await write(before['enabled'] as String?, before['strength'] as String?, before['loaded'] as bool);
      return false;
    }
    return true;
  }

  /// Tiling is selected by the stable 1-based workspace index.
  Future<Map<String, dynamic>> _setTiling(int index, bool on) async {
    if (!maprismaTilingInstalled) return {'error': 'not_available', 'message': 'Maprisma Tiling is not installed'};
    final ws = await wm(['workspaces']);
    final list = ws?['workspaces'];
    if (list is! List) return ws ?? {'error': 'unavailable'};
    if (!list.whereType<Map>().any((w) => w['index'] == index)) return {'error': 'not_found', 'message': 'no workspace $index'};
    final ignored = untiledDesktops;
    final changed = on ? ignored.remove(index) : ignored.add(index);
    if (!changed) return {'done': true};
    final indices = ignored.toList()..sort();
    if (!await _run(['kwriteconfig6', '--file', 'kwinrc', '--group', 'Script-maprisma-tiling', '--key', 'untiledDesktops', indices.join(',')])) {
      return {'error': 'unavailable', 'message': 'kwinrc could not be written'};
    }
    await _run(['qdbus6', 'org.kde.KWin', '/KWin', 'reconfigure']);
    return {'done': true};
  }

  /// KWin through scripts (kwin_bridge.dart), opened on first use.
  KWinBridge? _bridge;

  /// The bridge's scripts unloaded (the daemon at exit).
  Future<void> close() async {
    final b = _bridge;
    _bridge = null;
    await b?.dispose();
  }
  KWinBridge? get bridge {
    if (_bridge != null) return _bridge;
    final bus = sessionBus(environment);
    return bus == null ? null : _bridge = KWinBridge(bus, scriptDir: paths.runtime);
  }

  /// ~/.config (XDG_CONFIG_HOME): the folder COSMIC's config is in.
  String get _configHome => File(paths.cosmicConfig).parent.path;
  String get _kdeglobals => '$_configHome/kdeglobals';
  String get _appletsrc => '$_configHome/plasma-org.kde.plasma.desktop-appletsrc';
  String get _konsolerc => '$_configHome/konsolerc';
  String get _konsoleDir => '${paths.data}/konsole';

  String _text(String path) => readSmall(path, limit: 1024 * 1024) ?? '';

  /// XDG_DATA_DIRS (the system's data folders).
  List<String> get _dataDirs {
    final v = environment['XDG_DATA_DIRS'];
    final dirs = (v == null || v.isEmpty ? '/usr/local/share:/usr/share' : v).split(':');
    return [for (final d in dirs) if (d.startsWith('/')) d];
  }

  String? _program(String name) {
    for (final dir in const ['/usr/lib', '/usr/libexec']) {
      if (name == 'plasma-changeicons' && Posix.instance.executable('$dir/$name')) return '$dir/$name';
    }
    return which(name, environment);
  }

  Future<bool> _run(List<String> argv, {Duration timeout = const Duration(seconds: 20)}) async {
    final program = _program(argv.first);
    if (program == null) return false;
    final (code, _) = await runBounded([program, ...argv.skip(1)], timeout: timeout);
    return code == 0;
  }

  /// Runs a plasmashell script (`print` lines come back), or null.
  Future<String?> _plasmaScript(String script) async {
    final qdbus = which('qdbus6', environment) ?? which('qdbus', environment);
    if (qdbus == null) return null;
    final (code, out) = await runBounded(
      [qdbus, 'org.kde.plasmashell', '/PlasmaShell', 'org.kde.PlasmaShell.evaluateScript', script],
      maxBytes: 256 * 1024,
      timeout: const Duration(seconds: 15),
    );
    return code == 0 ? out : null;
  }

  // --- colors ----------------------------------------------------------------

  @override
  Future<bool> applyColors(Map<String, String> colors) async {
    final template = readSmall('${paths.templates}/kde.colors.tpl', limit: 256 * 1024);
    if (template == null) return false;
    final name = _nextSchemeName();
    final text = renderKdeScheme(template, resolveColors(colors), name);
    if (text == null) return false;
    return _applyScheme(name, text);
  }

  /// A KDE Store scheme as it came, under Maprisma's alternating name.
  @override
  Future<bool> applyKdeScheme(String path) async {
    final original = readSmall(path, limit: 256 * 1024);
    if (original == null) return false;
    final name = _nextSchemeName();
    var text = setIniValue(original, 'General', 'ColorScheme', name);
    text = setIniValue(text, 'General', 'Name', name);
    return _applyScheme(name, text);
  }

  String _nextSchemeName() {
    final inUse = iniValue(_text(_kdeglobals), 'General', 'ColorScheme');
    return inUse == kdeSchemeNames.first ? kdeSchemeNames.last : kdeSchemeNames.first;
  }

  Future<bool> _applyScheme(String name, String text) async {
    final dir = '${paths.data}/color-schemes';
    try {
      writeText('$dir/$name.colors', text, mode: 420);
    } on FileSystemException {
      return false;
    }
    if (!await _run(['plasma-apply-colorscheme', name])) return false;
    if (iniValue(_text(_kdeglobals), 'General', 'ColorScheme') != name) return false;
    for (final other in kdeSchemeNames) {
      if (other != name) DesktopBase.deleteQuietly('$dir/$other.colors');
    }
    // The active window frame (Maprisma Tiling) in the theme's accent.
    final focus = kdeRgbHex(iniValue(text, 'Colors:View', 'DecorationFocus'));
    if (focus != null) {
      await _run(['kwriteconfig6', '--file', 'kwinrc', '--group', 'Script-maprisma-tiling', '--key', 'borderColor', focus]);
      // The script reads its settings when KWin reconfigures.
      await _run(['qdbus6', 'org.kde.KWin', '/KWin', 'reconfigure']);
    }
    return true;
  }

  @override
  Future<bool> applyRon(String path) async => false;

  @override
  Future<Map<String, dynamic>?> current() async => kdeCurrentLook(_text(_kdeglobals));

  // --- wallpaper: every desktop containment, through plasmashell ---------------

  /// {containment id: {plugin, image}} of the desktops, read from plasmashell's
  /// config file. Plasma writes it with a delay (seconds): good for showing the
  /// wallpaper, not for putting one back ([snapshotBackground] asks Plasma).
  Map<String, Map<String, String?>> _desktops() {
    final out = <String, Map<String, String?>>{};
    String? group;
    for (final raw in const LineSplitter().convert(_text(_appletsrc))) {
      final line = raw.trim();
      if (line.startsWith('[') && line.endsWith(']')) {
        group = line.substring(1, line.length - 1);
        continue;
      }
      final eq = line.indexOf('=');
      if (group == null || eq < 0) continue;
      final key = line.substring(0, eq), value = line.substring(eq + 1);
      final top = RegExp(r'^Containments\]\[(\d+)$').firstMatch(group);
      if (top != null && key == 'wallpaperplugin') {
        out.putIfAbsent(top[1]!, () => {})['plugin'] = value;
        continue;
      }
      final image = RegExp(r'^Containments\]\[(\d+)\]\[Wallpaper\]\[org\.kde\.image\]\[General$').firstMatch(group);
      if (image != null && key == 'Image') out.putIfAbsent(image[1]!, () => {})['image'] = value;
    }
    out.removeWhere((_, v) => v['plugin'] == null);
    return out;
  }

  static String? _filePath(String? url) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('/')) return url;
    try {
      final u = Uri.parse(url);
      return u.scheme == 'file' ? u.toFilePath() : null;
    } on FormatException {
      return null;
    }
  }

  @override
  String? wallpaper() {
    for (final d in _desktops().values) {
      if (d['plugin'] == 'org.kde.image') return _filePath(d['image']);
    }
    return null;
  }

  /// [targets]: {containment id: (plugin, image url or null)}; null = every desktop
  /// gets [image] with the image plugin.
  Future<bool> _setDesktops(String? image, Map<String, (String, String?)>? targets) async {
    final data = jsonEncode({
      'image': image,
      'targets': targets?.map((k, v) => MapEntry(k, {'plugin': v.$1, 'image': v.$2})),
    });
    final out = await _plasmaScript('''
var data = $data;
var n = 0;
desktops().forEach(function (d) {
  var t = data.targets === null ? {plugin: 'org.kde.image', image: data.image} : data.targets[String(d.id)];
  if (!t) return;
  d.wallpaperPlugin = t.plugin;
  if (t.image !== null && t.plugin === 'org.kde.image') {
    d.currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];
    d.writeConfig('Image', t.image);
  }
  n++;
});
print('maprisma-done ' + n);
''');
    return out != null && RegExp(r'maprisma-done [1-9]').hasMatch(out);
  }

  @override
  Future<bool> setWallpaper(String path) async {
    if (!path.startsWith('/') || !File(path).existsSync()) return false;
    // Every way a background reaches the desktop is checked here.
    if (imageSizeProblem(path) != null) return false;
    return _setDesktops(Uri.file(path).toString(), null);
  }

  /// What every desktop shows now, asked from plasmashell (its config file
  /// lags behind). An image desktop without an `Image` of its own (Plasma's
  /// default picture) is kept as an empty image, which puts the default back.
  @override
  Future<Object?> snapshotBackground() async {
    final out = await _plasmaScript('''
var r = {};
desktops().forEach(function (d) {
  d.currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];
  r[String(d.id)] = {plugin: d.wallpaperPlugin, image: d.wallpaperPlugin === 'org.kde.image' ? String(d.readConfig('Image') || '') : null};
});
print('maprisma-snapshot ' + JSON.stringify(r));
''');
    final m = out == null ? null : RegExp(r'maprisma-snapshot (\{.*\})').firstMatch(out);
    if (m == null) return null;
    try {
      final raw = jsonDecode(m[1]!) as Map<String, dynamic>;
      return <String, (String, String?)>{
        for (final e in raw.entries)
          if (e.value is Map && e.value['plugin'] is String) e.key: (e.value['plugin'] as String, e.value['image'] as String?),
      };
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  @override
  Future<bool> restoreBackground(Object? snapshot) async {
    if (snapshot is! Map<String, (String, String?)>) return false;
    if (snapshot.isEmpty) return true;
    return _setDesktops(null, snapshot);
  }

  // --- Konsole --------------------------------------------------------------------

  /// Writes the Maprisma color scheme and gives it to Konsole's default
  /// profile: the user's own profile keeps everything else; without one,
  /// a Maprisma profile becomes the default.
  @override
  Future<bool> setTerminal(Map<String, String> colors, String name) async {
    if (which('konsole', environment) == null) return false;
    final template = readSmall('${paths.templates}/konsole.colorscheme.tpl', limit: 256 * 1024);
    if (template == null) return false;
    final scheme = renderKdeScheme(template, resolveColors(colors), 'Maprisma: $name');
    if (scheme == null) return false;
    try {
      writeText('$_konsoleDir/$konsoleSchemeName.colorscheme', scheme, mode: 420);
      final rc = _text(_konsolerc);
      final def = iniValue(rc, 'Desktop Entry', 'DefaultProfile');
      // The default profile wherever Konsole finds it (the user's folder
      // first, then the system's); a system one gets a copy in the user's
      // folder, which Konsole then uses, so all its settings stay.
      final found = def != null && def.isNotEmpty && !def.contains('/') && def.endsWith('.profile')
          ? [_konsoleDir, ..._dataDirs.map((d) => '$d/konsole')].map((d) => '$d/$def').where((p) => File(p).existsSync()).firstOrNull
          : null;
      final own = found != null ? def : null;
      final file = own ?? '$konsoleProfileName.profile';
      final existing = readSmall(found ?? '$_konsoleDir/$file', limit: 256 * 1024);
      final profileName = existing == null ? konsoleProfileName : iniValue(existing, 'General', 'Name') ?? konsoleProfileName;
      writeText('$_konsoleDir/$file', konsoleProfile(existing, profileName, konsoleSchemeName), mode: 420);
      if (own == null) writeText(_konsolerc, setIniValue(rc.isEmpty ? null : rc, 'Desktop Entry', 'DefaultProfile', file), mode: 384);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  // --- fonts and icons: kdeglobals ---------------------------------------------------

  Future<bool> _notifyFont() =>
      _run(['dbus-send', '--session', '--type=signal', '/KGlobalSettings', 'org.kde.KGlobalSettings.notifyChange', 'int32:1', 'int32:0']);

  @override
  String? monospaceFont() => qfontFamily(iniValue(_text(_kdeglobals), 'General', 'fixed'));

  @override
  Future<bool> setMonospaceFont(String family) async {
    if (!(await monospaceFonts()).contains(family)) return false;
    final String value;
    try {
      value = qfontWithFamily(iniValue(_text(_kdeglobals), 'General', 'fixed'), family);
    } on ArgumentError {
      return false;
    }
    if (!await _run(['kwriteconfig6', '--file', 'kdeglobals', '--group', 'General', '--key', 'fixed', value])) return false;
    await _notifyFont();
    return true;
  }

  @override
  Future<bool> resetMonospaceFont() async {
    if (!await _run(['kwriteconfig6', '--file', 'kdeglobals', '--group', 'General', '--key', 'fixed', '--delete'])) return false;
    await _notifyFont();
    return true;
  }

  /// The interface font: kdeglobals [General] font. The other fonts KDE
  /// shows in the interface follow when they had the same family (as
  /// System Settings' "Adjust All Fonts"); a font of its own stays.
  static const _interfaceFollowers = [('General', 'menuFont'), ('General', 'toolBarFont'), ('WM', 'activeFont')];

  /// The keys a theme's interface font changed, with their values before
  /// (null: the key was missing); written before the first change, so going
  /// back touches exactly those keys and puts back what they were.
  String get _uiFontReceipt => '${paths.state}/kde-ui-font.json';

  Map<String, String?>? _uiReceipt() {
    final m = readJsonMap(_uiFontReceipt);
    if (m.isEmpty || m.values.any((v) => v != null && v is! String)) return null;
    return {for (final e in m.entries) e.key: e.value as String?};
  }

  /// Writes kdeglobals values ({"Group/key": value or null to delete}); on a
  /// failure the keys already written get their old values back.
  Future<bool> _writeGlobals(Map<String, String?> values) async {
    final text = _text(_kdeglobals);
    final done = <String, String?>{};
    for (final e in values.entries) {
      final [group, key] = e.key.split('/');
      final before = iniValue(text, group, key);
      if (!await _run(['kwriteconfig6', '--file', 'kdeglobals', '--group', group, '--key', key, e.value ?? '--delete'])) {
        for (final d in done.entries) {
          final [g, k] = d.key.split('/');
          await _run(['kwriteconfig6', '--file', 'kdeglobals', '--group', g, '--key', k, d.value ?? '--delete']);
        }
        return false;
      }
      done[e.key] = before;
    }
    return true;
  }

  @override
  String? interfaceFont() => qfontFamily(iniValue(_text(_kdeglobals), 'General', 'font'));

  @override
  Future<bool> setInterfaceFont(String family) async {
    if (!(await interfaceFonts()).contains(family)) return false;
    final text = _text(_kdeglobals);
    final receipt = _uiReceipt();
    if (receipt != null && qfontFamily(receipt['General/font']) == family) return _restoreInterfaceFont(receipt);
    final keys = receipt?.keys.toList() ?? [
      'General/font',
      for (final (group, key) in _interfaceFollowers)
        if (interfaceFont() case final String old when qfontFamily(iniValue(text, group, key)) == old) '$group/$key',
    ];
    final Map<String, String?> values;
    try {
      values = {
        for (final k in keys) k: qfontWithFamily(iniValue(text, k.split('/')[0], k.split('/')[1]), family),
      };
    } on ArgumentError {
      return false;
    }
    final fresh = receipt == null;
    if (fresh) writeJson(_uiFontReceipt, {for (final k in keys) k: iniValue(text, k.split('/')[0], k.split('/')[1])});
    if (!await _writeGlobals(values)) {
      if (fresh) _dropUiReceipt();
      return false;
    }
    await _notifyFont();
    return true;
  }

  /// Back to KDE's default interface font: what a theme changed goes back as
  /// it was (the default when the font key was missing); without a theme's
  /// change only the font key goes.
  @override
  Future<bool> resetInterfaceFont() async {
    final receipt = _uiReceipt();
    if (receipt != null) return _restoreInterfaceFont(receipt);
    if (!await _writeGlobals({'General/font': null})) return false;
    await _notifyFont();
    return true;
  }

  Future<bool> _restoreInterfaceFont(Map<String, String?> receipt) async {
    if (!await _writeGlobals(receipt)) return false;
    _dropUiReceipt();
    await _notifyFont();
    return true;
  }

  void _dropUiReceipt() {
    try {
      File(_uiFontReceipt).deleteSync();
    } on FileSystemException {
      // already gone
    }
  }

  @override
  String? iconTheme() => iniValue(_text(_kdeglobals), 'Icons', 'Theme') ?? 'breeze';

  @override
  Future<bool> setIconTheme(String name) async {
    if (!iconThemes().contains(name)) return false;
    return _run(['plasma-changeicons', name]);
  }

  // --- not yet on KDE (step 4) -------------------------------------------------------

  @override
  Future<Map<String, dynamic>?> wm(List<String> args, {Duration timeout = const Duration(seconds: 20)}) async {
    if (args.length == 1 && args[0] == 'tile-style') return tileStyle();
    if (args.length == 2 && args[0] == 'set-tile-style') return _setTileStyle(args[1]);
    if (args.length == 1 && args[0] == 'animations') return animations();
    if (args.length == 2 && args[0] == 'set-animations') return _setAnimations(args[1]);
    if (args.length == 3 && args[0] == 'set-tiling' && int.tryParse(args[1]) != null && (args[2] == 'on' || args[2] == 'off')) {
      return _setTiling(int.parse(args[1]), args[2] == 'on');
    }
    final b = bridge;
    if (b == null) return {'error': 'unavailable', 'message': 'no session bus'};
    try {
      final r = await kdeWm(b, args).timeout(timeout);
      return args.isNotEmpty && args.first == 'workspaces' ? withTiling(r) : r;
    } on Object catch (e) {
      return {'error': 'unavailable', 'message': '$e'};
    }
  }

  @override
  ShortcutBinder shortcutBinder(Paths paths) => KdeShortcutBinder(paths, environment);

  @override
  Stream<Map<String, dynamic>>? watch() => bridge?.watch();

  /// `helper`: are Plasma's tools there (no helper of ours is needed).
  @override
  Future<Map<String, dynamic>> health(Paths paths, Map<String, String> environment) async {
    final tool = _program('plasma-apply-colorscheme');
    final qdbus = which('qdbus6', environment) ?? which('qdbus', environment);
    return {
      'helper': {'ok': tool != null && qdbus != null && _program('kwriteconfig6') != null, 'path': tool},
    };
  }
}
