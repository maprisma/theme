import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';
import '../window.dart';
import 'editor_page.dart';
import 'shortcut_page.dart';
import 'wallpapers_page.dart';

/// The theme list, as the plugin's main view: every theme as a tile in two
/// to four columns (preview, badges current/system/hidden and its
/// workspaces, ★ and name, its key under the name, the ☰ menu), favorites
/// first, the hidden-themes note at the bottom. A click or Enter applies;
/// ↑/↓, Page Up/Down, Home/End and ←/→ move, → on the last card of a line
/// (or the Menu key) opens the menu, typing filters (the title shows it),
/// Esc clears the filter or closes the window, Ctrl+I imports.
class ThemesPage extends StatefulWidget {
  const ThemesPage({super.key});
  @override
  State<ThemesPage> createState() => _ThemesPageState();
}

class _ThemesPageState extends State<ThemesPage> {
  List<Map<String, dynamic>> themes = [];
  Map<String, List<String>> shortcutLabels = {};
  Map<int, String> workspaceThemes = {};
  Map<String, dynamic> plan = {};
  bool showHidden = false, loading = true;
  String filter = '';
  String? selected;
  int columns = 2;
  final focus = FocusNode();
  final scroll = ScrollController();
  final _tileKeys = <String, GlobalKey>{};
  final _menuKeys = <String, GlobalKey<PopupMenuButtonState<VoidCallback>>>{};
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
    scroll.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _quiet(String method) async {
    try {
      return await app.call(method);
    } catch (_) {
      return null;
    }
  }

  Future<void> load() async {
    final r = await app.run('themes.list');
    final labels = app.can('shortcuts') ? await _quiet('shortcuts.labels') : null;
    final ws = app.can('workspaces') ? await _quiet('auto.workspace_themes') : null;
    final schedule = await _quiet('auto.schedule');
    if (!mounted || r == null) return;
    setState(() {
      themes = [for (final t in r['themes'] as List) Map<String, dynamic>.from(t as Map)];
      showHidden = r['show_hidden'] == true;
      loading = false;
      shortcutLabels = {
        for (final e in ((labels?['labels'] as Map?) ?? const {}).entries)
          '${e.key}': [for (final l in e.value as List) '$l'],
      };
      workspaceThemes = {
        for (final e in ((ws?['themes'] as Map?) ?? const {}).entries)
          if (int.tryParse('${e.key}') != null && e.value is String) int.parse('${e.key}'): e.value as String,
      };
      plan = Map<String, dynamic>.from((schedule?['schedule'] as Map?) ?? const {});
      final list = shown;
      if (selected == null || !list.any((t) => t['slug'] == selected)) {
        selected = list.isEmpty ? null : list.first['slug'] as String;
      }
    });
  }

  /// The active theme is always listed (marked when hidden), as in the plugin.
  bool _listed(Map t) => showHidden || t['hidden'] != true || t['current'] == true;

  List<Map<String, dynamic>> get shown {
    final q = filter.trim().toLowerCase();
    return [
      for (final t in themes)
        if (_listed(t) &&
            (q.isEmpty || '${t['name']}'.toLowerCase().contains(q) || '${t['slug']}'.toLowerCase().contains(q)))
          t,
    ];
  }

  int get hiddenOut => themes.where((t) => !_listed(t)).length;

  String nameOf(String slug) => '${themes.firstWhere((t) => t['slug'] == slug, orElse: () => {'name': slug})['name']}';

