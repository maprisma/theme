import 'i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'apply.dart';
import 'auto.dart' show showChosenBackground;
import 'context.dart';
import 'images.dart';
import 'posix.dart';
import 'themes.dart';
import 'trash.dart';
import 'wallhaven.dart';
import 'wallpapers.dart';
import 'web_images.dart';
import 'created_pictures.dart';

/// The name a drop offers in its type (`application/octet-stream;name="x.jpg"`,
/// how Chromium offers a dragged picture), or ''.
String offeredFileName(String mime) {
  final m = RegExp(r';\s*name="?([^";]{1,200})"?').firstMatch(mime);
  return m == null ? '' : baseName(m[1]!);
}

/// The largest base64 `data` a request can carry (the protocol caps a
/// request at 64 KiB); larger drops go through a private file in the
/// runtime folder (`file`, named `drop-*`), which the core reads and removes.
const maxInlineBytes = 40 * 1024;

/// Routes of the wallpaper module (docs/agents.md, module A).
Map<String, Handler> wallpaperRoutes(Ctx ctx, {Fetch? fetch}) {
  final receipts = ReceiptBook();
  final web = Wallhaven(ctx, fetch: fetch);
  final pictures = WebImages(ctx);
  final created = CreatedPictures(ctx);
  var previewing = false;
  Object? beforePreview;

  ThemeInfo themeOf(Map<String, dynamic> p) => ctx.theme(validSlug(str(p, 'slug')));

  Map<String, dynamic> added((List<String>, List<String>) r) => {'added': r.$1, 'errors': r.$2};

  WebWallpaper item(Map<String, dynamic> p) {
    final w = WebWallpaper.check(p['item']);
    if (w == null) throw RouteError('bad_params', 'item');
    return w;
  }

  Future<Map<String, dynamic>> undo(Map<String, dynamic> p) async {
    final list = receipts.take(str(p, 'receipt'));
    if (list == null) throw RouteError('expired', tr("Undo is no longer possible"));
    final restored = <String>[];
    for (final r in list) {
      try {
        restored.add(baseName(restoreFromTrash(r)));
      } on TrashException catch (e) {
        throw RouteError('undo_failed', e.message);
      } on FileSystemException catch (e) {
        throw RouteError('undo_failed', e.osError?.message ?? e.message);
      }
    }
    return {'restored': restored};
  }

  return {
    'wallpapers.list': (p) async {
      final theme = themeOf(p);
      final isCurrent = theme.slug == ctx.current.slug;
      final shown = isCurrent ? ctx.current.wallpaper : null;
      return {
        'slug': theme.slug,
        'name': theme.name,
        'current': isCurrent,
        'system': theme.system,
        'folder': '${ctx.paths.backgrounds}/${theme.slug}',
        'wallpapers': [
          for (final w in listBackgrounds(ctx.paths, theme))
            {...w.toJson(), 'shown': w.path == shown, 'problem': imageSizeProblem(w.path)},
        ],
      };
    },
    'wallpapers.add_files': (p) async {
      final slug = themeOf(p).slug;
      final paths = p['paths'];
      if (paths is! List || paths.any((x) => x is! String)) throw RouteError('bad_params', 'paths');
      return added(await addFiles(ctx, slug, paths.cast<String>()));
    },
    'wallpapers.add_bytes': (p) async {
      final slug = themeOf(p).slug;
      final offered = offeredFileName(optStr(p, 'type') ?? '');
      Uint8List data;
      final file = optStr(p, 'file');
      if (file != null) {
        final dir = ctx.paths.runtime;
        if (!file.startsWith('$dir/') || file.substring(dir.length + 1).contains('/') ||
            !baseName(file).startsWith('drop-')) {
          throw RouteError('bad_params', 'file');
        }
        final read = Posix.instance.readRegular(file, maxBackgroundBytes, follow: false);
        try {
          File(file).deleteSync();
        } on FileSystemException {
          // gone
        }
        if (read == null) throw RouteError('too_large', tr("The image could not be read (or is over 50 MiB)."));
        data = read;
      } else {
        try {
          data = base64Decode(str(p, 'data'));
        } on FormatException {
          throw RouteError('bad_params', 'data');
        }
        if (data.length > maxInlineBytes + 8 * 1024) throw RouteError('bad_params', 'data');
      }
      final path = addBackgroundData(ctx, slug, data, name: offered.isNotEmpty ? offered : 'dropped-image');
      return {'added': [baseName(path)], 'errors': <String>[], 'path': path};
    },
    'wallpapers.add_clipboard': (p) async => addClipboard(ctx, str(p, 'slug')),
    'wallpapers.hide': (p) async {
      final theme = themeOf(p);
      final w = findWallpaper(ctx, theme, str(p, 'name'));
      final hide = boolParam(p, 'hidden');
      final path = setWallpaperHidden(ctx, theme, w, hide);
      if (hide) await leaveWallpaper(ctx, theme, w.path);
      return {'hidden': hide, 'path': path};
    },
    'wallpapers.delete': (p) async {
      final theme = themeOf(p);
      final w = findWallpaper(ctx, theme, str(p, 'name'));
      if (!w.deletable) throw RouteError('locked', w.lockedReason.isEmpty ? tr("Can't delete: hide instead") : w.lockedReason);
      final r = removeWallpaper(ctx, w.path);
      await leaveWallpaper(ctx, theme, w.path);
      return {'receipt': r == null ? null : receipts.keep([r]), 'name': w.name};
    },
    'wallpapers.undo_delete': undo,
    'wallpapers.set': (p) async {
      final path = str(p, 'path');
      final theme = ctx.theme(validSlug(optStr(p, 'slug') ?? ctx.current.slug));
      final w = listBackgrounds(ctx.paths, theme).where((x) => x.path == path && !x.hidden).firstOrNull;
      if (w == null) throw RouteError('not_found', trf("not a visible wallpaper of {0}", [theme.name]));
      final problem = imageSizeProblem(path);
      if (problem != null) throw RouteError('bad_image', problem);
      if (theme.slug != ctx.current.slug) {
        // Another theme: its start wallpaper next time it is applied.
        rememberWallpaper(ctx, theme.slug, w.name);
        return {'set': false, 'remembered': true};
      }
      // As the applet's scroll: a workspace with its own wallpaper gets it, else it is the new base.
      if (!await showChosenBackground(ctx, theme, path)) throw RouteError('set_failed', tr("Could not set the background"));
      previewing = false;
      beforePreview = null;
      return {'set': true, 'remembered': true};
    },
    'wallpapers.preview': (p) async {
      final path = str(p, 'path');
      if (!path.startsWith('/') || !imageExts.contains(extOf(path))) throw RouteError('bad_params', 'path');
      final problem = imageSizeProblem(path);
      if (problem != null) throw RouteError('bad_image', problem);
      if (!previewing) beforePreview = await ctx.desktop.snapshotBackground();
      previewing = true;
      // Shown only: Current and the remembered wallpaper stay as they are.
      return {'shown': await ctx.desktop.setWallpaper(path)};
    },
    'wallpapers.preview_end': (p) async {
      if (!previewing) return {'restored': false};
      previewing = false;
      // The whole background config as it was (per-monitor setups included).
      final snapshot = beforePreview;
      beforePreview = null;
      return {'restored': await ctx.desktop.restoreBackground(snapshot)};
    },
    'themes.delete': (p) async {
      final slug = validSlug(str(p, 'slug'));
      final r = removeTheme(ctx, slug);
      return {'receipt': r == null ? null : receipts.keep([r]), 'slug': slug};
    },
    'themes.undo_delete': undo,
    'wallhaven.search': (p) async {
      final query = str(p, 'query');
      final page = p['page'] is int ? (p['page'] as int).clamp(1, 999) : 1;
      final slug = optStr(p, 'slug');
      final (results, last) = await web.search(query, page: page);
      return {
        'query': cleanQuery(query),
        'page': page,
        'last_page': last,
        'results': [
          for (final w in results)
            {...w.toJson(), 'added': slug != null && slugRe.hasMatch(slug) && web.alreadyAdded(slug, w)},
        ],
      };
    },
    'wallhaven.thumb': (p) async => {'path': await web.thumb(item(p))},
    'wallhaven.preview': (p) async => {'path': await web.preview(item(p))},
    'wallhaven.add': (p) async {
      final theme = themeOf(p);
      final path = await web.add(theme.slug, item(p));
      var set = false;
      if (boolParam(p, 'set', fallback: false) && theme.slug == ctx.current.slug) {
        set = await setBackground(ctx, path);
      }
      return {'path': path, 'name': baseName(path), 'set': set};
    },
    'wallhaven.open': (p) async => {'opened': await openWallhavenPage(ctx, str(p, 'page'))},
    // Pictures Ask AI found on the web: the local copy (thumbnail and preview), add, open.
    'webimg.get': (p) async => {'path': await pictures.get(p['url'])},
    'webimg.add': (p) async {
      final theme = themeOf(p);
      final path = await pictures.add(theme.slug, p['url']);
      var set = false;
      if (boolParam(p, 'set', fallback: false) && theme.slug == ctx.current.slug) {
        set = await setBackground(ctx, path);
      }
      return {'path': path, 'name': baseName(path), 'set': set};
    },
    'webimg.open': (p) async => {'opened': await openWebPage(ctx, p['page'])},
    // Wallpapers made here with Maprisma Playground's picture generator.
    'create.status': (p) async => created.status(),
    'create.setup': (p) async => created.startSetup(),
    'create.cancel_setup': (p) async {
      created.cancelSetup();
      return created.status();
    },
    'create.make': (p) async {
      final seed = p['seed'] is int ? p['seed'] as int : DateTime.now().microsecondsSinceEpoch;
      return {'path': await created.make(str(p, 'prompt'), seed), 'seed': seed & 0x7fffffff};
    },
    'create.cancel': (p) async {
      created.cancel();
      return {'cancelled': true};
    },
    'create.add': (p) async {
      final theme = themeOf(p);
      final path = str(p, 'path');
      // Only a picture made here: a plain file right in the cache folder.
      if (!path.startsWith('${created.cacheDir}/') || path.substring(created.cacheDir.length + 1).contains('/') ||
          FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) {
        throw RouteError('bad_params', 'path');
      }
      final added = addBackgroundBytes(ctx, theme.slug, File(path).readAsBytesSync(), baseName(path));
      var set = false;
      if (boolParam(p, 'set', fallback: false) && theme.slug == ctx.current.slug) set = await setBackground(ctx, added);
      return {'path': added, 'name': baseName(added), 'set': set};
    },
  };
}
