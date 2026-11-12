import '../i18n.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../flip_picture.dart';
import '../theme.dart';
import '../widgets.dart';
import '../window.dart';
import 'editor_page.dart';
import 'look_dialog.dart';
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
  String? currentWallpaper;
  /// The theme shown in the big preview (click / Enter on a card), or null.
  String? bigSlug;
  final _bigFlip = GlobalKey<FlipPictureState>();
  final _bigClose = FocusNode(debugLabel: 'big preview close');
  // One pin at a time; a click while one runs waits, and only the latest waiting one runs.
  bool _pinBusy = false;
  ({Map t, String wp, Completer<bool> done})? _pinNext;
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
    _pinNext?.done.complete(false);
    _pinNext = null;
    _bigClose.dispose();
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

  /// Reads the list again; false when it could not be read (or the page is gone).
  Future<bool> load() async {
    final r = await app.run('themes.list');
    final labels = app.can('shortcuts') ? await _quiet('shortcuts.labels') : null;
    final ws = app.can('workspaces') ? await _quiet('auto.workspace_themes') : null;
    final schedule = await _quiet('auto.schedule');
    if (!mounted || r == null) return false;
    setState(() {
      themes = [for (final t in r['themes'] as List) Map<String, dynamic>.from(t as Map)];
      currentWallpaper = r['current_wallpaper'] as String?;
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
    return true;
  }

  /// The active theme is always listed (marked when hidden), as in the plugin.
  bool _listed(Map t) => showHidden || t['hidden'] != true || t['current'] == true;

  /// The listed themes, the one in use first; the rest keep their order.
  List<Map<String, dynamic>> get shown {
    final q = filter.trim().toLowerCase();
    final list = [
      for (final t in themes)
        if (_listed(t) &&
            (q.isEmpty || '${t['name']}'.toLowerCase().contains(q) || '${t['slug']}'.toLowerCase().contains(q)))
          t,
    ];
    final i = list.indexWhere((t) => t['current'] == true);
    if (i > 0) list.insert(0, list.removeAt(i));
    return list;
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
    app.notify(trf("Applying {0}…", [t['name']]), duration: const Duration(seconds: 20));
    final r = await app.run('themes.apply', {'slug': t['slug']});
    if (r == null) return;
    app.notify(trf("Theme applied: {0}", [t['name']]));
    app.changed();
  }

  Future<bool> pinWallpaper(Map t, String wpPath) {
    if (_pinBusy) {
      _pinNext?.done.complete(false); // superseded by this click
      final done = Completer<bool>();
      _pinNext = (t: t, wp: wpPath, done: done);
      return done.future;
    }
    _pinBusy = true;
    return _drainPins(t, wpPath);
  }

  /// Runs [t]'s pin, then every pin that waited meanwhile (only the latest each time), one after
  /// the other with nothing in between: a waiting pin acts on a freshly read list (the pin before it
  /// may have applied another theme) and is dropped when the list cannot be read or the page is gone.
  Future<bool> _drainPins(Map t, String wpPath) async {
    bool first;
    try {
      first = await _pin(t, wpPath);
    } catch (_) {
      first = false;
    }
    while (_pinNext != null) {
      final next = _pinNext!;
      _pinNext = null;
      var ok = false;
      if (mounted && await load() && mounted) {
        final fresh = themes.where((x) => x['slug'] == next.t['slug']).firstOrNull;
        if (fresh != null) {
          try {
            ok = await _pin(fresh, next.wp);
          } catch (_) {
            ok = false;
          }
        }
      }
      next.done.complete(ok);
    }
    _pinBusy = false;
    return first;
  }

  Future<bool> _pin(Map t, String wpPath) async {
    final slug = t['slug'] as String;
    if (t['current'] == true) {
      final r = await app.run('wallpapers.set', {'slug': slug, 'path': wpPath}, tr("Could not set background"));
      if (r == null) return false;
      if (mounted) setState(() => currentWallpaper = wpPath);
      return true;
    }
    if (app.settings['preview_pin_apply_theme'] == false) {
      final r = await app.run('wallpapers.set', {'slug': slug, 'path': wpPath}, tr("Could not set background"));
      if (r == null) return false;
      app.changed(); // its remembered wallpaper (chosen_wallpaper) is read again
      return true;
    }
    if (t['hidden'] == true) await app.run('themes.hide', {'slug': slug, 'hidden': false});
    app.notify(trf("Applying {0}…", [t['name']]), duration: const Duration(seconds: 20));
    final r = await app.run('themes.apply', {'slug': slug, 'wallpaper': wpPath});
    if (r == null) return false;
    if (r['wallpaper_set'] == false) {
      // The theme is in use, its picture is not: say so instead of only "applied".
      app.notify('${trf("Theme applied: {0}", [t['name']])} · ${tr("Could not set background")}');
      app.changed();
      return false;
    }
    app.notify(trf("Theme applied: {0}", [t['name']]));
    app.changed();
    return true;
  }

  /// The theme in use gets its stored fonts and blur now.
  Future<void> reapply(Map t) async {
    final r = await app.run('looks.apply', {'slug': t['slug']});
    if (r == null) return;
    app.notify(trf("Reapplied: {0}", [t['name']]));
    app.changed();
  }

  static String _lookField(Object? key) => switch (key) {
    'mono_font' => tr("monospace font"),
    'ui_font' => tr("interface font"),
    'blur' => tr('Blur'),
    _ => '$key',
  };

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
      trf("Delete theme “{0}”?", [t['name']]),
      tr("Wallpapers you added to it are kept.\nThe theme goes to the trash: Undo brings it back."),
      action: tr("Delete theme"),
    );
    if (!ok) return;
    final next = neighbor(t['slug'] as String);
    final r = await app.run('themes.delete', {'slug': t['slug']});
    if (r == null) return;
    selected = next;
    app.changed();
    app.notify(trf("“{0}” moved to the trash", [t['name']]), undo: r['receipt'] == null ? null : () async {
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
    final message = which == 'day'
        ? trf('{0} is the day theme', [t['name']])
        : trf('{0} is the night theme', [t['name']]);
    final timing = p['enabled'] == true ? trf('From {0}.', [p['${which}_at']]) : tr('Switch on “Switch themes by time of day” in Settings (⚙).');
    app.notify('$message. $timing');
    app.changed();
  }

  Future<void> onWorkspaces(Map t) async {
    final slug = t['slug'] as String;
    final anchor = rectOf(_menuKeys[slug] ?? GlobalKey());
    if (anchor == null) return;
    final mine = {for (final e in workspaceThemes.entries) if (e.value == slug) e.key};
    final others = {for (final e in workspaceThemes.entries) if (e.value != slug) e.key: nameOf(e.value)};
    final ws = await showWorkspaceMenu(context, anchor: anchor, title: tr("Use theme on workspace"), mine: mine, others: others);
    if (ws == null || ws == 0 || !mounted) return;
    final on = !mine.contains(ws);
    final wanted = on ? {...mine, ws} : ({...mine}..remove(ws));
    final r = await app.run('auto.set_workspace_themes', {'slug': slug, 'workspaces': wanted.toList()..sort()},
        tr("Could not assign workspace"));
    if (r == null) return;
    app.notify(on ? trf("Workspace {0} assigned: {1}", [ws, t['name']]) : trf("Workspace {0} cleared", [ws]));
    app.changed();
  }

  Future<void> useEverywhere(Map t) async {
    final r = await app.run('auto.use_everywhere', const {}, tr("Could not change the workspaces"));
    if (r == null) return;
    app.changed();
    app.notify(trf("Every workspace uses {0}", [t['name']]), undo: r['saved'] == null ? null : () async {
      final u = await app.run('auto.undo_use_everywhere', {'saved': r['saved']}, tr("Could not undo"));
      if (u != null && u['restored'] == false) app.notify(tr("Could not undo: the workspaces' themes changed meanwhile."));
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
    var shortcut = key == null ? tr("Shortcut…") : trf("Shortcut: {0}…", [key]);
    if (key != null && hidden) shortcut = trf("Shortcut: {0} (works while hidden)…", [key]);
    final isDay = plan['day'] == slug, isNight = plan['night'] == slug;
    return [
      if (current) ...[
        item(Icons.check, tr("Current theme"), () {}, enabled: false),
        // only while its fonts or blur aren't on the desktop (saved in Font & effects, or changed elsewhere)
        if ((t['pending'] as List?)?.isNotEmpty == true)
          item(Icons.refresh, tr("Reapply"), () => reapply(t),
              tooltip: trf("Not on the desktop yet: {0}", [(t['pending'] as List).map(_lookField).join(', ')])),
      ] else
        item(Icons.play_arrow, tr("Apply theme"), () => apply(t)),
      item(Icons.image_outlined, tr("Wallpapers"), () => open(WallpapersPage(slug: slug)), end: Icons.chevron_right),
      if (app.can('workspaces')) item(Icons.grid_view, tr("Use on workspace…"), () => onWorkspaces(t),
          tooltip: tr("Switches the theme when that workspace gains focus")),
      if (app.can('workspaces') && current && workspaceThemes.isNotEmpty)
        item(Icons.apps, tr("Use on all workspaces"), () => useEverywhere(t),
            tooltip: tr("Removes the other workspaces' own themes: this one everywhere (until the next day/night switch)")),
      item(Icons.add, tr("New theme from this…"), () => open(EditorPage(base: slug)),
          tooltip: tr("Your own copy with other colors, a font and these wallpapers")),
      if (t['custom'] == true)
        item(Icons.edit_outlined, tr("Edit theme…"), () => open(EditorPage(edit: slug)), tooltip: tr("Name, colors and font")),
      if (app.can('fonts') || app.can('uiFont') || app.can('blur'))
        item(Icons.text_format, tr("Font & effects…"), () async {
          await lookDialog(context, app, slug);
          if (mounted) focus.requestFocus();
        }, tooltip: tr("Fonts and blur for this theme; the theme files stay as they are")),
      if (app.can('shortcuts')) item(Icons.keyboard_outlined, shortcut, () => open(ShortcutPage(target: 'apply:$slug', title: '${t['name']}')),
          tooltip: trf("A key that applies this theme from anywhere{0}", [hidden ? tr(". It also works while the theme is hidden, and applying it unhides it.") : ''])),
      if (fav)
        item(Icons.star, tr("Remove from favorites"), () => setFavorite(t, false))
      else
        item(Icons.star_border, tr("Add to favorites"), () => setFavorite(t, true),
            tooltip: tr("Listed first, and in the panel icon's right-click menu")),
      if (isDay)
        item(Icons.check, tr("This is the day theme"), () {}, enabled: false)
      else if (isNight)
        item(Icons.check, tr("This is the night theme"), () {}, enabled: false)
      else ...[
        item(Icons.wb_sunny_outlined, tr("Use as day theme"), () => dayNight(t, 'day'),
            tooltip: tr("Applied at the day time set in Settings (⚙)")),
        item(Icons.nightlight_outlined, tr("Use as night theme"), () => dayNight(t, 'night'),
            tooltip: tr("Applied at the night time set in Settings (⚙)")),
      ],
      menuLine(),
      if (hidden)
        item(Icons.visibility_outlined, tr("Unhide from list"), () => setHidden(t, false))
      else
        item(Icons.visibility_off_outlined, tr("Hide from list"), () => setHidden(t, true),
            enabled: !current, tooltip: current ? tr("This is the active theme: apply another theme first") : null),
      menuLine(),
      if (t['deletable'] == true && current)
        item(Icons.delete_outline, tr("Delete theme…"), () {},
            enabled: false, tooltip: tr("This is the active theme: apply another theme first"))
      else if (t['deletable'] == true)
        item(Icons.delete_outline, tr("Delete theme…"), () => delete(t), destructive: true)
      else
        item(Icons.lock_outline, tr("System theme (read-only)"), () {},
            enabled: false, tooltip: tr("System themes cannot be deleted; hide them instead")),
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

  /// Click or Enter on a card: the big preview (Settings › Themes › Big preview on click),
  /// else the theme's wallpapers as before.
  void activateTheme(Map t) {
    if (app.settings['preview_big_card'] != false && t['preview'] != null) {
      openBig(t['slug'] as String);
    } else {
      open(WallpapersPage(slug: t['slug'] as String));
    }
  }

  void openBig(String slug) {
    setState(() => bigSlug = slug);
    // Keyboard focus into the preview (its Close button), never on the list behind it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && bigSlug == slug) _bigClose.requestFocus();
    });
  }

  void closeBig() {
    if (bigSlug == null) return;
    setState(() => bigSlug = null);
    focus.requestFocus();
  }

  KeyEventResult onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    // Super+digit switches desktops: the digit is no filter text.
    final meta = HardwareKeyboard.instance.isMetaPressed;
    if (bigSlug != null) {
      // The big preview has the keys: Esc and Backspace close it, ← → turn it, Tab, Space and
      // Enter go to its focused button; typing does not filter the list behind it.
      switch (key) {
        case LogicalKeyboardKey.escape || LogicalKeyboardKey.backspace:
          closeBig();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowLeft:
          _bigFlip.currentState?.rotateStep(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight:
          _bigFlip.currentState?.rotateStep(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.tab || LogicalKeyboardKey.space || LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
          return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
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
        if (i >= 0) activateTheme(list[i]); // the big preview, or (off) its wallpapers
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
    if (!ctrl && !alt && !meta && ch != null && ch.length == 1 && ch.codeUnitAt(0) >= 32 && ch.codeUnitAt(0) != 127 &&
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
            ? (filter.isEmpty ? tr("No themes.") : trf("No theme matches “{0}”. Backspace or Esc clears the filter.", [filter]))
            : hiddenCount == 1
                ? trf('{0} hidden theme not shown. The eye button in the header shows them.', [hiddenCount])
                : trf('{0} hidden themes not shown. The eye button in the header shows them.', [hiddenCount]),
        style: hintStyle(context),
      ),
    );
    final showFooter = list.isEmpty || (hiddenCount > 0 && filter.isEmpty);
    final routeActive = ModalRoute.of(context)?.isCurrent ?? true;
    final flip3d = app.settings['preview_flip_3d'] != false;
    final flipDelay = (app.settings['preview_flip_delay'] as num?)?.toDouble() ?? 2.0;
    final pinApplyTheme = app.settings['preview_pin_apply_theme'] != false;
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
                final big = bigSlug == null ? null : themes.where((t) => t['slug'] == bigSlug).firstOrNull;
                return Stack(children: [
                  // Behind an open big preview the list takes no focus: Tab stays inside the preview.
                  Positioned.fill(
                    child: ExcludeFocus(
                      excluding: big != null,
                      child: _grid(list, showFooter, footer, routeActive, flip3d, flipDelay, pinApplyTheme),
                    ),
                  ),
                  if (big != null)
                    Positioned.fill(
                      child: FocusTraversalGroup(child: _BigPreview(
                        theme: big,
                        box: box.biggest,
                        flipKey: _bigFlip,
                        closeFocus: _bigClose,
                        delaySeconds: app.settings['preview_big_auto_rotate'] != false ? flipDelay : 0,
                        pinApplyTheme: pinApplyTheme,
                        canPin: app.can('wallpaper'),
                        currentWallpaper: currentWallpaper,
                        onPin: (wp) => pinWallpaper(big, wp),
                        onApply: () => apply(big),
                        onReapply: () => reapply(big),
                        onWallpapers: () {
                          closeBig();
                          open(WallpapersPage(slug: big['slug'] as String));
                        },
                        onClose: closeBig,
                        menu: () => menu(big),
                      )),
                    ),
                ]);
              }),
      ),
    );
  }

  Widget _grid(List<Map<String, dynamic>> list, bool showFooter, Widget footer, bool routeActive, bool flip3d,
      double flipDelay, bool pinApplyTheme) {
    // The cards behind an open big preview stay still (no flip under it).
    final cardsActive = routeActive && bigSlug == null;
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
            flipActive: cardsActive && slug == selected,
            pageVisible: cardsActive,
            flip3d: flip3d,
            flipDelay: flipDelay,
            pinApplyTheme: pinApplyTheme,
            canPin: app.can('wallpaper'),
            currentWallpaper: currentWallpaper,
            onPin: (wp) => pinWallpaper(t, wp),
            shortcuts: app.can('shortcuts') ? shortcutLabels['apply:$slug'] ?? const [] : const [],
            workspaces: [if (app.can('workspaces')) for (final e in workspaceThemes.entries) if (e.value == slug) e.key]..sort(),
            menuKey: _menuKeys.putIfAbsent(slug, () => GlobalKey()),
            onApply: () {
              focus.requestFocus();
              select(slug, reveal: false);
              // As the plugin (child-activated): the big preview, or (off) the wallpapers.
              activateTheme(t);
            },
            onHover: () {
              if (selected != slug) select(slug, reveal: false);
            },
            menu: () => menu(t),
          ),
        );
      },
    );
  }
}

