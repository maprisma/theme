import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../widgets.dart';
import 'wallpapers_page.dart' show failText, previewSeconds;

const _source = 'wallhaven.cc';
const _thumbWorkers = 4;

/// Search wallpapers on wallhaven.cc for one theme (the plugin's web search
/// page): safe for work, landscape, at least 1920×1080, more as you scroll.
class WallhavenPage extends StatefulWidget {
  const WallhavenPage({super.key, required this.slug, required this.themeName, this.current = false});
  final String slug, themeName;

  /// The theme is in use (Add and set as background is offered).
  final bool current;
  @override
  State<WallhavenPage> createState() => _WallhavenPageState();
}

class _WallhavenPageState extends State<WallhavenPage> {
  late final MaprismaThemeAppState app;
  final field = TextEditingController();
  final fieldFocus = FocusNode();
  final gridFocus = FocusNode();
  final scroll = ScrollController();
  final _tileKeys = <String, GlobalKey>{};
  final _menuKeys = <String, GlobalKey<PopupMenuButtonState<VoidCallback>>>{};

  List<Map<String, dynamic>> results = [];
  final thumbs = <String, String?>{};
  String query = '', status = '';
  int page = 0, lastPage = 1, generation = 0, selected = 0, columns = 3;
  bool loading = false;
  final _thumbQueue = <Map<String, dynamic>>[];
  int _thumbsRunning = 0;

  /// The result whose preview is loading or shown (`web:<id>`), null when none.
  String? previewing;
  bool previewShown = false;
  Timer? previewTimer;

