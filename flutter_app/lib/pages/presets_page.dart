import '../i18n.dart';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';

/// The Presets page as in the plugin (workspaces_page.py, theme_popup.py
/// build_presets_page): three tabs with icons, a note above them, the
/// workspace cards in two groups (All Workspaces in both), the chosen
/// workspace's controls below them in group cards and, in a wide window,
/// that workspace large on the right as it looks. The one difference
/// (docs/ui-parity.md): COSMIC's own layouts only, Tiled, Floating and Native.
class PresetsPage extends StatefulWidget {
  const PresetsPage({super.key});
  @override
  State<PresetsPage> createState() => _PresetsPageState();
}

/// From this width the tabs use two columns (the plugin's WIDE_FROM).
const _wideFrom = 900.0;
const _groups = [(1, 5), (6, 10)];
const _modes = ['tiled', 'floating', 'default'];

String modeLabel(String mode) => switch (mode) {
  'tiled' => tr("Tiled"),
  'floating' => tr("Floating"),
  _ => tr("Native"),
};

/// Who tiles on [desktop]: COSMIC itself, on KDE Plasma the Maprisma Tiling script.
String tilerOf(String desktop) => desktop == 'KDE Plasma' ? 'Maprisma Tiling' : desktop;

String modeHint(String mode, [String desktop = 'COSMIC']) => switch (mode) {
  'tiled' => desktop == 'KDE Plasma'
      ? tr("Maprisma Tiling tiles the windows of this workspace (its layout)")
      : trf("{0} tiles the windows: each new one splits the last along its longer side", [tilerOf(desktop)]),
  'floating' => tr("Tiling off: windows float where they open"),
  _ => trf("Leaves {0}'s own tiling setting of the workspace as it is", [tilerOf(desktop)]),
};

/// The windows of a layout as rectangles in 0…1 of the area below the bar.
/// Tiled: COSMIC's autotile, every new window splits the newest one along
/// its longer side; Floating: cascaded; Native: drawn as tiled (dashed).
List<Rect> layoutRects(String mode, int count, {double aspect = 16 / 9}) {
  final n = count.clamp(0, 8);
  if (n == 0) return const [];
  if (mode == 'floating') {
    if (n == 1) return const [Rect.fromLTWH(0.19, 0.14, 0.62, 0.72)];
    final step = math.min(0.12, 0.34 / (n - 1));
    return [for (var i = 0; i < n; i++) Rect.fromLTWH(0.07 + i * step * 1.2, 0.07 + i * step, 0.56, 0.6)];
  }
  final cells = <Rect>[const Rect.fromLTWH(0, 0, 1, 1)];
  for (var i = 1; i < n; i++) {
    final last = cells.removeLast();
    if (last.width * aspect >= last.height) {
      cells.addAll([
        Rect.fromLTWH(last.left, last.top, last.width / 2, last.height),
        Rect.fromLTWH(last.left + last.width / 2, last.top, last.width / 2, last.height),
      ]);
    } else {
      cells.addAll([
        Rect.fromLTWH(last.left, last.top, last.width, last.height / 2),
        Rect.fromLTWH(last.left, last.top + last.height / 2, last.width, last.height / 2),
      ]);
    }
  }
  const g = 0.035;
  return [
    for (final c in cells)
      Rect.fromLTRB(
        c.left + (c.left <= 0.0001 ? g : g / 2),
        c.top + (c.top <= 0.0001 ? g : g / 2),
        c.right - (c.right >= 0.9999 ? g : g / 2),
        c.bottom - (c.bottom >= 0.9999 ? g : g / 2),
      ),
  ];
}

