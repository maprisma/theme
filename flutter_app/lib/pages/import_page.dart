import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../widgets.dart';

/// Import themes: the omarchy.org gallery (git themes, applied on COSMIC
/// through their colors.toml) and cosmic-themes.org (native COSMIC themes).
/// Each tab is a searchable grid; a tile's ☰ menu installs, installs and
/// applies, or opens the theme's page in the browser.
class ImportPage extends StatelessWidget {
  const ImportPage({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Import themes'),
          bottom: const TabBar(tabs: [Tab(text: 'omarchy.org'), Tab(text: 'cosmic-themes.org')]),
        ),
        body: const TabBarView(children: [_OmarchyTab(), _CosmicTab()]),
      ),
    ),
  );
}

/// The search field both tabs use; Esc clears it, then leaves the page.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.hint, this.trailing});
  final TextEditingController controller;
  final String hint;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
    child: Row(
      children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (controller.text.isNotEmpty) {
                  controller.clear();
                } else {
                  Navigator.maybePop(context);
                }
              },
            },
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 100,
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                prefixIcon: const Icon(Icons.search),
                hintText: hint,
                border: const OutlineInputBorder(),
                suffixIcon: ListenableBuilder(
                  listenable: controller,
                  builder: (_, _) => controller.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(tooltip: 'Clear', icon: const Icon(Icons.close), onPressed: controller.clear),
                ),
              ),
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 10), trailing!],
      ],
    ),
  );
}

/// One gallery theme: preview, name, tags and the ☰ menu.
class _ImportTile extends StatelessWidget {
  const _ImportTile({
    super.key,
    required this.name,
    required this.preview,
    required this.tags,
    required this.menu,
    required this.busy,
    this.subtitle,
  });
  final String name;
  final String? subtitle;
  final Widget preview;
  final List<Widget> tags;
  final List<PopupMenuEntry<VoidCallback>> Function() menu;
  final bool busy;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              preview,
              if (busy) const ColoredBox(color: Color(0x66000000), child: Center(child: CircularProgressIndicator())),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    if (tags.isNotEmpty) Wrap(spacing: 4, runSpacing: 2, children: tags),
                  ],
                ),
              ),
              PopupMenuButton<VoidCallback>(
                tooltip: 'Menu',
                icon: const Icon(Icons.menu),
                enabled: !busy,
                itemBuilder: (_) => menu(),
                onSelected: (f) => f(),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _grid(int count, Widget Function(BuildContext, int) builder, {ScrollController? controller}) => LayoutBuilder(
  builder: (context, box) => GridView.builder(
    controller: controller,
    padding: const EdgeInsets.all(14),
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: (box.maxWidth / 300).floor().clamp(2, 4),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.25,
    ),
    itemCount: count,
    itemBuilder: builder,
  ),
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
    app.notify(r['applied'] == true ? '$name installed and applied' : '$name installed');
  }
  return true;
}

// --- omarchy.org ---------------------------------------------------------------

class _OmarchyTab extends StatefulWidget {
  const _OmarchyTab();
  @override
  State<_OmarchyTab> createState() => _OmarchyTabState();
}

class _OmarchyTabState extends State<_OmarchyTab> with AutomaticKeepAliveClientMixin {
  late final MaprismaThemeAppState app;
  final search = TextEditingController();
  List<Map<String, dynamic>> themes = [];
  bool loading = true;
  String? error;
  final busy = <String>{};

  /// slug → preview path ('' while loading or when there is none).
  final previews = <String, String>{};
  final _queue = <String>[];
  var _running = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    app = AppScope.read(context);
    search.addListener(() => setState(() {}));
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Could not load the theme list from omarchy.org.';
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
      app.call('import.omarchy_preview', {'slug': slug}).then((r) {
        final path = r['path'];
        if (mounted && path is String) setState(() => previews[slug] = path);
      }).catchError((_) {}).whenComplete(() {
        _running--;
        if (mounted) _pump();
      });
    }
  }

  List<Map<String, dynamic>> get shown {
    final q = search.text.trim().toLowerCase();
    return [
      for (final t in themes)
        if (q.isEmpty || (t['name'] as String).toLowerCase().contains(q) || (t['repo'] as String).toLowerCase().contains(q)) t,
    ];
  }

  Future<void> install(Map<String, dynamic> t, bool apply) async {
    final slug = t['slug'] as String;
    setState(() => busy.add(slug));
    final ok = await _install(app, 'import.omarchy_install', {'name': slug}, t['name'] as String, apply);
    if (!mounted) return;
    setState(() {
      busy.remove(slug);
      if (ok) t['installed'] = true;
    });
  }

  List<PopupMenuEntry<VoidCallback>> menu(Map<String, dynamic> t) {
    final installed = t['installed'] == true;
    return [
      item(Icons.download_outlined, 'Install', () => install(t, false), enabled: !installed),
      item(Icons.check_circle_outline, 'Install and apply', () => install(t, true), enabled: !installed),
      const PopupMenuDivider(),
      item(Icons.open_in_new, 'Open page in browser', () => app.run('import.open', {'url': t['repo']})),
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final list = shown;
    return Column(
      children: [
        _SearchField(
          controller: search,
          hint: themes.isEmpty ? 'Search' : 'Search ${themes.length} themes',
          trailing: IconButton(tooltip: 'Reload the list', icon: const Icon(Icons.refresh), onPressed: () => load(force: true)),
        ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null && themes.isEmpty
              ? Center(child: Text(error!))
              : list.isEmpty
              ? Center(child: Text('No theme matches “${search.text.trim()}”.'))
              : _grid(list.length, (context, i) {
                  final t = list[i];
                  final slug = t['slug'] as String;
                  wantPreview(slug);
                  final path = previews[slug] ?? '';
                  return _ImportTile(
                    key: ValueKey(slug),
                    name: t['name'] as String,
                    busy: busy.contains(slug),
                    preview: path.isEmpty
                        ? ColoredBox(color: scheme.surfaceContainerHighest, child: const Icon(Icons.image_outlined))
                        : Image.file(File(path), fit: BoxFit.cover, cacheWidth: 600,
                            errorBuilder: (_, _, _) => ColoredBox(color: scheme.surfaceContainerHighest)),
                    tags: [if (t['installed'] == true) Tag(label: 'installed', color: scheme.primary)],
                    menu: () => menu(t),
                  );
                }),
        ),
      ],
    );
  }
}

