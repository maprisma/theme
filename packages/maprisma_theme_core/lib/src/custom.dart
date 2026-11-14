import 'proposals.dart';
import 'i18n.dart';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'apply.dart';
import 'auto.dart' show renameThemeState;
import 'colors.dart';
import 'context.dart';
import 'extract.dart';
import 'looks.dart' show checkLook;
import 'posix.dart';
import 'preview_draw.dart';
import 'store.dart';
import 'themes.dart';

/// Your own themes, made from an existing one or from a picture
/// (theme_custom.py). A custom theme is an ordinary user theme in
/// `~/.config/maprisma-theme/themes/<slug>/`:
///
/// - colors.toml: the colors you picked (only #rrggbb values; the base
///   theme's other values are kept as they were),
/// - backgrounds/: copies of the base theme's visible wallpapers (optional),
/// - icons.theme: taken over from the base theme,
/// - preview.png: drawn from the first wallpaper and the colors,
/// - theme-manager.json: the base theme and the font, so it can be edited again,
/// - cosmic.ron: only for themes imported from cosmic-themes.org.
///
/// Nothing that runs code is ever copied.

const markerName = 'theme-manager.json';
final _hexRe = RegExp(r'^#[0-9a-fA-F]{6}$');
final fontRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,79}$');
const maxColorsBytes = 64 * 1024;
const maxWallpapers = 60;
const maxNameLength = 40;
const maxRonBytes = 256 * 1024;
const defaultThemeName = 'New Custom Theme';

// The keys Omarchy's templates use, in the order colors.toml lists them.
// Derived keys follow their base color unless edited.
const mainKeys = ['background', 'foreground', 'accent', 'selection', 'muted'];
const paletteKeys = ['red', 'yellow', 'orange', 'green', 'cyan', 'blue', 'magenta', 'brown'];
const shadeKeys = [
  'dark_background',
  'darker_background',
  'lighter_background',
  'dark_foreground',
  'light_foreground',
  'bright_foreground',
];
const brightKeys = ['bright_red', 'bright_yellow', 'bright_green', 'bright_cyan', 'bright_blue', 'bright_magenta'];
const knownKeys = [...mainKeys, ...shadeKeys, ...paletteKeys, ...brightKeys];

/// The editor's groups: the terminal colors with their bright variants, and
/// every other shade under "More colors" (the base's own plain colors last).
const terminalKeys = [
  'red',
  'green',
  'yellow',
  'blue',
  'magenta',
  'cyan',
  'bright_red',
  'bright_green',
  'bright_yellow',
  'bright_blue',
  'bright_magenta',
  'bright_cyan',
];
const moreKeys = ['orange', 'brown', ...shadeKeys];

/// Keys whose change moves the shades and bright variants not edited by hand.
const baseColorKeys = [...mainKeys, ...paletteKeys];

Map<String, String> get _labels => {
  'red': tr("Red"),
  'yellow': tr("Yellow"),
  'orange': tr("Orange"),
  'green': tr("Green"),
  'cyan': tr("Cyan"),
  'blue': tr("Blue"),
  'magenta': tr("Magenta"),
  'brown': tr("Brown"),
  'bright_red': tr("Bright red"),
  'bright_yellow': tr("Bright yellow"),
  'bright_green': tr("Bright green"),
  'bright_cyan': tr("Bright cyan"),
  'bright_blue': tr("Bright blue"),
  'bright_magenta': tr("Bright magenta"),

  'background': tr("Background"),
  'foreground': tr("Text"),
  'accent': tr("Accent"),
  'selection': tr("Selection"),
  'muted': tr("Muted text"),
  'dark_background': tr("Background, darker"),
  'darker_background': tr("Background, darkest"),
  'lighter_background': tr("Background, lighter"),
  'dark_foreground': tr("Text, dim"),
  'light_foreground': tr("Text, soft"),
  'bright_foreground': tr("Text, bright"),
};

const defaultColors = {
  'background': '#1e1e2e',
  'foreground': '#cdd6f4',
  'accent': '#89b4fa',
  'selection': '#45475a',
  'muted': '#6c7086',
  'red': '#f38ba8',
  'yellow': '#f9e2af',
  'orange': '#fab387',
  'green': '#a6e3a1',
  'cyan': '#94e2d5',
  'blue': '#89b4fa',
  'magenta': '#cba6f7',
  'brown': '#7d5d3b',
};

String colorLabel(String key) {
  final l = _labels[key];
  if (l != null) return l;
  final words = key.replaceAll('bright_', 'bright ').replaceAll('_', ' ');
  return words.isEmpty ? key : words[0].toUpperCase() + words.substring(1);
}

