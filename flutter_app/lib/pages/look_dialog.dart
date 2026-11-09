import 'package:flutter/material.dart';

import '../app.dart';

/// Font & effects for any theme (docs/theme-looks.md): the monospace font,
/// the interface font and blur, each "Theme default" or a value of its own.
/// Saved in looks.json; the theme in use gets it at once, with Undo.
Future<void> lookDialog(BuildContext context, MaprismaThemeAppState app, String slug) async {
  final data = await app.run('looks.get', {'slug': slug});
  if (data == null || !context.mounted) return;
  final caps = {...(data['caps'] as List? ?? const []).cast<String>()};
  final look = Map<String, dynamic>.from(data['look'] as Map? ?? const {});
  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (context) => _LookDialog(data: data, caps: caps, look: look),
  );
  if (result == null || !context.mounted) return;
  final r = await app.run('looks.set', {'slug': slug, 'look': result});
  if (r == null) return;
  final previous = r['previous'];
  final name = data['name'] ?? slug;
  app.notify(
    data['in_use'] == true ? 'Font & effects applied' : 'Font & effects saved for $name',
    undo: previous is Map ? () => app.run('looks.set', {'slug': slug, 'look': previous}) : null,
  );
}

class _LookDialog extends StatefulWidget {
  const _LookDialog({required this.data, required this.caps, required this.look});
  final Map<String, dynamic> data;
  final Set<String> caps;
  final Map<String, dynamic> look;

  @override
  State<_LookDialog> createState() => _LookDialogState();
}

class _LookDialogState extends State<_LookDialog> {
  late String? mono = widget.look['mono_font'] as String?;
  late String? ui = widget.look['ui_font'] as String?;

  /// null: the theme's default; else {on, strength}.
  late Map<String, dynamic>? blur =
      widget.look['blur'] is Map ? Map<String, dynamic>.from(widget.look['blur'] as Map) : null;

  Map get _theme => widget.data['theme'] as Map? ?? const {};
  Map get _own => widget.data['own'] as Map? ?? const {};
  Map get _blurInfo => widget.data['blur'] as Map? ?? const {};

  List<String> _fonts(String key) => [...((widget.data['fonts'] as Map?)?[key] as List? ?? const []).cast<String>()];

  /// What "Theme default" means for a font: the theme's, else the user's own.
  String _defaultFont(String key) {
    final t = _theme[key];
    if (t is String) return 'Theme default ($t)';
    final own = _own[key];
    return own is String ? 'Theme default (yours: $own)' : 'Theme default (desktop font)';
  }

  String _defaultBlur() {
    final t = _blurInfo['theme'], own = _blurInfo['own'];
    String describe(Object? b) => b is Map ? (b['on'] == true ? 'on, ${b['strength']}' : 'off') : 'unknown';
    return t is Map ? 'Theme default (${describe(t)})' : 'Theme default (yours, ${describe(own)})';
  }

  Widget _fontRow(String key, String label, String tip, String? value, ValueChanged<String?> onChanged) {
    final fonts = _fonts(key);
    return _Row(
      label: label,
      tip: tip,
      child: DropdownMenu<String?>(
        key: ValueKey('look-$key'),
        width: 320,
        menuHeight: 360,
        textStyle: Theme.of(context).textTheme.bodyMedium,
        initialSelection: fonts.contains(value) ? value : null,
        enableFilter: true,
        requestFocusOnTap: true,
        hintText: _defaultFont(key),
        inputDecorationTheme: const InputDecorationTheme(isDense: true),
        dropdownMenuEntries: [
          DropdownMenuEntry<String?>(value: null, label: _defaultFont(key)),
          for (final f in fonts) DropdownMenuEntry<String?>(value: f, label: f),
        ],
        onSelected: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final b = blur;
    return AlertDialog(
      title: Text('Font & effects · ${widget.data['name'] ?? widget.data['slug']}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Used whenever this theme is applied; the theme files stay as they are. '
              'Themes without a choice give your own fonts and blur back.',
              style: small,
            ),
            const SizedBox(height: 12),
            if (widget.caps.contains('mono_font'))
              _fontRow('mono_font', 'Monospace font', 'Terminals and editors', mono, (v) => setState(() => mono = v)),
            if (widget.caps.contains('ui_font'))
              _fontRow('ui_font', 'Interface font', 'Menus, panels, window titles and app texts', ui, (v) => setState(() => ui = v)),
            if (widget.caps.contains('blur')) ...[
              _Row(
                label: 'Blur',
                tip: 'Behind see-through panels, menus and windows',
                child: SegmentedButton<String>(
                  key: const ValueKey('look-blur'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'default', label: Text('Theme default')),
                    ButtonSegment(value: 'on', label: Text('On')),
                    ButtonSegment(value: 'off', label: Text('Off')),
                  ],
                  selected: {b == null ? 'default' : (b['on'] == true ? 'on' : 'off')},
                  onSelectionChanged: (s) => setState(() {
                    final strength = (b?['strength'] as int?) ??
                        ((_blurInfo['current'] as Map?)?['strength'] as int?) ??
                        8;
                    blur = switch (s.first) {
                      'on' => {'on': true, 'strength': strength},
                      'off' => {'on': false, 'strength': strength},
                      _ => null,
                    };
                  }),
                ),
              ),
              if (b == null)
                Padding(padding: const EdgeInsets.only(left: 160, bottom: 8), child: Text(_defaultBlur(), style: small)),
              if (b != null && b['on'] == true)
                _Row(
                  label: 'Strength',
                  tip: 'From light (1) to strong (15)',
                  child: Row(children: [
                    Expanded(
                      child: Slider(
                        key: const ValueKey('look-strength'),
                        min: 1,
                        max: 15,
                        divisions: 14,
                        value: (b['strength'] as int).toDouble(),
                        label: '${b['strength']}',
                        onChanged: (v) => setState(() => blur = {'on': true, 'strength': v.round()}),
                      ),
                    ),
                    SizedBox(width: 28, child: Text('${b['strength']}', textAlign: TextAlign.end)),
                  ]),
                ),
            ],
            if (widget.caps.isEmpty) Text('This desktop has no fonts or blur Maprisma Theme can change.', style: small),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('look-save'),
          onPressed: widget.caps.isEmpty
              ? null
              : () => Navigator.pop(context, {
                    if (mono != null) 'mono_font': mono,
                    if (ui != null) 'ui_font': ui,
                    if (blur != null) 'blur': blur,
                  }),
          child: Text(widget.data['in_use'] == true ? 'Apply' : 'Save'),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.tip, required this.child});
  final String label, tip;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [
      SizedBox(
        width: 160,
        child: Tooltip(message: tip, child: Text(label)),
      ),
      Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
    ]),
  );
}
