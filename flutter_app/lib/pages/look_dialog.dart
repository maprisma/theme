import '../i18n.dart';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../theme.dart' show cornerSizes;
import 'editor_page.dart' show pickColor;

/// WCAG contrast ratio of two #rrggbb colours (1..21).
double contrastRatio(String a, String b) {
  double lum(String hex) {
    final v = int.parse(hex.substring(1), radix: 16);
    double ch(int c) {
      final s = c / 255;
      return s <= .03928 ? s / 12.92 : math.pow((s + .055) / 1.055, 2.4).toDouble();
    }

    return .2126 * ch(v >> 16 & 255) + .7152 * ch(v >> 8 & 255) + .0722 * ch(v & 255);
  }

  final x = lum(a), y = lum(b);
  return (math.max(x, y) + .05) / (math.min(x, y) + .05);
}

/// Below this the text is hard to read on the theme's background.
const minTextContrast = 3.0;

/// Font & effects for any theme (docs/theme-looks.md): the monospace font,
/// the interface font, blur and the text colour, each "Theme default" or a
/// value of its own.
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

  /// null: the theme's own foreground; else #rrggbb.
  late String? textColor = widget.look['text_color'] as String?;

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

  Map<String, dynamic> get _edited => {
    if (mono != null) 'mono_font': mono,
    if (ui != null) 'ui_font': ui,
    if (blur != null) 'blur': blur,
    if (textColor != null) 'text_color': textColor,
  };

  Map get _textInfo => widget.data['text_color'] as Map? ?? const {};
  String get _themeText => (_textInfo['theme'] as String?) ?? '#ffffff';
  String get _background => (_textInfo['background'] as String?) ?? '#000000';
  static Color _c(String hex) => Color(0xff000000 | int.parse(hex.substring(1), radix: 16));

  /// Text colour: a swatch that opens the picker, Theme's own back, a contrast
  /// warning, and a preview on the theme's background.
  Widget _textColorRow(TextStyle? small) {
    final shown = textColor ?? _themeText;
    final ratio = contrastRatio(shown, _background);
    final look = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _Row(
        label: tr("Text colour"),
        tip: tr("The main text colour of the desktop, terminals and editors with this theme"),
        child: Row(children: [
          Tooltip(
            message: tr("Choose a text colour"),
            child: InkWell(
              key: const ValueKey('look-text-color'),
              borderRadius: BorderRadius.circular(cornerSizes(context).small),
              onTap: () async {
                final picked = await pickColor(context, shown, tr("Text colour"));
                if (picked != null && mounted) setState(() => textColor = picked.toLowerCase() == _themeText.toLowerCase() ? null : picked.toLowerCase());
              },
              child: Container(
                width: 36,
                height: 24,
                decoration: BoxDecoration(
                  color: _c(shown),
                  borderRadius: BorderRadius.circular(cornerSizes(context).small),
                  border: Border.all(color: look.colorScheme.outline),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(textColor == null ? trf("Theme's own ({0})", [_themeText]) : textColor!, style: small),
          const SizedBox(width: 8),
          if (textColor != null)
            TextButton(
              key: const ValueKey('look-text-color-reset'),
              onPressed: () => setState(() => textColor = null),
              child: Text(tr("Theme's own")),
            ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 160, bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            key: const ValueKey('look-text-preview'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(color: _c(_background), borderRadius: BorderRadius.circular(cornerSizes(context).control)),
            child: Text(tr("The quick brown fox jumps over the lazy dog"), style: TextStyle(color: _c(shown))),
          ),
          if (ratio < minTextContrast)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                trf("Hard to read: contrast {0}:1 with the background (at least 3:1 is advised)", [ratio.toStringAsFixed(1)]),
                key: const ValueKey('look-text-contrast'),
                style: small?.copyWith(color: look.colorScheme.error),
              ),
            ),
        ]),
      ),
    ]);
  }

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
                tr("Used whenever this theme is applied; the theme files stay as they are. Themes without a choice give your own fonts and blur back and show their own text colour."),
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
              _textColorRow(small),
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
            onPressed: saving || !_changed ? null : _submit,
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
    padding: const EdgeInsets.symmetric(vertical: 8),
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