/// The big preview over the dimmed list: the theme's card at about half the window with the 3D
/// flip, ‹ › and the pin, its name, Apply (or Reapply), Wallpapers and Close (focused, Esc).
/// A click on the dimmed area closes it.
class _BigPreview extends StatelessWidget {
  const _BigPreview({
    required this.theme,
    required this.box,
    required this.flipKey,
    required this.closeFocus,
    required this.delaySeconds,
    required this.pinApplyTheme,
    required this.canPin,
    required this.currentWallpaper,
    required this.onPin,
    required this.onApply,
    required this.onReapply,
    required this.onWallpapers,
    required this.onClose,
    required this.menu,
  });

  final Map<String, dynamic> theme;
  final Size box;
  final GlobalKey<FlipPictureState> flipKey;
  final FocusNode closeFocus;
  final double delaySeconds;
  final bool pinApplyTheme, canPin;
  final String? currentWallpaper;
  final Future<bool> Function(String path) onPin;
  final VoidCallback onApply, onReapply, onWallpapers, onClose;
  final List<PopupMenuEntry<VoidCallback>> Function() menu;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final r = corners(context);
    final t = theme;
    final slug = t['slug'] as String;
    final colors = (t['colors'] as Map?) ?? const {};
    final preview = t['preview'] as String?;
    final wallpapers = [
      for (final w in (t['wallpapers'] as List?) ?? const [])
        if (w is String) w,
    ];
    final isCurrent = t['current'] == true;
    final pending = (t['pending'] as List?)?.isNotEmpty == true;
    // About half the window, never past it (room around it so the list stays visible).
    var w = math.min(math.max(box.width * 0.54, 360.0), box.width - 48);
    var h = w * 9 / 16;
    final maxH = math.min(box.height - 48, box.height * 0.68) - 56;
    if (h > maxH) {
      h = math.max(112, maxH);
      w = h * 16 / 9;
    }
    final innerRadius = r == 0 ? 0.0 : math.max(2.0, r - 4.0);
    final badges = Wrap(spacing: 4, runSpacing: 4, children: [
      if (isCurrent) TileBadge(tr("current"), kind: BadgeKind.current),
      if (t['scope'] == 'system') TileBadge(tr("system")),
      if (t['hidden'] == true) TileBadge(tr("hidden")),
    ]);
    final menuButton = TileMenuButton(tooltip: tr("Theme actions (Menu key)"), menu: menu);
    final Widget media = preview != null && wallpapers.isNotEmpty
        ? FlipPicture(
            key: flipKey,
            slug: slug,
            preview: preview,
            wallpapers: wallpapers,
            colors: colors,
            borderRadius: innerRadius,
            active: true,
            themeCurrent: isCurrent,
            pinApplyTheme: pinApplyTheme,
            delaySeconds: delaySeconds, // 0: arrows only, no turn by itself
            canPin: canPin,
            activeWallpaper: pinnedWallpaper(t, wallpapers, isCurrent, currentWallpaper, pinApplyTheme),
            badges: badges,
            menuButton: menuButton,
            onPin: onPin,
          )
        : ClipRRect(
            borderRadius: BorderRadius.circular(innerRadius),
            child: Stack(fit: StackFit.expand, children: [
              preview != null
                  ? Image.file(File(preview),
                      fit: BoxFit.cover, cacheWidth: 1280, errorBuilder: (_, _, _) => ColorPreview(colors: colors))
                  : ColorPreview(colors: colors),
              Positioned(left: 6, right: 40, bottom: 6, child: badges),
              Positioned(top: 0, right: 0, child: menuButton),
            ]),
          );
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onClose,
          child: ColoredBox(color: Colors.black.withValues(alpha: .45)),
        ),
      ),
      Center(
        child: Container(
          width: w + 12,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: look.bg,
            border: isCurrent
                ? Border.all(color: hexColor(colors, 'green') ?? hexColor(colors, 'accent') ?? look.accent, width: 2)
                : Border.all(color: look.fg.withValues(alpha: .22)),
            borderRadius: BorderRadius.circular(r),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(width: w, height: h, child: media),
            const SizedBox(height: 6),
            Row(children: [
              if (t['favorite'] == true) ...[
                Text('★', style: TextStyle(color: look.accent)),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Text('${t['name']}', overflow: TextOverflow.ellipsis, style: TextStyle(color: look.fg)),
              ),
              if (!isCurrent)
                TextButton.icon(onPressed: onApply, icon: const Icon(Icons.play_arrow, size: 16), label: Text(tr("Apply theme")))
              else if (pending)
                TextButton.icon(onPressed: onReapply, icon: const Icon(Icons.refresh, size: 16), label: Text(tr("Reapply"))),
              IconButton(
                tooltip: tr("Wallpapers"),
                onPressed: onWallpapers,
                icon: const Icon(Icons.image_outlined, size: 18),
              ),
              IconButton(
                focusNode: closeFocus,
                tooltip: tr("Close preview (Esc)"),
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 18),
              ),
            ]),
          ]),
        ),
      ),
    ]);
  }
}

