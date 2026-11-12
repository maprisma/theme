import 'i18n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// A menu row running [action], as the plugin's menu items: a 14 px icon,
/// 13 px text, an optional icon at the end (→ for entries that open a page)
/// and a tooltip.
PopupMenuItem<VoidCallback> item(
  IconData icon,
  String label,
  VoidCallback action, {
  bool enabled = true,
  bool destructive = false,
  String? tooltip,
  IconData? end,
  Key? key,
}) {
  final row = Builder(builder: (context) {
    final look = Look.of(context);
    final color = destructive ? look.red : look.fg;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 174),
      child: Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        Flexible(
          fit: FlexFit.tight,
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w500, color: color)),
        ),
        if (end != null) ...[const SizedBox(width: 8), Icon(end, size: 14, color: color)],
      ]),
    );
  });
  return PopupMenuItem<VoidCallback>(
    key: key,
    value: action,
    enabled: enabled,
    height: 30,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: tooltip == null ? row : Tooltip(message: tooltip, child: row),
  );
}

/// The thin line between groups of menu entries (`separator.tm-menu-separator`).
PopupMenuEntry<VoidCallback> menuLine() => const _MenuLine();

class _MenuLine extends PopupMenuEntry<VoidCallback> {
  const _MenuLine();
  @override
  double get height => 7;
  @override
  bool represents(VoidCallback? value) => false;
  @override
  State<_MenuLine> createState() => _MenuLineState();
}

class _MenuLineState extends State<_MenuLine> {
  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    color: Look.of(context).muted.withValues(alpha: .6),
  );
}

/// The plugin's hint text (`.tm-hint`: muted, 14 px).
TextStyle hintStyle(BuildContext context) => Theme.of(context).textTheme.bodyMedium!.copyWith(color: Look.of(context).muted);

/// A small label (current, system, a shortcut, `ws 2 · 5`).
class Tag extends StatelessWidget {
  const Tag({super.key, required this.label, this.color});
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final c = color ?? look.muted;
    final r = cornerSizes(context).small;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(r),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelMedium!.copyWith(fontWeight: FontWeight.w600, color: c)),
    );
  }
}

/// What a tile badge says: plain (dark glass, white text), the current theme
/// (accent), a workspace (accent).
enum BadgeKind { plain, current, workspace }

/// A badge on a tile's picture (`.tm-badge.tm-tile-badge`).
class TileBadge extends StatelessWidget {
  const TileBadge(this.label, {super.key, this.kind = BadgeKind.plain, this.tooltip});
  final String label;
  final BadgeKind kind;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final r = cornerSizes(context).small;
    final (bg, fg) = switch (kind) {
      BadgeKind.current => (look.accent, look.bg),
      BadgeKind.workspace => (look.accent.withValues(alpha: .85), look.bg),
      BadgeKind.plain => (Colors.black.withValues(alpha: .6), Colors.white),
    };
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(r)),
      child: Text(label, maxLines: 1, style: Theme.of(context).textTheme.labelMedium!.copyWith(fontWeight: FontWeight.w600, color: fg, height: 1.25)),
    );
    return tooltip == null ? badge : Tooltip(message: tooltip!, child: badge);
  }
}

/// The ☰ button in a tile's top-right corner (`button.tm-tile-menu`): dark
/// glass, white icon, accent while hovered. [menuKey] lets the keyboard open it.
class TileMenuButton extends StatefulWidget {
  const TileMenuButton({super.key, required this.menu, this.menuKey, this.tooltip, this.enabled = true});
  final List<PopupMenuEntry<VoidCallback>> Function() menu;
  final GlobalKey<PopupMenuButtonState<VoidCallback>>? menuKey;
  final String? tooltip;
  final bool enabled;
  @override
  State<TileMenuButton> createState() => _TileMenuButtonState();
}

class _TileMenuButtonState extends State<TileMenuButton> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final r = cornerSizes(context).control;
    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: PopupMenuButton<VoidCallback>(
        key: widget.menuKey,
        tooltip: widget.tooltip ?? tr("Actions"),
        enabled: widget.enabled,
        padding: EdgeInsets.zero,
        position: PopupMenuPosition.under,
        itemBuilder: (_) => widget.menu(),
        onSelected: (f) => f(),
        child: Container(
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: hover ? look.accent : Colors.black.withValues(alpha: .6),
            borderRadius: BorderRadius.circular(r),
          ),
          child: Icon(Icons.menu, size: 16, color: hover ? look.bg : Colors.white),
        ),
      ),
    );
  }
}

