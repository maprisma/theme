import '../i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart' show Paths, Posix, ServiceError;

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';
import '../window.dart';
import 'editor_page.dart';
import 'wallhaven_page.dart';
import 'look_dialog.dart';

const previewSeconds = 5;
const maxDrops = 10;
const _inlineDropBytes = 40 * 1024; // larger drops go through a private file

/// The reason a core call failed, as the core said it.
String failText(Object e) => e is ServiceError && (e.reason ?? '').isNotEmpty ? e.reason! : errorText(e);

/// Local files from a dropped text/uri-list (at most [maxDrops]).
List<String> droppedPaths(String text) {
  final out = <String>[];
  for (final line in const LineSplitter().convert(text)) {
    if (out.length >= maxDrops) break;
    var t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    if (t.startsWith('file://')) {
      try {
        final uri = Uri.parse(t);
        if (uri.host.isNotEmpty && uri.host != 'localhost') continue;
        t = Uri.decodeComponent(uri.path);
      } on FormatException {
        continue;
      } on ArgumentError {
        continue;
      }
    }
    if (t.startsWith('/')) out.add(t);
  }
  return out;
}

/// A theme's wallpapers (the plugin's wallpaper page): add by chooser, drop
/// or paste, set, preview, per-workspace, new theme from one, hide, delete.
class WallpapersPage extends StatefulWidget {
  const WallpapersPage({super.key, required this.slug});
  final String slug;
  @override
  State<WallpapersPage> createState() => _WallpapersPageState();
}

class _WallpapersPageState extends State<WallpapersPage> {
  late final MaprismaThemeAppState app;
  final focus = FocusNode();
  final scroll = ScrollController();
  final _subs = <StreamSubscription>[];
  final _tileKeys = <String, GlobalKey>{};
  final _menuKeys = <String, GlobalKey<PopupMenuButtonState<VoidCallback>>>{};

  Map<String, dynamic>? data;
  Map<int, String> workspaces = {};
  bool dragging = false, busy = false;
  String filter = '';
  int selected = 0, columns = 3;
  bool previewing = false;
  Timer? previewTimer;

  @override
  void initState() {
    super.initState();
    app = AppScope.read(context);
    app.revision.addListener(load);
    _subs.add(AppWindow.instance.dragging.stream.listen((at) {
      if (!_onTop) return;
      final on = at != null;
      if (on != dragging && mounted) setState(() => dragging = on);
    }));
    _subs.add(AppWindow.instance.drops.stream.listen((d) {
      if (mounted) setState(() => dragging = false);
      if (_onTop) onDrop(d);
    }));
    load();
  }

