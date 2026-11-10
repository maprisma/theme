import '../i18n.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';

/// Font & effects for any theme (docs/theme-looks.md): the monospace font,
/// the interface font and blur, each "Theme default" or a value of its own.
/// Saved in looks.json, with Undo. One button, Apply (as in the Omarchy plugin):
/// enabled once something changed; it stores the look, and the theme in use
/// gets it on the desktop at once.
Future<void> lookDialog(BuildContext context, MaprismaThemeAppState app, String slug) async {
  final data = await app.run('looks.get', {'slug': slug});
  if (data == null || !context.mounted) return;
  final caps = {...(data['caps'] as List? ?? const []).cast<String>()};
  final look = Map<String, dynamic>.from(data['look'] as Map? ?? const {});
  // saved from inside the dialog: it closes only when the save worked
  final r = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (context) => _LookDialog(
      data: data,
      caps: caps,
      look: look,
      save: (result, apply) => app.run('looks.set', {'slug': slug, 'look': result, 'apply': apply}),
    ),
  );
  if (r == null || !context.mounted) return;
  final previous = r['previous'];
  final name = data['name'] ?? slug;
  final applied = data['in_use'] == true;
  app.notify(
    applied ? tr("Font & effects saved and applied") : trf("Font & effects saved for {0}", [name]),
    // Undo puts the look back as it was, also a font no longer installed (applied again only
    // when the change was applied)
    undo: previous is Map ? () => app.run('looks.set', {'slug': slug, 'look': previous, 'restore': true, 'apply': applied}) : null,
  );
  app.changed(); // the menu's Reapply follows what is pending
}

class _LookDialog extends StatefulWidget {
  const _LookDialog({required this.data, required this.caps, required this.look, required this.save});
  final Map<String, dynamic> data;
  final Set<String> caps;
  final Map<String, dynamic> look;

  /// looks.set (apply: whether the theme in use gets it now); null when it
  /// failed (the app has said why).
  final Future<Map<String, dynamic>?> Function(Map<String, dynamic> look, bool apply) save;

  @override
  State<_LookDialog> createState() => _LookDialogState();
}

class _LookDialogState extends State<_LookDialog> {
  late String? mono = widget.look['mono_font'] as String?;
  late String? ui = widget.look['ui_font'] as String?;

  /// null: the theme's default; else {on, strength}.
  late Map<String, dynamic>? blur = widget.look['blur'] is Map ? Map<String, dynamic>.from(widget.look['blur'] as Map) : null;

  bool saving = false;
  final _menus = {'mono_font': MenuController(), 'ui_font': MenuController()};
  final _fields = {'mono_font': FocusNode(), 'ui_font': FocusNode()};
  final _saveFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    for (final f in [..._fields.values, _saveFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  /// Esc closes an open font list first, then the dialog; a font field
  /// would otherwise keep Esc for itself.
  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) return false;
    if (_menus.values.any((m) => m.isOpen)) return false;
    if (_fields.values.any((f) => f.hasFocus) && mounted) {
      Navigator.of(context).pop();
      return true;
    }
    return false;
  }

  Map<String, dynamic> get _edited => {if (mono != null) 'mono_font': mono, if (ui != null) 'ui_font': ui, if (blur != null) 'blur': blur};

  /// A field differs from the stored look.
  bool get _changed {
    final now = _edited, then = widget.look;
    final keys = {...now.keys, ...then.keys};
    return keys.any((k) => jsonEncode(now[k]) != jsonEncode(then[k]));
  }

  bool get _inUse => widget.data['in_use'] == true;

  /// Apply: stores the change; the theme in use gets it at once.
  Future<void> _submit() async {
    setState(() => saving = true);
    final r = await widget.save(_edited, _inUse);
    if (!mounted) return;
    if (r == null) {
      setState(() => saving = false); // the edits stay for another try
    } else {
      Navigator.of(context).pop(r);
    }
  }

  Map get _theme => widget.data['theme'] as Map? ?? const {};
  Map get _own => widget.data['own'] as Map? ?? const {};
  Map get _blurInfo => widget.data['blur'] as Map? ?? const {};

  List<String> _fonts(String key) => [...((widget.data['fonts'] as Map?)?[key] as List? ?? const []).cast<String>()];

  /// What "Theme default" means for a font: the theme's, else the user's own.
  String _defaultFont(String key) {
    final t = _theme[key];
    if (t is String) return trf("Theme default ({0})", [t]);
    final own = _own[key];
    return own is String ? trf("Theme default (yours: {0})", [own]) : tr("Theme default (desktop font)");
  }

  String _defaultBlur() {
    final t = _blurInfo['theme'], own = _blurInfo['own'];
    String describe(Object? b) => b is Map ? (b['on'] == true ? trf('on, {0}', [b['strength']]) : tr('off')) : tr('unknown');
    return t is Map ? trf("Theme default ({0})", [describe(t)]) : trf("Theme default (yours, {0})", [describe(own)]);
  }

