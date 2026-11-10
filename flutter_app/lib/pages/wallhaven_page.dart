import '../i18n.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../theme.dart';
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
    return trf("Type what you are looking for and press Enter. Results come from {0}: safe for work, landscape, at least 1920×1080.", [_source]);
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
      status = trf("Searching {0} for “{1}”…", [_source, query]);
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
        status = trf("Search failed: {0}", [error]);
        return;
      }
      page = next;
      lastPage = (r['last_page'] as num?)?.toInt() ?? 1;
      final fresh = [for (final x in (r['results'] as List?) ?? const []) Map<String, dynamic>.from(x as Map)];
      final known = {for (final x in results) x['id']};
      results.addAll(fresh.where((x) => !known.contains(x['id'])));
      _thumbQueue.addAll(fresh.where((x) => !thumbs.containsKey(x['id'])));
      if (results.isEmpty) {
        status = trf("Nothing found for “{0}”. Try other words.", [query]);
      } else {
        status = trf("{0} wallpapers for “{1}”.{2} Enter on a tile opens its menu.", [results.length, query, page < lastPage ? tr(" Scroll down for more.") : '']);
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
    setState(() => status = trf("Downloading {0}…", [item['file_name']]));
    try {
      final r = await app.call('wallhaven.add', {'slug': widget.slug, 'item': _plain(item), 'set': set});
      if (!mounted) return;
      setState(() {
        item['added'] = true;
        status = trf("Added {0} to {1}.", [r['name'], widget.themeName]);
      });
      app.notify(trf("Wallpaper added: {0} → {1}", [r['name'], widget.themeName]));
      app.changed();
    } catch (e) {
      final why = failText(e);
      if (mounted) setState(() => status = trf("Could not add {0}: {1}", [item['file_name'], why]));
      app.notify(trf("Could not add wallpaper: {0}: {1}", [item['file_name'], why]));
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
    setState(() => status = trf("Loading a preview of {0}…", [item['file_name']]));
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
      app.notify(trf("No preview: {0} could not be loaded", [item['file_name']]));
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
    if (r != null && r['opened'] != true) app.notify(tr("No web browser could be started (xdg-open)."));
  }

  List<PopupMenuEntry<VoidCallback>> menuFor(Map<String, dynamic> w) => [
    if (w['added'] == true)
      item_(Icons.check, tr("Already added"), null)
    else ...[
      item(Icons.add, trf("Add to {0}", [widget.themeName]), () => add(w), tooltip: trf("Saved in ~/.config/maprisma-theme/backgrounds/{0}/", [widget.slug])),
      if (widget.current && app.can('wallpaper')) item_(Icons.wallpaper_outlined, tr("Add and set as background"), () => add(w, set: true)),
    ],
    if (app.can('wallpaper'))
      item(Icons.visibility_outlined, tr("Preview on desktop"), () => preview(w, seconds: previewSeconds),
          tooltip: trf("Loads the full image and shows it for {0} seconds; or hold Space on the tile", [previewSeconds])),
    menuLine(),
    item(Icons.open_in_browser, trf("Open on {0}", [_source]), () => openPage(w), tooltip: '${w['page']}'),
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
    if (key == LogicalKeyboardKey.space && app.can('wallpaper')) {
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
    final look = Look.of(context);
    final id = item['id'] as String;
    final menuKey = _menuKeys.putIfAbsent(id, () => GlobalKey());
    final thumb = thumbs[id];
    return PluginTile(
      selected: index == selected && gridFocus.hasFocus,
      onTap: () {
        gridFocus.requestFocus();
        select(index);
      },
      onSecondaryTap: () => menuKey.currentState?.showButtonMenu(),
      // Thumbnails are header-checked by the core before they are handed over.
      picture: thumb != null
          ? Image.file(File(thumb), fit: BoxFit.cover, cacheWidth: 640,
              errorBuilder: (_, _, _) => ColoredBox(color: look.fg.withValues(alpha: .06)))
          : ColoredBox(
              color: look.fg.withValues(alpha: .06),
              child: thumbs.containsKey(id) ? Icon(Icons.image_not_supported_outlined, color: look.muted) : null,
            ),
      menu: TileMenuButton(menuKey: menuKey, tooltip: tr("Wallpaper actions (Enter)"), menu: () => menuFor(item)),
      bottomLeft: [if (item['added'] == true) TileBadge(tr("added"))],
      captionText: '${item['resolution']}'.replaceAll('x', ' × '),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SubPage(
      title: trf("{0} — search wallpapers", [widget.themeName]),
      section: false,
      backTooltip: tr("Back to the wallpapers (Backspace or Esc)"),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Focus(
          onKeyEvent: onFieldKey,
          child: TextField(
            controller: field,
            focusNode: fieldFocus,
            maxLength: 100,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: tr("Search, e.g. misty forest, neon city"),
              counterText: '',
            ),
            onSubmitted: (_) => search(),
          ),
        ),
        const SizedBox(height: 8),
        Text(hint, style: hintStyle(context)),
        const SizedBox(height: 8),
        Expanded(
          child: Focus(
            focusNode: gridFocus,
            onKeyEvent: onGridKey,
            onFocusChange: (_) => setState(() {}),
            child: LayoutBuilder(builder: (context, box) {
              columns = gridColumns(box.maxWidth);
              return TileGrid(
                controller: scroll,
                count: results.length,
                columns: columns,
                footer: loading ? const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())) : null,
                builder: (context, i) {
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