/// The plugin's plain luminance (dark or light background).
double _plainLuminance(String hex) {
  final (r, g, b) = rgbOf(hex);
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

bool isDarkBackground(String hex) => _plainLuminance(hex) < 0.5;

/// Shades and bright variants computed from the main colors.
Map<String, String> derivedColors(Map<String, String> colors) {
  final bg = colors['background']!, fg = colors['foreground']!;
  final dark = isDarkBackground(bg);
  final edge = dark ? '#000000' : '#ffffff';
  final muted = colors['muted'];
  final out = <String, String>{
    'dark_background': mixColor(bg, edge, 0.25),
    'darker_background': mixColor(bg, edge, 0.5),
    'lighter_background': mixColor(bg, fg, 0.08),
    'dark_foreground': isHex(muted) ? muted!.toLowerCase() : mixColor(fg, bg, 0.5),
    'light_foreground': mixColor(fg, bg, 0.2),
    'bright_foreground': mixColor(fg, dark ? '#ffffff' : '#000000', 0.3),
  };
  final lift = dark ? '#ffffff' : '#000000';
  for (final k in ['red', 'yellow', 'green', 'cyan', 'blue', 'magenta']) {
    out['bright_$k'] = mixColor(colors[k] ?? defaultColors[k]!, lift, 0.2);
  }
  return out;
}

/// Every color of a theme: the known keys (always complete) plus any other
/// values the base theme had (kept as they were; plain colors among them
/// can be edited too).
final class Palette {
  Palette(this.colors, this.extras);
  final Map<String, String> colors;
  final Map<String, String> extras;

  List<String> get editableExtras => [
    for (final e in extras.entries)
      if (_hexRe.hasMatch(e.value)) e.key,
  ];

  String get mode => isDarkBackground(colors['background']!) ? 'dark' : 'light';

  /// The known keys and the editable extras, all #rrggbb.
  Map<String, String> get editable => {...colors, for (final k in editableExtras) k: extras[k]!.toLowerCase()};

  bool canSet(String key) => knownKeys.contains(key) || (extras.containsKey(key) && _hexRe.hasMatch(extras[key]!));

  /// Takes [given] (key -> #rrggbb): a changed base color also moves the
  /// shades and bright variants that are not given themselves. Keys that are
  /// neither known nor an editable extra are ignored.
  void take(Map<String, String> given) {
    for (final e in given.entries) {
      if (!canSet(e.key)) continue;
      if (!_hexRe.hasMatch(e.value)) throw RouteError('bad_color', trf('{0}: use #rrggbb', [e.key]));
    }
    var moved = false;
    for (final e in given.entries) {
      if (!canSet(e.key)) continue;
      final v = e.value.toLowerCase();
      if (knownKeys.contains(e.key)) {
        if (baseColorKeys.contains(e.key) && colors[e.key] != v) moved = true;
        colors[e.key] = v;
      } else {
        extras[e.key] = v;
      }
    }
    if (moved) {
      derivedColors(colors).forEach((k, v) {
        if (!given.containsKey(k)) colors[k] = v;
      });
    }
  }

  Palette copy() => Palette(Map.of(colors), Map.of(extras));
}

final _extraKeyRe = RegExp(r'^[a-z][a-z0-9_]{0,40}$');
final _extraValueRe = RegExp(r'^[#A-Za-z0-9(),. ]*$');
final _lineRe = RegExp(r'''^\s*([A-Za-z0-9_-]+)\s*=\s*(?:"([^"\\]*)"|'([^']*)')\s*(?:#.*)?$''');

/// The top-level string values of a colors.toml (tables, numbers and
/// anything odd left out, as the plugin's tomllib reading did).
Map<String, String> _topLevelStrings(String text) {
  final out = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('[')) break; // the rest belongs to a table
    if (line.isEmpty || line.startsWith('#')) continue;
    final m = _lineRe.firstMatch(line);
    if (m == null) continue;
    out[m[1]!] = m[2] ?? m[3]!;
  }
  return out;
}

