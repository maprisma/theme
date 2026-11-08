import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';

/// Import themes, as the plugin's import page: the omarchy.org gallery (git
/// themes, applied on COSMIC through their colors.toml) and, as a second
/// source, cosmic-themes.org (native COSMIC themes). A search field and the
/// reload button, a hint, then the themes as tiles; a tile's ☰ menu installs,
/// installs and applies, or opens the theme's page. Typing searches, ↓ or
/// Enter goes from the field to the tiles, the arrows move, Enter, Space or
/// the Menu key open a tile's menu, ← from the left column, Backspace or Esc
/// go back.
class ImportPage extends StatefulWidget {
  const ImportPage({super.key});
  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final r = corners(context);
    Widget tabButton(int i, String label) {
      final on = tab == i;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: OutlinedButton(
          onPressed: () => setState(() => tab = i),
          style: OutlinedButton.styleFrom(
            foregroundColor: on ? look.accent : look.fg,
            backgroundColor: on ? look.accent.withValues(alpha: .08) : Colors.transparent,
            side: BorderSide(color: on ? look.accent : look.fg.withValues(alpha: .25), width: on ? 2 : 1),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
          ),
          child: Text(label),
        ),
      );
    }

    return SubPage(
      title: tab == 0 ? 'Import themes — omarchy.org' : 'Import themes — cosmic-themes.org',
      section: false,
      backTooltip: 'Back to themes (Left, Backspace or Esc)',
      actions: [tabButton(0, 'omarchy.org'), tabButton(1, 'cosmic-themes.org')],
      body: IndexedStack(
        index: tab,
        children: [
          _OmarchyTab(active: tab == 0),
          _CosmicTab(active: tab == 1),
        ],
      ),
    );
  }
}

/// The search field with the reload button (or the sort) beside it.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller, required this.focus, required this.hint, required this.onKey, this.trailing});
  final TextEditingController controller;
  final FocusNode focus;
  final String hint;
  final FocusOnKeyEventCallback onKey;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Focus(
          onKeyEvent: onKey,
          child: TextField(
            controller: controller,
            focusNode: focus,
            maxLength: 100,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(counterText: '', prefixIcon: const Icon(Icons.search, size: 18), hintText: hint),
          ),
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: 8), trailing!],
    ],
  );
}