// --- cosmic-themes.org ---------------------------------------------------------

class _CosmicTab extends StatefulWidget {
  const _CosmicTab();
  @override
  State<_CosmicTab> createState() => _CosmicTabState();
}

class _CosmicTabState extends State<_CosmicTab> with AutomaticKeepAliveClientMixin {
  late final MaprismaThemeAppState app;
  final search = TextEditingController();
  final scroll = ScrollController();
  List<Map<String, dynamic>> themes = [];
  List<Map> sorts = const [
    {'value': 'popular', 'label': 'Popular'},
    {'value': 'new', 'label': 'New'},
    {'value': 'name', 'label': 'Name'},
  ];
  String sort = 'popular';
  int? nextPage;
  bool loading = true, loadingMore = false;
  String? error;
  final busy = <int>{};
  Timer? _debounce;
  String _lastSearch = '';
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    app = AppScope.read(context);
    search.addListener(() {
      if (search.text.trim() == _lastSearch) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 400), load);
    });
    scroll.addListener(() {
      if (scroll.position.extentAfter < 400) more();
    });
    load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _params => {
    if (search.text.trim().isNotEmpty) 'search': search.text.trim(),
    'sort': sort,
  };

  Future<void> load() async {
    final gen = ++_generation;
    _lastSearch = search.text.trim();
    setState(() {
      loading = true;
      error = null;
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
    } catch (_) {
      if (!mounted || gen != _generation) return;
      setState(() {
        loading = false;
        error = 'Could not load the theme list from cosmic-themes.org.';
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
    setState(() => busy.add(id));
    final ok = await _install(app, 'import.cosmic_install', {'id': id}, t['name'] as String, apply);
    if (!mounted) return;
    setState(() {
      busy.remove(id);
      if (ok) t['installed'] = true;
    });
  }

  List<PopupMenuEntry<VoidCallback>> menu(Map<String, dynamic> t) {
    final installed = t['installed'] == true;
    return [
      item(Icons.download_outlined, 'Install', () => install(t, false), enabled: !installed),
      item(Icons.check_circle_outline, 'Install and apply', () => install(t, true), enabled: !installed),
      const PopupMenuDivider(),
      item(Icons.open_in_new, 'Open page in browser', () => app.run('import.open', {'url': t['page']})),
    ];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        _SearchField(
          controller: search,
          hint: 'Search cosmic-themes.org',
          trailing: DropdownButton<String>(
            value: sorts.any((s) => s['value'] == sort) ? sort : null,
            hint: const Text('Sort'),
            underline: const SizedBox.shrink(),
            items: [for (final s in sorts) DropdownMenuItem(value: '${s['value']}', child: Text('${s['label']}'))],
            onChanged: (v) {
              if (v == null || v == sort) return;
              setState(() => sort = v);
              load();
            },
          ),
        ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
              ? Center(child: Text(error!))
              : themes.isEmpty
              ? Center(child: Text(search.text.trim().isEmpty ? 'No themes found.' : 'No theme matches “${search.text.trim()}”.'))
              : _grid(themes.length + (loadingMore ? 1 : 0), controller: scroll, (context, i) {
                  if (i >= themes.length) return const Center(child: CircularProgressIndicator());
                  final t = themes[i];
                  final id = t['id'] as int;
                  final author = '${t['author'] ?? ''}';
                  final downloads = t['downloads'] as int? ?? 0;
                  return _ImportTile(
                    key: ValueKey(id),
                    name: t['name'] as String,
                    subtitle: [if (author.isNotEmpty) author, '$downloads downloads'].join(' · '),
                    busy: busy.contains(id),
                    preview: ColorPreview(colors: (t['preview'] as Map?) ?? const {}, title: t['name'] as String),
                    tags: [
                      if (t['installed'] == true) Tag(label: 'installed', color: scheme.primary),
                      Tag(label: t['dark'] == true ? 'dark' : 'light'),
                    ],
                    menu: () => menu(t),
                  );
                }),
        ),
      ],
    );
  }
}