/// A theme's colors.toml as a palette. Missing known keys are filled in
/// (from the legacy keys Omarchy understands, else the main colors, then
/// defaults), so every template finds its value.
Palette parsePalette(String text) {
  final data = _topLevelStrings(text);
  final colors = <String, String>{}, extras = <String, String>{};
  for (final e in data.entries) {
    if (e.key == 'mode' || !_extraKeyRe.hasMatch(e.key)) continue;
    if (knownKeys.contains(e.key)) {
      if (_hexRe.hasMatch(e.value)) colors[e.key] = e.value.toLowerCase();
    } else if (e.value.length <= 200 && _extraValueRe.hasMatch(e.value)) {
      extras[e.key] = e.value;
    }
  }
  final resolved = resolveColors(parseColorsToml(text));
  for (final k in [...mainKeys, ...paletteKeys]) {
    colors.putIfAbsent(k, () => isHex(resolved[k]) ? resolved[k]!.toLowerCase() : defaultColors[k]!);
  }
  derivedColors(colors).forEach((k, v) => colors.putIfAbsent(k, () => v));
  return Palette(colors, extras);
}

Palette paletteFromColors(Map<String, String> colors) {
  final p = parsePalette('');
  p.take({
    for (final e in colors.entries)
      if (knownKeys.contains(e.key) && isHex(e.value)) e.key: e.value,
  });
  return p;
}

String _plain(String s) => s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();

/// colors.toml text: mode, the known keys (only #rrggbb), then the base's
/// other values.
String renderColors(Palette palette, String name, String base) {
  final b = StringBuffer()
    ..writeln('# ${_plain(name)}: made with Maprisma Theme from ${_plain(base)}.')
    ..writeln("# Every app's colors are built from this file.")
    ..writeln()
    ..writeln('mode = "${palette.mode}"')
    ..writeln();
  for (final group in [mainKeys, shadeKeys, paletteKeys, brightKeys]) {
    for (final k in group) {
      final v = palette.colors[k];
      if (v != null && _hexRe.hasMatch(v)) b.writeln('$k = "${v.toLowerCase()}"');
    }
    b.writeln();
  }
  final extras = [
    for (final e in palette.extras.entries)
      if (_extraKeyRe.hasMatch(e.key) &&
          e.key != 'mode' &&
          !knownKeys.contains(e.key) &&
          e.value.length <= 200 &&
          _extraValueRe.hasMatch(e.value))
        e,
  ];
  if (extras.isNotEmpty) {
    b.writeln('# Kept from the base theme.');
    for (final e in extras) {
      b.writeln('${e.key} = "${e.value}"');
    }
    b.writeln();
  }
  return b.toString();
}

/// The palette of a theme: its colors.toml (a user copy without one: the
/// system theme's), else a native COSMIC theme's colors.
Future<Palette> loadPalette(Ctx ctx, ThemeInfo theme) async {
  for (final dir in [theme.dir, ?theme.systemDir]) {
    final f = '$dir/colors.toml';
    if (FileSystemEntity.typeSync(f) == FileSystemEntityType.notFound) continue;
    final text = readSmall(f, limit: maxColorsBytes);
    if (text == null) throw RouteError('bad_theme', tr("colors.toml is too large or unreadable"));
    return parsePalette(text);
  }
  if (theme.cosmicNative) {
    final ron = await ctx.desktop.ronColors('${theme.dir}/cosmic.ron');
    if (ron != null) return paletteFromColors(resolveColors(ron));
  }
  return parsePalette('');
}

// --- names ------------------------------------------------------------------------

/// `My Ristretto` -> `my-ristretto` (shown as "My Ristretto").
String slugFor(String name) {
  var slug = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  slug = slug.replaceAll(RegExp(r'^-+|-+$'), '').replaceAll(RegExp(r'-{2,}'), '-');
  if (slug.length > maxNameLength) slug = slug.substring(0, maxNameLength);
  slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.isEmpty) throw RouteError('bad_name', tr("give the theme a name (letters or digits)"));
  return slug;
}

final _meaningless = RegExp(
  r'^(wallhaven|img|dsc|dscn|pxl|photo|image|screenshot|pasted|dropped|wallpaper|'
  r'download|unsplash|pexels|bg|background)$',
  caseSensitive: false,
);

/// `2-coffee-beans.jpg` -> `Coffee Beans`; null when the file name says
/// nothing (`wallhaven-xlqrwv.jpg`, `IMG_0937.HEIC`, `pasted-image.png`).
String? nameFromFile(String fileName) {
  var stem = baseName(fileName);
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  stem = stem.replaceFirst(RegExp(r'^[0-9]+[-_ ]+'), '');
  final words = stem.split(RegExp(r'[^A-Za-z0-9]+')).where((w) => w.isNotEmpty).toList();
  final real = [
    for (final w in words)
      if (RegExp(r'^[A-Za-z]{3,}$').hasMatch(w) && RegExp('[aeiouy]', caseSensitive: false).hasMatch(w) && !_meaningless.hasMatch(w)) w,
  ];
  if (real.isEmpty || real.length < words.length / 2) return null;
  var name = real.map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase()).join(' ');
  if (name.length > maxNameLength) name = name.substring(0, maxNameLength);
  name = name.trim();
  return name.isEmpty ? null : name;
}