  @override
  void initState() {
    super.initState();
    app = AppScope.read(context);
    scroll.addListener(() {
      if (scroll.position.pixels > scroll.position.maxScrollExtent - 400) loadMore();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => fieldFocus.requestFocus());
  }

  @override
  void dispose() {
    generation++;
    if (previewShown) app.call('wallpapers.preview_end').ignore();
    previewTimer?.cancel();
    field.dispose();
    fieldFocus.dispose();
    gridFocus.dispose();
    scroll.dispose();
    super.dispose();
  }

  String get hint {
    if (status.isNotEmpty) return status;
    return 'Type what you are looking for and press Enter. Results come from $_source: safe for work, '
        'landscape, at least 1920×1080.';
  }

  Future<void> search() async {
    final q = field.text.trim();
    if (q.isEmpty) return;
    generation++;
    _thumbQueue.clear();
    setState(() {
      query = q;
      page = 0;
      lastPage = 1;
      results = [];
      selected = 0;
      loading = false;
    });
    await loadMore();
  }

  Future<void> loadMore() async {
    if (loading || query.isEmpty || page >= lastPage) return;
    final gen = generation, next = page + 1;
    setState(() {
      loading = true;
      status = 'Searching $_source for “$query”…';
    });
    Map<String, dynamic>? r;
    String? error;
    try {
      r = await app.call('wallhaven.search', {'query': query, 'page': next, 'slug': widget.slug});
    } catch (e) {
      error = failText(e);
    }
    if (!mounted || gen != generation) return;
    setState(() {
      loading = false;
      if (r == null) {
        status = 'Search failed: $error';
        return;
      }
      page = next;
      lastPage = (r['last_page'] as num?)?.toInt() ?? 1;
      final fresh = [for (final x in (r['results'] as List?) ?? const []) Map<String, dynamic>.from(x as Map)];
      final known = {for (final x in results) x['id']};
      results.addAll(fresh.where((x) => !known.contains(x['id'])));
      _thumbQueue.addAll(fresh.where((x) => !thumbs.containsKey(x['id'])));
      if (results.isEmpty) {
        status = 'Nothing found for “$query”. Try other words.';
      } else {
        status = '${results.length} wallpapers for “$query”.${page < lastPage ? ' Scroll down for more.' : ''} '
            'Enter on a tile opens its menu.';
      }
    });
    _pumpThumbs(gen);
    // A first page that does not fill the window cannot be scrolled: load on.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && gen == generation && scroll.hasClients && scroll.position.maxScrollExtent < 50) loadMore();
    });
  }

  void _pumpThumbs(int gen) {
    while (_thumbsRunning < _thumbWorkers && _thumbQueue.isNotEmpty) {
      final item = _thumbQueue.removeAt(0);
      _thumbsRunning++;
      () async {
        String? path;
        try {
          path = (await app.call('wallhaven.thumb', {'item': item}))['path'] as String?;
        } catch (_) {
          path = null;
        }
        _thumbsRunning--;
        if (!mounted || gen != generation) return;
        setState(() => thumbs[item['id'] as String] = path);
        _pumpThumbs(gen);
      }();
    }
  }

  // --- actions -------------------------------------------------------------------

  Future<void> add(Map<String, dynamic> item, {bool set = false}) async {
    setState(() => status = 'Downloading ${item['file_name']}…');
    try {
      final r = await app.call('wallhaven.add', {'slug': widget.slug, 'item': _plain(item), 'set': set});
      if (!mounted) return;
      setState(() {
        item['added'] = true;
        status = 'Added ${r['name']} to ${widget.themeName}.';
      });
      app.notify('Wallpaper added: ${r['name']} → ${widget.themeName}');
      app.changed();
    } catch (e) {
      final why = failText(e);
      if (mounted) setState(() => status = 'Could not add ${item['file_name']}: $why');
      app.notify('Could not add wallpaper: ${item['file_name']}: $why');
    }
  }

  /// The fields the core checks again (its exact URL shapes).
  Map<String, dynamic> _plain(Map item) => {
    for (final k in ['id', 'page', 'thumb', 'full', 'resolution', 'file_size']) k: item[k],
  };

  Future<void> preview(Map<String, dynamic> item, {int seconds = 0}) async {
    final tag = 'web:${item['id']}';
    previewTimer?.cancel();
    previewTimer = null;
    previewing = tag;
    setState(() => status = 'Loading a preview of ${item['file_name']}…');
    String? path;
    try {
      path = (await app.call('wallhaven.preview', {'item': _plain(item)}))['path'] as String?;
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    setState(() => status = '');
    if (path == null) {
      if (previewing == tag) previewing = null;
      app.notify('No preview: ${item['file_name']} could not be loaded');
      return;
    }
    if (previewing != tag) return; // Space was let go meanwhile
    final r = await app.run('wallpapers.preview', {'path': path});
    if (r == null) return;
    previewShown = true;
    if (previewing != tag) {
      endPreview();
      return;
    }
    if (seconds > 0) previewTimer = Timer(Duration(seconds: seconds), endPreview);
  }

  Future<void> endPreview() async {
    previewTimer?.cancel();
    previewTimer = null;
    previewing = null;
    if (!previewShown) return;
    previewShown = false;
    await app.run('wallpapers.preview_end');
  }

  Future<void> openPage(Map item) async {
    final r = await app.run('wallhaven.open', {'page': item['page']});
    if (r != null && r['opened'] != true) app.notify('No web browser could be started (xdg-open).');
  }

  List<PopupMenuEntry<VoidCallback>> menuFor(Map<String, dynamic> item) => [
    if (item['added'] == true)
      item_(Icons.check, 'Already added', null)
    else ...[
      item_(Icons.add, 'Add to ${widget.themeName}', () => add(item)),
      if (widget.current) item_(Icons.wallpaper_outlined, 'Add and set as background', () => add(item, set: true)),
    ],
    item_(Icons.visibility_outlined, 'Preview on desktop ($previewSeconds s)', () => preview(item, seconds: previewSeconds)),
    const PopupMenuDivider(),
    item_(Icons.open_in_browser, 'Open on $_source', () => openPage(item)),
  ];

  PopupMenuItem<VoidCallback> item_(IconData icon, String label, VoidCallback? action) =>
      item(icon, label, action ?? () {}, enabled: action != null);

  // --- keyboard ------------------------------------------------------------------

  void select(int i) {
    if (results.isEmpty) return;
    setState(() => selected = i.clamp(0, results.length - 1));
    final ctx = _tileKeys['${results[selected]['id']}']?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .5, duration: const Duration(milliseconds: 120));
    if (selected >= results.length - columns) loadMore();
  }

  KeyEventResult onGridKey(FocusNode node, KeyEvent e) {
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      if (e is KeyDownEvent && selected < results.length) {
        preview(results[selected]);
      } else if (e is KeyUpEvent && previewTimer == null) {
        endPreview();
      }
      return KeyEventResult.handled;
    }
    if (e is KeyUpEvent) return KeyEventResult.ignored;
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
        if (selected < columns) {
          fieldFocus.requestFocus();
        } else {
          select(selected - columns);
        }
      case LogicalKeyboardKey.home:
        select(0);
      case LogicalKeyboardKey.end:
        select(results.length - 1);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter || LogicalKeyboardKey.contextMenu:
        if (selected < results.length) _menuKeys['${results[selected]['id']}']?.currentState?.showButtonMenu();
      case LogicalKeyboardKey.escape || LogicalKeyboardKey.backspace:
        Navigator.of(context).maybePop();
      default:
        final ch = e.character;
        if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 32 && ch.codeUnitAt(0) != 127) {
          // typing goes back to the search field
          field.text += ch;
          field.selection = TextSelection.collapsed(offset: field.text.length);
          fieldFocus.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult onFieldKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown && results.isNotEmpty) {
      gridFocus.requestFocus();
      select(selected);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- view ----------------------------------------------------------------------

  Widget tile(Map<String, dynamic> item, int index) {
    final scheme = Theme.of(context).colorScheme;
    final id = item['id'] as String;
    final menuKey = _menuKeys.putIfAbsent(id, () => GlobalKey());
    final thumb = thumbs[id];
    final isSelected = index == selected && gridFocus.hasFocus;
    return GestureDetector(
      onTap: () {
        gridFocus.requestFocus();
        select(index);
      },
      onSecondaryTap: () => menuKey.currentState?.showButtonMenu(),
      child: Column(children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: isSelected ? scheme.primary : Colors.transparent, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(fit: StackFit.expand, children: [
                // Thumbnails are header-checked by the core before they are handed over.
                if (thumb != null)
                  Image.file(File(thumb), fit: BoxFit.cover, cacheWidth: 480,
                      errorBuilder: (_, _, _) => Container(color: scheme.surfaceContainerHighest))
                else
                  Container(
                    color: scheme.surfaceContainerHighest,
                    child: thumbs.containsKey(id) ? const Center(child: Icon(Icons.image_not_supported_outlined)) : null,
                  ),
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
                      itemBuilder: (_) => menuFor(item),
                      onSelected: (action) => action(),
                    ),
                  ),
                ),
                if (item['added'] == true)
                  Positioned(bottom: 6, left: 6, child: Tag(label: 'added', color: scheme.primary)),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('${item['resolution']}'.replaceAll('x', ' × '), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SubPage(
      title: '${widget.themeName} — search wallpapers',
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Focus(
            onKeyEvent: onFieldKey,
            child: TextField(
              controller: field,
              focusNode: fieldFocus,
              maxLength: 100,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search wallhaven.cc',
                counterText: '',
                isDense: true,
              ),
              onSubmitted: (_) => search(),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        Expanded(
          child: Focus(
            focusNode: gridFocus,
            onKeyEvent: onGridKey,
            onFocusChange: (_) => setState(() {}),
            child: LayoutBuilder(builder: (context, box) {
              columns = (box.maxWidth / 230).floor().clamp(2, 4);
              return GridView.builder(
                controller: scroll,
                padding: const EdgeInsets.all(12),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 16 / 11,
                ),
                itemCount: results.length + (loading ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i >= results.length) return const Center(child: CircularProgressIndicator());
                  final item = results[i];
                  return KeyedSubtree(
                    key: _tileKeys.putIfAbsent('${item['id']}', () => GlobalKey()),
                    child: tile(item, i),
                  );
                },
              );
            }),
          ),
        ),
      ]),
    );
  }
}