/// A grid tile as the plugin draws wallpapers, web results and gallery
/// themes (`.tm-tile`): a faint mat with a hairline, the 16:9 picture with
/// the ☰ button and badges over it, a caption below. [selected] is the
/// keyboard focus (accent border), [lit] the add tile while something is
/// dragged over the page, [dashed] the add tile's border.
class PluginTile extends StatelessWidget {
  const PluginTile({
    super.key,
    required this.picture,
    this.caption,
    this.captionText,
    this.menu,
    this.topLeft = const [],
    this.bottomLeft = const [],
    this.selected = false,
    this.lit = false,
    this.dashed = false,
    this.dimmed = false,
    this.onTap,
    this.onSecondaryTap,
    this.onHover,
    this.tooltip,
  });
  final Widget picture;
  final Widget? caption;
  final String? captionText;
  final Widget? menu;
  final List<Widget> topLeft, bottomLeft;
  final bool selected, lit, dashed, dimmed;
  final VoidCallback? onTap, onSecondaryTap, onHover;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final r = corners(context);
    final on = selected || lit;
    final border = on ? look.accent : look.fg.withValues(alpha: .22);
    final fill = on ? look.accent.withValues(alpha: .12) : look.fg.withValues(alpha: .08);
    Widget tile = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(r),
        border: dashed ? null : Border.all(color: border, width: on ? 1.5 : 1),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(r == 0 ? 0 : math.max(2, r - 4)),
            child: Stack(fit: StackFit.expand, children: [
              picture,
              if (topLeft.isNotEmpty)
                Positioned(top: 6, left: 6, child: Wrap(spacing: 4, runSpacing: 4, children: topLeft)),
              if (bottomLeft.isNotEmpty)
                Positioned(left: 6, bottom: 6, right: 6, child: Wrap(spacing: 4, runSpacing: 4, children: bottomLeft)),
              if (menu != null) Positioned(top: 0, right: 0, child: menu!),
            ]),
          ),
        ),
        const SizedBox(height: 4),
        caption ??
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(captionText ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: look.muted)),
            ),
        const SizedBox(height: 4),
      ]),
    );
    if (dashed) {
      tile = CustomPaint(
        foregroundPainter: DashedBorder(color: on ? look.accent : look.fg.withValues(alpha: .3), radius: r),
        child: tile,
      );
    }
    tile = Opacity(opacity: dimmed ? .45 : 1, child: tile);
    tile = MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      onHover: onHover == null ? null : (_) => onHover!(),
      child: GestureDetector(onTap: onTap, onSecondaryTap: onSecondaryTap, behavior: HitTestBehavior.opaque, child: tile),
    );
    return tooltip == null ? tile : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 700), child: tile);
  }
}

/// A rounded dashed outline (`.tm-add-tile`: 2 px dashed).
class DashedBorder extends CustomPainter {
  DashedBorder({required this.color, required this.radius});
  final Color color;
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)).deflate(1));
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, math.min(d + 5, metric.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(DashedBorder oldDelegate) => oldDelegate.color != color || oldDelegate.radius != radius;
}

/// Columns of the grids as in the plugin: about 320 px each, at least two,
/// at most four (a wider window gets larger tiles, not more).
int gridColumns(double width) => ((width + 8) ~/ 320).clamp(2, 4);

/// Tiles in [columns] columns, each row as tall as its tallest tile (the
/// plugin's FlowBox), built lazily row by row.
class TileGrid extends StatelessWidget {
  const TileGrid({
    super.key,
    required this.count,
    required this.columns,
    required this.builder,
    this.controller,
    this.spacing = 8,
    this.footer,
    this.padding = EdgeInsets.zero,
  });
  final int count, columns;
  final IndexedWidgetBuilder builder;
  final ScrollController? controller;
  final double spacing;
  final Widget? footer;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final rows = (count + columns - 1) ~/ columns;
    return ListView.builder(
      controller: controller,
      padding: padding,
      itemCount: rows + (footer == null ? 0 : 1),
      itemBuilder: (context, row) {
        if (row >= rows) return footer!;
        return Padding(
          padding: EdgeInsets.only(bottom: spacing),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var c = 0; c < columns; c++) ...[
              if (c > 0) SizedBox(width: spacing),
              Expanded(child: row * columns + c < count ? builder(context, row * columns + c) : const SizedBox()),
            ],
          ]),
        );
      },
    );
  }
}