Set<String> _taken(Ctx ctx) => {for (final t in ctx.themes()) t.slug};

/// [name], or `name 2`, `name 3`, … if a theme with that name exists.
String uniqueName(Ctx ctx, String name) {
  final taken = _taken(ctx);
  for (var n = 1; n < 100; n++) {
    final candidate = n == 1 ? name : '$name $n';
    try {
      if (!taken.contains(slugFor(candidate))) return candidate;
    } on RouteError {
      return defaultThemeName;
    }
  }
  return '$name ${ctx.clock().millisecondsSinceEpoch ~/ 1000}';
}

String suggestedName(Ctx ctx, String baseSlug) {
  final taken = _taken(ctx);
  String cut(String s) => s.length > maxNameLength ? s.substring(0, maxNameLength) : s;
  for (var n = 1; n < 100; n++) {
    final slug = cut(n == 1 ? 'my-$baseSlug' : 'my-$baseSlug-$n');
    if (!taken.contains(slug)) return displayName(slug);
  }
  return displayName('my-$baseSlug-${ctx.clock().millisecondsSinceEpoch ~/ 1000}');
}

// --- the marker ------------------------------------------------------------------

/// Maprisma Theme's note in a custom theme, or null for any other theme.
Map<String, dynamic>? markerOf(ThemeInfo theme) {
  if (theme.system) return null;
  final path = '${theme.dir}/$markerName';
  if (FileSystemEntity.isLinkSync(path)) return null;
  final text = readSmall(path, limit: 4096);
  if (text == null) return null;
  final data = readJson(path);
  return data is Map ? Map<String, dynamic>.from(data) : null;
}

bool isCustom(ThemeInfo theme) => !theme.fromGit && !FileSystemEntity.isLinkSync(theme.dir) && markerOf(theme) != null;

String? fontOf(ThemeInfo theme) {
  final f = markerOf(theme)?['font'];
  return f is String && fontRe.hasMatch(f) ? f : null;
}

/// The blur a theme made here brings ({on, strength}), if any.
Map<String, dynamic>? blurOf(ThemeInfo theme) => _blurOrNull(markerOf(theme)?['blur']);

Map<String, dynamic>? _blurOrNull(Object? v) => checkLook({'blur': v})?['blur'] as Map<String, dynamic>?;

/// A blur given to a save: null (none) or {on: bool, strength: 1..15}.
Map<String, dynamic>? _checkBlur(Object? v) {
  if (v == null) return null;
  return _blurOrNull(v) ?? (throw RouteError('bad_blur', tr('blur: {on, strength 1..15}')));
}

// --- file system --------------------------------------------------------------------

final _libc = DynamicLibrary.open('libc.so.6');
final _mkdir = _libc.lookupFunction<Int Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('mkdir');
final int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)? _renameat2 = () {
  try {
    return _libc.lookupFunction<
      Int Function(Int, Pointer<Utf8>, Int, Pointer<Utf8>, Uint32),
      int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
    >('renameat2');
  } on ArgumentError {
    return null;
  }
}();

/// mkdir(2): false when it exists already (never writes into a foreign folder).
bool _mkdirNew(String path, {int mode = 493 /* 0755 */}) {
  final p = path.toNativeUtf8();
  try {
    return _mkdir(p, mode) == 0;
  } finally {
    malloc.free(p);
  }
}

/// Renames [from] to [to], never replacing anything at [to].
void _renameNoReplace(String from, String to) {
  final f = _renameat2;
  if (f != null) {
    final a = from.toNativeUtf8(), b = to.toNativeUtf8();
    try {
      if (f(-100, a, -100, b, 1 /* RENAME_NOREPLACE */) == 0) return;
    } finally {
      malloc.free(a);
      malloc.free(b);
    }
    if (FileSystemEntity.typeSync(to, followLinks: false) != FileSystemEntityType.notFound) {
      throw RouteError('exists', trf("{0} already exists", [baseName(to)]));
    }
  }
  if (FileSystemEntity.typeSync(to, followLinks: false) != FileSystemEntityType.notFound) {
    throw RouteError('exists', trf("{0} already exists", [baseName(to)]));
  }
  Directory(from).renameSync(to);
}

