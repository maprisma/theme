import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'apply.dart';
import 'bounded.dart';
import 'context.dart';
import 'images.dart';
import 'posix.dart';
import 'store.dart';
import 'themes.dart';
import 'trash.dart';

/// Wallpaper operations (theme_core.py): add (files, bytes, clipboard,
/// HEIC), hide, delete to the trash, and theme delete.

const maxDrops = 10; // one drop or paste adds at most this many wallpapers
const heifDecoderMaxMemory = 2 * 1024 * 1024 * 1024;
const tooLarge = 'image too large (max 50 MiB)';

String validSlug(String slug) {
  final s = slug.trim();
  if (s.isEmpty || !slugRe.hasMatch(s)) throw RouteError('bad_params', 'invalid theme slug');
  return s;
}

bool _isImageName(String name) => imageExts.contains(extOf(name));

bool _exists(String path) => FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

String _stemOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

/// A free name in the theme's added-wallpaper folder (`name-2.jpg`, …).
String _uniqueDest(Ctx ctx, String slug, String name) {
  final dir = '${ctx.paths.backgrounds}/$slug';
  Directory(dir).createSync(recursive: true);
  final dot = name.lastIndexOf('.');
  final stem = dot <= 0 ? name : name.substring(0, dot);
  final ext = dot <= 0 ? '' : name.substring(dot);
  var candidate = '$dir/$name';
  for (var n = 2; _exists(candidate) || _exists('$dir/$hiddenDir/${baseName(candidate)}'); n++) {
    candidate = '$dir/$stem-$n$ext';
  }
  return candidate;
}

/// Stores checked image [data] as [name] in `backgrounds/<slug>/`: a PNG loses
/// its metadata chunks first, then the declared size is checked; the file is
/// created exclusively, never through a link.
String addBackgroundBytes(Ctx ctx, String slug, Uint8List data, String name) {
  slug = validSlug(slug);
  if (data.isEmpty) throw RouteError('bad_image', 'empty image data');
  if (data.length > maxBackgroundBytes) throw RouteError('too_large', tooLarge);
  name = sanitizeName(name);
  if (!_isImageName(name)) throw RouteError('bad_image', 'not an image: $name');
  var bytes = data;
  if (isPng(bytes)) {
    try {
      bytes = stripPngMetadata(bytes);
    } on FormatException catch (e) {
      throw RouteError('bad_image', e.message);
    }
  }
  final problem = imageBytesProblem(bytes);
  if (problem != null) throw RouteError('bad_image', problem);
  final ext = imageExtension(bytes);
  if (ext == null) throw RouteError('bad_image', unsupportedImage);
  final dest = _uniqueDest(ctx, slug, name);
  // Never delete after a failure: when the exclusive create lost a race, the
  // file there is someone else's (writeNewPrivate cannot tell us apart).
  if (!Posix.instance.writeNewPrivate(dest, bytes)) throw RouteError('write_failed', 'could not store ${baseName(dest)}');
  chmodPath(dest, 420 /* 0644 */);
  return dest;
}

/// Image bytes of unknown origin (a drop from a browser, the clipboard): the
/// type comes from the bytes, never from the offered name.
String addBackgroundData(Ctx ctx, String slug, Uint8List data, {String name = 'image'}) {
  final ext = imageExtension(data.length > 16 ? Uint8List.sublistView(data, 0, 16) : data);
  if (ext == null) throw RouteError('bad_image', unsupportedImage);
  var stem = _stemOf(sanitizeName(name));
  if (stem.isEmpty) stem = 'image';
  return addBackgroundBytes(ctx, slug, data, '$stem$ext');
}

Uint8List _readSource(String source) {
  final stat = FileStat.statSync(source);
  if (stat.type != FileSystemEntityType.file) throw RouteError('not_found', 'not a file: ${baseName(source)}');
  if (stat.size > maxBackgroundBytes) throw RouteError('too_large', tooLarge);
  final data = Posix.instance.readRegular(source, maxBackgroundBytes);
  if (data == null) throw RouteError('too_large', '${baseName(source)}: unreadable or $tooLarge');
  return data;
}

/// Copies one image file into the theme's added-wallpaper folder (HEIC
/// photos are converted to JPEG). Checked on our copy, so the source cannot
/// change after the check.
Future<String> addBackgroundFile(Ctx ctx, String slug, String source) async {
  slug = validSlug(slug);
  if (!source.startsWith('/')) throw RouteError('bad_params', 'not an absolute path');
  final name = baseName(source);
  if (heifExts.contains(extOf(name))) return _addHeif(ctx, slug, source);
  if (!_isImageName(name)) throw RouteError('bad_image', 'not an image: $name');
  final data = _readSource(source);
  return addBackgroundBytes(ctx, slug, data, name);
}