/// A button as the plugin's outlined ones (`button.tm-paste`): an accent
/// icon and a label.
class OutlineAction extends StatelessWidget {
  const OutlineAction({super.key, required this.label, this.icon, this.onPressed, this.tooltip});
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final b = icon == null
        ? OutlinedButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton.icon(onPressed: onPressed, icon: Icon(icon, size: 16), label: Text(label));
    return tooltip == null ? b : Tooltip(message: tooltip!, child: b);
  }
}

/// A theme drawn from its colors: background, a text line, the accent and
/// the terminal colors (tiles without a preview, Ask AI candidates).
class ColorPreview extends StatelessWidget {
  const ColorPreview({super.key, required this.colors, this.title});
  final Map colors;
  final String? title;
  @override
  Widget build(BuildContext context) {
    final bg = hexColor(colors, 'background') ?? Colors.black;
    final fg = hexColor(colors, 'foreground') ?? Colors.white;
    final accent = hexColor(colors, 'accent') ?? fg;
    final swatch = [for (final k in ['red', 'green', 'yellow', 'blue', 'magenta', 'cyan']) hexColor(colors, k) ?? fg];
    return Container(
      color: bg,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(title ?? '~ \$ ls', style: TextStyle(color: fg, fontFamily: 'monospace', fontSize: 12), maxLines: 1)),
          ]),
          const SizedBox(height: 6),
          Container(height: 3, width: 60, color: accent),
          const Spacer(),
          Row(children: [for (final c in swatch) Expanded(child: Container(height: 10, color: c))]),
        ],
      ),
    );
  }
}

/// A confirmation as the plugin's (a question, a muted note, Cancel and a
/// red action button that has the keyboard).
Future<bool> confirm(BuildContext context, String title, String body, {String? action, bool danger = true}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) {
        final look = Look.of(context);
        return AlertDialog(
          title: Text(title, style: textRole(Theme.of(context).textTheme.titleLarge).copyWith(fontWeight: FontWeight.w600)),
          content: body.isEmpty ? null : Text(body, style: hintStyle(context)),
          actions: [
            OutlinedButton(onPressed: () => Navigator.pop(context, false), child: Text(tr("Cancel"))),
            FilledButton(
              autofocus: true,
              style: danger ? FilledButton.styleFrom(backgroundColor: look.red, foregroundColor: Theme.of(context).colorScheme.onError) : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(action ?? tr('OK')),
            ),
          ],
        );
      },
    ) ??
    false;

/// Workspaces 1–10 to tick; null when cancelled.
Future<Set<int>?> pickWorkspaces(BuildContext context, String title, Set<int> initial) => showDialog<Set<int>>(
  context: context,
  builder: (context) {
    final picked = {...initial};
    return StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 1; i <= 10; i++)
              FilterChip(
                label: Text('$i'),
                selected: picked.contains(i),
                onSelected: (on) => setState(() => on ? picked.add(i) : picked.remove(i)),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr("Cancel"))),
          FilledButton(onPressed: () => Navigator.pop(context, picked), child: Text(tr("Save"))),
        ],
      ),
    );
  },
);

/// The plugin's workspace menu (a popover where the ☰ button is):
/// workspaces 1–10 in two rows of five, ✓ on the ones that already use
/// this, the other owner's name (dimmed) on the others. Returns the
/// workspace clicked, 0 for [clearLabel], null when closed.
Future<int?> showWorkspaceMenu(
  BuildContext context, {
  required Rect anchor,
  required String title,
  required Set<int> mine,
  Map<int, String> others = const {},
  String? clearLabel,
  String Function(int ws)? tooltipOf,
  bool namesOthers = true,
}) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<int>(
    context: context,
    position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
    items: [
      _WorkspaceGrid(title: title, mine: mine, others: others, tooltipOf: tooltipOf, namesOthers: namesOthers),
      if (clearLabel != null) ...[
        const PopupMenuDivider(height: 7),
        PopupMenuItem<int>(
          value: 0,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            const Icon(Icons.clear_all, size: 14),
            const SizedBox(width: 8),
            Text(clearLabel, style: textRole(Theme.of(context).textTheme.labelLarge).copyWith(fontWeight: FontWeight.w500)),
          ]),
        ),
      ],
    ],
  );
}

