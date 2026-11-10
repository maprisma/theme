import '../i18n.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';

/// The key map's keys from a key event (keysym names, as the core takes them).
final _eventKeys = <LogicalKeyboardKey, String>{
  for (var i = 0; i < 26; i++) LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + i): String.fromCharCode(65 + i),
  for (var i = 0; i < 10; i++) LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i): '$i',
  LogicalKeyboardKey.f1: 'F1', LogicalKeyboardKey.f2: 'F2', LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4', LogicalKeyboardKey.f5: 'F5', LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7', LogicalKeyboardKey.f8: 'F8', LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10', LogicalKeyboardKey.f11: 'F11', LogicalKeyboardKey.f12: 'F12',
  LogicalKeyboardKey.enter: 'Return', LogicalKeyboardKey.space: 'space',
  LogicalKeyboardKey.backspace: 'BackSpace', LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.home: 'Home', LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'Page_Up', LogicalKeyboardKey.pageDown: 'Page_Down',
  LogicalKeyboardKey.insert: 'Insert', LogicalKeyboardKey.minus: 'minus', LogicalKeyboardKey.equal: 'equal',
  LogicalKeyboardKey.bracketLeft: 'bracketleft', LogicalKeyboardKey.bracketRight: 'bracketright',
  LogicalKeyboardKey.backslash: 'backslash', LogicalKeyboardKey.semicolon: 'semicolon',
  LogicalKeyboardKey.quote: 'apostrophe', LogicalKeyboardKey.backquote: 'grave',
  LogicalKeyboardKey.comma: 'comma', LogicalKeyboardKey.period: 'period', LogicalKeyboardKey.slash: 'slash',
};

const keyRows = [
  ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'minus', 'equal'],
  ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 'bracketleft', 'bracketright'],
  ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'semicolon', 'apostrophe', 'backslash'],
  ['grave', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', 'comma', 'period', 'slash'],
  ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'],
  ['Return', 'space', 'BackSpace', 'Delete', 'Home', 'End', 'Page_Up', 'Page_Down', 'Insert', 'Tab'],
];

const modOrder = ['SUPER', 'SHIFT', 'CTRL', 'ALT'];
const modNames = {'SUPER': 'Super', 'SHIFT': 'Shift', 'CTRL': 'Ctrl', 'ALT': 'Alt'};

String keyName(String name) => const {
  'Return': 'Enter', 'space': 'Space', 'BackSpace': 'Backspace', 'Page_Up': 'Page Up', 'Page_Down': 'Page Down',
  'minus': '-', 'equal': '=', 'bracketleft': '[', 'bracketright': ']', 'backslash': r'\', 'semicolon': ';',
  'apostrophe': "'", 'grave': '`', 'comma': ',', 'period': '.', 'slash': '/',
}[name] ?? name;

/// Shortcut… (the plugin's shortcut page, like Launch & Bind's): hold the
/// modifiers and press a key, or toggle Super/Shift/Ctrl/Alt and click a key.
/// Keys are coloured by who has them: green free, yellow one of yours (or
/// another Maprisma Theme key), orange a COSMIC default. A taken key can be
/// rebound; Remove gives it back. [target]: `open`, `bg:next`, `bg:prev`,
/// `theme:next` or `apply:<slug>`.
class ShortcutPage extends StatefulWidget {
  const ShortcutPage({super.key, required this.target, this.title});
  final String target;
  final String? title;
  @override
  State<ShortcutPage> createState() => _ShortcutPageState();
}

class _ShortcutPageState extends State<ShortcutPage> {
  MaprismaThemeAppState get app => AppScope.read(context);
  Map<String, dynamic> view = const {};
  bool loading = true, busy = false;
  List<String> mods = const ['SUPER', 'CTRL'];
  String? key;
  String message = '';
  bool messageOk = false;
  int _asked = 0;
  final _focus = FocusNode();