final _unsafeName = RegExp('[\\x00-\\x1f\\x7f<>"\'|:*?\\\\/]');

String _sanitizeName(String name) {
  var n = baseName(name);
  if (n.isEmpty || n == '.' || n == '..') n = 'image';
  n = n.replaceAll(_unsafeName, '_').trim().replaceAll(RegExp(r'^\.+|\.+$'), '');
  if (n.length > 200) n = n.substring(n.length - 200);
  return n.isEmpty ? 'image' : n;
}

/// Copies one picture into [dir]/backgrounds/ (an image, header checked, at
/// most 50 MiB, never over an existing file). The new path, or null.
String? _copyPicture(String source, String dir) {
  final ext = extOf(source);
  if (!imageExts.contains(ext)) return null;
  final folder = Directory('$dir/backgrounds');
  if (!folder.existsSync()) folder.createSync(recursive: true);
  final bytes = Posix.instance.readRegular(source, maxImageBytes);
  if (bytes == null || headerSizeProblem(bytes) != null) return null;
  final dest = '${folder.path}/${_sanitizeName(source)}';
  if (!Posix.instance.writeNewPrivate(dest, bytes)) return null;
  chmodPath(dest, 420 /* 0644 */);
  return dest;
}

int _copyWallpapers(Ctx ctx, ThemeInfo base, String dir, int room) {
  var copied = 0;
  for (final w in listBackgrounds(ctx.paths, base)) {
    if (copied >= room) break;
    if (w.hidden) continue;
    if (_copyPicture(w.path, dir) != null) copied++;
  }
  return copied;
}

void _copyIcons(ThemeInfo base, String dir) {
  for (final d in [base.dir, ?base.systemDir]) {
    final source = '$d/icons.theme';
    if (FileSystemEntity.isLinkSync(source)) return;
    final text = readSmall(source, limit: 200);
    if (text == null) continue;
    final first = text.trim().split('\n').first.trim();
    if (RegExp(r'^[A-Za-z0-9._+-]{1,80}$').hasMatch(first)) writeText('$dir/icons.theme', '$first\n', mode: 420);
    return;
  }
}

/// Where a theme came from (cosmic-themes.org imports): kept on every save.
const _importKeys = ['source', 'id', 'author', 'homepage'];

void _writeMarker(String dir, String base, String? font, num created, [Map<String, dynamic> keep = const {}, Map<String, dynamic>? blur]) =>
    writeJson('$dir/$markerName', {...keep, 'base': base, 'font': font, 'created': created, 'blur': ?blur}, mode: 420);

/// An edited theme's colors are colors.toml's from now on: its cosmic.ron
/// (a cosmic-themes.org import) is kept as cosmic.ron.orig, so applying it
/// gives COSMIC the same colors as the terminals and apps.
void _setRonAside(String dir) {
  final ron = '$dir/cosmic.ron';
  if (FileSystemEntity.typeSync(ron, followLinks: false) == FileSystemEntityType.notFound) return;
  var dest = '$ron.orig';
  for (var n = 2; FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound; n++) {
    dest = '$ron.orig-$n';
  }
  File(ron).renameSync(dest);
}

/// The first picture of a theme's folder, else of its added wallpapers.
String? _firstPicture(Ctx ctx, String dir, String slug) {
  for (final folder in ['$dir/backgrounds', '${ctx.paths.backgrounds}/$slug']) {
    final found = imagesIn(folder).where((p) => !FileSystemEntity.isLinkSync(p)).toList();
    if (found.isNotEmpty) return found.first;
  }
  return null;
}

/// Writes preview.png into [dir]; false when it could not be drawn.
Future<bool> makePreview(Ctx ctx, String dir, Palette palette, {String? wallpaper}) async {
  try {
    final png = await drawPreview(palette.colors, wallpaper ?? _firstPicture(ctx, dir, baseName(dir)));
    writeAtomic('$dir/preview.png', png, mode: 420);
    return true;
  } catch (_) {
    return false;
  }
}

String? _checkFont(String? font) {
  if (font == null || font.isEmpty) return null;
  if (!fontRe.hasMatch(font)) throw RouteError('bad_font', tr("bad font name"));
  return font;
}

// --- create, edit, rename ------------------------------------------------------------