  void setFilter(String value) {
    setState(() {
      filter = value;
      final list = shown;
      selected = list.isEmpty ? null : list.first['slug'] as String;
    });
    app.listFilter.value = value;
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  // --- actions -------------------------------------------------------------------

  Future<void> apply(Map t) async {
    // Applying a hidden theme means it is wanted again: unhide it first.
    if (t['hidden'] == true) await app.run('themes.hide', {'slug': t['slug'], 'hidden': false});
    app.notify('Applying ${t['name']}…', duration: const Duration(seconds: 20));
    final r = await app.run('themes.apply', {'slug': t['slug']});
    if (r == null) return;
    app.notify('Theme applied: ${t['name']}');
    app.changed();
  }

  Future<void> setFavorite(Map t, bool on) async {
    await app.run('themes.favorite', {'slug': t['slug'], 'favorite': on});
    app.changed();
  }

  Future<void> setHidden(Map t, bool on) async {
    if (on && t['current'] == true) return; // the theme in use is never hidden
    await app.run('themes.hide', {'slug': t['slug'], 'hidden': on});
    app.changed();
  }

  /// The theme listed after [slug] (or before it, at the end).
  String? neighbor(String slug) {
    final list = shown;
    final i = list.indexWhere((t) => t['slug'] == slug);
    if (i < 0) return null;
    if (i + 1 < list.length) return list[i + 1]['slug'] as String;
    return i > 0 ? list[i - 1]['slug'] as String : null;
  }

  Future<void> delete(Map t) async {
    final ok = await confirm(
      context,
      'Delete theme “${t['name']}”?',
      'Wallpapers you added to it are kept.\nThe theme goes to the trash: Undo brings it back.',
      action: 'Delete theme',
    );
    if (!ok) return;
    final next = neighbor(t['slug'] as String);
    final r = await app.run('themes.delete', {'slug': t['slug']});
    if (r == null) return;
    selected = next;
    app.changed();
    app.notify('“${t['name']}” moved to the trash', undo: r['receipt'] == null ? null : () async {
      await app.run('themes.undo_delete', {'receipt': r['receipt']});
      app.changed();
    });
    // Once Undo is gone, the theme's favorites, key and assignments go too.
    Future.delayed(const Duration(seconds: 10), () async {
      try {
        await app.call('themes.forget', {'slug': t['slug']});
      } catch (_) {}
    });
  }

  Future<void> dayNight(Map t, String which) async {
    final r = await app.run('auto.schedule_set', {which: t['slug']});
    if (r == null) return;
    final p = (r['schedule'] as Map?) ?? plan;
    app.notify('${t['name']} is the $which theme. '
        '${p['enabled'] == true ? 'From ${p['${which}_at']}.' : 'Switch on “Switch themes by time of day” in Settings (⚙).'}');
    app.changed();
  }

  Future<void> onWorkspaces(Map t) async {
    final slug = t['slug'] as String;
    final anchor = rectOf(_menuKeys[slug] ?? GlobalKey());
    if (anchor == null) return;
    final mine = {for (final e in workspaceThemes.entries) if (e.value == slug) e.key};
    final others = {for (final e in workspaceThemes.entries) if (e.value != slug) e.key: nameOf(e.value)};
    final ws = await showWorkspaceMenu(context, anchor: anchor, title: 'Use theme on workspace', mine: mine, others: others);
    if (ws == null || ws == 0 || !mounted) return;
    final on = !mine.contains(ws);
    final wanted = on ? {...mine, ws} : ({...mine}..remove(ws));
    final r = await app.run('auto.set_workspace_themes', {'slug': slug, 'workspaces': wanted.toList()..sort()},
        'Could not assign workspace');
    if (r == null) return;
    app.notify(on ? 'Workspace $ws assigned: ${t['name']}' : 'Workspace $ws cleared');
    app.changed();
  }

  Future<void> useEverywhere(Map t) async {
    final r = await app.run('auto.use_everywhere', const {}, 'Could not change the workspaces');
    if (r == null) return;
    app.changed();
    app.notify('Every workspace uses ${t['name']}', undo: r['saved'] == null ? null : () async {
      final u = await app.run('auto.undo_use_everywhere', {'saved': r['saved']}, 'Could not undo');
      if (u != null && u['restored'] == false) app.notify("Could not undo: the workspaces' themes changed meanwhile.");
      app.changed();
    });
  }

  void open(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)).then((_) {
        if (mounted) focus.requestFocus();
        load();
      });