  @override
  void dispose() {
    app.revision.removeListener(load);
    for (final s in _subs) {
      s.cancel();
    }
    if (previewing) app.call('wallpapers.preview_end').ignore();
    previewTimer?.cancel();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  bool get _onTop => mounted && (ModalRoute.of(context)?.isCurrent ?? false);

  String get themeName => (data?['name'] as String?) ?? widget.slug;
  bool get isCurrent => data?['current'] == true;

  Future<void> load() async {
    final r = await app.run('wallpapers.list', {'slug': widget.slug});
    final ws = <int, String>{};
    try {
      final w = app.can('workspaces') ? await app.call('auto.workspace_wallpapers', {'slug': widget.slug}) : <String, dynamic>{};
      for (final e in ((w['map'] as Map?) ?? const {}).entries) {
        final n = int.tryParse('${e.key}');
        if (n != null && e.value is String) ws[n] = e.value as String;
      }
    } catch (_) {
      // nothing assigned (or the automation module is not there)
    }
    if (!mounted || r == null) return;
    setState(() {
      data = r;
      workspaces = ws;
      selected = min(selected, max(0, tiles.length - 1));
    });
  }

  Future<Map<String, dynamic>?> _try(String method, Map<String, dynamic> params, [String? what]) async {
    try {
      return await app.call(method, params);
    } catch (e) {
      app.notify(what == null ? failText(e) : '$what: ${failText(e)}');
      return null;
    }
  }

  List<Map<String, dynamic>> get wallpapers => [
    for (final w in (data?['wallpapers'] as List?) ?? const [])
      if ((app.showHidden || w['hidden'] != true) &&
          (filter.isEmpty || '${w['name']}'.toLowerCase().contains(filter.toLowerCase())))
        Map<String, dynamic>.from(w as Map),
  ];

  /// The add tile first (not while filtering), then the wallpapers.
  List<Map<String, dynamic>?> get tiles => [if (filter.isEmpty) null, ...wallpapers];

  List<int> workspacesOf(String name) => [for (final e in workspaces.entries) if (e.value == name) e.key]..sort();

  // --- adding --------------------------------------------------------------------

  void reportAdded(Map<String, dynamic>? r) {
    if (r == null) return;
    final added = [for (final a in (r['added'] as List?) ?? const []) '$a'];
    final errors = [for (final e in (r['errors'] as List?) ?? const []) '$e'];
    if (added.isNotEmpty) {
      app.notify(trf("{0} added: {1}{2}{3}", [added.length == 1 ? tr("Wallpaper") : tr("Wallpapers"), added.take(5).join(', '), added.length > 5 ? '…' : '', errors.isEmpty ? '' : trf(" — skipped: {0}", [errors.take(3).join('; ')])]));
    } else if (errors.isNotEmpty) {
      app.notify(trf("Some files were skipped: {0}{1}", [errors.take(3).join('; '), errors.length > 3 ? '…' : '']));
    }
    load();
    app.changed();
  }

  Future<void> addFiles(List<String> paths) async {
    if (paths.isEmpty) {
      app.notify(tr("Nothing added: drop local image files (JPG, PNG, WebP, GIF, BMP, HEIC)."));
      return;
    }
    if (paths.length > maxDrops) app.notify(trf("At most {0} files at once; the first {1} are added.", [maxDrops, maxDrops]));
    setState(() => busy = true);
    final r = await _try('wallpapers.add_files', {'slug': widget.slug, 'paths': paths.take(maxDrops).toList()},
        tr("Could not add wallpaper"));
    if (mounted) setState(() => busy = false);
    reportAdded(r);
  }

  Future<void> choose() async {
    final group = XTypeGroup(
      label: tr("Images"),
      extensions: ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif'],
      mimeTypes: ['image/jpeg', 'image/png', 'image/gif', 'image/bmp', 'image/webp', 'image/heic', 'image/heif'],
    );
    final home = Platform.environment['HOME'] ?? '/';
    final pictures = Directory('$home/Pictures').existsSync() ? '$home/Pictures' : home;
    final files = await openFiles(acceptedTypeGroups: [group], initialDirectory: pictures, confirmButtonText: tr("Add"));
    if (files.isEmpty || !mounted) return;
    await addFiles([for (final f in files) f.path]);
  }

  Future<void> paste() async {
    setState(() => busy = true);
    final r = await _try('wallpapers.add_clipboard', {'slug': widget.slug}, tr("Could not add wallpaper"));
    if (mounted) setState(() => busy = false);
    reportAdded(r);
  }

  Future<void> onDrop(Drop d) async {
    if (d.isUriList) {
      await addFiles(droppedPaths(utf8.decode(d.data, allowMalformed: true)));
      return;
    }
    if (d.data.isEmpty) {
      app.notify(tr("Nothing added: the image could not be read (or is over 50 MiB)."));
      return;
    }
    setState(() => busy = true);
    Map<String, dynamic>? r;
    if (d.data.length <= _inlineDropBytes) {
      r = await _try('wallpapers.add_bytes', {'slug': widget.slug, 'data': base64Encode(d.data), 'type': d.type},
          tr("Could not add wallpaper"));
    } else {
      // The protocol carries small requests only: hand the bytes over in a
      // private file of the runtime folder, which the core reads and removes.
      final dir = Paths.fromEnvironment(Platform.environment, share: '/nonexistent').runtime;
      final file = '$dir/drop-$pid-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
      var ok = false;
      try {
        Directory(dir).createSync(recursive: true);
        ok = Posix.instance.writeNewPrivate(file, d.data);
      } on FileSystemException {
        ok = false;
      }
      if (ok) {
        r = await _try('wallpapers.add_bytes', {'slug': widget.slug, 'file': file, 'type': d.type},
            tr("Could not add wallpaper"));
      } else {
        app.notify(tr("Nothing added: the image could not be stored."));
      }
    }
    if (mounted) setState(() => busy = false);
    reportAdded(r);
  }

  // --- actions -------------------------------------------------------------------

  Future<void> setBackground(Map w) async {
    final r = await _try('wallpapers.set', {'slug': widget.slug, 'path': w['path']}, tr("Could not set background"));
    if (r == null) return;
    previewing = false;
    load();
    app.changed();
  }

  Future<void> startPreview(String path, {int seconds = 0}) async {
    if (!app.can('wallpaper')) return;
    previewTimer?.cancel();
    previewTimer = null;
    final r = await _try('wallpapers.preview', {'path': path}, tr("No preview"));
    if (r == null) return;
    previewing = true;
    if (seconds > 0) previewTimer = Timer(Duration(seconds: seconds), stopPreview);
  }

  Future<void> stopPreview() async {
    previewTimer?.cancel();
    previewTimer = null;
    if (!previewing) return;
    previewing = false;
    await app.run('wallpapers.preview_end');
  }

  Future<void> showOnWorkspaces(Map w) async {
    final name = '${w['name']}';
    final anchor = rectOf(_menuKeys[w['path']] ?? GlobalKey());
    if (anchor == null) return;
    final mine = workspacesOf(name).toSet();
    final others = {for (final e in workspaces.entries) if (e.value != name) e.key: e.value};
    final ws = await showWorkspaceMenu(
      context,
      anchor: anchor,
      title: tr("Show on workspace"),
      mine: mine,
      others: others,
      namesOthers: false,
      clearLabel: mine.isEmpty ? null : tr("Not on any workspace"),
      tooltipOf: (ws) => trf("Workspace {0}: {1}", [ws, mine.contains(ws) ? tr("shows this wallpaper (click to clear)") : others[ws] != null ? trf("shows {0} (click to use this one)", [others[ws]]) : tr("use this wallpaper")]),
    );
    if (ws == null || !mounted) return;
    final wanted = ws == 0 ? <int>{} : (mine.contains(ws) ? ({...mine}..remove(ws)) : {...mine, ws});
    final r = await _try('auto.set_workspace_wallpaper',
        {'slug': widget.slug, 'name': name, 'workspaces': wanted.toList()..sort()},
        tr("Could not change the workspace wallpaper"));
    if (r == null) return;
    load();
    app.changed();
  }

  Future<void> setHidden(Map w, bool hide) async {
    final r = await _try('wallpapers.hide', {'slug': widget.slug, 'name': w['name'], 'hidden': hide},
        hide ? tr("Could not hide wallpaper") : tr("Could not unhide wallpaper"));
    if (r == null) return;
    load();
    app.changed();
    if (hide) {
      app.notify(trf("{0} hidden", [w['name']]), undo: () async {
        await _try('wallpapers.hide', {'slug': widget.slug, 'name': w['name'], 'hidden': false}, tr("Could not unhide wallpaper"));
        load();
        app.changed();
      });
    }
  }

  Future<void> delete(Map w) async {
    final ok = await confirm(context, trf("Delete wallpaper “{0}” from “{1}”?", [w['name'], themeName]),
        tr("It goes to the trash: Undo brings it back."), action: tr("Delete wallpaper"));
    if (!ok) return;
    final r = await _try('wallpapers.delete', {'slug': widget.slug, 'name': w['name']}, tr("Could not delete wallpaper"));
    if (r == null) return;
    load();
    app.changed();
    final receipt = r['receipt'];
    app.notify(trf("“{0}” moved to the trash", [w['name']]), undo: receipt is! String ? null : () async {
      final u = await _try('wallpapers.undo_delete', {'receipt': receipt}, tr("Could not undo"));
      if (u != null) app.notify(trf("Restored {0}", [w['name']]));
      load();
      app.changed();
    });
  }

  void newTheme(Map w) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorPage(wallpaper: w['path'] as String)));

  void openSearch() {
    stopPreview();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => WallhavenPage(slug: widget.slug, themeName: themeName, current: isCurrent)))
        .then((_) {
      load();
      focus.requestFocus();
    });
  }

  List<PopupMenuEntry<VoidCallback>> menuFor(Map w) {
    final hidden = w['hidden'] == true;
    final ws = workspacesOf('${w['name']}');
    return [
      if (app.can('wallpaper') && isCurrent && !hidden) item(Icons.wallpaper_outlined, tr("Set as background"), () => setBackground(w)),
      if (app.can('wallpaper') && !hidden)
        item(Icons.visibility_outlined, tr("Preview on desktop"), () => startPreview(w['path'] as String, seconds: previewSeconds),
            tooltip: trf("Shows it for {0} seconds; or hold Space on the tile", [previewSeconds])),
      if (!hidden)
        item(Icons.palette_outlined, tr("New theme from this wallpaper…"), () => newTheme(w),
            tooltip: tr("A theme in this picture's colors, with this wallpaper")),
      if (app.can('workspaces') && !hidden)
        item(Icons.grid_view, ws.isEmpty ? tr("Show on workspace…") : trf("On workspace {0}…", [ws.join(', ')]), () => showOnWorkspaces(w),
            end: Icons.chevron_right,
            tooltip: trf("This wallpaper appears whenever you switch to that workspace{0}", [isCurrent ? '' : tr(" (while this theme is applied)")])),
      menuLine(),
      if (hidden)
        item(Icons.visibility_outlined, tr("Unhide"), () => setHidden(w, false), tooltip: tr("Show it again here and in the rotation"))
      else
        item(Icons.visibility_off_outlined, tr("Hide"), () => setHidden(w, true),
            tooltip: tr("Keep it out of the rotation and the next-wallpaper step; the file stays")),
      menuLine(),
      if (w['deletable'] == true)
        item(Icons.delete_outline, tr("Delete…"), () => delete(w), destructive: true)
      else
        item(Icons.lock_outline, tr("Can't delete: hide instead"), () {}, enabled: false, tooltip: '${w['locked_reason'] ?? ''}'),
    ];
  }

  // --- keyboard ------------------------------------------------------------------

  void select(int i) {
    final list = tiles;
    if (list.isEmpty) return;
    setState(() => selected = i.clamp(0, list.length - 1));
    final t = list[selected];
    final ctx = _tileKeys[t == null ? '+' : t['path']]?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .5, duration: const Duration(milliseconds: 120));
  }

  void openTile(int i) {
    final list = tiles;
    if (i < 0 || i >= list.length) return;
    final t = list[i];
    if (t == null) {
      choose();
    } else {
      _menuKeys[t['path']]?.currentState?.showButtonMenu();
    }
  }

  KeyEventResult onKey(FocusNode node, KeyEvent e) {
    final key = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final list = tiles;
    if (app.can('wallpaper') && key == LogicalKeyboardKey.space && filter.isEmpty) {
      final t = selected < list.length ? list[selected] : null;
      if (e is KeyDownEvent && t != null && t['hidden'] != true && t['problem'] == null) {
        startPreview(t['path'] as String);
      } else if (e is KeyUpEvent && previewTimer == null) {
        stopPreview();
      }
      return KeyEventResult.handled;
    }
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    if (ctrl && key == LogicalKeyboardKey.keyV) {
      if (e is KeyDownEvent) paste();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyF) {
      if (e is KeyDownEvent) openSearch();
      return KeyEventResult.handled;
    }
    if (ctrl) return KeyEventResult.ignored;
    switch (key) {
      case LogicalKeyboardKey.arrowRight:
        select(selected + 1);
      case LogicalKeyboardKey.arrowLeft:
        if (selected % columns == 0) {
          Navigator.of(context).maybePop();
        } else {
          select(selected - 1);
        }
      case LogicalKeyboardKey.arrowDown:
        select(selected + columns);
      case LogicalKeyboardKey.arrowUp:
        select(selected - columns);
      case LogicalKeyboardKey.home:
        select(0);
      case LogicalKeyboardKey.end:
        select(list.length - 1);
      case LogicalKeyboardKey.pageDown:
        select(selected + columns * 3);
      case LogicalKeyboardKey.pageUp:
        select(selected - columns * 3);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter || LogicalKeyboardKey.contextMenu:
        openTile(selected);
      case LogicalKeyboardKey.escape:
        if (previewing) {
          stopPreview();
        } else if (filter.isNotEmpty) {
          setState(() => filter = '');
        } else {
          Navigator.of(context).maybePop();
        }
      case LogicalKeyboardKey.backspace:
        if (filter.isNotEmpty) {
          setState(() {
            filter = filter.substring(0, filter.length - 1);
            selected = 0;
          });
        } else {
          Navigator.of(context).maybePop();
        }
      default:
        final ch = e.character;
        if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 32 || ch.codeUnitAt(0) == 127) {
          return KeyEventResult.ignored;
        }
        setState(() {
          filter += ch;
          selected = 0;
        });
    }
    return KeyEventResult.handled;
  }

  // --- view ----------------------------------------------------------------------

  Widget brokenPicture(ColorScheme scheme, [String? why]) => Tooltip(
    message: why ?? tr("unreadable image"),
    child: Container(color: scheme.surfaceContainerHighest, child: const Center(child: Icon(Icons.broken_image_outlined))),
  );

  /// The first tile: choose image files; drops and pastes anywhere on the
  /// page land here too (it lights up while something is dragged over).
  Widget addTile(bool selectedTile) {
    final look = Look.of(context);
    final empty = wallpapers.isEmpty;
    final lit = dragging;
    return PluginTile(
      dashed: true,
      lit: lit,
      selected: selectedTile,
      tooltip: trf("Choose image files (Enter), drag them anywhere onto this page, or paste an image or file with Ctrl+V. HEIC photos are converted. {0}", [data?['system'] == true ? tr("Stored in your wallpaper folder for this theme, next to its own wallpapers.") : tr("Stored in the theme's user wallpaper folder.")]),
      onTap: () {
        focus.requestFocus();
        select(0);
        choose();
      },
      picture: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(busy ? Icons.hourglass_top : Icons.add, size: 32, color: lit || selectedTile ? look.accent : look.muted),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              trf("{0}Drop images here, paste with Ctrl+V or click to choose", [empty ? tr("No wallpapers yet. ") : '']),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: look.muted),
            ),
          ),
        ]),
      ),
      captionText: tr("Add wallpapers…"),
    );
  }

  Widget wallpaperTile(Map<String, dynamic> w, int index, bool selectedTile) {
    final scheme = Theme.of(context).colorScheme;
    final hidden = w['hidden'] == true;
    final problem = w['problem'] as String?;
    final ws = workspacesOf('${w['name']}');
    final menuKey = _menuKeys.putIfAbsent(w['path'] as String, () => GlobalKey());
    // The core checked the header (16384 px per side, 64 MP) before this decodes.
    final picture = problem != null
        ? brokenPicture(scheme, problem)
        : Image.file(
            File(w['path'] as String),
            key: ValueKey(w['path']),
            fit: BoxFit.cover,
            cacheWidth: 640,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => brokenPicture(scheme),
          );
    return PluginTile(
      picture: picture,
      captionText: '${w['name']}',
      selected: selectedTile,
      dimmed: hidden,
      onTap: () {
        focus.requestFocus();
        select(index);
      },
      onSecondaryTap: () => menuKey.currentState?.showButtonMenu(),
      menu: TileMenuButton(menuKey: menuKey, tooltip: tr("Wallpaper actions (Enter)"), menu: () => menuFor(w)),
      topLeft: [
        if (app.can('workspaces') && ws.isNotEmpty)
          TileBadge(trf("ws {0}", [ws.join(' · ')]), kind: BadgeKind.workspace, tooltip: trf("Shown on workspace {0}", [ws.join(', ')])),
      ],
      bottomLeft: [if (hidden) TileBadge(tr("hidden"))],
    );
  }

  @override
  Widget build(BuildContext context) {
    AppScope.of(context); // the header's eye button shows hidden wallpapers too
    final list = tiles;
    final title = trf("{0} — wallpapers{1}", [themeName, filter.isEmpty ? '' : ' — $filter']);
    return SubPage(
      title: title,
      section: false,
      backTooltip: tr("Back to themes (Left, Backspace or Esc)"),
      body: Focus(
        focusNode: focus,
        autofocus: true,
        onKeyEvent: onKey,
        child: data == null
            ? const Center(child: CircularProgressIndicator())
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(spacing: 8, runSpacing: 6, children: [
                  OutlineAction(
                    icon: Icons.content_paste,
                    label: tr("Paste image (Ctrl+V)"),
                    tooltip: trf("Add the image copied to the clipboard (from the web or the file manager){0}", [data?['system'] == true ? tr(" — stored in your per-theme folder") : '']),
                    onPressed: busy ? null : paste,
                  ),
                  OutlineAction(
                    icon: Icons.search,
                    label: tr("Search the web"),
                    tooltip: tr("Find wallpapers on wallhaven.cc (Ctrl+F)"),
                    onPressed: openSearch,
                  ),
                  if (app.can('fonts') || app.can('uiFont') || app.can('blur'))
                    OutlineAction(
                      icon: Icons.text_format,
                      label: tr("Font & effects…"),
                      tooltip: tr("Fonts and blur for this theme; the theme files stay as they are"),
                      onPressed: () async {
                        await lookDialog(context, app, widget.slug);
                        if (mounted) focus.requestFocus();
                      },
                    ),
                ]),
                const SizedBox(height: 8),
                Expanded(
                  child: LayoutBuilder(builder: (context, box) {
                    columns = gridColumns(box.maxWidth);
                    if (list.isEmpty) {
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Text(trf("No wallpaper matches “{0}”", [filter]), style: hintStyle(context)),
                      );
                    }
                    return TileGrid(
                      controller: scroll,
                      count: list.length,
                      columns: columns,
                      builder: (context, i) {
                        final t = list[i];
                        final key = _tileKeys.putIfAbsent(t == null ? '+' : t['path'] as String, () => GlobalKey());
                        return KeyedSubtree(
                          key: key,
                          child: t == null ? addTile(i == selected) : wallpaperTile(t, i, i == selected),
                        );
                      },
                    );
                  }),
                ),
              ]),
      ),
    );
  }
}