class _WorkspaceGrid extends PopupMenuEntry<int> {
  const _WorkspaceGrid({required this.title, required this.mine, required this.others, this.tooltipOf, this.namesOthers = true});
  final bool namesOthers;
  final String title;
  final Set<int> mine;
  final Map<int, String> others;
  final String Function(int ws)? tooltipOf;
  @override
  double get height => 90;
  @override
  bool represents(int? value) => false;
  @override
  State<_WorkspaceGrid> createState() => _WorkspaceGridState();
}

class _WorkspaceGridState extends State<_WorkspaceGrid> {
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final r = cornerSizes(context).control;
    Widget cell(int ws) {
      final mine = widget.mine.contains(ws);
      final other = widget.others[ws];
      final text = '${mine ? '✓ ' : ''}$ws${other != null && widget.namesOthers ? ' · $other' : ''}';
      final button = InkWell(
        autofocus: ws == 1,
        borderRadius: BorderRadius.circular(r),
        focusColor: look.selection,
        hoverColor: look.selection.withValues(alpha: .6),
        onTap: () => Navigator.pop(context, ws),
        child: Container(
          height: 30,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                fontWeight: mine ? FontWeight.w700 : FontWeight.w500,
                color: mine ? look.accent : other != null ? look.muted : look.fg,
              )),
        ),
      );
      final tip = widget.tooltipOf?.call(ws) ?? (other != null ? trf("Replaces {0}", [other]) : null);
      return Expanded(child: tip == null ? button : Tooltip(message: tip, child: button));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
          child: Text(widget.title, style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: look.muted)),
        ),
        SizedBox(
          width: widget.others.isEmpty || !widget.namesOthers ? 230 : 360,
          child: Column(children: [
            Row(children: [for (var ws = 1; ws <= 5; ws++) cell(ws)]),
            const SizedBox(height: 4),
            Row(children: [for (var ws = 6; ws <= 10; ws++) cell(ws)]),
          ]),
        ),
      ]),
    );
  }
}

/// The global rectangle of the widget behind [key] (to open a menu there).
Rect? rectOf(GlobalKey key) {
  final box = key.currentContext?.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// "← Back · ⌫" as in Maprisma: accent text, no border.
class PluginBackButton extends StatelessWidget {
  const PluginBackButton({super.key, this.tooltip, this.onPressed});
  final String? tooltip;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    return Tooltip(
      message: tooltip ?? tr("Back (Backspace, Esc)"),
      child: TextButton(
        onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
        style: TextButton.styleFrom(
          foregroundColor: look.accent,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: const Size(0, 28),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.chevron_left, size: 18),
          SizedBox(width: 4),
          Text(tr("Back"), style: textRole(Theme.of(context).textTheme.labelLarge)),
          SizedBox(width: 8),
          Text('· ⌫', style: textRole(Theme.of(context).textTheme.labelLarge)),
        ]),
      ),
    );
  }
}

/// Whether the keyboard is in a text field right now.
bool typingInTextField() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// A page under the main header, as the plugin's: "← Back · ⌫" and the
/// page's title — an uppercase section title over a thin rule (Settings,
/// Information, Presets, Ask AI) or, with [section] false, the larger title
/// of the wallpaper and import pages. Esc goes back; Backspace too unless a
/// text field has the keyboard (keys the page handles itself come first).
class SubPage extends StatelessWidget {
  const SubPage({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.floating,
    this.section = true,
    this.backTooltip,
  });
  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? floating;
  final bool section;
  final String? backTooltip;

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    return Focus(
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        final esc = e.logicalKey == LogicalKeyboardKey.escape;
        final back = e.logicalKey == LogicalKeyboardKey.backspace && !typingInTextField();
        if (!esc && !back) return KeyEventResult.ignored;
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      },
      child: Scaffold(
        backgroundColor: look.bg,
        floatingActionButton: floating,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            PluginBackButton(tooltip: backTooltip ?? tr("Back to themes (Backspace, Esc)")),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                section ? title.toUpperCase() : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: section
                    ? TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: look.fg)
                    : Theme.of(context).textTheme.titleLarge!.copyWith(fontWeight: FontWeight.w600, color: look.fg),
              ),
            ),
            ...actions,
          ]),
          if (section) ...[const SizedBox(height: 8), const Divider(height: 1)],
          const SizedBox(height: 8),
          Expanded(child: body),
        ]),
      ),
    );
  }
}