  /// The plugin's theme menu, in its order.
  List<PopupMenuEntry<VoidCallback>> menu(Map t) {
    final slug = t['slug'] as String;
    final fav = t['favorite'] == true, hidden = t['hidden'] == true, current = t['current'] == true;
    final key = (shortcutLabels['apply:$slug'] ?? const []).firstOrNull;
    var shortcut = key == null ? 'Shortcut…' : 'Shortcut: $key…';
    if (key != null && hidden) shortcut = 'Shortcut: $key (works while hidden)…';
    final isDay = plan['day'] == slug, isNight = plan['night'] == slug;
    return [
      if (current)
        item(Icons.check, 'Current theme', () {}, enabled: false)
      else
        item(Icons.play_arrow, 'Apply theme', () => apply(t)),
      item(Icons.image_outlined, 'Wallpapers', () => open(WallpapersPage(slug: slug)), end: Icons.chevron_right),
      if (app.can('workspaces')) item(Icons.grid_view, 'Use on workspace…', () => onWorkspaces(t),
          tooltip: 'Switches the theme when that workspace gains focus'),
      if (app.can('workspaces') && current && workspaceThemes.isNotEmpty)
        item(Icons.apps, 'Use on all workspaces', () => useEverywhere(t),
            tooltip: "Removes the other workspaces' own themes: this one everywhere (until the next day/night switch)"),
      item(Icons.add, 'New theme from this…', () => open(EditorPage(base: slug)),
          tooltip: 'Your own copy with other colors, a font and these wallpapers'),
      if (t['custom'] == true)
        item(Icons.edit_outlined, 'Edit theme…', () => open(EditorPage(edit: slug)), tooltip: 'Name, colors and font'),
      if (app.can('shortcuts')) item(Icons.keyboard_outlined, shortcut, () => open(ShortcutPage(target: 'apply:$slug', title: '${t['name']}')),
          tooltip: 'A key that applies this theme from anywhere'
              '${hidden ? '. It also works while the theme is hidden, and applying it unhides it.' : ''}'),
      if (fav)
        item(Icons.star, 'Remove from favorites', () => setFavorite(t, false))
      else
        item(Icons.star_border, 'Add to favorites', () => setFavorite(t, true),
            tooltip: "Listed first, and in the panel icon's right-click menu"),
      if (isDay)
        item(Icons.check, 'This is the day theme', () {}, enabled: false)
      else if (isNight)
        item(Icons.check, 'This is the night theme', () {}, enabled: false)
      else ...[
        item(Icons.wb_sunny_outlined, 'Use as day theme', () => dayNight(t, 'day'),
            tooltip: 'Applied at the day time set in Settings (⚙)'),
        item(Icons.nightlight_outlined, 'Use as night theme', () => dayNight(t, 'night'),
            tooltip: 'Applied at the night time set in Settings (⚙)'),
      ],
      menuLine(),
      if (hidden)
        item(Icons.visibility_outlined, 'Unhide from list', () => setHidden(t, false))
      else
        item(Icons.visibility_off_outlined, 'Hide from list', () => setHidden(t, true),
            enabled: !current, tooltip: current ? 'This is the active theme: apply another theme first' : null),
      menuLine(),
      if (t['deletable'] == true && current)
        item(Icons.delete_outline, 'Delete theme…', () {},
            enabled: false, tooltip: 'This is the active theme: apply another theme first')
      else if (t['deletable'] == true)
        item(Icons.delete_outline, 'Delete theme…', () => delete(t), destructive: true)
      else
        item(Icons.lock_outline, 'System theme (read-only)', () {},
            enabled: false, tooltip: 'System themes cannot be deleted; hide them instead'),
    ];
  }

  // --- keyboard ------------------------------------------------------------------

