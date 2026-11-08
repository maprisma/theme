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
  /// No `tiling` (KWin has no per-desktop switch Maprisma Theme can drive;
  /// Krohnkite has no control API) and no `panel` (the daemon's tray icon
  /// stands in).
  @override
  Set<Cap> get caps => const {
    Cap.appearance, Cap.kdeScheme, Cap.wallpaper, Cap.terminal, Cap.fonts, Cap.icons,
    Cap.workspaces, Cap.windows, Cap.shortcuts,
  };

  /// KWin through scripts (kwin_bridge.dart), opened on first use.
  KWinBridge? _bridge;
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
    final b = bridge;
    if (b == null) return {'error': 'unavailable', 'message': 'no session bus'};
    try {
      return await kdeWm(b, args).timeout(timeout);
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