class _PresetsPageState extends State<PresetsPage> {
  MaprismaThemeAppState? app;
  bool loaded = false, busy = false, chosenOnce = false;
  Map state = {};
  Map looks = {};
  List presets = [];
  List themes = [];
  int? activeWorkspace;
  final wallpapers = <String, List<String>>{};
  int tab = 0; // 0 Workspaces, 1 App Presets, 2 Save/Load Presets
  int group = 0;
  int selected = 1; // 0 = All Workspaces (Workspaces tab only)
  int? zoomed; // the large preview over a narrow window
  int? highlight; // the window chosen by keyboard (←/→) in the preview
  Map? conflict; // a restore waiting for the user's choice
  String message = '';
  bool include = true;
  final name = TextEditingController();
  final previewFocus = FocusNode(debugLabel: tr("workspace preview"));
  final zoomFocus = FocusNode(debugLabel: tr("large preview"));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppScope.of(context);
    if (app != next) {
      app?.revision.removeListener(reload);
      app = next;
      next.revision.addListener(reload);
    }
    if (!loaded) {
      loaded = true;
      reload();
    }
  }

  @override
  void dispose() {
    app?.revision.removeListener(reload);
    name.dispose();
    previewFocus.dispose();
    zoomFocus.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    final a = app!;
    final w = a.can('workspaces') ? await a.run('workspaces.get') : null;
    final l = a.can('workspaces') ? await a.run('workspaces.looks') : null;
    final p = await a.run('presets.list');
    final t = await a.run('themes.list');
    if (!mounted) return;
    setState(() {
      state = w?['state'] as Map? ?? state;
      looks = l?['workspaces'] as Map? ?? looks;
      presets = p?['presets'] as List? ?? presets;
      themes = t?['themes'] as List? ?? themes;
      final active = l?['active_workspace'];
      activeWorkspace = active is int && active >= 1 && active <= 10 ? active : null;
      wallpapers.clear();
      if (!chosenOnce && l != null) {
        // The workspace you are on is the one chosen (ws_choose_current).
        chosenOnce = true;
        if (activeWorkspace != null) selected = activeWorkspace!;
        group = groupOf(selected);
      }
    });
    await loadWallpapers();
  }

  Future<void> loadWallpapers() async {
    final slug = look(current())['theme'] as String?;
    if (slug == null || wallpapers.containsKey(slug)) return;
    Map<String, dynamic>? r;
    try {
      r = await app!.call('wallpapers.list', {'slug': slug});
    } catch (_) {
      r = null;
    }
    if (!mounted || r == null) return;
    setState(() {
      wallpapers[slug] = [
        for (final w in (r!['wallpapers'] as List? ?? []).whereType<Map>())
          if (w['hidden'] != true && w['problem'] == null) '${w['name']}',
      ];
    });
  }

  // --- state helpers -------------------------------------------------------------------

  Map look(int ws) => looks['$ws'] as Map? ?? const {};
  int groupOf(int ws) => ws <= _groups[0].$2 ? 0 : 1;
  Map get caps => state['workspaceCaps'] as Map? ?? const {};
  Map get modes => state['workspaceModes'] as Map? ?? const {};
  Map get defaults => state['defaultModes'] as Map? ?? const {};
  Map get layouts => state['workspaceLayouts'] as Map? ?? const {};
  int get globalCap => state['maxWindows'] as int? ?? 2;
  int limitOf(int ws) => ws == 0 ? globalCap : (caps['$ws'] as int? ?? globalCap);
  String modeOf(int ws) {
    if (ws > 0 && modes['$ws'] is String) return modes['$ws'] as String;
    return defaults['${limitOf(ws)}'] as String? ?? 'default';
  }

  List<String> appsOf(int ws) => ((layouts['$ws'] as Map?)?['apps'] as List? ?? const []).cast<String>();
  Map colorsOf(int ws) {
    final c = look(ws)['colors'];
    return c is Map && c.isNotEmpty ? c : app!.colors;
  }

  /// The workspace the controls and preview are for (App Presets: never All).
  int current() => tab == 1 && selected <= 0 ? _groups[group].$1 : selected;

  String title(int ws) => ws == 0 ? tr("All Workspaces") : trf("Workspace {0}", [ws]);
  String windows(int n) => n == 1 ? trf('{0} window', [n]) : trf('{0} windows', [n]);

  String summary(int ws) {
    if (tab == 1) {
      final apps = appsOf(ws);
      if (!layouts.containsKey('$ws')) return tr("No App Preset");
      var text = apps.isEmpty ? tr("App Preset") : (apps.length == 1 ? trf('{0} app saved', [apps.length]) : trf('{0} apps saved', [apps.length]));
      if ((layouts['$ws'] as Map?)?['autostart'] == true) text += tr(" · Autostart on");
      return text;
    }
    if (ws == 0) return trf("Default: {0}", [windows(limitOf(0))]);
    return trf("Max {0} · {1}", [limitOf(ws), modeLabel(modeOf(ws))]);
  }

  ({List<Rect> rects, bool dashed}) pictureOf(int ws) {
    final mode = modeOf(ws);
    if (tab == 1) {
      final apps = appsOf(ws);
      return (rects: layoutRects(mode == 'floating' ? 'floating' : 'tiled', apps.length), dashed: false);
    }
    return (rects: layoutRects(mode, limitOf(ws)), dashed: mode == 'default');
  }

  String caption(int ws) {
    final l = look(ws);
    final wall = l['wallpaper'] as String?;
    return [
      l['name'] as String? ?? tr("Theme missing"),
      if (ws > 0 && wall != null) wall.split('/').last,
      summary(ws),
    ].join(' · ');
  }

  // --- running changes -------------------------------------------------------------------

  /// Runs a change with Undo (also Ctrl+Z). [tiling]: the layout changed, so
  /// COSMIC's tiling of the open workspaces follows at once (Undo puts it back).
  Future<Map<String, dynamic>?> perform(String route, Map<String, dynamic> params, String done,
      {bool tiling = false}) async {
    if (busy) return null;
    setState(() => busy = true);
    try {
      final result = await app!.run(route, params);
      if (result == null) return null;
      String? applied;
      if (tiling && app!.can('workspaces') && app!.can('tiling') && app!.can('windows')) {
        try {
          applied = (await app!.call('workspaces.apply'))['receipt'] as String?;
        } catch (_) {
          applied = null; // no COSMIC helper: the applet applies it later
        }
      }
      final receipt = result['receipt'];
      app!.notify(
        done,
        undo: receipt == null
            ? null
            : () async {
                if (applied != null) await app!.run('presets.undo', {'receipt': applied});
                await app!.run('presets.undo', {'receipt': receipt, 'appearance': result['appearance'] == true});
                app!.changed();
                await reload();
              },
      );
      if (result['appearance'] == true) app!.changed();
      await reload();
      return result;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Gaps of tiled windows (screen edges, between tiles) and the active
  /// window's frame width, applied at once with Undo.
  Future<void> tileStyleDialog() async {
    final now = await app!.run('tiling.style');
    if (now == null || !mounted) return;
    final fields = [
      ('top', tr("Gap top"), 200),
      ('right', tr("Gap right"), 200),
      ('bottom', tr("Gap bottom"), 200),
      ('left', tr("Gap left"), 200),
      ('between', tr("Gap between windows"), 200),
      ('border', tr("Active window frame"), 16),
      ('radius', tr("Frame corner radius"), 32),
    ];
    final values = {for (final f in fields) f.$1: (now[f.$1] as num?)?.toInt() ?? 0};
    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(tr("Tiling gaps & frame")),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final f in fields)
                Row(children: [
                  Expanded(child: Text(f.$2)),
                  IconButton(
                    tooltip: tr("Less"),
                    icon: const Icon(Icons.remove),
                    onPressed: values[f.$1]! > 0 ? () => setState(() => values[f.$1] = values[f.$1]! - 1) : null,
                  ),
                  SizedBox(width: 56, child: Text(trf("{0} px", [values[f.$1]]), textAlign: TextAlign.center)),
                  IconButton(
                    tooltip: tr("More"),
                    icon: const Icon(Icons.add),
                    onPressed: values[f.$1]! < f.$3 ? () => setState(() => values[f.$1] = values[f.$1]! + 1) : null,
                  ),
                ]),
              const SizedBox(height: 8),
              Text(tr("The frame is drawn in the theme accent on tiled workspaces; 0 px hides it."),
                  style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr("Cancel"))),
            FilledButton(onPressed: () => Navigator.pop(context, Map.of(values)), child: Text(tr("Apply"))),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => busy = true);
    try {
      final r = await app!.run('tiling.style.set', result);
      final previous = r?['previous'];
      if (r != null) {
        app!.notify(tr("Gaps and frame applied"),
            undo: previous is Map
                ? () => app!.run('tiling.style.set', {
                      for (final f in fields)
                        if (previous[f.$1] is num) f.$1: (previous[f.$1] as num).toInt(),
                    })
                : null);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> setWs(int ws, Map<String, dynamic> params, String done, {bool tiling = false}) =>
      perform('workspaces.set', {if (ws > 0) 'workspace': ws, ...params}, done, tiling: tiling);

  Future<void> setLimit(int ws, int n) async {
    n = n.clamp(1, 4);
    if (ws == 0) {
      await setWs(0, {'maxWindows': n}, trf("Default: {0}", [windows(n)]), tiling: true);
    } else {
      await setWs(ws, {'limit': n}, trf("Workspace {0}: Max {1} · {2}", [ws, n, modeLabel(modeOf(ws))]), tiling: true);
    }
  }

  Future<void> pickMode(int ws, String mode) async {
    if (ws == 0) {
      final cap = globalCap;
      final same = defaults['$cap'] == mode; // click again: the default goes
      await setWs(0, {'defaultLimit': cap, 'defaultMode': same ? null : mode},
          same ? tr("Default layout removed") : trf("Default for {0}: {1}", [windows(cap), modeLabel(mode)]), tiling: true);
      return;
    }
    final same = modes['$ws'] == mode; // click again: the preset goes
    await setWs(ws, {'mode': same ? null : mode},
        same ? trf("Workspace {0}: layout preset removed", [ws]) : trf("Workspace {0}: {1}", [ws, modeLabel(mode)]), tiling: true);
  }

  Future<void> addWindow(int ws, int by) async {
    if (tab == 1) {
      if (by > 0) await addApp(ws);
      return;
    }
    final n = limitOf(ws) + by;
    if (n < 1 || n > 4) return;
    await setLimit(ws, n);
  }

  // --- tabs and note ---------------------------------------------------------------------

  Widget tabButton(int index, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    final on = tab == index;
    return Semantics(
      selected: on,
      label: label,
      child: OutlinedButton.icon(
        onPressed: () => setState(() {
          tab = index;
          zoomed = null;
          conflict = null;
          message = '';
          if (tab == 1 && selected == 0) selected = _groups[group].$1;
        }),
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          backgroundColor: on ? scheme.surfaceContainerHigh : null,
          side: BorderSide(color: on ? scheme.primary : scheme.outlineVariant, width: on ? 2 : 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  /// The note above the tabs (the plugin's hand-over note): who moves the windows.
  Widget note() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(cornerSizes(context).small),
      ),
      child: Text(
        state['active'] == true
            ? trf("Maprisma Theme {0} arranges the windows: window limits and overflow take effect there at once. Tiled and Floating switch {1}'s tiling; Native leaves it as it is.", [app!.can('panel') ? tr("applet in the panel") : tr("tray service"), tilerOf(app!.desktopName)])
            : trf("Tiling is off (All Workspaces): layouts switch {0}'s tiling of a workspace, window limits wait until Tiling active is on. Native leaves {1}'s tiling as it is.", [tilerOf(app!.desktopName), tilerOf(app!.desktopName)]),
        style: textRole(Theme.of(context).textTheme.bodySmall),
      ),
    );
  }

  // --- cards ---------------------------------------------------------------------------

  Widget groupButtons() {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < _groups.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              selected: group == i,
              child: OutlinedButton(
                onPressed: () {
                  if (group == i) return;
                  setState(() {
                    group = i;
                    zoomed = null;
                    conflict = null;
                    if (selected != 0 && groupOf(selected) != i) selected = _groups[i].$1;
                  });
                  loadWallpapers();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.onSurface,
                  backgroundColor: group == i ? scheme.surfaceContainerHigh : null,
                  side: BorderSide(
                      color: group == i ? scheme.onSurface.withValues(alpha: .8) : scheme.outlineVariant,
                      width: group == i ? 1.5 : 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(trf("Workspaces {0}–{1}", [_groups[i].$1, _groups[i].$2]), style: textRole(Theme.of(context).textTheme.bodyMedium)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  void select(int ws) {
    setState(() {
      selected = ws;
      conflict = null;
      highlight = null;
      if (ws > 0) group = groupOf(ws);
    });
    loadWallpapers();
  }

  Widget cards(double width, bool wide) {
    final ids = [
      if (tab == 0) 0,
      for (var ws = _groups[group].$1; ws <= _groups[group].$2; ws++) ws,
    ];
    const gap = 6.0;
    final perRow = wide || width >= 560 ? 3 : 2;
    final cardW = ((width - gap * (perRow - 1)) / perRow).floorToDouble();
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [for (final ws in ids) SizedBox(width: cardW, child: card(ws, wide))],
    );
  }

  Widget card(int ws, bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = ws == current();
    final pic = pictureOf(ws);
    final text = app!.can('tiling') ? summary(ws) : title(ws);
    final picture = AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedOpacity(
            opacity: zoomed == ws ? 0 : 1,
            duration: const Duration(milliseconds: 180),
            child: CustomPaint(painter: LayoutPicture(colorsOf(ws), pic.rects, pic.dashed, deck: ws == 0)),
          ),
          if (pic.rects.isEmpty) Center(child: Text('—', style: TextStyle(color: scheme.onSurfaceVariant))),
          Positioned(
            right: 3,
            bottom: 3,
            child: Tooltip(
              message: tr("Preview"),
              child: Semantics(
                button: true,
                label: trf("Preview: {0}", [title(ws)]),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => zoom(ws, wide),
                  child: Container(
                    padding: const EdgeInsets.all(1.5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.surface.withValues(alpha: .85),
                      border: Border.all(color: scheme.onSurface.withValues(alpha: .6)),
                    ),
                    child: Icon(Icons.zoom_in, size: 13, color: scheme.onSurface),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title(ws),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall!.copyWith(
              fontWeight: FontWeight.w600,
              color: ws > 0 && ws == activeWorkspace ? scheme.primary : scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          if (app!.can('tiling')) picture,
          const SizedBox(height: 4),
          Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: chosen ? scheme.onSurface : scheme.onSurfaceVariant)),
        ],
      ),
    );
    return Tooltip(
      message: text,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        selected: chosen,
        button: true,
        label: '${title(ws)}: $text',
        child: Material(
          color: chosen ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow,
          shape: ws == 0
              ? _DashedBorder(chosen ? scheme.onSurface.withValues(alpha: .8) : scheme.outline, cornerSizes(context).control)
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(cornerSizes(context).control),
                  side: BorderSide(
                    color: chosen ? scheme.onSurface.withValues(alpha: .7) : scheme.outlineVariant,
                    width: chosen ? 1.5 : 1,
                  ),
                ),
          child: InkWell(onTap: () => select(ws), child: body),
        ),
      ),
    );
  }

  /// Wide: the preview on the right shows it (it is chosen); narrow: the
  /// large preview over the page, the small picture fading out.
  void zoom(int ws, bool wide) {
    if (!app!.can('tiling')) return;
    select(ws);
    if (wide) {
      previewFocus.requestFocus();
      return;
    }
    setState(() => zoomed = ws);
    WidgetsBinding.instance.addPostFrameCallback((_) => zoomFocus.requestFocus());
  }

  // --- the workspace as it looks (right panel, large preview) ----------------------------

  KeyEventResult previewKey(int ws, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final char = event.character;
    if (char == '+' || key == LogicalKeyboardKey.numpadAdd) {
      addWindow(ws, 1);
      return KeyEventResult.handled;
    }
    if (char == '-' || key == LogicalKeyboardKey.numpadSubtract) {
      addWindow(ws, -1);
      return KeyEventResult.handled;
    }
    final count = pictureOf(ws).rects.length;
    if ((key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) && count > 0) {
      setState(() => highlight = highlight == null
          ? 0
          : (highlight! + (key == LogicalKeyboardKey.arrowLeft ? -1 : 1)) % count);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) && tab == 0) {
      final i = _modes.indexOf(modeOf(ws));
      final next = _modes[(i + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % _modes.length];
      if (ws == 0) {
        setWs(0, {'defaultLimit': globalCap, 'defaultMode': next}, trf("Default: {0}", [modeLabel(next)]), tiling: true);
      } else {
        setWs(ws, {'mode': next}, trf("Workspace {0}: {1}", [ws, modeLabel(next)]), tiling: true);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && zoomed != null) {
      setState(() => zoomed = null);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget lookAlike(int ws, FocusNode focus) {
    final l = look(ws);
    final pic = pictureOf(ws);
    final colors = colorsOf(ws);
    final wall = ws == 0 ? null : (l['wallpaper'] as String? ?? l['preview'] as String?);
    final limit = limitOf(ws);
    final plus = tab == 1 ? appsOf(ws).length < 64 : limit < 4;
    final minus = tab == 0 && limit > 1;
    return Focus(
      focusNode: focus,
      onKeyEvent: (_, e) => previewKey(ws, e),
      child: ListenableBuilder(
        listenable: focus,
        builder: (context, _) => AspectRatio(
          aspectRatio: 16 / 9,
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth, h = box.maxHeight;
            final k = math.max(1.0, w / 272);
            final bar = math.max(7.0, (h * 0.055).roundToDouble());
            final top = bar + 2 * k;
            final r = math.max(10.0, 9 * k);
            final cy = top + (h - top) / 2;
            return Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(cornerSizes(context).control),
                    child: Stack(fit: StackFit.expand, children: [
                      ColoredBox(color: hexColor(colors, 'background') ?? Colors.black),
                      if (wall != null)
                        Image.file(File(wall),
                            fit: BoxFit.cover,
                            cacheWidth: (w * 1.5).round().clamp(64, 2400),
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => const SizedBox()),
                      CustomPaint(
                        painter: LookPainter(
                          colors: colors,
                          rects: pic.rects,
                          dashed: pic.dashed,
                          wallpaper: wall != null,
                          allLabel: ws == 0 ? tr("All workspaces · default") : '',
                          highlight: focus.hasFocus ? highlight : null,
                          focused: focus.hasFocus,
                          activeIndex: modeOf(ws) == 'floating' ? pic.rects.length - 1 : 0,
                        ),
                      ),
                    ]),
                  ),
                ),
                if (minus)
                  Positioned(
                    left: 3,
                    top: cy - r,
                    child: _RoundHandle(
                        r: r, minus: true, colors: colors, tooltip: tr("One window less"), onTap: () => addWindow(ws, -1)),
                  ),
                if (plus)
                  Positioned(
                    right: 3,
                    top: cy - r,
                    child: _RoundHandle(
                        r: r,
                        minus: false,
                        colors: colors,
                        tooltip: tab == 1 ? tr("Add app…") : tr("One window more"),
                        onTap: () => addWindow(ws, 1)),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget rightPanel(int ws) {
    final scheme = Theme.of(context).colorScheme;
    return groupCard([
      Text(title(ws).toUpperCase(), style: heading(scheme)),
      const SizedBox(height: 8),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        child: KeyedSubtree(key: ValueKey('$tab/$ws'), child: lookAlike(ws, previewFocus)),
      ),
      const SizedBox(height: 8),
      Text(caption(ws), style: Theme.of(context).textTheme.bodySmall!.copyWith(color: scheme.onSurfaceVariant)),
      const SizedBox(height: 4),
      Text(
        tab == 1
            ? tr("Tab to the preview: + adds an app.")
            : tr("Tab to the preview: + and − change the limit, ↑/↓ the layout, ←/→ choose a window."),
        style: Theme.of(context).textTheme.labelSmall!.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: .75)),
      ),
    ]);
  }

  Widget zoomOverlay(int ws) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => zoomed = null),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: .55),
          child: LayoutBuilder(builder: (context, box) {
            var width = math.max(240.0, box.maxWidth - 64);
            var height = width * 9 / 16;
            final room = box.maxHeight - 110;
            if (height > room) {
              height = math.max(135.0, room);
              width = height * 16 / 9;
            }
            return Center(
              child: Semantics(
                label: '${title(ws)} · ${caption(ws)}',
                scopesRoute: true,
                explicitChildNodes: true,
                child: GestureDetector(
                  onTap: () {}, // a click on the preview itself keeps it open
                  child: SizedBox(
                    width: width,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        lookAlike(ws, zoomFocus),
                        const SizedBox(height: 8),
                        Text('${title(ws)} · ${caption(ws)}',
                            style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: Colors.white.withValues(alpha: .9))),
                        Text(tr("A click beside it or Esc closes it."),
                            style: Theme.of(context).textTheme.labelSmall!.copyWith(color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  // --- controls ------------------------------------------------------------------------

  TextStyle heading(ColorScheme scheme) =>
      TextStyle(fontSize: 11, letterSpacing: 1.3, color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700);

  /// A section in its own group card (the plugin's Sections).
  Widget groupCard(List<Widget> children, {String? title}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(cornerSizes(context).small),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[Text(title.toUpperCase(), style: heading(scheme)), const SizedBox(height: 8)],
          ...children,
        ],
      ),
    );
  }

  Widget hint(String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
  );

  Widget choiceRow(List<({String label, bool on, VoidCallback tap, String tooltip})> items) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: items[i].tooltip,
              child: Semantics(
                selected: items[i].on,
                child: OutlinedButton(
                  onPressed: busy ? null : items[i].tap,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.onSurface,
                    disabledForegroundColor: scheme.onSurface.withValues(alpha: .7),
                    backgroundColor: items[i].on ? scheme.surfaceContainerHigh : null,
                    side: BorderSide(
                        color: items[i].on ? scheme.onSurface.withValues(alpha: .85) : scheme.outlineVariant,
                        width: items[i].on ? 1.5 : 1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(items[i].label, style: textRole(Theme.of(context).textTheme.bodyMedium)),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// The LAYOUT PRESET tiles: COSMIC's choices, drawn for [cap] windows.
  Widget layoutChoices(int ws, int cap, String? chosen, double width) {
    final scheme = Theme.of(context).colorScheme;
    final colors = colorsOf(ws);
    final tileW = ((width - 3 * 6) / 4 - 10).clamp(64.0, 150.0);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final mode in _modes)
          Tooltip(
            message: modeHint(mode, app!.desktopName),
            child: Semantics(
              selected: mode == chosen,
              button: true,
              label: modeLabel(mode),
              child: Material(
                color: mode == chosen ? scheme.surfaceContainerHigh : Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(cornerSizes(context).control),
                  side: BorderSide(
                      color: mode == chosen ? scheme.onSurface.withValues(alpha: .85) : scheme.outlineVariant,
                      width: mode == chosen ? 1.5 : 1),
                ),
                child: InkWell(
                  onTap: busy ? null : () => pickMode(ws, mode),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                    child: SizedBox(
                      width: tileW,
                      child: Column(children: [
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: CustomPaint(
                            painter: LayoutPicture(
                                colors, layoutRects(mode, mode == 'default' ? math.max(cap, 3) : cap), mode == 'default'),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(modeLabel(mode), style: textRole(Theme.of(context).textTheme.labelSmall)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget action(String label, IconData icon, VoidCallback? onTap, {String tooltip = '', bool destructive = false}) {
    final scheme = Theme.of(context).colorScheme;
    final button = OutlinedButton.icon(
      onPressed: busy ? null : onTap,
      icon: Icon(icon, size: 16, color: destructive ? scheme.error : scheme.primary),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: destructive ? scheme.error : scheme.onSurface,
        side: BorderSide(color: destructive ? scheme.error.withValues(alpha: .6) : scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cornerSizes(context).control)),
        visualDensity: VisualDensity.compact,
      ),
    );
    return tooltip.isEmpty ? button : Tooltip(message: tooltip, child: button);
  }

  Widget toggle(String title, String hint, bool on, ValueChanged<bool>? flip, {String tooltip = ''}) {
    final scheme = Theme.of(context).colorScheme;
    final row = Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title),
          if (hint.isNotEmpty) Text(hint, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
      Switch(value: on, onChanged: busy ? null : flip),
    ]);
    return tooltip.isEmpty ? row : Tooltip(message: tooltip, child: row);
  }

  List<Widget> layoutControls(int ws, double width) {
    if (ws == 0) {
      final cap = globalCap;
      return [
        if (app!.can('windows') && app!.can('tiling')) groupCard([
          toggle(tr("Tiling active"), tr("Window limits with overflow to the next workspace with room"),
              state['active'] == true, (v) => setWs(0, {'active': v}, v ? tr("Tiling active") : tr("Tiling off")),
              tooltip: tr("Move new windows when full · Manual moves override")),
        ]),
        if (app!.can('windows')) groupCard(title: tr("Default window limit (all workspaces)"), [
          choiceRow([
            for (var n = 1; n <= 4; n++)
              (label: '$n', on: cap == n, tap: () => setLimit(0, n), tooltip: trf("Default: {0}", [windows(n)])),
          ]),
        ]),
        if (app!.can('tiling')) groupCard(title: tr("Default layout preset"), [
          layoutChoices(0, cap, defaults['$cap'] as String?, width),
          hint(trf("For {0} on workspaces without a layout of their own. Click again to remove it (Native).", [windows(cap)])),
        ]),
        if (app!.can('tiling') && app!.can('windows')) groupCard(title: tr("Preset & App Preset management (all workspaces)"), [
          Wrap(spacing: 8, runSpacing: 8, children: [
            action(tr("Reset All to Default"), Icons.undo,
                () => perform('workspaces.bulk', {'action': 'reset_all'}, tr("All workspaces reset to the default"),
                    tiling: true),
                tooltip: tr("Reset all workspaces to the default limit and layout preset")),
            action(tr("Remove All Presets"), Icons.layers_clear_outlined,
                () => perform('workspaces.bulk', {'action': 'remove_all'}, tr("All workspaces Native"), tiling: true),
                tooltip: trf("Set all workspaces to Native: {0}'s own tiling, no layout preset or limit of their own", [tilerOf(app!.desktopName)])),
            action(tr("Clear All Presets & App Presets"), Icons.delete_outline, () async {
              if (await confirm(context, tr("Clear All Presets & App Presets?"),
                  tr("Clear all workspace layouts, limits, saved apps and autostart settings"), action: tr("Delete"))) {
                await perform('workspaces.reset', {}, tr("Everything cleared"), tiling: true);
              }
            }, tooltip: tr("Clear all workspace layouts, limits, saved apps and autostart settings"), destructive: true),
          ]),
        ]),
      ];
    }
    final cap = limitOf(ws);
    final own = modes['$ws'] as String?;
    final fallback = defaults['$cap'] as String?;
    return [
      if (app!.can('windows')) groupCard(title: tr("Window limit"), [
        choiceRow([
          for (var n = 1; n <= 4; n++)
            (label: '$n', on: cap == n, tap: () => setLimit(ws, n), tooltip: trf("Set Workspace {0} limit to {1}", [ws, windows(n)])),
        ]),
        if (caps.containsKey('$ws')) ...[
          const SizedBox(height: 8),
          action(trf("Reset Limit to Default ({0})", [globalCap]), Icons.undo,
              () => setWs(ws, {'limit': null}, trf("Workspace {0}: default limit", [ws]), tiling: true)),
        ],
      ]),
      if (app!.can('tiling')) groupCard(title: tr("Layout preset"), [
        if (cap <= 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: hint(tr("Keeps one window on this workspace. Newly opened windows move to the next workspace with room.")),
          ),
        layoutChoices(ws, cap, own, width),
        if (own != null)
          hint(tr("Click again or Reset to remove preset."))
        else if (fallback != null)
          hint(trf("Uses the default for {0}: {1}.", [windows(cap), modeLabel(fallback)])),
        const SizedBox(height: 8),
        action(tr("Reset Workspace to Default"), Icons.undo,
            () => setWs(ws, {'mode': null, if (app!.can('windows')) 'limit': null}, trf("Workspace {0} reset to the default", [ws]), tiling: true)),
      ]),
      lookControls(ws),
    ];
  }

  /// The workspace's own theme and wallpaper (the workspace themes and
  /// wallpapers of Settings, as the plugin's assign menu sets them).
  Widget lookControls(int ws) {
    final l = look(ws);
    final ownTheme = l['own_theme'] as String?;
    final ownWall = l['own_wallpaper'] as String?;
    final slug = l['theme'] as String?;
    final visible = [
      for (final t in themes.whereType<Map>())
        if (t['hidden'] != true || t['slug'] == ownTheme) t,
    ]..sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
    final walls = slug == null ? const <String>[] : wallpapers[slug] ?? const <String>[];
    String nameOf(String? s) => '${visible.firstWhere((t) => t['slug'] == s, orElse: () => const {})['name']}';
    return groupCard(title: tr("Theme and wallpaper"), [
      Row(children: [
        SizedBox(width: 84, child: Text(tr("Theme"))),
        Expanded(
          child: DropdownButton<String?>(
            isExpanded: true,
            value: visible.any((t) => t['slug'] == ownTheme) ? ownTheme : null,
            items: [
              DropdownMenuItem<String?>(value: null, child: Text(tr("The current theme"))),
              for (final t in visible)
                DropdownMenuItem<String?>(
                    value: t['slug'] as String, child: Text('${t['name']}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: busy
                ? null
                : (v) => perform('workspaces.set_look', {'workspace': ws, 'theme': v},
                    v == null ? trf("Workspace {0}: the current theme", [ws]) : trf("Workspace {0}: {1}", [ws, nameOf(v)])),
          ),
        ),
      ]),
      Row(children: [
        SizedBox(width: 84, child: Text(tr("Wallpaper"))),
        Expanded(
          child: DropdownButton<String?>(
            isExpanded: true,
            value: walls.contains(ownWall) ? ownWall : null,
            items: [
              DropdownMenuItem<String?>(value: null, child: Text(tr("The theme's wallpaper"))),
              for (final w in walls)
                DropdownMenuItem<String?>(value: w, child: Text(w, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: busy || slug == null
                ? null
                : (v) => perform('workspaces.set_look', {'workspace': ws, 'wallpaper': v},
                    v == null ? trf("Workspace {0}: the theme's wallpaper", [ws]) : trf("Workspace {0}: {1}", [ws, v])),
          ),
        ),
      ]),
      hint(trf("Shown when you switch to Workspace {0}.", [ws])),
    ]);
  }

  // --- App Presets -----------------------------------------------------------------------

  Future<void> addApp(int ws) async {
    final result = await app!.run('apppresets.launchers');
    if (result == null || !mounted) return;
    final launchers = (result['launchers'] as List).cast<Map>();
    var query = '';
    final id = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) {
          final matches =
              launchers.where((l) => '${l['name']} ${l['desktop_id']}'.toLowerCase().contains(query)).toList();
          return AlertDialog(
            title: Text(trf("Add app to Workspace {0}", [ws])),
            content: SizedBox(
              width: 480,
              height: 420,
              child: Column(children: [
                TextField(
                  autofocus: true,
                  decoration: InputDecoration(hintText: tr("Search apps"), prefixIcon: Icon(Icons.search)),
                  onChanged: (v) => update(() => query = v.toLowerCase()),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: matches.isEmpty
                      ? Center(child: Text(tr("No installed apps found.")))
                      : ListView.builder(
                          itemCount: matches.length,
                          itemBuilder: (c, i) {
                            final l = matches[i];
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.apps),
                              title: Text('${l['name']}'),
                              subtitle: Text('${l['desktop_id']}'),
                              onTap: () => Navigator.pop(c, l['desktop_id'] as String),
                            );
                          },
                        ),
                ),
              ]),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr("Cancel")))],
          );
        },
      ),
    );
    if (id != null && mounted) {
      await perform('apppresets.add', {'workspace': ws, 'desktop_id': id},
          trf("Added {0} to Workspace {1} (Restore App Preset starts it)", [id, ws]));
    }
  }

  Future<void> restore(int ws, [String? choice]) async {
    if (busy) return;
    final how = choice ?? (state['autoMoveOnRestore'] == true ? 'move' : 'ask');
    setState(() {
      busy = true;
      conflict = null;
    });
    Map<String, dynamic>? result;
    try {
      result = await app!.run('apppresets.restore', {'workspace': ws, 'action': how});
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (result == null || !mounted) return;
    if (result['status'] == 'conflict') {
      setState(() {
        conflict = {...result!, 'workspace': ws};
        message = trf("Workspace {0} has {1} open window(s) not in this preset.", [ws, result['conflict_count']]);
      });
      return;
    }
    final failed = (result['failed'] as List? ?? []).join(', ');
    final launched = (result['launched'] as List? ?? []).join(', ');
    final text = failed.isNotEmpty
        ? (launched.isNotEmpty ? trf("Launched: {0} · Could not restore: {1}", [launched, failed]) : trf("Could not restore: {0}", [failed]))
        : launched.isNotEmpty
        ? trf("Launched: {0}", [launched])
        : tr("Action completed.");
    setState(() => message = text);
    final receipt = result['receipt'];
    app!.notify(text,
        undo: receipt == null
            ? null
            : () async {
                await app!.run('presets.undo', {'receipt': receipt});
                await reload();
              });
    await reload();
  }

  Widget conflictCard(int ws) {
    final scheme = Theme.of(context).colorScheme;
    final buttons = [
      (tr("Move Conflicting Windows"), 'move', tr("Move conflicting windows to the next empty workspace")),
      (tr("Close"), 'close', tr("Close existing windows and restore the saved apps")),
      (tr("Keep"), 'keep', tr("Keep existing windows on this workspace")),
      (tr("Cancel"), null, tr("Cancel restoring this preset")),
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(cornerSizes(context).small),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(trf("Workspace {0} has {1} open window(s) not in this preset.", [ws, conflict!['conflict_count']])),
        const SizedBox(height: 4),
        Text(tr("How would you like to handle them before restoring?")),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (label, choice, tip) in buttons)
            Tooltip(
              message: tip,
              child: OutlinedButton(
                onPressed: () => choice == null
                    ? setState(() {
                        conflict = null;
                        message = tr("Restore cancelled.");
                      })
                    : restore(ws, choice),
                child: Text(label),
              ),
            ),
        ]),
      ]),
    );
  }

  List<Widget> appControls(int ws) {
    final scheme = Theme.of(context).colorScheme;
    final layout = layouts['$ws'] as Map?;
    final apps = appsOf(ws);
    return [
      groupCard([
        Text(
          layout == null
              ? tr("No App Preset saved yet")
              : trf("App Preset · Workspace {0} · {1} {2}", [ws, apps.length, apps.length == 1 ? tr('app') : tr('apps')]),
          style: Theme.of(context).textTheme.titleSmall!.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (apps.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < apps.length; i++)
              Container(
                padding: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(cornerSizes(context).small),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.apps, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(apps[i].replaceAll(RegExp(r'\.desktop$'), ''),
                        overflow: TextOverflow.ellipsis, style: textRole(Theme.of(context).textTheme.bodyMedium)),
                  ),
                  IconButton(
                    tooltip: trf("Remove {0} from the App Preset", [apps[i]]),
                    visualDensity: VisualDensity.compact,
                    iconSize: 14,
                    icon: const Icon(Icons.close),
                    onPressed: busy
                        ? null
                        : () => perform('apppresets.remove', {'workspace': ws, 'index': i},
                            trf("Removed {0} from the saved layout.", [apps[i]])),
                  ),
                ]),
              ),
          ]),
          hint(tr("× removes an app from the App Preset; it does not close its open windows.")),
        ],
        if (conflict != null && conflict!['workspace'] == ws) ...[const SizedBox(height: 8), conflictCard(ws)],
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          action(tr("Save App Preset"), Icons.save_outlined,
              () => perform('apppresets.save', {'workspace': ws}, trf("Saved App Preset for Workspace {0}", [ws])),
              tooltip: trf("Saves the open windows of Workspace {0} as its App Preset.", [ws])),
          action(tr("Add app…"), Icons.add, () => addApp(ws),
              tooltip: tr("Adds an installed app to the App Preset; Restore App Preset starts it.")),
          if (apps.isNotEmpty)
            action(tr("Restore App Preset"), Icons.refresh, () => restore(ws),
                tooltip: trf("Starts missing apps and moves their windows to Workspace {0}.", [ws])),
        ]),
        if (layout != null) ...[
          const SizedBox(height: 8),
          action(tr("Remove App Preset"), Icons.delete_outline,
              () => perform('apppresets.remove', {'workspace': ws}, trf("Removed the App Preset of Workspace {0}", [ws])),
              destructive: true),
          const SizedBox(height: 8),
          toggle(tr("Autostart on session startup"), tr("Automatically launch saved apps on startup"),
              layout['autostart'] == true,
              (v) => perform('apppresets.autostart', {'workspace': ws, 'enabled': v},
                  v ? trf("Autostart on for Workspace {0}", [ws]) : trf("Autostart off for Workspace {0}", [ws]))),
        ],
        hint(trf("Documents, window positions and sizes are not saved: {0} places the windows.", [app!.desktopName])),
      ]),
      groupCard([
        toggle(tr("Auto-move on restore"), tr("Move existing windows to next free workspace without asking"),
            state['autoMoveOnRestore'] == true,
            (v) => setWs(0, {'autoMoveOnRestore': v}, v ? tr("Auto-move on restore on") : tr("Auto-move on restore off"))),
        const SizedBox(height: 8),
        action(tr("Remove All App Presets"), Icons.delete_outline, () async {
          if (await confirm(context, tr("Remove All App Presets?"),
              tr("Deletes all saved app presets and autostart settings across all workspaces."), action: tr("Delete"))) {
            await perform('apppresets.remove_all', {}, tr("All App Presets removed"));
          }
        }, tooltip: tr("Delete all saved app presets across all workspaces"), destructive: true),
      ]),
    ];
  }

  // --- the two workspace tabs --------------------------------------------------------------

  Widget workspaceTab() {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= _wideFrom && app!.can('tiling');
      final leftW = (wide ? (box.maxWidth - 32) * 0.56 : box.maxWidth - 32).floorToDouble();
      final ws = current();
      final left = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          groupButtons(),
          const SizedBox(height: 8),
          cards(leftW, wide),
          const SizedBox(height: 12),
          for (final w in tab == 0 ? layoutControls(ws, leftW - 24) : appControls(ws)) ...[
            w,
            const SizedBox(height: 12),
          ],
          if (message.isNotEmpty && tab == 1)
            Text(message, style: Theme.of(context).textTheme.bodySmall!.copyWith(color: scheme.onSurfaceVariant)),
        ],
      );
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: leftW, child: left),
                const SizedBox(width: 16),
                Expanded(child: rightPanel(ws)),
              ])
            : left,
      );
    });
  }

  // --- Save/Load Presets -------------------------------------------------------------------

  String? themeName(String? slug) {
    for (final t in themes.whereType<Map>()) {
      if (t['slug'] == slug) return '${t['name']}';
    }
    return null;
  }

  Future<void> saveCurrent() async {
    final text = name.text.trim();
    if (text.isEmpty) return;
    final exists = presets.whereType<Map>().any((p) => '${p['name']}'.toLowerCase() == text.toLowerCase());
    if (exists &&
        !await confirm(context, trf("Replace “{0}”?", [text]), tr("A preset with this name already exists."), action: tr("Replace"))) {
      return;
    }
    final r = await perform('presets.save', {'name': text, 'includeWorkspaces': include && app!.can('workspaces') && app!.can('tiling') && app!.can('windows')}, trf("Saved preset “{0}”", [text]));
    if (r != null) name.clear();
  }

  Future<void> applyPreset(Map p) async {
    final ws = p['workspaces'] as Map?;
    final apps = (ws?['workspaceLayouts'] as Map? ?? {}).keys.map((k) => '$k').toList()..sort();
    if (apps.isNotEmpty &&
        !await confirm(context, trf("Apply “{0}”?", [p['name']]),
            trf("Missing apps on workspaces {0} start; other windows there move to a free workspace.", [apps.join(', ')]),
            action: tr("Apply"))) {
      return;
    }
    await perform('presets.apply', {'name': p['name'], 'confirmed': ws != null}, tr("Preset applied"));
  }

  Future<void> assign(Map p) async {
    final installed = themeName(p['theme'] as String?) != null;
    final options = [
      ('theme', tr("Theme")),
      if (installed && p['wallpaper'] != null) ('wallpaper', tr("Wallpaper")),
      if (installed && p['wallpaper'] != null) ('both', tr("Theme + wallpaper")),
    ];
    var part = options.first.$1;
    final ws = await showDialog<int>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, update) => AlertDialog(
          title: Text(tr("Assign to workspace")),
          content: SizedBox(
            width: 340,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              DropdownButton<String>(
                isExpanded: true,
                value: part,
                items: [for (final (v, l) in options) DropdownMenuItem(value: v, child: Text(l))],
                onChanged: (v) => update(() => part = v!),
              ),
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 5,
                shrinkWrap: true,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                childAspectRatio: 1.6,
                children: [
                  for (var w = 1; w <= 10; w++)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                      onPressed: () => Navigator.pop(c, w),
                      child: Text('$w'),
                    ),
                ],
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(tr("Cancel")))],
        ),
      ),
    );
    if (ws == null || !mounted) return;
    await perform('presets.assign', {
      'name': p['name'],
      'part': part,
      'workspaces': [ws],
    }, trf("Workspace {0} assigned: {1}", [ws, p['name']]));
  }

  Widget savedTab() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        Text(tr("Save the current theme, wallpaper and font for later."),
            style: Theme.of(context).textTheme.bodySmall!.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: name,
              maxLength: 60,
              decoration: InputDecoration(hintText: tr("Preset name"), counterText: ''),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => saveCurrent(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: busy || name.text.trim().isEmpty ? null : saveCurrent,
            child: Text(tr("Save current")),
          ),
        ]),
        if (app!.can('workspaces') && app!.can('tiling') && app!.can('windows')) CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text(tr("Include workspace presets and app presets")),
          value: include,
          onChanged: (v) => setState(() => include = v!),
        ),
        if (presets.isEmpty) Padding(padding: EdgeInsets.only(top: 8), child: Text(tr("No presets yet."))),
        for (final p in presets.whereType<Map>()) ...[presetRow(p), const SizedBox(height: 8)],
      ],
    );
  }

  bool canApplyPreset(Map p) => p['workspaces'] == null ||
      (app!.can('workspaces') && app!.can('tiling') && app!.can('windows'));

  Widget presetRow(Map p) {
    final scheme = Theme.of(context).colorScheme;
    final theme = themeName(p['theme'] as String?);
    final ws = p['workspaces'] as Map?;
    final layoutCount = ws == null
        ? 0
        : {...(ws['workspaceCaps'] as Map? ?? {}).keys, ...(ws['workspaceModes'] as Map? ?? {}).keys}.length;
    final appCount = (ws?['workspaceLayouts'] as Map? ?? {}).length;
    final small = Theme.of(context).textTheme.bodySmall!.copyWith(color: scheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(cornerSizes(context).small),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              [theme ?? tr("Theme missing"), p['wallpaper'] ?? tr("No wallpaper"), p['font'] ?? tr("No font")].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: small,
            ),
            if (!canApplyPreset(p)) Text(trf("This preset needs workspace features unavailable on {0}.", [app!.desktopName]), style: small),
            if (app!.can('workspaces') && ws != null) Text(trf("Workspace presets: {0} · App presets: {1}", [layoutCount, appCount]), style: small),
          ]),
        ),
        const SizedBox(width: 8),
        if (canApplyPreset(p)) OutlinedButton(onPressed: busy || theme == null ? null : () => applyPreset(p), child: Text(tr("Apply"))),
        if (app!.can('workspaces')) IconButton(
          tooltip: tr("Assign theme and/or wallpaper to workspace"),
          icon: const Icon(Icons.grid_view),
          onPressed: busy || theme == null ? null : () => assign(p),
        ),
        IconButton(
          tooltip: tr("Delete preset"),
          icon: Icon(Icons.delete_outline, color: scheme.error),
          onPressed: busy
              ? null
              : () async {
                  if (await confirm(context, trf("Delete preset “{0}”?", [p['name']]), tr("You can undo this."), action: tr("Delete"))) {
                    await perform('presets.delete', {'name': p['name']}, trf("Deleted preset “{0}”", [p['name']]));
                  }
                },
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppScope.of(context);
    final hasWorkspaces = app!.can('workspaces');
    final hasApps = hasWorkspaces && app!.can('windows');
    final effectiveTab = !hasWorkspaces || (tab == 1 && !hasApps) ? 2 : tab;
    final z = hasWorkspaces && app!.can('tiling') ? zoomed : null;
    return PopScope(
      canPop: z == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && zoomed != null) setState(() => zoomed = null);
      },
      child: SubPage(
        title: tr("Presets"),
        body: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    if (hasWorkspaces) tabButton(0, Icons.grid_view, tr("Workspaces")),
                    if (hasApps) tabButton(1, Icons.apps, tr("App Presets")),
                    tabButton(2, Icons.download_outlined, tr("Save/Load Presets")),
                    if (hasWorkspaces && app!.can('tiling') && app!.desktopId == 'kde')
                      IconButton(
                        tooltip: tr("Gaps of tiled windows and the active window frame"),
                        icon: const Icon(Icons.border_outer),
                        onPressed: busy ? null : tileStyleDialog,
                      ),
                  ]),
                ),
                Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: hasWorkspaces && app!.can('tiling') && app!.can('windows') ? note() : Text(trf("{0} are not available on {1} yet.", [hasWorkspaces ? tr("Tiling and window limits") : tr("Workspaces"), app!.desktopName]))),
                SizedBox(height: 2, child: busy ? const LinearProgressIndicator() : null),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 120),
                    layoutBuilder: (current, previous) =>
                        Stack(fit: StackFit.expand, children: [...previous, ?current]),
                    child: KeyedSubtree(key: ValueKey(effectiveTab), child: effectiveTab == 2 ? savedTab() : workspaceTab()),
                  ),
                ),
              ],
            ),
            if (z != null) zoomOverlay(z),
          ],
        ),
      ),
    );
  }
}