/// The tiles of one source with the keyboard of the plugin's import page.
mixin _Gallery<T extends StatefulWidget> on State<T> {
  late final MaprismaThemeAppState app;
  final search = TextEditingController();
  final fieldFocus = FocusNode();
  final gridFocus = FocusNode();
  final scroll = ScrollController();
  final menuKeys = <Object, GlobalKey<PopupMenuButtonState<VoidCallback>>>{};
  final tileKeys = <Object, GlobalKey>{};
  int selected = 0, columns = 2;

  List<Map<String, dynamic>> get items;
  Object idOf(Map<String, dynamic> t);

  @override
  void initState() {
    super.initState();
    app = AppScope.read(context);
  }

  @override
  void dispose() {
    search.dispose();
    fieldFocus.dispose();
    gridFocus.dispose();
    scroll.dispose();
    super.dispose();
  }

  void select(int i) {
    final list = items;
    if (list.isEmpty) return;
    setState(() => selected = i.clamp(0, list.length - 1));
    final ctx = tileKeys[idOf(list[selected])]?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, alignment: .5, duration: const Duration(milliseconds: 100));
  }

  void openMenu() {
    final list = items;
    if (selected < list.length) menuKeys[idOf(list[selected])]?.currentState?.showButtonMenu();
  }

  KeyEventResult onFieldKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if ((key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.enter) && items.isNotEmpty) {
      gridFocus.requestFocus();
      select(0);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.backspace) && search.text.isEmpty) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult onGridKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final n = items.length;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter || LogicalKeyboardKey.space || LogicalKeyboardKey.contextMenu:
        openMenu();
      case LogicalKeyboardKey.arrowRight:
        select(selected + 1);
      case LogicalKeyboardKey.arrowLeft:
        if (selected % columns == 0) {
          Navigator.of(context).maybePop();
        } else {
          select(selected - 1);
        }
      case LogicalKeyboardKey.arrowDown:
        if (selected + columns < n) select(selected + columns);
      case LogicalKeyboardKey.arrowUp:
        if (selected < columns) {
          fieldFocus.requestFocus();
        } else {
          select(selected - columns);
        }
      case LogicalKeyboardKey.pageDown:
        select(selected + 4 * columns);
      case LogicalKeyboardKey.pageUp:
        select(selected - 4 * columns);
      case LogicalKeyboardKey.home:
        select(0);
      case LogicalKeyboardKey.end:
        select(n - 1);
      case LogicalKeyboardKey.backspace:
        Navigator.of(context).maybePop();
      default:
        // Typing anywhere on the page searches.
        final ch = e.character;
        if (ch == null || ch.length != 1 || ch.codeUnitAt(0) < 32 || ch.codeUnitAt(0) == 127) return KeyEventResult.ignored;
        search.text += ch;
        search.selection = TextSelection.collapsed(offset: search.text.length);
        fieldFocus.requestFocus();
    }
    return KeyEventResult.handled;
  }

  /// The grid of [tile]s under the toolbar and the hint.
  Widget gallery({
    required Widget toolbar,
    required String hint,
    required Widget Function(int i, bool selected) tile,
    Widget? empty,
    Widget? footer,
  }) {
    final list = items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        toolbar,
        const SizedBox(height: 8),
        Text(hint, style: hintStyle(context)),
        const SizedBox(height: 8),
        Expanded(
          child: Focus(
            focusNode: gridFocus,
            onKeyEvent: onGridKey,
            onFocusChange: (_) => setState(() {}),
            child: LayoutBuilder(
              builder: (context, box) {
                columns = gridColumns(box.maxWidth);
                if (list.isEmpty) return Align(alignment: Alignment.topLeft, child: empty ?? const SizedBox());
                return TileGrid(
                  controller: scroll,
                  count: list.length,
                  columns: columns,
                  footer: footer,
                  builder: (context, i) => KeyedSubtree(
                    key: tileKeys.putIfAbsent(idOf(list[i]), () => GlobalKey()),
                    child: tile(i, gridFocus.hasFocus && i == selected),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// One gallery theme as the plugin's tile: preview, “installed”, ☰, name.
  Widget themeTile(
    int i,
    bool isSelected, {
    required Widget picture,
    required String name,
    required List<PopupMenuEntry<VoidCallback>> Function() menu,
    bool installed = false,
    bool busy = false,
    List<Widget> extraBadges = const [],
    String? tooltip,
  }) {
    final t = items[i];
    final menuKey = menuKeys.putIfAbsent(idOf(t), () => GlobalKey());
    return PluginTile(
      selected: isSelected,
      tooltip: tooltip,
      onTap: () {
        gridFocus.requestFocus();
        select(i);
      },
      onSecondaryTap: () => menuKey.currentState?.showButtonMenu(),
      picture: Stack(
        fit: StackFit.expand,
        children: [
          picture,
          if (busy)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
      menu: TileMenuButton(menuKey: menuKey, tooltip: 'Theme actions (Enter)', enabled: !busy, menu: menu),
      bottomLeft: [if (installed) const TileBadge('installed'), ...extraBadges],
      captionText: name,
    );
  }
}

Widget _noPicture(BuildContext context) => ColoredBox(
  color: Look.of(context).fg.withValues(alpha: .06),
  child: Icon(Icons.image_outlined, color: Look.of(context).muted),
);

/// Installs through [method]; tells how it went and lets the other pages
/// reload. True when the theme was installed.
Future<bool> _install(MaprismaThemeAppState app, String method, Map<String, dynamic> params, String name, bool apply) async {
  app.notify(apply ? 'Installing and applying $name…' : 'Installing $name…', duration: const Duration(seconds: 60));
  final r = await app.run(method, {...params, 'apply': apply});
  if (r == null) return false;
  app.changed();
  if (r['apply_error'] != null) {
    app.notify('$name installed, but not applied: ${r['apply_error']}');
  } else {
    app.notify(r['applied'] == true ? 'Theme installed and applied: $name' : 'Theme installed: $name');
  }
  return true;
}

Future<void> _open(MaprismaThemeAppState app, Object? url) async {
  final r = await app.run('import.open', {'url': url});
  if (r != null && r['opened'] != true) {
    app.notify("No default web browser is set, so theme pages can't be opened.");
  }
}

Future<void> _apply(MaprismaThemeAppState app, String slug, String name) async {
  final r = await app.run('themes.apply', {'slug': slug});
  if (r == null) return;
  app.notify('Theme applied: $name');
  app.changed();
}

// --- omarchy.org ---------------------------------------------------------------

class _OmarchyTab extends StatefulWidget {
  const _OmarchyTab({required this.active});
  final bool active;
  @override
  State<_OmarchyTab> createState() => _OmarchyTabState();
}

class _OmarchyTabState extends State<_OmarchyTab> with _Gallery<_OmarchyTab> {
  List<Map<String, dynamic>> themes = [];
  bool loading = true;
  String? error, status;
  final busy = <String>{};

  /// slug → preview path ('' while loading or when there is none).
  final previews = <String, String>{};
  final _queue = <String>[];
  var _running = 0;

  @override
  Object idOf(Map<String, dynamic> t) => t['slug'] as String;

  @override
  void initState() {
    super.initState();
    search.addListener(() => setState(() => selected = 0));
    load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) fieldFocus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(_OmarchyTab old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) fieldFocus.requestFocus();
  }

  Future<void> load({bool force = false}) async {
    setState(() {
      loading = themes.isEmpty;
      error = null;
    });
    try {
      final r = await app.call('import.omarchy_list', {'force': force});
      if (!mounted) return;
      setState(() {
        themes = [for (final t in r['themes'] as List) Map<String, dynamic>.from(t as Map)];
        for (final t in themes) {
          if (t['preview'] is String) previews[t['slug'] as String] = t['preview'] as String;
        }
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Could not load the theme list: ${errorText(e)}';
      });
    }
  }

  /// Fetches a preview (the core caches it), at most four at a time.
  void wantPreview(String slug) {
    if (previews.containsKey(slug)) return;
    previews[slug] = '';
    _queue.add(slug);
    scheduleMicrotask(_pump);
  }

  void _pump() {
    while (_running < 4 && _queue.isNotEmpty) {
      final slug = _queue.removeLast(); // the latest tiles first: what is on screen now
      _running++;
      app
          .call('import.omarchy_preview', {'slug': slug})
          .then((r) {
            final path = r['path'];
            if (mounted && path is String) setState(() => previews[slug] = path);
          })
          .catchError((_) {})
          .whenComplete(() {
            _running--;
            if (mounted) _pump();
          });
    }
  }

  @override
  List<Map<String, dynamic>> get items {
    final q = search.text.trim().toLowerCase();
    return [
      for (final t in themes)
        if (q.isEmpty || '${t['name']}'.toLowerCase().contains(q) || '${t['repo']}'.toLowerCase().contains(q)) t,
    ];
  }

  Future<void> install(Map<String, dynamic> t, bool apply) async {
    final slug = t['slug'] as String;
    setState(() {
      busy.add(slug);
      status = 'Installing ${t['name']}…';
    });
    final ok = await _install(app, 'import.omarchy_install', {'name': slug}, t['name'] as String, apply);
    if (!mounted) return;
    setState(() {
      busy.remove(slug);
      status = null;
      if (ok) t['installed'] = true;
    });
  }

  List<PopupMenuEntry<VoidCallback>> menu(Map<String, dynamic> t) {
    final installed = t['installed'] == true;
    return [
      if (installed) ...[
        item(Icons.check, 'Installed', () {}, enabled: false),
        item(Icons.play_arrow, 'Apply theme', () => _apply(app, t['slug'] as String, '${t['name']}')),
      ] else ...[
        item(
          Icons.download_outlined,
          'Install',
          () => install(t, false),
          tooltip: 'git clone into ~/.config/maprisma-theme/themes/${t['slug']}',
        ),
        item(Icons.play_arrow, 'Install and apply', () => install(t, true)),
      ],
      menuLine(),
      item(Icons.public, 'Open theme page', () => _open(app, t['repo']), tooltip: '${t['repo']}'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final hint =
        status ??
        error ??
        (loading
            ? 'Loading themes from omarchy.org…'
            : "${themes.length} themes from omarchy.org. Enter opens a theme's menu: install, install and apply, or open its page.");
    return gallery(
      toolbar: _Toolbar(
        controller: search,
        focus: fieldFocus,
        hint: 'Search themes',
        onKey: onFieldKey,
        trailing: Tooltip(
          message: 'Reload the list from omarchy.org',
          child: OutlinedButton(onPressed: () => load(force: true), child: const Icon(Icons.refresh, size: 18)),
        ),
      ),
      hint: hint,
      empty: loading
          ? const Center(child: CircularProgressIndicator())
          : themes.isEmpty
          ? null
          : Text('No theme matches “${search.text.trim()}”.', style: hintStyle(context)),
      tile: (i, isSelected) {
        final t = items[i];
        final slug = t['slug'] as String;
        wantPreview(slug);
        final path = previews[slug] ?? '';
        return themeTile(
          i,
          isSelected,
          name: '${t['name']}',
          installed: t['installed'] == true,
          busy: busy.contains(slug),
          menu: () => menu(t),
          picture: path.isEmpty
              ? _noPicture(context)
              : Image.file(File(path), fit: BoxFit.cover, cacheWidth: 640, errorBuilder: (_, _, _) => _noPicture(context)),
        );
      },
    );
  }
}

// --- cosmic-themes.org ---------------------------------------------------------

class _CosmicTab extends StatefulWidget {
  const _CosmicTab({required this.active});
  final bool active;
  @override
  State<_CosmicTab> createState() => _CosmicTabState();
}

class _CosmicTabState extends State<_CosmicTab> with _Gallery<_CosmicTab> {
  List<Map<String, dynamic>> themes = [];
  List<Map> sorts = const [
    {'value': 'popular', 'label': 'Popular'},
    {'value': 'new', 'label': 'New'},
    {'value': 'name', 'label': 'Name'},
  ];
  String sort = 'popular';
  int? nextPage;
  bool loading = true, loadingMore = false, started = false;
  String? error, status;
  final busy = <int>{};
  Timer? _debounce;
  String _lastSearch = '';
  int _generation = 0;

  @override
  Object idOf(Map<String, dynamic> t) => t['id'] as int;

  @override
  List<Map<String, dynamic>> get items => themes;

  @override
  void initState() {
    super.initState();
    search.addListener(() {
      if (search.text.trim() == _lastSearch) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), load);
    });
    scroll.addListener(() {
      if (scroll.position.extentAfter < 400) more();
    });
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(_CosmicTab old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _start();
      fieldFocus.requestFocus();
    }
  }

  /// Only once the tab is opened: no request to cosmic-themes.org before.
  void _start() {
    if (started) return;
    started = true;
    load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Map<String, dynamic> get _params => {if (search.text.trim().isNotEmpty) 'search': search.text.trim(), 'sort': sort};

  Future<void> load() async {
    final gen = ++_generation;
    _lastSearch = search.text.trim();
    setState(() {
      loading = true;
      error = null;
      selected = 0;
    });
    try {
      final r = await app.call('import.cosmic_list', _params);
      if (!mounted || gen != _generation) return;
      setState(() {
        themes = [for (final t in r['themes'] as List) Map<String, dynamic>.from(t as Map)];
        nextPage = r['next_page'] as int?;
        final s = r['sorts'];
        if (s is List && s.isNotEmpty) sorts = [for (final o in s) o as Map];
        loading = false;
      });
      if (scroll.hasClients) scroll.jumpTo(0);
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        loading = false;
        error = 'Could not load the theme list: ${errorText(e)}';
      });
    }
  }

  /// The next page, when the grid is scrolled near its end.
  Future<void> more() async {
    final page = nextPage;
    if (page == null || loading || loadingMore) return;
    final gen = _generation;
    setState(() => loadingMore = true);
    try {
      final r = await app.call('import.cosmic_list', {..._params, 'page': page});
      if (!mounted || gen != _generation) return;
      final have = {for (final t in themes) t['id']};
      setState(() {
        themes = [
          ...themes,
          for (final t in r['themes'] as List)
            if (!have.contains((t as Map)['id'])) Map<String, dynamic>.from(t),
        ];
        nextPage = r['next_page'] as int?;
      });
    } catch (_) {
      // the next scroll tries again
    } finally {
      if (mounted) setState(() => loadingMore = false);
    }
  }

  Future<void> install(Map<String, dynamic> t, bool apply) async {
    final id = t['id'] as int;
    setState(() {
      busy.add(id);
      status = 'Installing ${t['name']}…';
    });
    final ok = await _install(app, 'import.cosmic_install', {'id': id}, t['name'] as String, apply);
    if (!mounted) return;
    setState(() {
      busy.remove(id);
      status = null;
      if (ok) t['installed'] = true;
    });
  }

  List<PopupMenuEntry<VoidCallback>> menu(Map<String, dynamic> t) {
    final installed = t['installed'] == true;
    final slug = t['slug'];
    return [
      if (installed) ...[
        item(Icons.check, 'Installed', () {}, enabled: false),
        if (slug is String) item(Icons.play_arrow, 'Apply theme', () => _apply(app, slug, '${t['name']}')),
      ] else ...[
        item(Icons.download_outlined, 'Install', () => install(t, false)),
        item(Icons.play_arrow, 'Install and apply', () => install(t, true)),
      ],
      menuLine(),
      item(Icons.public, 'Open theme page', () => _open(app, t['page']), tooltip: '${t['page']}'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final native = AppScope.of(context).can('ron');
    final hint =
        status ??
        error ??
        (loading
            ? 'Loading themes from cosmic-themes.org…'
            : "${native ? 'Native COSMIC themes' : 'Theme colors'} from cosmic-themes.org. Enter opens a theme's menu: install, install and apply, or open its page.");
    return gallery(
      toolbar: _Toolbar(
        controller: search,
        focus: fieldFocus,
        hint: 'Search cosmic-themes.org',
        onKey: onFieldKey,
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: look.fg.withValues(alpha: .25)),
            borderRadius: BorderRadius.circular(corners(context)),
          ),
          child: DropdownButton<String>(
            value: sorts.any((s) => s['value'] == sort) ? sort : null,
            hint: const Text('Sort'),
            isDense: true,
            dropdownColor: look.bg,
            underline: const SizedBox.shrink(),
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 13, color: look.fg),
            items: [for (final s in sorts) DropdownMenuItem(value: '${s['value']}', child: Text('${s['label']}'))],
            onChanged: (v) {
              if (v == null || v == sort) return;
              setState(() => sort = v);
              load();
            },
          ),
        ),
      ),
      hint: hint,
      empty: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? null
          : Text(search.text.trim().isEmpty ? 'No themes found.' : 'No theme matches “${search.text.trim()}”.', style: hintStyle(context)),
      footer: loadingMore
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            )
          : null,
      tile: (i, isSelected) {
        final t = themes[i];
        final author = '${t['author'] ?? ''}';
        final downloads = t['downloads'] as int? ?? 0;
        return themeTile(
          i,
          isSelected,
          name: '${t['name']}',
          tooltip: [if (author.isNotEmpty) 'by $author', '$downloads downloads'].join(' · '),
          installed: t['installed'] == true,
          busy: busy.contains(t['id']),
          extraBadges: [TileBadge(t['dark'] == true ? 'dark' : 'light')],
          menu: () => menu(t),
          picture: ColorPreview(colors: (t['preview'] as Map?) ?? const {}, title: '${t['name']}'),
        );
      },
    );
  }
}