Future<String> _addHeif(Ctx ctx, String slug, String source) async {
  final data = _readSource(source);
  final decoder = which('heif-dec', ctx.environment);
  final limiter = which('prlimit', ctx.environment);
  if (decoder == null || limiter == null) throw RouteError('no_heif', 'HEIC photos need libheif (heif-dec) installed');
  final problem = heifSizeProblem(data);
  if (problem != null) throw RouteError('bad_image', problem);
  final tmp = Directory.systemTemp.createTempSync('maprisma-theme-heif-');
  try {
    chmodPath(tmp.path, 448);
    final private = '${tmp.path}/source.heic';
    if (!Posix.instance.writeNewPrivate(private, data)) throw RouteError('write_failed', 'could not copy the photo');
    final converted = '${tmp.path}/image.jpg';
    // Declared sizes are checked above; prlimit is the backstop for the
    // decoder's memory (--as) and every file it writes (--fsize).
    final (code, _) = await runBounded([
      limiter, '--as=$heifDecoderMaxMemory', '--fsize=$maxBackgroundBytes', '--',
      decoder, '--quiet', '--quality', '92', private, converted,
    ], maxBytes: 65536, timeout: const Duration(seconds: 60));
    if (code != 0 || !File(converted).existsSync()) throw RouteError('convert_failed', 'could not convert ${baseName(source)}');
    final jpeg = Posix.instance.readRegular(converted, maxBackgroundBytes, follow: false);
    if (jpeg == null) throw RouteError('too_large', tooLarge);
    var stem = _stemOf(sanitizeName(baseName(source)));
    if (stem.isEmpty) stem = 'image';
    return addBackgroundBytes(ctx, slug, jpeg, '$stem.jpg');
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // gone
    }
  }
}

/// Adds up to [maxDrops] files; ({added names}, {errors}).
Future<(List<String>, List<String>)> addFiles(Ctx ctx, String slug, List<String> paths) async {
  final added = <String>[], errors = <String>[];
  for (final p in paths.take(maxDrops)) {
    try {
      added.add(baseName(await addBackgroundFile(ctx, slug, p)));
    } on RouteError catch (e) {
      errors.add('${baseName(p)}: ${e.message ?? e.code}');
    } on FileSystemException catch (e) {
      errors.add('${baseName(p)}: ${e.osError?.message ?? e.message}');
    }
  }
  return (added, errors);
}

// --- clipboard and dropped file lists ---------------------------------------------

/// Existing local files named in a uri-list, gnome-copied-files or plain
/// list: one `file://` URI or absolute path per line; other URIs ignored.
List<String> parseFileList(String text, {int limit = maxDrops}) {
  final out = <String>[];
  for (final line in const LineSplitter().convert(text)) {
    if (out.length >= limit) break;
    var token = line.trim();
    if (token.isEmpty || token.startsWith('#') || token == 'copy' || token == 'cut') continue;
    if (token.startsWith('file://')) {
      try {
        final uri = Uri.parse(token);
        if (uri.host.isNotEmpty && uri.host != 'localhost') continue;
        token = Uri.decodeComponent(uri.path);
      } on FormatException {
        continue;
      } on ArgumentError {
        continue;
      }
    } else if (!token.startsWith('/')) {
      continue;
    }
    if (FileSystemEntity.isFileSync(token)) out.add(token);
  }
  return out;
}

const _fileListMimes = ['text/uri-list', 'x-special/gnome-copied-files', 'text/plain;charset=utf-8', 'text/plain'];

Future<List<String>> _clipboardTypes(String wlPaste) async {
  final out = await readBoundedText([wlPaste, '--list-types'], maxBytes: 65536, timeout: const Duration(seconds: 3));
  return out == null ? const [] : [for (final l in const LineSplitter().convert(out)) if (l.trim().isNotEmpty) l.trim()];
}

/// Pastes what the Wayland clipboard holds: image bytes (type by magic), or
/// image files a file manager copied (at most 10, 50 MiB each).
Future<Map<String, dynamic>> addClipboard(Ctx ctx, String slug) async {
  slug = ctx.theme(validSlug(slug)).slug;
  final wlPaste = which('wl-paste', ctx.environment);
  if (wlPaste == null) throw RouteError('no_clipboard', 'wl-paste (wl-clipboard) is not installed');
  final types = await _clipboardTypes(wlPaste);
  for (final mime in types) {
    if (extensionForMime(mime) == null) continue;
    final data = await readBoundedBytes([wlPaste, '--type', mime],
        maxBytes: maxBackgroundBytes, timeout: const Duration(seconds: 8));
    if (data == null || data.isEmpty) continue;
    final path = addBackgroundData(ctx, slug, data, name: 'pasted-image');
    return {'added': [baseName(path)], 'errors': <String>[]};
  }
  for (final mime in _fileListMimes) {
    if (!types.contains(mime)) continue;
    final text = await readBoundedText([wlPaste, '--no-newline', '--type', mime],
        maxBytes: 1024 * 1024, timeout: const Duration(seconds: 3));
    final paths = text == null ? const <String>[] : parseFileList(text);
    if (paths.isEmpty) continue;
    final (added, errors) = await addFiles(ctx, slug, paths);
    return {'added': added, 'errors': errors};
  }
  throw RouteError('no_image', 'No image in the clipboard. Copy an image first (in the browser or the file manager).');
}