/// A new user theme: colors.toml from [colors] (known keys as #rrggbb; on top
/// of [baseSlug]'s palette, whose other values are kept; shades not given
/// follow the main colors), icons.theme from the base, copies of
/// [wallpapers] (and with [copyBaseWallpapers] the base's visible ones),
/// [cosmicRon] as cosmic.ron, preview.png and theme-manager.json. Never
/// overwrites an existing theme. Returns the slug.
Future<String> createThemeFolder(
  Ctx ctx, {
  required String name,
  required Map<String, String> colors,
  String? font,
  String? baseSlug,
  List<String> wallpapers = const [],
  String? cosmicRon,
  bool copyBaseWallpapers = false,
  Map<String, dynamic>? blur,
}) async {
  final slug = slugFor(name);
  if (!slugRe.hasMatch(slug)) throw RouteError('bad_name', tr("give the theme a name (letters or digits)"));
  font = _checkFont(font);
  blur = _checkBlur(blur);
  if (cosmicRon != null && cosmicRon.length > maxRonBytes) throw RouteError('too_large', tr("cosmic.ron is too large"));
  final base = baseSlug == null ? null : findTheme(ctx.paths, baseSlug);
  if (baseSlug != null && base == null) throw RouteError('not_found', trf("no theme {0}", [baseSlug]));
  final palette = base != null ? (await loadPalette(ctx, base)).copy() : parsePalette('');
  palette.take(colors);
  if (_taken(ctx).contains(slug)) throw RouteError('exists', trf("a theme called {0} already exists", [displayName(slug)]));
  checkAskAiBoundary();
  Directory(ctx.paths.userThemes).createSync(recursive: true);
  final dir = '${ctx.paths.userThemes}/$slug';
  if (!_mkdirNew(dir)) throw RouteError('exists', trf("a theme called {0} already exists", [displayName(slug)]));
  try {
    writeText('$dir/colors.toml', renderColors(palette, displayName(slug), base?.name ?? 'scratch'), mode: 420);
    if (base != null) _copyIcons(base, dir);
    String? firstOwn;
    var copied = 0;
    for (final w in wallpapers) {
      if (copied >= maxWallpapers) break;
      final p = _copyPicture(w, dir);
      if (p == null) continue;
      firstOwn ??= p;
      copied++;
    }
    if (copyBaseWallpapers && base != null) _copyWallpapers(ctx, base, dir, maxWallpapers - copied);
    if (cosmicRon != null) writeText('$dir/cosmic.ron', cosmicRon, mode: 420);
    _writeMarker(dir, base?.slug ?? '', font, ctx.clock().millisecondsSinceEpoch / 1000, const {}, blur);
    await makePreview(ctx, dir, palette, wallpaper: firstOwn);
  } catch (_) {
    try {
      Directory(dir).deleteSync(recursive: true);
    } on FileSystemException {
      // nothing more to clean up
    }
    rethrow;
  }
  return slug;
}

ThemeInfo _editable(Ctx ctx, String slug) {
  final theme = ctx.theme(slug);
  if (!isCustom(theme)) throw RouteError('not_custom', tr("only themes made with Maprisma Theme can be edited here"));
  return theme;
}

/// New colors, font and blur for a custom theme.
Future<void> updateTheme(Ctx ctx, ThemeInfo theme, Palette palette, String? font, {Map<String, dynamic>? blur}) async {
  final marker = markerOf(theme);
  if (marker == null || theme.fromGit) {
    throw RouteError('not_custom', tr("only themes made with Maprisma Theme can be edited here"));
  }
  font = _checkFont(font);
  blur = _checkBlur(blur);
  final base = marker['base'] is String ? marker['base'] as String : '';
  final baseLabel = base.isEmpty ? 'scratch' : displayName(base);
  writeText('${theme.dir}/colors.toml', renderColors(palette, theme.name, baseLabel), mode: 420);
  final created = marker['created'] is num ? marker['created'] as num : ctx.clock().millisecondsSinceEpoch / 1000;
  _setRonAside(theme.dir);
  _writeMarker(theme.dir, base, font, created, {
    for (final k in _importKeys)
      if (marker[k] != null) k: marker[k],
  }, blur);
  await makePreview(ctx, theme.dir, palette);
}

