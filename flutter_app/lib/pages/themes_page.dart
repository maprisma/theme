import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';
import '../window.dart';
import 'ask_page.dart';
import 'editor_page.dart';
import 'import_page.dart';
import 'info_page.dart';
import 'presets_page.dart';
import 'settings_page.dart';
import 'shortcut_page.dart';
import 'wallpapers_page.dart';

/// The theme list: every theme as a tile, favorites first (the plugin's main view).
class ThemesPage extends StatefulWidget {
  const ThemesPage({super.key});
  @override
  State<ThemesPage> createState() => _ThemesPageState();
}

class _ThemesPageState extends State<ThemesPage> {
  List<Map<String, dynamic>> themes = [];
  Map<String, List<String>> shortcutLabels = {};
  bool showHidden = false, loading = true;
  String filter = '';
  final focus = FocusNode();
  late final MaprismaThemeAppState app;

  @override
  void initState() {
    super.initState();
    app = AppScope.read(context);
    app.revision.addListener(load);
    load();
  }

  @override
  void dispose() {
    app.revision.removeListener(load);
    focus.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final r = await app.run('themes.list');
    Map<String, dynamic>? labels;
    try {
      labels = await app.call('shortcuts.labels');
    } catch (_) {
      labels = null;
    }
    if (!mounted || r == null) return;
    setState(() {
      themes = [for (final t in r['themes'] as List) Map<String, dynamic>.from(t as Map)];
      showHidden = r['show_hidden'] == true;
      loading = false;
      shortcutLabels = {
        for (final e in ((labels?['labels'] as Map?) ?? const {}).entries)
          '${e.key}': [for (final l in e.value as List) '$l'],
      };
    });
  }

  List<Map<String, dynamic>> get shown => [
    for (final t in themes)
      if ((showHidden || t['hidden'] != true) &&
          (filter.isEmpty || (t['name'] as String).toLowerCase().contains(filter.toLowerCase())))
        t,
  ];

  Future<void> apply(Map t) async {
    app.notify('Applying ${t['name']}…', duration: const Duration(seconds: 20));
    final r = await app.run('themes.apply', {'slug': t['slug']});
    if (r == null) return;
    app.notify('${t['name']} applied');
    app.changed();
  }

  Future<void> setFavorite(Map t, bool on) async {
    await app.run('themes.favorite', {'slug': t['slug'], 'favorite': on});
    app.changed();
  }

  Future<void> setHidden(Map t, bool on) async {
    await app.run('themes.hide', {'slug': t['slug'], 'hidden': on});
    app.changed();
    if (on) {
      app.notify('${t['name']} hidden', undo: () async {
        await app.run('themes.hide', {'slug': t['slug'], 'hidden': false});
        app.changed();
      });
    }
  }

  Future<void> delete(Map t) async {
    final ok = await confirm(context, 'Delete ${t['name']}?',
        'The theme goes to the trash. Wallpapers you added to it are kept.', action: 'Delete');
    if (!ok) return;
    final r = await app.run('themes.delete', {'slug': t['slug']});
    if (r == null) return;
    app.changed();
    app.notify('${t['name']} deleted', undo: r['receipt'] == null ? null : () async {
      await app.run('themes.undo_delete', {'receipt': r['receipt']});
      app.changed();
    });
  }

  Future<void> dayNight(Map t, String which) async {
    await app.run('auto.schedule_set', {which: t['slug']});
    app.notify('${t['name']} is the $which theme');
    app.changed();
  }

  Future<void> onWorkspaces(Map t) async {
    final r = await app.run('auto.workspace_themes');
    if (r == null || !mounted) return;
    final assigned = <int>{
      for (final e in ((r['themes'] as Map?) ?? const {}).entries)
        if (e.value == t['slug']) int.parse('${e.key}'),
    };
    final picked = await pickWorkspaces(context, 'Use ${t['name']} on workspace…', assigned);
    if (picked == null) return;
    await app.run('auto.set_workspace_themes', {'slug': t['slug'], 'workspaces': picked.toList()..sort()});
    app.changed();
  }

  Future<void> useEverywhere(Map t) async {
    final r = await app.run('auto.use_everywhere');
    if (r == null) return;
    app.changed();
    app.notify('${t['name']} is used on all workspaces', undo: r['saved'] == null ? null : () async {
      await app.run('auto.undo_use_everywhere', {'saved': r['saved']});
      app.changed();
    });
  }