/// The wallpaper a card shows pinned: the desktop's for the theme in use; on another theme's card
/// (pinning without applying) only the one really remembered for it (the list puts it first),
/// never a first wallpaper that was never chosen.
String? pinnedWallpaper(Map t, List<String> wallpapers, bool isCurrent, String? currentWallpaper, bool pinApplyTheme) {
  if (wallpapers.isEmpty) return null;
  if (isCurrent) return currentWallpaper ?? wallpapers.first;
  if (pinApplyTheme) return null;
  final chosen = t['chosen_wallpaper'];
  final first = wallpapers.first;
  return chosen is String && first.substring(first.lastIndexOf('/') + 1) == chosen ? first : null;
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
    this.onPin,
    this.selected = false,
    this.flipActive = false,
    this.pageVisible = true,
    this.flip3d = true,
    this.flipDelay = 1.0,
    this.pinApplyTheme = true,
    this.canPin = true,
    this.currentWallpaper,
    this.shortcuts = const [],
    this.workspaces = const [],
  });
  final Map<String, dynamic> theme;
  final VoidCallback onApply;
  final VoidCallback? onHover;
  final Future<bool> Function(String path)? onPin;
  final List<PopupMenuEntry<VoidCallback>> Function() menu;
  final GlobalKey<PopupMenuButtonState<VoidCallback>>? menuKey;
  final bool selected;
  final bool flipActive;
  final bool pageVisible;
  final bool flip3d;
  final double flipDelay;
  final bool pinApplyTheme;
  final bool canPin;
  final String? currentWallpaper;
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
    final slug = t['slug'] as String;
    final colors = (t['colors'] as Map?) ?? const {};
    final preview = t['preview'] as String?;
    final wallpapers = [
      for (final w in (t['wallpapers'] as List?) ?? const [])
        if (w is String) w,
    ];
    final hidden = t['hidden'] == true;
    final isCurrent = t['current'] == true;
    final text = widget.selected ? look.selectionFg : look.fg;
    final key = widget.shortcuts.firstOrNull;
    final innerRadius = r == 0 ? 0.0 : math.max(2.0, r - 4.0);
    final badges = Wrap(spacing: 4, runSpacing: 4, children: [
      if (isCurrent) TileBadge(tr("current"), kind: BadgeKind.current),
      if (t['scope'] == 'system') TileBadge(tr("system")),
      if (hidden) TileBadge(tr("hidden")),
      if (widget.workspaces.isNotEmpty)
        TileBadge(trf("ws {0}", [widget.workspaces.join(' · ')]),
            tooltip: trf("Used on workspace {0}", [widget.workspaces.join(', ')])),
    ]);
    final menuButton = TileMenuButton(menuKey: widget.menuKey, tooltip: tr("Theme actions (Menu key)"), menu: widget.menu);
    final Widget media;
    if (widget.flip3d && preview != null && wallpapers.isNotEmpty) {
      media = FlipPicture(
        key: ValueKey('flip-$slug'),
        slug: slug,
        preview: preview,
        wallpapers: wallpapers,
        colors: colors,
        borderRadius: innerRadius,
        active: widget.flipActive,
        pageVisible: widget.pageVisible,
        themeCurrent: isCurrent,
        pinApplyTheme: widget.pinApplyTheme,
        delaySeconds: widget.flipDelay,
        canPin: widget.canPin,
        activeWallpaper: pinnedWallpaper(t, wallpapers, isCurrent, widget.currentWallpaper, widget.pinApplyTheme),
        badges: badges,
        menuButton: menuButton,
        onPin: widget.onPin,
      );
    } else {
      final picture = preview != null
          ? Image.file(File(preview),
              fit: BoxFit.cover, cacheWidth: 640, errorBuilder: (_, _, _) => ColorPreview(colors: colors))
          : ColorPreview(colors: colors);
      media = ClipRRect(
        borderRadius: BorderRadius.circular(innerRadius),
        child: Stack(fit: StackFit.expand, children: [
          picture,
          Positioned(left: 6, right: 40, bottom: 6, child: badges),
          Positioned(top: 0, right: 0, child: menuButton),
        ]),
      );
    }
    final tile = Container(
      padding: EdgeInsets.all(isCurrent ? 2 : 3), // the wider border keeps the tile's size
      decoration: BoxDecoration(
        color: look.fg.withValues(alpha: .08),
        // The theme in use: its own green (its accent without one), a little wider,
        // also under the pointer; the desktop's palette may carry no green (KDE).
        border: isCurrent
            ? Border.all(color: hexColor(colors, 'green') ?? hexColor(colors, 'accent') ?? look.accent, width: 2)
            : Border.all(color: hover ? look.accent : look.fg.withValues(alpha: .22)),
        borderRadius: BorderRadius.circular(r),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: media,
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
                message: key == null ? '' : trf("{0} applies this theme", [key]),
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