/// Gives a custom theme a new name: its folder, its added wallpapers' folder
/// and every list that names it move along. Returns the new slug.
String renameTheme(Ctx ctx, ThemeInfo theme, String newName) {
  if (!isCustom(theme)) throw RouteError('not_custom', tr("only themes made with Maprisma Theme can be renamed here"));
  final old = theme.slug, slug = slugFor(newName);
  if (slug == old) return old;
  if (_taken(ctx).contains(slug)) throw RouteError('exists', trf("a theme called {0} already exists", [displayName(slug)]));
  final source = '${ctx.paths.userThemes}/$old';
  if (FileSystemEntity.isLinkSync(source) || !FileSystemEntity.isDirectorySync(source)) {
    throw RouteError('not_custom', tr("not a theme folder of yours"));
  }
  final oldWalls = '${ctx.paths.backgrounds}/$old', newWalls = '${ctx.paths.backgrounds}/$slug';
  if (FileSystemEntity.typeSync(newWalls, followLinks: false) != FileSystemEntityType.notFound) {
    throw RouteError('exists', trf("{0} already exists", [newWalls]));
  }
  _renameNoReplace(source, '${ctx.paths.userThemes}/$slug');
  if (FileSystemEntity.isDirectorySync(oldWalls) && !FileSystemEntity.isLinkSync(oldWalls)) {
    _renameNoReplace(oldWalls, newWalls);
  }
  _renameLists(ctx, old, slug);
  // Workspace themes and wallpapers, day/night and the theme's key (module C).
  renameThemeState(ctx, old, slug);
  return slug;
}

/// The shared lists (hidden, favorites, recent, hidden wallpapers, the
/// remembered wallpaper and the theme in use) follow a renamed theme.
void _renameLists(Ctx ctx, String old, String slug) {
  final lists = ctx.lists;
  final hidden = lists.hidden;
  if (hidden.remove(old)) lists.hidden = hidden..add(slug);
  final favorites = lists.favorites;
  if (favorites.contains(old)) lists.favorites = [for (final f in favorites) f == old ? slug : f];
  final recent = lists.recent;
  if (recent.containsKey(old)) {
    recent[slug] = recent.remove(old)!;
    writeJson(ctx.paths.file('recent.json'), recent);
  }
  final walls = loadHiddenWallpapers(ctx.paths);
  if (walls.containsKey(old)) {
    walls[slug] = walls.remove(old)!;
    saveHiddenWallpapers(ctx.paths, walls);
  }
  final chosen = chosenWallpapers(ctx);
  if (chosen.containsKey(old)) {
    chosen[slug] = chosen.remove(old)!;
    writeJson('${ctx.paths.state}/theme-backgrounds.json', chosen);
  }
  if (ctx.current.slug == old) ctx.current.save(slug: slug, clearWallpaper: true);
}

// --- the editor ------------------------------------------------------------------------

/// Hex keys of [palette] whose value is not what the main colors would give
/// (a shade the theme set itself: it stays when a main color changes).
List<String> ownShades(Palette palette) {
  final d = derivedColors(palette.colors);
  return [
    for (final e in d.entries)
      if (palette.colors[e.key] != e.value) e.key,
  ];
}

String? _checkedPicture(String? path) {
  if (path == null) return null;
  try {
    readCheckedImage(path);
    return path;
  } on FormatException {
    return null;
  }
}

ThemeInfo _defaultBase(Ctx ctx) {
  final current = ctx.current.slug;
  final t = current.isEmpty ? null : findTheme(ctx.paths, current);
  if (t != null) return t;
  final all = ctx.themes();
  if (all.isEmpty) throw RouteError('not_found', tr("no themes installed"));
  return all.first;
}

/// What the editor shows (custom.editor).
Future<Map<String, dynamic>> editorData(Ctx ctx, {String? base, String? edit, String? wallpaper}) async {
  final fonts = (await ctx.desktop.monospaceFonts()).where(fontRe.hasMatch).take(200).toList();
  final systemFont = ctx.desktop.monospaceFont();
  ThemeInfo theme;
  Palette palette;
  String name, title;
  String? font;
  Map<String, dynamic>? blur;
  var copy = true;
  if (edit != null) {
    theme = _editable(ctx, edit);
    palette = await loadPalette(ctx, theme);
    name = theme.name;
    title = trf('Edit {0}', [theme.name]);
    font = fontOf(theme);
    blur = blurOf(theme);
    copy = false;
  } else {
    theme = base != null ? ctx.theme(base) : _defaultBase(ctx);
    if (wallpaper != null) {
      if (!wallpaper.startsWith('/')) throw RouteError('bad_params', 'wallpaper');
      palette = paletteFromColors(await _colorsFromPicture(wallpaper));
      name = uniqueName(ctx, nameFromFile(baseName(wallpaper)) ?? defaultThemeName);
      title = trf('New theme from {0}', [baseName(wallpaper)]);
      copy = false; // the picture is always included; the base's others only if wanted
    } else {
      palette = await loadPalette(ctx, theme);
      name = suggestedName(ctx, theme.slug);
      title = trf('New theme from {0}', [theme.name]);
    }
  }
  final visible = visibleBackgrounds(ctx.paths, theme);
  final extras = palette.editableExtras;
  final editable = palette.editable;
  return {
    'name': name,
    'title': title,
    'mode': palette.mode,
    'colors': editable,
    'labels': {for (final k in editable.keys) k: colorLabel(k)},
    'editable_keys': {
      'main': mainKeys,
      'terminal': terminalKeys,
      'more': [...moreKeys, ...extras],
    },
    'own_shades': edit != null ? ownShades(palette) : <String>[],
    'font': font,
    'blur': blur,
    'fonts': fonts,
    'system_font': systemFont,
    'base': edit != null ? (markerOf(theme)?['base'] as String? ?? '') : theme.slug,
    'base_name': theme.name,
    'edit': edit,
    'current': edit != null && ctx.current.slug == edit,
    'wallpaper': wallpaper,
    'copy_wallpapers': copy,
    'base_wallpapers': visible.length,
    'base_wallpaper': _checkedPicture(visible.isEmpty ? null : visible.first.path),
    'sample_wallpaper': _checkedPicture(wallpaper),
    'max_name': maxNameLength,
  };
}