/// A mini monitor with the windows of a layout (the plugin's LayoutPicture).
class LayoutPicture extends CustomPainter {
  LayoutPicture(this.colors, this.rects, this.dashed, {this.deck = false});
  final Map colors;
  final List<Rect> rects;
  final bool dashed, deck;

  @override
  void paint(Canvas canvas, Size size) {
    final fg = hexColor(colors, 'foreground') ?? const Color(0xffcdd6f4);
    final accent = hexColor(colors, 'accent') ?? const Color(0xff89b4fa);
    var width = size.width, height = size.height;
    if (deck) {
      // All Workspaces: two screens behind (up right), the front one smaller.
      final off = math.max(3.0, height * 0.08);
      for (final (step, alpha) in [(2, 0.35), (1, 0.6)]) {
        final r = RRect.fromRectAndRadius(
            Rect.fromLTWH(0.5 + step * off, 0.5, width - 1 - 2 * off, height - 1 - 2 * off), const Radius.circular(5));
        canvas.drawRRect(r, Paint()..color = accent.withValues(alpha: 0.10 * alpha));
        canvas.drawRRect(
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = accent.withValues(alpha: alpha));
      }
      canvas.translate(0, 2 * off);
      width -= 2 * off;
      height -= 2 * off;
    }
    final screen = RRect.fromRectAndRadius(Rect.fromLTWH(0.5, 0.5, width - 1, height - 1), const Radius.circular(5));
    canvas.drawRRect(screen, Paint()..color = fg.withValues(alpha: 0.06));
    canvas.drawRRect(
        screen,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = fg.withValues(alpha: 0.25));
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Rect.fromLTWH(1, 1, width - 2, height - 2), const Radius.circular(4)));
    for (final r in rects) {
      final box = RRect.fromRectAndRadius(
          Rect.fromLTWH(r.left * width, r.top * height, r.width * width, r.height * height), const Radius.circular(3));
      if (dashed) {
        _dashed(
            canvas,
            box,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = fg.withValues(alpha: 0.45),
            3,
            2);
      } else {
        canvas.drawRRect(box, Paint()..color = accent.withValues(alpha: 0.45));
        canvas.drawRRect(
            box,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = accent.withValues(alpha: 0.9));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LayoutPicture old) =>
      old.colors != colors || old.dashed != dashed || old.deck != deck || old.rects.toString() != rects.toString();
}