  void select(String? slug, {bool reveal = true, bool down = true}) {
    if (slug == null) return;
    setState(() => selected = slug);
    if (!reveal) return;
    void show() {
      final ctx = _tileKeys[slug]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: const Duration(milliseconds: 100),
            alignmentPolicy:
                down ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd : ScrollPositionAlignmentPolicy.keepVisibleAtStart);
        return;
      }
      // Not built yet (far away): jump near its row first.
      final list = shown;
      final i = list.indexWhere((t) => t['slug'] == slug);
      final some = _tileKeys.values.map((k) => k.currentContext?.findRenderObject()).whereType<RenderBox>().firstOrNull;
      if (i < 0 || some == null || !scroll.hasClients) return;
      final row = some.size.height + 8;
      scroll.jumpTo(math.min(scroll.position.maxScrollExtent, (i ~/ columns) * row));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _tileKeys[slug]?.currentContext;
        if (c != null) Scrollable.ensureVisible(c);
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => show());
  }

  void openMenu(String slug) => _menuKeys[slug]?.currentState?.showButtonMenu();

  KeyEventResult onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    if (key == LogicalKeyboardKey.escape) {
      if (filter.isNotEmpty) {
        setFilter('');
      } else {
        AppWindow.instance.hide();
      }
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyI) {
      app.openPage('import');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace && filter.isNotEmpty) {
      setFilter(filter.substring(0, filter.length - 1));
      return KeyEventResult.handled;
    }
    final list = shown;
    final i = list.indexWhere((t) => t['slug'] == selected);
    String? at(int j) => list.isEmpty ? null : list[j.clamp(0, list.length - 1)]['slug'] as String;
    final column = i < 0 ? 0 : i % columns;
    switch (key) {
      case LogicalKeyboardKey.arrowLeft:
        if (i > 0 && column > 0) select(at(i - 1), down: false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (i >= 0 && column < columns - 1 && i + 1 < list.length) {
          select(at(i + 1));
        } else if (selected != null) {
          openMenu(selected!);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.contextMenu:
        if (selected != null) openMenu(selected!);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        if (i >= 0) open(WallpapersPage(slug: list[i]['slug'] as String)); // Enter opens its wallpapers
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (i + columns < list.length) select(at(i + columns));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (i - columns >= 0) select(at(i - columns), down: false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageDown:
        select(at(i < 0 ? 0 : i + 4 * columns));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageUp:
        select(at(i - 4 * columns), down: false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        select(at(0), down: false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        select(at(list.length - 1));
        return KeyEventResult.handled;
    }
    final ch = e.character;
    if (!ctrl && !alt && ch != null && ch.length == 1 && ch.codeUnitAt(0) >= 32 && ch.codeUnitAt(0) != 127 &&
        (ch != ' ' || filter.isNotEmpty)) {
      setFilter(filter + ch);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- view ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    AppScope.of(context);
    final look = Look.of(context);
    final list = shown;
    final hiddenCount = hiddenOut;
    final footer = Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      child: Text(
        list.isEmpty
            ? (filter.isEmpty ? 'No themes.' : 'No theme matches “$filter”. Backspace or Esc clears the filter.')
            : '$hiddenCount hidden theme${hiddenCount == 1 ? '' : 's'} not shown. The eye button in the header shows them.',
        style: hintStyle(context),
      ),
    );
    final showFooter = list.isEmpty || (hiddenCount > 0 && filter.isEmpty);
    return Focus(
      focusNode: focus,
      autofocus: true,
      onKeyEvent: onKey,
      child: Scaffold(
        backgroundColor: look.bg,
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(builder: (context, box) {
                columns = gridColumns(box.maxWidth);
                return TileGrid(
                  controller: scroll,
                  count: list.length,
                  columns: columns,
                  spacing: 6,
                  footer: showFooter ? footer : null,
                  builder: (context, i) {
                    final t = list[i];
                    final slug = t['slug'] as String;
                    return KeyedSubtree(
                      key: _tileKeys.putIfAbsent(slug, () => GlobalKey()),
                      child: ThemeTile(
                        theme: t,
                        selected: slug == selected,
                        shortcuts: app.can('shortcuts') ? shortcutLabels['apply:$slug'] ?? const [] : const [],
                        workspaces: [if (app.can('workspaces')) for (final e in workspaceThemes.entries) if (e.value == slug) e.key]..sort(),
                        menuKey: _menuKeys.putIfAbsent(slug, () => GlobalKey()),
                        onApply: () {
                          focus.requestFocus();
                          select(slug, reveal: false);
                          // As the plugin (child-activated): a click opens the theme's wallpapers.
                          open(WallpapersPage(slug: slug));
                        },
                        onHover: () {
                          if (selected != slug) select(slug, reveal: false);
                        },
                        menu: () => menu(t),
                      ),
                    );
                  },
                );
              }),
      ),
    );
  }
}

/// One theme, as the plugin's tile: the preview in a faint mat with the ☰
/// button and the badges (current, system, hidden, its workspaces) over it,
/// ★ and the name under it, its key below. The selection (keyboard or
/// pointer) lies around it in the selection colour.
class ThemeTile extends StatefulWidget {
  const ThemeTile({
    super.key,
    required this.theme,
    required this.onApply,
    required this.menu,
    this.menuKey,
    this.onHover,
    this.selected = false,
    this.shortcuts = const [],
    this.workspaces = const [],
  });
  final Map<String, dynamic> theme;
  final VoidCallback onApply;
  final VoidCallback? onHover;
  final List<PopupMenuEntry<VoidCallback>> Function() menu;
  final GlobalKey<PopupMenuButtonState<VoidCallback>>? menuKey;
  final bool selected;
  final List<String> shortcuts;
  final List<int> workspaces;

  @override
  State<ThemeTile> createState() => _ThemeTileState();
}

class _ThemeTileState extends State<ThemeTile> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    AppScope.of(context);
    final look = Look.of(context);
    final r = corners(context);
    final t = widget.theme;
    final colors = (t['colors'] as Map?) ?? const {};
    final preview = t['preview'] as String?;
    final hidden = t['hidden'] == true;
    final text = widget.selected ? look.selectionFg : look.fg;
    final key = widget.shortcuts.firstOrNull;
    final picture = preview != null
        ? Image.file(File(preview),
            fit: BoxFit.cover, cacheWidth: 640, errorBuilder: (_, _, _) => ColorPreview(colors: colors))
        : ColorPreview(colors: colors);
    final tile = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: look.fg.withValues(alpha: .08),
        border: Border.all(color: hover ? look.accent : look.fg.withValues(alpha: .22)),
        borderRadius: BorderRadius.circular(r),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(r == 0 ? 0 : math.max(2, r - 4)),
            child: Stack(fit: StackFit.expand, children: [
              picture,
              Positioned(
                left: 6,
                right: 40,
                bottom: 6,
                child: Wrap(spacing: 4, runSpacing: 4, children: [
                  if (t['current'] == true) const TileBadge('current', kind: BadgeKind.current),
                  if (t['scope'] == 'system') const TileBadge('system'),
                  if (hidden) const TileBadge('hidden'),
                  if (widget.workspaces.isNotEmpty)
                    TileBadge('ws ${widget.workspaces.join(' · ')}',
                        tooltip: 'Used on workspace ${widget.workspaces.join(', ')}'),
                ]),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: TileMenuButton(menuKey: widget.menuKey, tooltip: 'Theme actions (Menu key)', menu: widget.menu),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(children: [
            if (t['favorite'] == true) ...[
              Icon(Icons.star, size: 15, color: look.accent),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Tooltip(
                message: key == null ? '' : '$key applies this theme',
                child: Text('${t['name']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: text)),
              ),
            ),
          ]),
        ),
        if (key != null)
          Text(key.replaceAll(' + ', '+'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, fontFamily: 'monospace', color: widget.selected ? look.selectionFg : look.muted)),
        const SizedBox(height: 2),
      ]),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      onHover: (_) => widget.onHover?.call(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onApply,
        onSecondaryTap: () => widget.menuKey?.currentState?.showButtonMenu(),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: widget.selected
                ? look.selection
                : hover
                ? look.fg.withValues(alpha: .06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(r),
          ),
          child: Opacity(opacity: hidden ? .45 : 1, child: tile),
        ),
      ),
    );
  }
}