Future<Map<String, String>> _colorsFromPicture(String path) async {
  try {
    return await colorsFromImageFile(path);
  } on FormatException catch (e) {
    throw RouteError('bad_image', trf("could not read the colors: {0}", [e.message]));
  }
}

/// custom.from_wallpaper: every color for a picture, and a name for it.
Future<Map<String, dynamic>> fromWallpaper(Ctx ctx, String path) async {
  if (!path.startsWith('/')) throw RouteError('bad_params', 'path');
  final palette = paletteFromColors(await _colorsFromPicture(path));
  return {'colors': palette.editable, 'mode': palette.mode, 'name': uniqueName(ctx, nameFromFile(baseName(path)) ?? defaultThemeName)};
}

Map<String, String> _colorsParam(Map<String, dynamic> p) {
  final v = p['colors'];
  if (v is! Map) throw RouteError('bad_params', 'colors');
  final out = <String, String>{};
  for (final e in v.entries) {
    if (e.key is! String || e.value is! String) throw RouteError('bad_params', 'colors');
    if (!_hexRe.hasMatch(e.value as String)) throw RouteError('bad_color', trf('{0}: use #rrggbb', [e.key]));
    out[e.key as String] = (e.value as String).toLowerCase();
  }
  return out;
}

/// custom.save: a new theme, or (edit) new colors, font and name for one.
/// The theme in use (or with `apply`) is applied again afterwards.
Future<Map<String, dynamic>> saveCustom(Ctx ctx, Map<String, dynamic> p) async {
  final name = str(p, 'name');
  final colors = _colorsParam(p);
  final font = _checkFont(optStr(p, 'font'));
  final blur = _checkBlur(p['blur']);
  final edit = optStr(p, 'edit');
  final wantApply = boolParam(p, 'apply', fallback: false);
  String slug;
  var reapply = wantApply;
  if (edit != null) {
    var theme = _editable(ctx, edit);
    final wasCurrent = ctx.current.slug == theme.slug;
    slugFor(name); // a bad name stops before anything moves
    final palette = (await loadPalette(ctx, theme)).copy()..take(colors);
    checkAskAiBoundary();
    slug = renameTheme(ctx, theme, name);
    theme = ctx.theme(slug);
    await updateTheme(ctx, theme, palette, font, blur: blur);
    reapply = reapply || wasCurrent;
  } else {
    final wallpaper = optStr(p, 'wallpaper');
    if (wallpaper != null && !wallpaper.startsWith('/')) throw RouteError('bad_params', 'wallpaper');
    slug = await createThemeFolder(
      ctx,
      name: name,
      colors: colors,
      font: font,
      baseSlug: optStr(p, 'base'),
      wallpapers: [?wallpaper],
      copyBaseWallpapers: boolParam(p, 'copy_wallpapers', fallback: wallpaper == null),
      blur: blur,
    );
  }
  final out = <String, dynamic>{'slug': slug, 'name': displayName(slug), 'applied': false};
  if (reapply) {
    try {
      await applyTheme(ctx, slug);
      out['applied'] = true;
    } on RouteError catch (e) {
      if (e.code == 'ask_ai_blocked') rethrow;
      out['apply_error'] = e.message ?? e.code;
    }
  }
  return out;
}
