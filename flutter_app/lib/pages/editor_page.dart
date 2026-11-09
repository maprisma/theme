import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart' show ServiceError, baseColorKeys, colorLabel, derivedColors, maxNameLength;

import '../app.dart';
import '../widgets.dart';

final _hexRe = RegExp(r'^#[0-9a-fA-F]{6}$');

/// From this window width the sample sits large on the left of the controls.
const _wideFrom = 900.0;

Color _color(String hex) => Color(0xff000000 | int.parse(hex.substring(1), radix: 16));

String _hexOf(Color c) => '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';

/// Theme editor (the plugin's editor page): name, colors (picker or
/// #rrggbb), font, the base's wallpapers, and a sample window in the colors
/// and font being edited.
/// [base]: new theme from this theme; [edit]: edit this custom theme;
/// [wallpaper]: new theme from this picture (a file); [initial]: preset
/// values (Ask AI: `name`, `font`, and color keys as #rrggbb), on top of [base];
/// [askWallpaper]: the picture on the Ask AI card (its cached thumbnail), shown
/// behind the sample; the Ask page adds it to the saved theme, so the base's
/// own wallpapers are only an extra then (off by default). [initialBlur]: the
/// card's blur ({on, strength}). [fromAsk]: a new theme from an Ask AI card —
/// its base is internal, so the title is the card's name and nothing names the
/// base (the card's picture, else the base's wallpapers, come without a row).
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    this.base,
    this.edit,
    this.wallpaper,
    this.initial,
    this.askWallpaper,
    this.initialBlur,
    this.fromAsk = false,
  });
  final String? base, edit, wallpaper, askWallpaper;
  final Map<String, String>? initial;
  final Map<String, dynamic>? initialBlur;
  final bool fromAsk;
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  Map<String, dynamic>? data;
  String? loadError;
  final colors = <String, String>{};
  final labels = <String, String>{};

  /// Shades picked by hand: they no longer follow their base color.
  final edited = <String>{};
  final hex = <String, TextEditingController>{};
  final name = TextEditingController();
  final pageFocus = FocusNode();
  final nameFocus = FocusNode();
  List<String> fonts = [];
  String? font;

  /// null: keep the blur in use; else {on, strength 1..15}.
  Map<String, dynamic>? blur;
  bool copyWallpapers = true, saving = false;
  String hint = '';

  bool get editing => widget.edit != null;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in hex.values) {
      c.dispose();
    }
    name.dispose();
    pageFocus.dispose();
    nameFocus.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final app = AppScope.read(context);
    Map<String, dynamic> d;
    try {
      d = await app.call('custom.editor', {
        if (widget.base != null) 'base': widget.base,
        if (widget.edit != null) 'edit': widget.edit,
        if (widget.wallpaper != null) 'wallpaper': widget.wallpaper,
      });
    } catch (e) {
      if (mounted) setState(() => loadError = 'Could not read the colors: ${_reason(e)}');
      return;
    }
    if (!mounted) return;
    setState(() {
      data = d;
      colors.addAll(Map<String, String>.from(d['colors'] as Map));
      labels.addAll(Map<String, String>.from(d['labels'] as Map));
      edited.addAll(List<String>.from(d['own_shades'] as List? ?? const []));
      for (final e in colors.entries) {
        hex[e.key] = TextEditingController(text: e.value);
      }
      fonts = List<String>.from(d['fonts'] as List);
      font = d['font'] as String?;
      if (!fonts.contains(font)) font = null;
      blur = d['blur'] is Map ? Map<String, dynamic>.from(d['blur'] as Map) : null;
      copyWallpapers = d['copy_wallpapers'] == true && widget.askWallpaper == null;
      name.text = d['name'] as String? ?? '';
      _takeInitial();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (editing) {
        pageFocus.requestFocus();
      } else {
        nameFocus.requestFocus();
        name.selection = TextSelection(baseOffset: 0, extentOffset: name.text.length);
      }
    });
  }

  /// Ask AI's values on top of the loaded ones: base colors first, so the
  /// shades it names itself win.
  void _takeInitial() {
    final initial = widget.initial;
    if (initial == null) return;
    final n = initial['name']?.trim();
    if (n != null && n.isNotEmpty) name.text = n.length > maxNameLength ? n.substring(0, maxNameLength) : n;
    final f = initial['font'];
    if (f != null && fonts.contains(f)) font = f;
    final b = widget.initialBlur;
    if (b != null && b['on'] is bool && b['strength'] is int) blur = Map<String, dynamic>.of(b);
    final keys = initial.keys.where(colors.containsKey).toList()
      ..sort((a, b) => (baseColorKeys.contains(a) ? 0 : 1).compareTo(baseColorKeys.contains(b) ? 0 : 1));
    for (final k in keys) {
      final v = initial[k]!;
      if (_hexRe.hasMatch(v)) _set(k, v.toLowerCase());
    }
  }

  String _reason(Object e) => e is ServiceError ? (e.reason ?? e.code.replaceAll('_', ' ')) : errorText(e);

  /// Changes one color (set_editor_color): a base color also moves the
  /// shades and bright variants not picked by hand.
  void _set(String key, String value) {
    colors[key] = value;
    if (baseColorKeys.contains(key)) {
      derivedColors(colors).forEach((k, v) {
        if (!edited.contains(k) && colors.containsKey(k)) colors[k] = v;
      });
    } else {
      edited.add(key);
    }
    for (final e in hex.entries) {
      final want = colors[e.key]!;
      if (e.value.text.toLowerCase() != want) e.value.text = want;
    }
  }

  /// From a hex field or the picker; false (and a hint) when it is not a color.
  bool setColor(String key, String text) {
    var value = text.trim().toLowerCase();
    if (!value.startsWith('#')) value = '#$value';
    if (value == colors[key]) return true;
    if (!_hexRe.hasMatch(value)) {
      setState(() {
        hint = '“${text.trim()}” is not a color: use #rrggbb, e.g. #3a6ea5.';
        hex[key]!.text = colors[key]!;
      });
      return false;
    }
    setState(() {
      hint = '';
      _set(key, value);
    });
    return true;
  }

  Future<void> pick(String key) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _ColorPickerDialog(initial: colors[key]!, label: labels[key] ?? colorLabel(key)),
    );
    if (picked != null) setColor(key, picked);
  }

  Future<void> save(bool apply) async {
    if (saving || data == null) return;
    // A color still being typed counts.
    for (final e in hex.entries.toList()) {
      if (e.value.text.trim().toLowerCase() != colors[e.key] && !setColor(e.key, e.value.text)) return;
    }
    final n = name.text.trim();
    if (!RegExp('[A-Za-z0-9]').hasMatch(n)) {
      setState(() => hint = 'Give the theme a name (letters or digits).');
      return;
    }
    final app = AppScope.read(context);
    final d = data!;
    setState(() {
      saving = true;
      hint = apply || d['current'] == true ? 'Saving and applying…' : 'Saving…';
    });
    Map<String, dynamic> r;
    try {
      r = await app.call('custom.save', {
        'name': n,
        'colors': colors,
        'font': ?font,
        'blur': ?blur,
        if (editing) 'edit': widget.edit else 'base': d['base'],
        if (!editing) 'copy_wallpapers': copyWallpapers,
        if (widget.wallpaper != null && !editing) 'wallpaper': widget.wallpaper,
        'apply': apply,
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          hint = 'Could not save: ${_reason(e)}';
        });
      }
      return;
    }
    if (!mounted) return;
    final shown = r['name'] as String? ?? n;
    final applyError = r['apply_error'] as String?;
    app.notify(
      applyError != null
          ? '$shown saved, but could not be applied: $applyError'
          : '${editing ? 'Theme saved' : 'Theme created'}: $shown${r['applied'] == true ? ' (applied)' : ''}',
    );
    app.changed();
    Navigator.of(context).pop(r['slug']);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.maybePop(context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String? get sampleWallpaper {
    final d = data;
    if (d == null) return null;
    final own = d['sample_wallpaper'] as String?;
    if (own != null) return own;
    final ask = widget.askWallpaper;
    if (ask != null && ask.startsWith('/') && File(ask).existsSync()) return ask;
    if (editing || copyWallpapers) return d['base_wallpaper'] as String?;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final askName = widget.initial?['name']?.trim();
    final title = widget.fromAsk
        ? (askName == null || askName.isEmpty ? 'New theme' : askName)
        : d?['title'] as String? ?? (editing ? 'Edit theme' : 'New theme');
    Widget body;
    if (loadError != null) {
      body = Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(loadError!)),
      );
    } else if (d == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      // The sample stays in view next to the controls: above them in a narrow
      // window, large on the left of them in a wide one (the plugin's ed_set_width).
      body = LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= _wideFrom;
          final controls = _controls(context, d);
          if (wide) {
            final w = (box.maxWidth - 2 * _pad) * 0.45;
            return Padding(
              padding: const EdgeInsets.fromLTRB(_pad, 4, 0, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: w, height: w * 9 / 16, child: _sample()),
                  const SizedBox(width: 18),
                  Expanded(child: controls),
                ],
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(_pad, 4, _pad, 0),
                child: SizedBox(height: 150, width: double.infinity, child: _sample()),
              ),
              const SizedBox(height: 8),
              Expanded(child: controls),
            ],
          );
        },
      );
    }
    return Focus(
      focusNode: pageFocus,
      onKeyEvent: _onKey,
      child: SubPage(
        title: title,
        section: false,
        backTooltip: 'Back without saving (Esc)',
        body: Column(
          children: [
            Expanded(child: body),
            if (d != null) _actions(context),
          ],
        ),
      ),
    );
  }

  static const _pad = 0.0; // the window frame already has its margin

  /// The hint line, then Create and Create and apply side by side, equally
  /// wide (Back or Esc leaves without saving).
  Widget _actions(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_pad, 6, _pad, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(hint, style: TextStyle(fontSize: 12.5, color: hint.endsWith('…') ? scheme.onSurfaceVariant : scheme.error)),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(onPressed: saving ? null : () => save(false), child: Text(editing ? 'Save' : 'Create')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: saving ? null : () => save(true),
                  child: Text(editing ? 'Save and apply' : 'Create and apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The plugin's order: the colors (main and terminal) in one list, then the
  /// shades, bright variants and the base's own extras under "More colors".
  (List<String>, List<String>) _keyGroups(Map<String, dynamic> d) {
    final groups = d['editable_keys'] as Map;
    final all = <String>[
      for (final g in ['main', 'terminal', 'more'])
        for (final k in (groups[g] as List? ?? const []))
          if (colors.containsKey(k)) k as String,
    ];
    final first = [
      for (final k in baseColorKeys)
        if (all.contains(k)) k,
    ];
    const order = [
      'dark_background',
      'darker_background',
      'lighter_background',
      'dark_foreground',
      'light_foreground',
      'bright_foreground',
      'bright_red',
      'bright_yellow',
      'bright_green',
      'bright_cyan',
      'bright_blue',
      'bright_magenta',
    ];
    final more = [
      for (final k in order)
        if (all.contains(k)) k,
      for (final k in all)
        if (!baseColorKeys.contains(k) && !order.contains(k)) k,
    ];
    return (first, more.toSet().toList());
  }

  Widget _controls(BuildContext context, Map<String, dynamic> d) {
    final (main, more) = _keyGroups(d);
    final baseName = d['base_name'] as String? ?? 'the base theme';
    final count = (d['base_wallpapers'] as num?)?.toInt() ?? 0;
    final fromPicture = widget.wallpaper != null;
    final scheme = Theme.of(context).colorScheme;
    final heading = TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: scheme.onSurface);
    String wallLabel, wallTip;
    if (widget.askWallpaper != null && !fromPicture) {
      wallLabel = "Also $baseName's wallpapers";
      wallTip =
          "The picture from the Ask AI card is always included; on: also $baseName's $count wallpapers. "
          "Change them later on the new theme's wallpaper page.";
    } else if (fromPicture) {
      wallLabel = "Also $baseName's wallpapers";
      wallTip =
          "${_fileName(widget.wallpaper!)} is always included; on: also $baseName's $count. "
          "Change them later on the new theme's wallpaper page.";
    } else {
      wallLabel = 'Take over its wallpapers ($count)';
      wallTip =
          "Copies of $baseName's $count visible wallpapers. Add, hide or delete them later on the new "
          "theme's wallpaper page.";
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(_pad, 0, _pad + 4, 12),
      children: [
        // Name and font as compact rows (explanations in tooltips), so the
        // colors still start on the first screen at the default size.
        _row(
          'Name',
          SizedBox(
            width: 180,
            child: Tooltip(
              message: editing ? 'Renaming keeps its wallpapers, favorites and other settings' : 'Shown in the theme list',
              child: TextField(
                controller: name,
                focusNode: nameFocus,
                maxLength: maxNameLength,
                decoration: const InputDecoration(isDense: true, counterText: ''),
                onSubmitted: (_) => save(false),
              ),
            ),
          ),
        ),
        if (AppScope.of(context).can('fonts'))
          _row(
            'Font',
            Tooltip(
              message:
                  'The monospace font (terminals, editors). It is switched when this theme is applied, '
                  'and back to your own font with other themes.',
              child: DropdownButton<String?>(
                value: font,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Keep the current font')),
                  for (final f in fonts) DropdownMenuItem<String?>(value: f, child: Text(f)),
                ],
                onChanged: (v) => setState(() => font = v),
              ),
            ),
          ),
        if (AppScope.of(context).can('blur')) ...[
          _row(
            'Blur',
            Tooltip(
              message:
                  'Frosted glass behind see-through windows and panels. It is switched when this theme is applied, '
                  'and back to your own with other themes.',
              child: DropdownButton<String>(
                key: const ValueKey('editor-blur'),
                value: blur == null ? 'keep' : (blur!['on'] == true ? 'on' : 'off'),
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'keep', child: Text('Keep the current blur')),
                  DropdownMenuItem(value: 'on', child: Text('On')),
                  DropdownMenuItem(value: 'off', child: Text('Off')),
                ],
                onChanged: (v) => setState(() {
                  final strength = (blur?['strength'] as int?) ?? 8;
                  blur = switch (v) {
                    'on' => {'on': true, 'strength': strength},
                    'off' => {'on': false, 'strength': strength},
                    _ => null,
                  };
                }),
              ),
            ),
          ),
          if (blur?['on'] == true)
            _row(
              'Blur strength',
              SizedBox(
                width: 200,
                child: Slider(
                  value: (blur!['strength'] as int).toDouble(),
                  min: 1,
                  max: 15,
                  divisions: 14,
                  label: '${blur!['strength']}',
                  onChanged: (v) => setState(() => blur = {'on': true, 'strength': v.round()}),
                ),
              ),
            ),
        ],
        if (!editing && !widget.fromAsk)
          _row(
            wallLabel,
            Tooltip(
              message: wallTip,
              child: Switch(value: copyWallpapers, onChanged: (v) => setState(() => copyWallpapers = v)),
            ),
          ),
        const SizedBox(height: 10),
        Text('Colors', style: heading),
        const SizedBox(height: 4),
        for (final k in main) _colorRow(k),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('More colors: shades and bright variants', style: heading),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    'These follow the colors above until you change them here.',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
              for (final k in more) _colorRow(k),
            ],
          ),
        ),
      ],
    );
  }

  static String _fileName(String path) => path.substring(path.lastIndexOf('/') + 1);

  Widget _row(String label, Widget control) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          control,
        ],
      ),
    ),
  );

  Widget _colorRow(String key) {
    final scheme = Theme.of(context).colorScheme;
    final controller = hex[key]!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Tooltip(
            message: 'Pick a color',
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => pick(key),
              child: Container(
                width: 34,
                height: 26,
                decoration: BoxDecoration(
                  color: _color(colors[key]!),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: scheme.onSurface.withValues(alpha: .4)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(labels[key] ?? colorLabel(key), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 10),
          SizedBox(
            width: 92,
            child: Focus(
              onFocusChange: (has) {
                if (!has && mounted && controller.text.trim().toLowerCase() != colors[key]) {
                  setColor(key, controller.text);
                }
              },
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  var t = value.text.trim();
                  if (!t.startsWith('#')) t = '#$t';
                  return TextField(
                    controller: controller,
                    maxLength: 7,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]'))],
                    decoration: InputDecoration(isDense: true, counterText: '', errorText: _hexRe.hasMatch(t) ? null : '#rrggbb'),
                    onSubmitted: (v) => setColor(key, v),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The sample (the plugin's build_sample): a small desktop in the colors
  /// and font being edited — the wallpaper, a bar with the workspaces and the
  /// clock, and an editor window with the accent border.
  Widget _sample() {
    final c = {for (final e in colors.entries) e.key: _color(e.value)};
    Color k(String key, [String fallback = 'foreground']) => c[key] ?? c[fallback] ?? Colors.grey;
    final family = font ?? data?['system_font'] as String?;
    const size = 11.0;
    TextStyle s(String key, {double fontSize = size}) => TextStyle(
      color: k(key),
      fontFamily: family ?? 'monospace',
      fontFamilyFallback: const ['monospace'],
      fontSize: fontSize,
      height: 1.3,
    );
    TextSpan t(String text, String key) => TextSpan(text: text, style: s(key));
    Widget line(List<TextSpan> spans) =>
        Text.rich(TextSpan(children: spans), maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false);
    final wall = sampleWallpaper;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        color: k('darker_background', 'background'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (wall != null) Image.file(File(wall), fit: BoxFit.cover, cacheWidth: 1280, errorBuilder: (_, _, _) => const SizedBox()),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  color: k('background').withValues(alpha: .94),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: line([t('● ', 'accent'), t('2 ', 'foreground'), t('3  4', 'muted')])),
                      Text('12:30', style: s('foreground')),
                    ],
                  ),
                ),
                Flexible(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      // blur on: the window lets the wallpaper show through, as on the desktop
                      color: k('background').withValues(alpha: blur?['on'] == true ? .72 : .97),
                      border: Border.all(color: k('accent'), width: 2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text('~/code/hello.py — nvim', style: s('muted', fontSize: 10), maxLines: 1),
                          ),
                          line([t('def', 'magenta'), t(' ', 'foreground'), t('greet', 'blue'), t('(name):', 'foreground')]),
                          line([t("    # say hello, in the theme's colors", 'muted')]),
                          line([
                            t('    ', 'foreground'),
                            t('print', 'yellow'),
                            t('(', 'foreground'),
                            t('"hello"', 'green'),
                            t(', ', 'foreground'),
                            t('42', 'orange'),
                            t(', ', 'foreground'),
                            t('True', 'cyan'),
                            t(')', 'foreground'),
                          ]),
                          Container(
                            margin: const EdgeInsets.symmetric(vertical: 1),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(color: k('selection'), borderRadius: BorderRadius.circular(3)),
                            child: Text('selected line', style: s('foreground'), maxLines: 1),
                          ),
                          line([t('~/code', 'cyan'), t(' ❯ ', 'accent'), t('maprisma-theme apply  ', 'foreground'), t('✗ 1 error', 'red')]),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A small HSV color picker: a saturation/value square, a hue bar, and a
/// #rrggbb field. Pops the picked color as #rrggbb.
class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial, required this.label});
  final String initial, label;
  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor hsv = HSVColor.fromColor(_color(widget.initial));
  late final field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  String get value => _hexOf(hsv.toColor());

  void _update(HSVColor next) {
    setState(() {
      hsv = next;
      field.text = value;
    });
  }

  void _square(Offset p, Size size) =>
      _update(hsv.withSaturation((p.dx / size.width).clamp(0.0, 1.0)).withValue(1 - (p.dy / size.height).clamp(0.0, 1.0)));

  void _hue(Offset p, double width) => _update(hsv.withHue((p.dx / width).clamp(0.0, 1.0) * 359.9));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const size = Size(280, 180);
    BoxDecoration swatch(Color color, BorderRadius radius) => BoxDecoration(
      color: color,
      borderRadius: radius,
      border: Border.all(color: scheme.onSurface.withValues(alpha: .4)),
    );
    return AlertDialog(
      title: Text(widget.label),
      content: SizedBox(
        width: size.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onPanDown: (e) => _square(e.localPosition, size),
              onPanUpdate: (e) => _square(e.localPosition, size),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CustomPaint(size: size, painter: _SquarePainter(hsv)),
              ),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onPanDown: (e) => _hue(e.localPosition, size.width),
              onPanUpdate: (e) => _hue(e.localPosition, size.width),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CustomPaint(size: Size(size.width, 20), painter: _HuePainter(hsv.hue)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Tooltip(
                  message: 'Before',
                  child: Container(
                    width: 34,
                    height: 26,
                    decoration: swatch(_color(widget.initial), const BorderRadius.horizontal(left: Radius.circular(6))),
                  ),
                ),
                Tooltip(
                  message: 'Now',
                  child: Container(
                    width: 34,
                    height: 26,
                    decoration: swatch(hsv.toColor(), const BorderRadius.horizontal(right: Radius.circular(6))),
                  ),
                ),
                const Spacer(),
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: field,
                    maxLength: 7,
                    style: const TextStyle(fontFamily: 'monospace'),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]'))],
                    decoration: const InputDecoration(isDense: true, counterText: ''),
                    onChanged: (v) {
                      final t = v.startsWith('#') ? v : '#$v';
                      if (_hexRe.hasMatch(t)) setState(() => hsv = HSVColor.fromColor(_color(t)));
                    },
                    onSubmitted: (_) => Navigator.pop(context, value),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, value), child: Text('Use for ${widget.label.toLowerCase()}')),
      ],
    );
  }
}

class _SquarePainter extends CustomPainter {
  _SquarePainter(this.hsv);
  final HSVColor hsv;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final pure = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas.drawRect(rect, Paint()..shader = LinearGradient(colors: [Colors.white, pure]).createShader(rect));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xff000000)],
        ).createShader(rect),
    );
    final at = Offset(hsv.saturation * size.width, (1 - hsv.value) * size.height);
    canvas.drawCircle(
      at,
      7,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      at,
      8.5,
      Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_SquarePainter old) => old.hsv != hsv;
}

class _HuePainter extends CustomPainter {
  _HuePainter(this.hue);
  final double hue;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h == 360 ? 359.9 : h.toDouble(), 1, 1).toColor()],
        ).createShader(rect),
    );
    final x = hue / 360 * size.width;
    canvas.drawRect(
      Rect.fromLTWH(x - 3, 0, 6, size.height),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_HuePainter old) => old.hue != hue;
}