  String get title => widget.title ?? '${view['title'] ?? widget.target}';

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final first = await _state();
    if (first == null || !mounted) return;
    final current = first['current'] as Map?;
    setState(() {
      mods = current != null
          ? [...(current['mods'] as List).cast<String>()]
          : [...(first['default_mods'] as List? ?? const ['SUPER', 'CTRL']).cast<String>()];
    });
    await _state();
  }

  Future<Map<String, dynamic>?> _state() async {
    final mine = ++_asked;
    try {
      final r = await AppScope.read(context).call('shortcuts.state', {'target': widget.target, 'mods': mods});
      if (!mounted || mine != _asked) return null;
      setState(() {
        view = r;
        loading = false;
      });
      return r;
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          message = errorText(e);
          messageOk = false;
        });
      }
      return null;
    }
  }

  Future<void> _setMods(List<String> value) async {
    setState(() => mods = [for (final m in modOrder) if (value.contains(m)) m]);
    await _state();
  }

  Map? _keyInfo(String name) =>
      (view['keys'] as List?)?.cast<Map>().where((k) => '${k['key']}'.toLowerCase() == name.toLowerCase()).firstOrNull;

  String comboLabel(List mods, String key) => [for (final m in mods) modNames[m] ?? '$m', keyName(key)].join(' + ');

  /// (text, kind, button, enabled) for the picked combination.
  (String, String, String, bool) status() {
    if (key == null) return (tr("Press a key, or pick a free key below."), 'info', tr("Assign"), false);
    if (mods.isEmpty) return (tr("Choose at least one modifier — Super is recommended."), 'info', tr("Assign"), false);
    final info = _keyInfo(key!);
    if (info == null) return (tr("That key cannot be used for a shortcut."), 'info', tr("Assign"), false);
    final owner = '${info['owner'] ?? ''}';
    return switch ('${info['level']}') {
      'free' => (trf("✓ Free.{0}", [mods.contains('SUPER') ? '' : tr(" Without Super, apps can no longer receive it.")]), 'free', tr("Assign"), true),
      'same' => (tr("That is the current key."), 'info', tr("Assign"), false),
      'ours' => (trf("{0} has it now. Assigning moves it here.", [owner]), 'warn', tr("Move here"), true),
      'custom' => (trf("Your shortcut “{0}”. Assigning turns it off while this one exists; removing it brings it back.", [owner]), 'warn', tr("Rebind"), true),
      _ => (trf("{0}'s “{1}”. Assigning overrides it while this one exists; removing it brings it back.", [app.desktopName, owner]), 'desktop', tr("Rebind"), true),
    };
  }

  Future<void> assign() async {
    final (_, _, _, enabled) = status();
    if (!enabled || busy) return;
    setState(() => busy = true);
    final label = comboLabel(mods, key!);
    try {
      await AppScope.read(context).call('shortcuts.set', {'target': widget.target, 'mods': mods, 'combo_key': key});
      if (!mounted) return;
      setState(() {
        message = trf("✓ Saved — {0}: {1}.", [label, title]);
        messageOk = true;
        key = null;
      });
      AppScope.read(context).changed();
      await _state();
    } catch (e) {
      if (mounted) {
        setState(() {
          message = trf("Not applied: {0}", [errorText(e)]);
          messageOk = false;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final r = await AppScope.read(context).call('shortcuts.remove', {'target': widget.target});
      if (!mounted) return;
      final replaces = '${r['replaces'] ?? ''}';
      setState(() {
        message = trf("✓ Removed.{0}", [replaces.isNotEmpty ? trf(" “{0}” works again.", [replaces]) : '']);
        messageOk = true;
      });
      AppScope.read(context).changed();
      await _state();
    } catch (e) {
      if (mounted) setState(() => message = trf("Not removed: {0}", [errorText(e)]));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.maybePop(context);
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    final held = [
      if (keyboard.isMetaPressed) 'SUPER',
      if (keyboard.isShiftPressed) 'SHIFT',
      if (keyboard.isControlPressed) 'CTRL',
      if (keyboard.isAltPressed) 'ALT',
    ];
    if ((event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) && held.isEmpty) {
      assign();
      return KeyEventResult.handled;
    }
    final name = _eventKeys[event.logicalKey];
    if (name == null || view['available'] != true) return KeyEventResult.ignored;
    setState(() => key = name);
    if (held.isNotEmpty && held.join() != mods.join()) _setMods(held);
    return KeyEventResult.handled;
  }

  Color levelColor(String level, ColorScheme scheme, MarkColors marks) => switch (level) {
    'free' => marks.running,
    'same' => scheme.primary,
    'ours' || 'custom' => marks.fresh,
    _ => marks.update,
  };

  Widget caps(String label, {bool large = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final part in label.split(' + '))
          Container(
            padding: EdgeInsets.symmetric(horizontal: large ? 10 : 6, vertical: large ? 5 : 2),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(5),
              color: scheme.surfaceContainerHighest,
            ),
            child: Text(part, style: TextStyle(fontSize: large ? 14 : 12, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  String keyTip(String label, Map info) {
    final owner = '${info['owner'] ?? ''}';
    return switch ('${info['level']}') {
      'free' => trf("{0} — free", [label]),
      'same' => trf("{0} — the current key", [label]),
      'ours' => trf("{0} — {1}; click to move it here", [label, owner]),
      'custom' => trf("{0} — your shortcut “{1}”; click to rebind", [label, owner]),
      _ => trf("{0} — {1}'s “{2}”; click to rebind", [label, app.desktopName, owner]),
    };
  }

  Widget _keyMap(ColorScheme scheme, MarkColors marks) {
    if (view['keys'] == null) return Text(tr("Choose modifiers above to see every key."));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in keyRows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final name in row)
                  if (_keyInfo(name) case final info?)
                    () {
                      final color = levelColor('${info['level']}', scheme, marks);
                      final picked = key?.toLowerCase() == name.toLowerCase();
                      return Tooltip(
                        message: keyTip(comboLabel(mods, name), info),
                        child: InkWell(
                          key: ValueKey('key-$name'),
                          borderRadius: BorderRadius.circular(5),
                          onTap: () => setState(() => key = picked ? null : name),
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 30),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(5),
                              color: color.withValues(alpha: picked ? .55 : .18),
                              border: Border.all(color: picked ? scheme.onSurface : color, width: picked ? 2 : 1),
                            ),
                            child: Text(keyName(name), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                          ),
                        ),
                      );
                    }(),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _body(ColorScheme scheme, MarkColors marks) {
    final (text, kind, button, enabled) = status();
    final current = view['current'] as Map?;
    final statusColor = switch (kind) {
      'free' => marks.running,
      'warn' => marks.fresh,
      'desktop' => marks.update,
      _ => scheme.onSurfaceVariant,
    };
    Widget section(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 6),
      child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
    final replaces = '${current?['replaces'] ?? ''}';
    return [
      section(tr("Current key")),
      if (current == null)
        Text(tr("None yet — pick one below."), style: TextStyle(color: scheme.onSurfaceVariant))
      else
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              caps('${current['label']}', large: true),
              if (replaces.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(trf("Overrides “{0}”", [replaces]), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
            ]),
          ),
          Tooltip(
            message: replaces.isNotEmpty ? trf("Remove this key — “{0}” works again", [replaces]) : tr("Remove this key"),
            child: TextButton.icon(
              key: const ValueKey('shortcut-remove'),
              onPressed: busy ? null : remove,
              icon: const Icon(Icons.close, size: 18),
              label: Text(tr("Remove")),
            ),
          ),
        ]),
      section(tr("Choose a key")),
      Wrap(
        spacing: 6,
        children: [
          for (final m in modOrder)
            FilterChip(
              key: ValueKey('mod-$m'),
              label: Text(modNames[m]!),
              selected: mods.contains(m),
              onSelected: (on) => _setMods(on ? [...mods, m] : [for (final x in mods) if (x != m) x]),
            ),
        ],
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: Tooltip(
            message: tr("Press a key now. Hold modifiers while pressing, or toggle them above."),
            child: key != null
                ? Align(alignment: Alignment.centerLeft, child: caps(comboLabel(mods, key!), large: true))
                : Row(children: [
                    if (mods.isNotEmpty) caps(mods.map((m) => modNames[m]).join(' + '), large: true),
                    const SizedBox(width: 6),
                    Text(tr("select a key"), style: TextStyle(color: scheme.onSurfaceVariant)),
                  ]),
          ),
        ),
        FilledButton(
          key: const ValueKey('shortcut-assign'),
          onPressed: enabled && !busy ? assign : null,
          child: Text(button),
        ),
      ]),
      Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(text, style: TextStyle(color: statusColor))),
      if (message.isNotEmpty) Text(message, style: TextStyle(color: messageOk ? marks.running : scheme.error)),
      section(mods.isEmpty ? tr("Keys") : trf("Keys with {0}", [mods.map((m) => modNames[m]).join(' + ')])),
      Tooltip(
        message: tr("Taken keys can be rebound; the original works again when you remove the shortcut."),
        child: Wrap(children: [
          for (final (t, c) in [(tr('free'), marks.running), (tr('yours'), marks.fresh), (trf("{0} default", [app.desktopName]), marks.update)])
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text('● $t', style: TextStyle(fontSize: 12, color: c)),
            ),
        ]),
      ),
      const SizedBox(height: 6),
      _keyMap(scheme, marks),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final marks = markColors(context);
    return SubPage(
      title: trf("Shortcut: {0}", [title]),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : view['available'] != true
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    message.isNotEmpty ? message : trf("{0}'s keyboard settings were not found, so shortcuts cannot be set here.", [app.desktopName]),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: _body(scheme, marks)),
      ),
    );
  }
}