  void open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)).then((_) => load());

  List<PopupMenuEntry<VoidCallback>> menu(Map t) {
    final fav = t['favorite'] == true, hidden = t['hidden'] == true;
    return [
      item(Icons.check_circle_outline, 'Apply', () => apply(t)),
      item(Icons.wallpaper_outlined, 'Wallpapers', () => open(WallpapersPage(slug: t['slug']))),
      const PopupMenuDivider(),
      item(fav ? Icons.star : Icons.star_border, fav ? 'Remove from favorites' : 'Add to favorites', () => setFavorite(t, !fav)),
      item(Icons.wb_sunny_outlined, 'Use as day theme', () => dayNight(t, 'day')),
      item(Icons.nightlight_outlined, 'Use as night theme', () => dayNight(t, 'night')),
      item(Icons.space_dashboard_outlined, 'Use on workspace…', () => onWorkspaces(t)),
      if (t['current'] == true) item(Icons.select_all, 'Use on all workspaces', () => useEverywhere(t)),
      item(Icons.keyboard_outlined, 'Shortcut…', () => open(ShortcutPage(target: 'apply:${t['slug']}', title: t['name']))),
      const PopupMenuDivider(),
      item(Icons.palette_outlined, 'New theme from this…', () => open(EditorPage(base: t['slug']))),
      if (t['custom'] == true) item(Icons.edit_outlined, 'Edit theme…', () => open(EditorPage(edit: t['slug']))),
      item(hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, hidden ? 'Unhide' : 'Hide', () => setHidden(t, !hidden)),
      if (t['deletable'] == true && t['current'] != true) item(Icons.delete_outline, 'Delete…', () => delete(t)),
    ];
  }

  KeyEventResult onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      if (filter.isNotEmpty) {
        setState(() => filter = '');
      } else {
        AppWindow.instance.hide();
      }
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace && filter.isNotEmpty) {
      setState(() => filter = filter.substring(0, filter.length - 1));
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed && e.logicalKey == LogicalKeyboardKey.keyI) {
      open(const ImportPage());
      return KeyEventResult.handled;
    }
    final ch = e.character;
    if (ch != null && ch.length == 1 && RegExp(r'[\w .+-]').hasMatch(ch) &&
        !HardwareKeyboard.instance.isControlPressed && !HardwareKeyboard.instance.isAltPressed &&
        !(ch == ' ' && filter.isEmpty)) {
      setState(() => filter += ch);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget headerButton(String id) {
    final askOn = app.settings['ask_ai'] == true;
    return switch (id) {
      'ask' => IconButton(
        tooltip: 'Ask AI',
        icon: Icon(Icons.auto_awesome, color: askOn ? Theme.of(context).colorScheme.primary : null),
        onPressed: () => open(const AskPage()),
      ),
      'import' => IconButton(tooltip: 'Import themes (Ctrl+I)', icon: const Icon(Icons.download_outlined), onPressed: () => open(const ImportPage())),
      'hidden' => IconButton(
        tooltip: showHidden ? 'Hide hidden themes' : 'Show hidden themes',
        icon: Icon(showHidden ? Icons.visibility : Icons.visibility_off_outlined),
        onPressed: () async {
          await app.run('settings.set', {'key': 'show_hidden', 'value': !showHidden});
          app.changed();
        },
      ),
      'presets' => IconButton(tooltip: 'Presets', icon: const Icon(Icons.bookmarks_outlined), onPressed: () => open(const PresetsPage())),
      'info' => IconButton(tooltip: 'Information', icon: const Icon(Icons.info_outline), onPressed: () => open(const InfoPage())),
      _ => const SizedBox.shrink(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final order = [for (final s in (app.settings['header_order'] as List?) ?? const ['ask', 'import', 'hidden', 'presets', 'info']) '$s'];
    final list = shown;
    return Focus(
      focusNode: focus,
      autofocus: true,
      onKeyEvent: onKey,
      child: Scaffold(
        appBar: AppBar(
          title: Text(filter.isEmpty ? 'Maprisma Theme' : 'Maprisma Theme · “$filter”'),
          actions: [
            for (final id in order) headerButton(id),
            IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => open(const SettingsPage())),
            const SizedBox(width: 6),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : list.isEmpty
            ? Center(child: Text(filter.isEmpty ? 'No themes found.' : 'No theme matches “$filter”.'))
            : LayoutBuilder(
                builder: (context, box) {
                  final columns = (box.maxWidth / 300).floor().clamp(2, 4);
                  return GridView.builder(
                    padding: const EdgeInsets.all(14),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.25,
                    ),
                    itemCount: list.length,
                    itemBuilder: (context, i) => ThemeTile(
                      theme: list[i],
                      shortcuts: shortcutLabels['apply:${list[i]['slug']}'] ?? const [],
                      onOpen: () => open(WallpapersPage(slug: list[i]['slug'])),
                      onApply: () => apply(list[i]),
                      menu: () => menu(list[i]),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// One theme: its preview (or its colors), name, badges and ⋮ menu.
class ThemeTile extends StatelessWidget {
  const ThemeTile({super.key, required this.theme, required this.onOpen, required this.onApply, required this.menu, this.shortcuts = const []});
  final Map<String, dynamic> theme;
  final VoidCallback onOpen, onApply;
  final List<PopupMenuEntry<VoidCallback>> Function() menu;
  final List<String> shortcuts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = (theme['colors'] as Map?) ?? const {};
    final preview = theme['preview'] as String?;
    final hidden = theme['hidden'] == true;
    return Opacity(
      opacity: hidden ? .5 : 1,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: theme['current'] == true
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(corners(context)),
                side: BorderSide(color: scheme.primary, width: 2),
              )
            : null,
        child: InkWell(
          onTap: onOpen,
          onDoubleTap: onApply,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: preview != null
                    ? Image.file(File(preview), fit: BoxFit.cover, cacheWidth: 600,
                        errorBuilder: (_, _, _) => ColorPreview(colors: colors))
                    : ColorPreview(colors: colors),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
                child: Row(
                  children: [
                    if (theme['favorite'] == true) Icon(Icons.star, size: 16, color: scheme.primary),
                    if (theme['favorite'] == true) const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(theme['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          Wrap(spacing: 4, runSpacing: 2, children: [
                            if (theme['current'] == true) Tag(label: 'current', color: scheme.primary),
                            if (theme['scope'] == 'system') const Tag(label: 'built-in'),
                            if (theme['cosmic'] == true) const Tag(label: 'COSMIC'),
                            if (theme['git'] == true) const Tag(label: 'git'),
                            if (hidden) const Tag(label: 'hidden'),
                            for (final s in shortcuts) Tag(label: s),
                          ]),
                        ],
                      ),
                    ),
                    PopupMenuButton<VoidCallback>(
                      tooltip: 'Menu',
                      icon: const Icon(Icons.more_vert),
                      itemBuilder: (_) => menu(),
                      onSelected: (f) => f(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