/// A workspace as it looks (the plugin's LookAlike): over the wallpaper, a
/// bar and the windows of its layout in the theme's colours, the active one
/// with the accent border.
class LookPainter extends CustomPainter {
  LookPainter({
    required this.colors,
    required this.rects,
    required this.dashed,
    required this.wallpaper,
    required this.allLabel,
    required this.highlight,
    required this.focused,
    required this.activeIndex,
  });
  final Map colors;
  final List<Rect> rects;
  final bool dashed, wallpaper, focused;
  final String allLabel;
  final int? highlight;
  final int activeIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width, height = size.height;
    final bg = hexColor(colors, 'background') ?? const Color(0xff1e1e2e);
    final fg = hexColor(colors, 'foreground') ?? const Color(0xffcdd6f4);
    final accent = hexColor(colors, 'accent') ?? const Color(0xff89b4fa);
    final all = Offset.zero & size;
    if (allLabel.isNotEmpty) {
      // Not a desktop: a striped template in the theme's colours.
      canvas.drawRect(all, Paint()..color = bg);
      final step = math.max(10.0, width / 30);
      final stripes = Paint()
        ..color = accent.withValues(alpha: 0.07)
        ..strokeWidth = step * 0.35;
      for (var x = -height; x < width; x += step) {
        canvas.drawLine(Offset(x, height), Offset(x + height, 0), stripes);
      }
    } else if (!wallpaper) {
      canvas.drawRect(all, Paint()..color = accent.withValues(alpha: 0.12));
    }
    final k = math.max(1.0, width / 272);
    final bar = math.max(7.0, (height * 0.055).roundToDouble());
    canvas.drawRect(Rect.fromLTWH(0, 0, width, bar), Paint()..color = bg.withValues(alpha: 0.92));
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(Offset((6 + i * 7) * k, bar / 2), 2 * k,
          Paint()..color = (i == 0 ? accent : fg).withValues(alpha: i == 0 ? 0.9 : 0.5));
    }
    canvas.drawRect(Rect.fromLTWH(width / 2 - 8 * k, bar / 2 - 1.2 * k, 16 * k, 2.4 * k),
        Paint()..color = fg.withValues(alpha: 0.6));
    final top = bar + 2 * k;
    final areaH = height - top;
    for (var index = 0; index < rects.length; index++) {
      final r = rects[index];
      final rect = Rect.fromLTWH(r.left * width, top + r.top * areaH, r.width * width, r.height * areaH);
      final box = RRect.fromRectAndRadius(rect, Radius.circular(4 * k));
      if (dashed) {
        canvas.drawRRect(box, Paint()..color = bg.withValues(alpha: 0.55));
        _dashed(
            canvas,
            box,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2 * k
              ..color = fg.withValues(alpha: 0.6),
            4 * k,
            3 * k);
        continue;
      }
      final active = index == activeIndex;
      canvas.drawRRect(box, Paint()..color = bg.withValues(alpha: 0.8));
      canvas.drawRRect(
          box,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (active ? 2 : 1.2) * k
            ..color = (active ? accent : fg).withValues(alpha: active ? 0.95 : 0.35));
      if (index == highlight) {
        final inner = RRect.fromRectAndRadius(rect.deflate(3 * k), Radius.circular(3 * k));
        canvas.drawRRect(inner, Paint()..color = accent.withValues(alpha: 0.25));
        _dashed(
            canvas,
            inner,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2 * k
              ..color = accent,
            5 * k,
            3 * k);
      }
      // A title line and a few text lines, so it reads as a window.
      final pad = math.max(3.0, rect.width * 0.08);
      final line = 2.5 * k;
      canvas.drawRect(Rect.fromLTWH(rect.left + pad, rect.top + pad, math.max(4, rect.width * 0.35), line),
          Paint()..color = (active ? accent : fg).withValues(alpha: 0.55));
      var y = rect.top + pad + line * 3;
      final text = Paint()..color = fg.withValues(alpha: 0.25);
      for (final part in const [0.75, 0.6, 0.68, 0.4, 0.7, 0.55, 0.62, 0.3]) {
        if (y + line > rect.bottom - pad) break;
        canvas.drawRect(
            Rect.fromLTWH(rect.left + pad, y, math.max(4, (rect.width - 2 * pad) * part), line * 0.8), text);
        y += line * 2.6;
      }
    }
    if (allLabel.isNotEmpty) {
      // A dashed accent frame and a tag: the defaults for every workspace.
      _dashed(
          canvas,
          RRect.fromRectAndRadius(Rect.fromLTWH(2, 2, width - 4, height - 4), const Radius.circular(8)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * k
            ..color = accent.withValues(alpha: 0.9),
          7 * k,
          4 * k);
      final painter = TextPainter(
        text: TextSpan(
            text: allLabel, style: TextStyle(color: bg, fontSize: math.max(10, 10 * k), fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      final pad = 6 * k;
      final tw = painter.width + 2 * pad, th = painter.height + pad;
      final tag =
          RRect.fromRectAndRadius(Rect.fromLTWH(width - tw - 8 * k, bar + 4 * k, tw, th), Radius.circular(th / 2));
      canvas.drawRRect(tag, Paint()..color = accent);
      painter.paint(canvas, Offset(tag.left + pad, tag.top + pad / 2));
      painter.dispose();
    }
    if (focused) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(1.5, 1.5, width - 3, height - 3), const Radius.circular(8)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = accent.withValues(alpha: 0.8));
    }
  }

  @override
  bool shouldRepaint(covariant LookPainter old) => true;
}