  Widget _fontRow(String key, String label, String tip, String? value, ValueChanged<String?> onChanged) {
    final fonts = _fonts(key);
    final missing = value != null && !fonts.contains(value);
    return _Row(
      label: label,
      tip: tip,
      child: Semantics(
        label: label,
        container: true,
        child: DropdownMenu<String?>(
          key: ValueKey('look-$key'),
          width: 320,
          menuHeight: 360,
          textStyle: Theme.of(context).textTheme.bodyMedium,
          menuController: _menus[key],
          focusNode: _fields[key],
          initialSelection: value,
          enableFilter: true,
          requestFocusOnTap: true,
          hintText: _defaultFont(key),
          inputDecorationTheme: const InputDecorationTheme(isDense: true),
          dropdownMenuEntries: [
            DropdownMenuEntry<String?>(value: null, label: _defaultFont(key)),
            // a saved font no longer installed stays until another is chosen
            if (missing) DropdownMenuEntry<String?>(value: value, label: trf("{0} (not installed)", [value])),
            for (final f in fonts) DropdownMenuEntry<String?>(value: f, label: f),
          ],
          onSelected: (v) {
            onChanged(v);
            _saveFocus.requestFocus(); // Esc and Enter belong to the dialog again
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final b = blur;
    return AlertDialog(
      title: Text(trf("Font & effects · {0}", [widget.data['name'] ?? widget.data['slug']])),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr("Used whenever this theme is applied; the theme files stay as they are. Themes without a choice give your own fonts and blur back."),
                style: small,
              ),
              const SizedBox(height: 12),
              if (widget.caps.contains('mono_font'))
                _fontRow('mono_font', tr("Monospace font"), tr("Terminals and editors"), mono, (v) => setState(() => mono = v)),
              if (widget.caps.contains('ui_font'))
                _fontRow('ui_font', tr("Interface font"), tr("Menus, panels, window titles and app texts"), ui, (v) => setState(() => ui = v)),
              if (widget.caps.contains('blur')) ...[
                _Row(
                  label: tr("Blur"),
                  tip: tr("Behind see-through panels, menus and windows"),
                  child: Semantics(
                    label: tr("Blur"),
                    container: true,
                    child: SegmentedButton<String>(
                      key: const ValueKey('look-blur'),
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: 'default', label: Text(tr("Theme default"))),
                        ButtonSegment(value: 'on', label: Text(tr("On"))),
                        ButtonSegment(value: 'off', label: Text(tr("Off"))),
                      ],
                      selected: {b == null ? 'default' : (b['on'] == true ? 'on' : 'off')},
                      onSelectionChanged: (s) => setState(() {
                        final strength = (b?['strength'] as int?) ?? ((_blurInfo['current'] as Map?)?['strength'] as int?) ?? 8;
                        blur = switch (s.first) {
                          'on' => {'on': true, 'strength': strength},
                          'off' => {'on': false, 'strength': strength},
                          _ => null,
                        };
                      }),
                    ),
                  ),
                ),
                if (b == null)
                  Padding(
                    padding: const EdgeInsets.only(left: 160, bottom: 8),
                    child: Text(_defaultBlur(), style: small),
                  ),
                if (b != null && b['on'] == true)
                  _Row(
                    label: tr("Strength"),
                    tip: tr("From light (1) to strong (15)"),
                    child: Row(
                      children: [
                        Expanded(
                          child: Slider(
                            key: const ValueKey('look-strength'),
                            min: 1,
                            max: 15,
                            divisions: 14,
                            value: (b['strength'] as int).toDouble(),
                            label: '${b['strength']}',
                            semanticFormatterCallback: (v) => trf("Blur strength {0} of 15", [v.round()]),
                            onChanged: (v) => setState(() => blur = {'on': true, 'strength': v.round()}),
                          ),
                        ),
                        SizedBox(width: 28, child: Text('${b['strength']}', textAlign: TextAlign.end)),
                      ],
                    ),
                  ),
              ],
              if (widget.caps.isEmpty) Text(tr("This desktop has no fonts or blur Maprisma Theme can change."), style: small),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr("Cancel"))),
        Tooltip(
          message: _inUse
              ? tr("Saves the change and puts it on the desktop now")
              : tr("Saves the change; it is used whenever this theme is applied"),
          child: FilledButton(
            key: const ValueKey('look-save'),
            focusNode: _saveFocus,
            onPressed: widget.caps.isEmpty || saving || !_changed ? null : _submit,
            child: Text(tr("Apply")),
          ),
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
    child: Row(
      children: [
        SizedBox(
          width: 160,
          child: Tooltip(message: tip, child: Text(label)),
        ),
        Expanded(
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
      ],
    ),
  );
}
