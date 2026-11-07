import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart' show Paths, Posix, ServiceError;

import '../app.dart';
import '../widgets.dart';
import '../window.dart';
import 'editor_page.dart';
import 'wallhaven_page.dart';

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
  bool showHidden = false, dragging = false, busy = false;
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
      final w = await app.call('auto.workspace_wallpapers', {'slug': widget.slug});
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
      if ((showHidden || w['hidden'] != true) &&
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
      app.notify('${added.length == 1 ? 'Wallpaper' : 'Wallpapers'} added: '
          '${added.take(5).join(', ')}${added.length > 5 ? '…' : ''}'
          '${errors.isEmpty ? '' : ' — skipped: ${errors.take(3).join('; ')}'}');
    } else if (errors.isNotEmpty) {
      app.notify('Some files were skipped: ${errors.take(3).join('; ')}${errors.length > 3 ? '…' : ''}');
    }
    load();
    app.changed();
  }

  Future<void> addFiles(List<String> paths) async {
    if (paths.isEmpty) {
      app.notify('Nothing added: drop local image files (JPG, PNG, WebP, GIF, BMP, HEIC).');
      return;
    }
    if (paths.length > maxDrops) app.notify('At most $maxDrops files at once; the first $maxDrops are added.');
    setState(() => busy = true);
    final r = await _try('wallpapers.add_files', {'slug': widget.slug, 'paths': paths.take(maxDrops).toList()},
        'Could not add wallpaper');
    if (mounted) setState(() => busy = false);
    reportAdded(r);
  }

  Future<void> choose() async {
    const group = XTypeGroup(
      label: 'Images',
      extensions: ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif'],
      mimeTypes: ['image/jpeg', 'image/png', 'image/gif', 'image/bmp', 'image/webp', 'image/heic', 'image/heif'],
    );
    final home = Platform.environment['HOME'] ?? '/';
    final pictures = Directory('$home/Pictures').existsSync() ? '$home/Pictures' : home;
    final files = await openFiles(acceptedTypeGroups: [group], initialDirectory: pictures, confirmButtonText: 'Add');
    if (files.isEmpty || !mounted) return;
    await addFiles([for (final f in files) f.path]);
  }

  Future<void> paste() async {
    setState(() => busy = true);
    final r = await _try('wallpapers.add_clipboard', {'slug': widget.slug}, 'Could not add wallpaper');
    if (mounted) setState(() => busy = false);
    reportAdded(r);
  }

  Future<void> onDrop(Drop d) async {
    if (d.isUriList) {
      await addFiles(droppedPaths(utf8.decode(d.data, allowMalformed: true)));
      return;
    }
    if (d.data.isEmpty) {
      app.notify('Nothing added: the image could not be read (or is over 50 MiB).');
      return;
    }
    setState(() => busy = true);
    Map<String, dynamic>? r;
    if (d.data.length <= _inlineDropBytes) {
      r = await _try('wallpapers.add_bytes', {'slug': widget.slug, 'data': base64Encode(d.data), 'type': d.type},
          'Could not add wallpaper');
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
            'Could not add wallpaper');
      } else {
        app.notify('Nothing added: the image could not be stored.');
      }
    }
    if (mounted) setState(() => busy = false);
    reportAdded(r);
  }

  // --- actions -------------------------------------------------------------------

  Future<void> setBackground(Map w) async {
    final r = await _try('wallpapers.set', {'slug': widget.slug, 'path': w['path']}, 'Could not set background');
    if (r == null) return;
    previewing = false;
    load();
    app.changed();
  }

  Future<void> startPreview(String path, {int seconds = 0}) async {
    previewTimer?.cancel();
    previewTimer = null;
    final r = await _try('wallpapers.preview', {'path': path}, 'No preview');
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
    final picked = await pickWorkspaces(context, 'Show $name on workspace…', workspacesOf(name).toSet());
    if (picked == null) return;
    final r = await _try('auto.set_workspace_wallpaper',
        {'slug': widget.slug, 'name': name, 'workspaces': picked.toList()..sort()},
        'Could not change the workspace wallpaper');
    if (r == null) return;
    load();
    app.changed();
  }

  Future<void> setHidden(Map w, bool hide) async {
    final r = await _try('wallpapers.hide', {'slug': widget.slug, 'name': w['name'], 'hidden': hide},
        hide ? 'Could not hide wallpaper' : 'Could not unhide wallpaper');
    if (r == null) return;
    load();
    app.changed();
    if (hide) {
      app.notify('${w['name']} hidden', undo: () async {
        await _try('wallpapers.hide', {'slug': widget.slug, 'name': w['name'], 'hidden': false}, 'Could not unhide wallpaper');
        load();
        app.changed();
      });
    }
  }

  Future<void> delete(Map w) async {
    final ok = await confirm(context, 'Delete wallpaper “${w['name']}” from “$themeName”?',
        'It goes to the trash: Undo brings it back.', action: 'Delete wallpaper');
    if (!ok) return;
    final r = await _try('wallpapers.delete', {'slug': widget.slug, 'name': w['name']}, 'Could not delete wallpaper');
    if (r == null) return;
    load();
    app.changed();
    final receipt = r['receipt'];
    app.notify('“${w['name']}” moved to the trash', undo: receipt is! String ? null : () async {
      final u = await _try('wallpapers.undo_delete', {'receipt': receipt}, 'Could not undo');
      if (u != null) app.notify('Restored ${w['name']}');
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
      if (isCurrent && !hidden) item(Icons.wallpaper_outlined, 'Set as background', () => setBackground(w)),
      if (!hidden)
        item(Icons.visibility_outlined, 'Preview on desktop ($previewSeconds s)',
            () => startPreview(w['path'] as String, seconds: previewSeconds)),
      if (!hidden) item(Icons.palette_outlined, 'New theme from this wallpaper…', () => newTheme(w)),
      if (!hidden)
        item(Icons.grid_view_outlined, ws.isEmpty ? 'Show on workspace…' : 'On workspace ${ws.join(', ')}…',
            () => showOnWorkspaces(w)),
      const PopupMenuDivider(),
      hidden
          ? item(Icons.visibility_outlined, 'Unhide', () => setHidden(w, false))
          : item(Icons.visibility_off_outlined, 'Hide', () => setHidden(w, true)),
      const PopupMenuDivider(),
      if (w['deletable'] == true)
        item(Icons.delete_outline, 'Delete…', () => delete(w))
      else
        PopupMenuItem<VoidCallback>(
          enabled: false,
          child: Tooltip(
            message: '${w['locked_reason'] ?? ''}',
            child: const Row(children: [
              Icon(Icons.lock_outline, size: 18),
              SizedBox(width: 12),
              Text("Can't delete: hide instead"),
            ]),
          ),
        ),
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
    if (key == LogicalKeyboardKey.space && filter.isEmpty) {
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
        if (filter.isNotEmpty) {
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
    message: why ?? 'unreadable image',
    child: Container(color: scheme.surfaceContainerHighest, child: const Center(child: Icon(Icons.broken_image_outlined))),
  );

  Widget addTile(bool selectedTile) {
    final scheme = Theme.of(context).colorScheme;
    final lit = dragging || selectedTile;
    final empty = wallpapers.isEmpty;
    return Tooltip(
      message: 'Choose image files (Enter), drag them anywhere onto this page, or paste an image or file with Ctrl+V. '
          'HEIC photos are converted. Stored in ${data?['folder'] ?? 'your wallpaper folder for this theme'}.',
      child: InkWell(
        onTap: () {
          focus.requestFocus();
          select(0);
          choose();
        },
        borderRadius: BorderRadius.circular(12),
        child: Column(children: [
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                color: dragging ? scheme.primary.withValues(alpha: .18) : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: lit ? scheme.primary : scheme.outlineVariant, width: lit ? 2 : 1),
              ),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(busy ? Icons.hourglass_top : Icons.add, size: 32, color: lit ? scheme.primary : null),
                    const SizedBox(height: 6),
                    Text(
                      '${empty ? 'No wallpapers yet. ' : ''}Drop images here, paste with Ctrl+V or click to choose',
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text('Add wallpapers…', maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      ),
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
            cacheWidth: 480,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => brokenPicture(scheme),
          );
    return Opacity(
      opacity: hidden ? .45 : 1,
      child: GestureDetector(
        onTap: () {
          focus.requestFocus();
          select(index);
        },
        onSecondaryTap: () => menuKey.currentState?.showButtonMenu(),
        child: Column(children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: selectedTile ? scheme.primary : Colors.transparent, width: 2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(fit: StackFit.expand, children: [
                  picture,
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Material(
                      color: scheme.surface.withValues(alpha: .7),
                      shape: const CircleBorder(),
                      child: PopupMenuButton<VoidCallback>(
                        key: menuKey,
                        tooltip: 'Wallpaper actions (Enter)',
                        icon: const Icon(Icons.menu, size: 18),
                        itemBuilder: (_) => menuFor(w),
                        onSelected: (action) => action(),
                      ),
                    ),
                  ),
                  if (ws.isNotEmpty)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Tooltip(
                        message: 'Shown on workspace ${ws.join(', ')}',
                        child: Tag(label: 'ws ${ws.join(' · ')}', color: scheme.primary),
                      ),
                    ),
                  if (hidden || w['shown'] == true)
                    Positioned(
                      bottom: 6,
                      left: 6,
                      child: Tag(label: hidden ? 'hidden' : 'on the desktop', color: hidden ? null : scheme.tertiary),
                    ),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text('${w['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = tiles;
    final title = '$themeName — wallpapers${filter.isEmpty ? '' : ' — $filter'}';
    final hiddenCount = ((data?['wallpapers'] as List?) ?? const []).where((w) => w['hidden'] == true).length;
    return SubPage(
      title: title,
      actions: [
        IconButton(
          tooltip: showHidden ? 'Hide hidden wallpapers' : 'Show hidden wallpapers ($hiddenCount)',
          icon: Icon(showHidden ? Icons.visibility : Icons.visibility_off_outlined),
          onPressed: () => setState(() {
            showHidden = !showHidden;
            selected = 0;
          }),
        ),
        IconButton(
          tooltip: 'Add the image copied to the clipboard (from the web or the file manager) — Ctrl+V',
          icon: const Icon(Icons.content_paste),
          onPressed: busy ? null : paste,
        ),
        IconButton(tooltip: 'Search the web (Ctrl+F)', icon: const Icon(Icons.travel_explore), onPressed: openSearch),
      ],
      body: Focus(
        focusNode: focus,
        autofocus: true,
        onKeyEvent: onKey,
        child: data == null
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(builder: (context, box) {
                columns = (box.maxWidth / 230).floor().clamp(2, 4);
                if (list.isEmpty) return Center(child: Text('No wallpaper matches “$filter”'));
                return GridView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.all(12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 16 / 11,
                  ),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
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
    );
  }
}