void _dashed(Canvas canvas, RRect box, Paint paint, double on, double off) {
  final path = Path()..addRRect(box);
  for (final metric in path.computeMetrics()) {
    var d = 0.0;
    while (d < metric.length) {
      canvas.drawPath(metric.extractPath(d, math.min(d + on, metric.length)), paint);
      d += on + off;
    }
  }
}

/// The round + / − on the preview's edges (one window more or less).
class _RoundHandle extends StatefulWidget {
  const _RoundHandle(
      {required this.r, required this.minus, required this.colors, required this.tooltip, required this.onTap});
  final double r;
  final bool minus;
  final Map colors;
  final String tooltip;
  final VoidCallback onTap;
  @override
  State<_RoundHandle> createState() => _RoundHandleState();
}

class _RoundHandleState extends State<_RoundHandle> {
  bool hot = false;
  @override
  Widget build(BuildContext context) {
    final bg = hexColor(widget.colors, 'background') ?? const Color(0xff1e1e2e);
    final accent = hexColor(widget.colors, 'accent') ?? const Color(0xff89b4fa);
    final size = widget.r * 2;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => hot = true),
          onExit: (_) => setState(() => hot = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (hot ? accent : bg).withValues(alpha: hot ? 0.95 : 0.9),
                border: Border.all(color: accent, width: 1.5),
              ),
              child: Icon(widget.minus ? Icons.remove : Icons.add, size: widget.r * 1.3, color: hot ? bg : accent),
            ),
          ),
        ),
      ),
    );
  }
}

/// A dashed frame for the All Workspaces card (the defaults, not a workspace).
class _DashedBorder extends ShapeBorder {
  const _DashedBorder(this.color, [this.radius = 3]);
  final Color color;
  final double radius;
  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.all(1);
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(RRect.fromRectAndRadius(rect.deflate(1), Radius.circular(radius)));
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) => _dashed(
      canvas,
      RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
      2,
      2);
  @override
  ShapeBorder scale(double t) => this;
}
