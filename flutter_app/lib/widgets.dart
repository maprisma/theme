import 'package:flutter/material.dart';

import 'theme.dart';

/// A menu row running [action].
PopupMenuItem<VoidCallback> item(IconData icon, String label, VoidCallback action, {bool enabled = true}) =>
    PopupMenuItem<VoidCallback>(
      value: action,
      enabled: enabled,
      child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)]),
    );

/// A small label (current, built-in, a shortcut, `ws 2 · 5`).
class Tag extends StatelessWidget {
  const Tag({super.key, required this.label, this.color});
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: c)),
    );
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

Future<bool> confirm(BuildContext context, String title, String body, {String action = 'OK'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, picked), child: const Text('Save')),
        ],
      ),
    );
  },
);

/// A page body with a back button title and Esc/Backspace going back.
class SubPage extends StatelessWidget {
  const SubPage({super.key, required this.title, required this.body, this.actions = const [], this.floating});
  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? floating;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title), actions: [...actions, const SizedBox(width: 6)]),
    body: body,
    floatingActionButton: floating,
  );
}