// --- hide, delete ------------------------------------------------------------------

WallpaperInfo findWallpaper(Ctx ctx, ThemeInfo theme, String name) {
  for (final w in listBackgrounds(ctx.paths, theme)) {
    if (w.name == name) return w;
  }
  throw RouteError('not_found', 'no wallpaper $name');
}

String _real(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}

bool _inside(String path, String base) => path == base || path.startsWith('$base/');

/// Hides or unhides one wallpaper. Added ones move into `.hidden/`, shipped
/// ones are listed in hidden-wallpapers.json. The last visible wallpaper of a
/// theme cannot be hidden. Returns the wallpaper's path afterwards.
String setWallpaperHidden(Ctx ctx, ThemeInfo theme, WallpaperInfo w, bool hide) {
  final slug = validSlug(theme.slug);
  if (w.hidden == hide) return w.path;
  if (hide) {
    final visible = listBackgrounds(ctx.paths, theme).where((x) => !x.hidden).length;
    if (visible <= 1) throw RouteError('last_visible', "This is the theme's last visible wallpaper");
  }
  if (w.source == 'user') {
    final dir = '${ctx.paths.backgrounds}/$slug';
    Directory(dir).createSync(recursive: true);
    final base = _real(dir);
    final parent = _real(File(w.path).parent.path);
    if (FileSystemEntity.isLinkSync(w.path) || !(parent == base || parent == '$base/$hiddenDir')) {
      throw RouteError('locked', 'not one of your added wallpapers');
    }
    final destDir = hide ? '$base/$hiddenDir' : base;
    if (!Directory(destDir).existsSync()) {
      Directory(destDir).createSync();
      chmodPath(destDir, 448);
    }
    final dest = '$destDir/${sanitizeName(w.name)}';
    if (_exists(dest)) throw RouteError('exists', '${baseName(dest)} already exists there');
    File(w.path).renameSync(dest);
    return dest;
  }
  final hidden = loadHiddenWallpapers(ctx.paths);
  final names = hidden.putIfAbsent(slug, () => <String>{});
  if (hide) {
    names.add(w.name);
  } else {
    names.remove(w.name);
  }
  saveHiddenWallpapers(ctx.paths, hidden);
  return w.path;
}

/// Deletes one wallpaper file into the trash: allowed only inside
/// `backgrounds/<slug>/` or a user theme's `backgrounds/` (not from git).
TrashReceipt? removeWallpaper(Ctx ctx, String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.directory) throw RouteError('locked', 'refusing to remove a directory');
  if (type == FileSystemEntityType.notFound) throw RouteError('not_found', baseName(path));
  final parent = _real(File(path).parent.path);
  final userBg = _real(ctx.paths.backgrounds);
  if (_inside(parent, userBg)) return discard(ctx.paths.trash, path);
  final userThemes = _real(ctx.paths.userThemes);
  if (_inside(parent, userThemes)) {
    final parts = parent.substring(userThemes.length).split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2 && parts[1] == 'backgrounds') {
      final themeDir = '$userThemes/${parts[0]}';
      if (!FileSystemEntity.isLinkSync(themeDir) && Directory('$themeDir/.git').existsSync()) {
        throw RouteError('locked', lockGit);
      }
      return discard(ctx.paths.trash, path);
    }
  }
  throw RouteError('locked', lockSystem);
}

/// Removes a user theme into the trash; the active theme and system themes
/// are refused. A symlinked theme is unlinked as a link.
TrashReceipt? removeTheme(Ctx ctx, String slug) {
  slug = validSlug(slug);
  if (slug == ctx.current.slug) throw RouteError('current', 'This is the active theme: apply another theme first');
  final base = ctx.paths.userThemes;
  final target = '$base/$slug';
  final type = FileSystemEntity.typeSync(target, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    if (Directory('${ctx.paths.systemThemes}/$slug').existsSync()) {
      throw RouteError('locked', 'Built-in themes cannot be deleted: hide it instead');
    }
    throw RouteError('not_found', 'theme $slug not found');
  }
  if (type == FileSystemEntityType.link) {
    Link(target).deleteSync();
    return null;
  }
  if (type != FileSystemEntityType.directory) throw RouteError('not_found', 'theme $slug not found');
  if (!_inside(_real(target), _real(base))) throw RouteError('locked', 'the theme folder escapes the user themes');
  return discard(ctx.paths.trash, target);
}

/// After [old] left the desktop's theme (hidden or deleted): when it was
/// the background shown, the theme's next visible wallpaper takes its place.
Future<void> leaveWallpaper(Ctx ctx, ThemeInfo theme, String old) async {
  if (theme.slug != ctx.current.slug || ctx.current.wallpaper != old) return;
  final next = startWallpaper(ctx, theme);
  if (next != null && imageSizeProblem(next.path) == null) await setBackground(ctx, next.path, remember: false);
}
