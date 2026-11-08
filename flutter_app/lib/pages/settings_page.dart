import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../theme.dart';
import '../widgets.dart';
import 'shortcut_page.dart';

/// One row of the settings: its section, its words (for the search) and its control.
final class _Row {
  const _Row(this.section, this.title, this.hint, this.control, {this.below});
  final String section, title, hint;
  final Widget control;

  /// A wide control under the title instead of beside it.
  final Widget? below;
}

/// The plugin's sections, in its order.
const _sections = [
  ('general', 'General'),
  ('themes', 'Themes'),
  ('day-night', 'Day and night'),
  ('wallpapers', 'Wallpapers'),
  ('shortcuts', 'Keyboard shortcuts'),
  ('screenshots', 'Screenshots'),
  ('ask-ai', 'Ask AI'),
  ('integration', 'Integration and backup'),
];

const _sectionHints = {
  'wallpapers': 'Scroll on the panel icon for the next or previous wallpaper; right-click it for your favorite themes.',
  'shortcuts':
      "Give a theme its own key in its ⋮ menu → Shortcut…. Keys are COSMIC custom shortcuts; "
      "a key taken from another shortcut works again when you remove yours.",
  'themes':
      'Apps get the theme colors through one marked include line in their own config (a backup is kept). '
      'Switching an app off removes that line again.',
};

const _slideshow = [
  (0, 'Never'),
  (5, 'Every 5 minutes'),
  (10, 'Every 10 minutes'),
  (15, 'Every 15 minutes'),
  (30, 'Every 30 minutes'),
  (60, 'Every hour'),
  (120, 'Every 2 hours'),
];

final _times = [
  for (var h = 0; h < 24; h++)
    for (final m in [0, 30]) '${'$h'.padLeft(2, '0')}:${'$m'.padLeft(2, '0')}',
];

/// Settings (the plugin's settings page): a section sidebar (a row of section
/// buttons when narrow) and a search field that shows matching rows across
/// sections; Reset to defaults at the bottom.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final MaprismaThemeAppState app;
  Map<String, dynamic> settings = {};
  Map<String, dynamic> plan = {};
  List<Map> themes = [], apps = [], helpers = [];
  Map<String, dynamic> shortcuts = {}, health = {};
  bool helpersKnown = false, loading = true;
  String section = 'general', search = '';
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

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
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _try(String method, [Map<String, dynamic> params = const {}]) async {
    try {
      return await app.call(method, params);
    } catch (_) {
      return null;
    }
  }

  Future<void> load() async {
    final results = await Future.wait([
      _try('settings.get'),
      _try('auto.schedule'),
      _try('themes.list'),
      _try('apps.list'),
      _try('shortcuts.list'),
      _try('ask.helpers'),
      _try('health.get'),
    ]);
    if (!mounted) return;
    setState(() {
      settings = Map<String, dynamic>.from(results[0]?['settings'] as Map? ?? app.settings);
      plan = Map<String, dynamic>.from(results[1]?['schedule'] as Map? ?? const {});
      themes = [for (final t in results[2]?['themes'] as List? ?? const []) t as Map]
        ..sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
      apps = [for (final a in results[3]?['apps'] as List? ?? const []) a as Map];
      shortcuts = results[4] ?? const {};
      final h = results[5]?['helpers'];
      helpersKnown = h is List;
      helpers = [
        for (final x in h is List ? h : const [])
          if (x is Map && x['installed'] != false) x,
      ];
      health = results[6] ?? const {};
      loading = false;
    });
  }

  Future<void> set(String key, Object? value) async {
    final r = await app.run('settings.set', {'key': key, 'value': value});
    if (r == null || !mounted) return;
    setState(() => settings = Map<String, dynamic>.from(r['settings'] as Map));
    app.changed();
  }

  Future<void> setSchedule(Map<String, dynamic> values) async {
    final r = await app.run('auto.schedule_set', values);
    if (r == null || !mounted) return;
    setState(() => plan = Map<String, dynamic>.from(r['schedule'] as Map));
  }

  Future<void> setApp(Map a, bool on) async {
    final r = await app.run('apps.set', {'id': a['id'], 'enabled': on});
    if (r == null || !mounted) return;
    setState(() => apps = [for (final x in r['apps'] as List) x as Map]);
    switch (r['result']) {
      case 'manual':
        app.notify(
          "${a['label']}'s config is laid out so that a line cannot be added safely: include "
          '~/.config/maprisma-theme/current/ yourself',
        );
      case 'failed':
        app.notify("${a['label']}'s config could not be changed");
      case 'ok':
        app.notify(on ? '${a['label']} uses the theme colors' : '${a['label']} keeps its own colors');
      default:
        if (!on) app.notify('${a['label']} keeps its own colors');
    }
  }

  // --- controls (the plugin's compact settings lines) ------------------------------

  Widget _switch(bool value, ValueChanged<bool>? onChanged, {Key? key}) => SizedBox(
    height: 22,
    child: FittedBox(
      child: Switch(key: key, value: value, onChanged: onChanged),
    ),
  );

  Widget _dropdown<T>(T value, List<(T, String)> choices, ValueChanged<T> onChanged, {Key? key}) {
    final look = Look.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: look.fg.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(corners(context)),
      ),
      child: DropdownButton<T>(
        key: key,
        value: choices.any((c) => c.$1 == value) ? value : choices.first.$1,
        isDense: true,
        underline: const SizedBox(),
        dropdownColor: look.bg,
        borderRadius: BorderRadius.circular(corners(context)),
        style: Theme.of(context).textTheme.bodyMedium!.copyWith(fontSize: 12, color: look.fg),
        icon: Icon(Icons.expand_more, size: 16, color: look.fg),
        items: [for (final (v, label) in choices) DropdownMenuItem(value: v, child: Text(label))],
        onChanged: (v) => v == null ? null : onChanged(v),
      ),
    );
  }

  /// `button.sc-small`: 11 px, a thin border.
  Widget _small(String label, VoidCallback? onPressed, {Key? key, IconData? icon, String? tooltip}) {
    final look = Look.of(context);
    final b = OutlinedButton(
      key: key,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: const Size(0, 24),
        side: BorderSide(color: look.fg.withValues(alpha: .35)),
        textStyle: Theme.of(context).textTheme.labelLarge!.copyWith(fontSize: 11),
      ),
      child: icon == null ? Text(label) : Icon(icon, size: 14),
    );
    return tooltip == null ? b : Tooltip(message: tooltip, child: b);
  }

  Widget _caps(String label) {
    final look = Look.of(context);
    final r = corners(context);
    return Wrap(
      spacing: 4,
      children: [
        for (final part in label.split(' + '))
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: look.fg.withValues(alpha: .35)),
              borderRadius: BorderRadius.circular(r == 0 ? 0 : (r - 4).clamp(4, 100)),
              color: look.fg.withValues(alpha: .08),
            ),
            child: Text(part, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  Future<void> _openShortcut(String target, String title) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShortcutPage(target: target, title: title),
      ),
    );
    load();
  }

  Future<void> _chooseScreenshotFolder() async {
    final dir = await getDirectoryPath(
      confirmButtonText: 'Choose',
      initialDirectory: settings['screenshot_dir'] as String?,
    );
    if (dir != null) await set('screenshot_dir', dir);
  }

  Future<void> _export() async {
    final name = await _try('backup.default_name');
    final where = await getSaveLocation(
      suggestedName: '${name?['name'] ?? 'maprisma-theme-backup.json'}',
      initialDirectory: name?['folder'] as String?,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (where == null) return;
    final r = await app.run('backup.export', {'path': where.path});
    if (r != null) app.notify('Backup saved: ${r['path']}');
  }

  Future<void> _restore() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (file == null || !mounted) return;
    final preview = await app.run('backup.preview', {'path': file.path});
    if (preview == null || !mounted) return;
    final files = [for (final f in preview['files'] as List) '$f'];
    final removes = [for (final f in preview['removes'] as List) '$f'];
    final ok = await confirm(
      context,
      'Restore this backup?',
      'Replaces: ${files.join(', ')}.'
          '${removes.isEmpty ? '' : '\nRemoves (not in the backup): ${removes.join(', ')}.'}'
          '\nA copy of the current state is saved in ~/.config/maprisma-theme/backups/ first.',
      action: 'Restore',
    );
    if (!ok) return;
    final r = await app.run('backup.restore', {'path': file.path});
    if (r == null) return;
    app.notify('Backup restored. The previous state is in ${r['safety_copy']}');
    app.changed();
  }

  Future<void> _repair() async {
    final r = await app.run('health.repair');
    if (r == null || !mounted) return;
    setState(() => health = r);
    app.notify('Written again');
  }

  Future<void> _reset() async {
    final ok = await confirm(
      context,
      'Reset to defaults?',
      'Resets corners, sorting, header button order, schedule, wallpaper rotation, and screenshot key and folder. '
          'Keeps favorites, hidden themes, shortcuts and saved workspace assignments; themes per workspace turn off.',
      action: 'Reset',
    );
    if (!ok) return;
    final r = await app.run('settings.reset');
    if (r == null) return;
    app.changed();
    await load();
    app.notify('Settings reset');
  }

  // --- rows ------------------------------------------------------------------------

  String get _cornersTip =>
      "Corners of the window and its theme cards. “Like windows” follows the COSMIC theme's corner radius.";

  List<_Row> rows() {
    final marks = markColors(context);
    Widget status(bool ok, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(ok ? Icons.check_circle_outline : Icons.error_outline, size: 14, color: ok ? marks.running : marks.update),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 12)),
      ],
    );
    final themeChoices = <(String, String)>[('', 'Choose…'), for (final t in themes) ('${t['slug']}', '${t['name']}')];
    final shotDir = settings['screenshot_dir'] as String?;
    final radius = app.windowRadius;
    final ready = [
      for (final h in helpers)
        if (h['signed_in'] != false) h,
    ];
    final out = <_Row>[
      _Row(
        'general',
        'Corners',
        _cornersTip,
        _dropdown('${settings['corners'] ?? 'windows'}', [
          ('windows', radius == null ? 'Like windows' : 'Like windows ($radius px)'),
          ('rounded', 'Rounded'),
          ('square', 'Square'),
        ], (v) => set('corners', v)),
      ),
      _Row(
        'themes',
        'Sort the list',
        "Favorites (★ in a theme's menu) always come first.",
        _dropdown('${settings['sort'] ?? 'name'}', const [
          ('name', 'By name'),
          ('recent', 'Recently used first'),
        ], (v) => set('sort', v)),
      ),
      for (final a in apps)
        _Row(
          'themes',
          'App colors: ${a['label']}',
          a['supported'] == false
              ? '${a['note']}'
              : a['installed'] == true
              ? '${a['note']}${a['enabled'] == true && a['included'] != true ? ' · not set up yet (applied with the next theme)' : ''}'
              : 'Not installed',
          _switch(
            a['enabled'] == true && a['supported'] != false,
            a['installed'] == true && a['supported'] != false ? (on) => setApp(a, on) : null,
            key: ValueKey('app-${a['id']}'),
          ),
        ),
      _Row(
        'day-night',
        'Switch themes by time of day',
        'At the times below. A theme you pick by hand stays until the next switch.',
        _switch(plan['enabled'] == true, (on) => setSchedule({'enabled': on})),
      ),
      for (final (k, at, label) in const [('day', 'day_at', 'Day theme'), ('night', 'night_at', 'Night theme')])
        _Row(
          'day-night',
          label,
          '',
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _dropdown('${plan[k] ?? ''}', themeChoices, (v) => v.isEmpty ? null : setSchedule({k: v})),
              _dropdown('${plan[at] ?? (k == 'day' ? '07:00' : '19:00')}', [
                for (final t in _times) (t, 'from $t'),
                if (!_times.contains(plan[at]) && plan[at] is String) ('${plan[at]}', 'from ${plan[at]}'),
              ], (v) => setSchedule({at: v})),
            ],
          ),
        ),
      _Row(
        'wallpapers',
        'A wallpaper for each workspace',
        "Choose workspaces in a wallpaper's ☰ menu → Show on workspace. Workspaces without one keep the theme's background.",
        _switch(settings['workspace_wallpapers'] == true, (on) => set('workspace_wallpapers', on)),
      ),
      _Row(
        'wallpapers',
        'A theme for each workspace',
        "Switches COSMIC's theme when you focus a workspace with an assigned theme. Switching takes a moment and changes "
            'every monitor. Leaving the workspace goes back to the theme you used before.',
        _switch(settings['workspace_themes'] == true, (on) => set('workspace_themes', on)),
      ),
      _Row(
        'wallpapers',
        'Change the wallpaper',
        "Goes through the current theme's visible wallpapers.",
        _dropdown(
          settings['slideshow_minutes'] is int ? settings['slideshow_minutes'] as int : 0,
          _slideshow,
          (v) => set('slideshow_minutes', v),
        ),
      ),
      if (shortcuts['available'] == false)
        _Row(
          'shortcuts',
          'Keyboard shortcuts',
          "COSMIC's keyboard settings were not found, so shortcuts cannot be set here.",
          const SizedBox(),
        ),
      for (final s in [
        ...shortcuts['globals'] as List? ?? const [],
        ...shortcuts['themes'] as List? ?? const [],
      ].cast<Map>())
        _Row(
          'shortcuts',
          '${s['title']}',
          s['label'] == null
              ? 'No key yet'
              : (s['replaces'] ?? '') != ''
              ? 'Overrides “${s['replaces']}”'
              : '',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s['label'] != null) ...[_caps('${s['label']}'), const SizedBox(width: 6)],
              _small(
                s['label'] == null ? 'Set…' : 'Change…',
                shortcuts['available'] == true ? () => _openShortcut('${s['target']}', '${s['title']}') : null,
                key: ValueKey('shortcut-${s['target']}'),
              ),
            ],
          ),
        ),
      _Row(
        'screenshots',
        'F12 saves a screenshot',
        'Save a picture of the Maprisma Theme window while it is open.',
        _switch(settings['screenshot_key'] != false, (on) => set('screenshot_key', on)),
      ),
      _Row(
        'screenshots',
        'Screenshots go to',
        shotDir ?? '~/Pictures/MaprismaTheme',
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                shotDir ?? '~/Pictures/MaprismaTheme',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 6),
            if (shotDir != null) ...[_small('Default', () => set('screenshot_dir', null)), const SizedBox(width: 6)],
            _small(
              'Choose folder…',
              _chooseScreenshotFolder,
              icon: Icons.folder_open_outlined,
              tooltip: 'Choose folder…',
            ),
          ],
        ),
      ),
      _Row(
        'ask-ai',
        'Ask AI',
        'Describe a theme and an installed, signed-in AI helper (Claude Code, Codex, pi, Hermes or a local model) suggests it. '
            'Off until you turn it on; it runs only when you click Ask.',
        _switch(settings['ask_ai'] == true, (on) => set('ask_ai', on)),
      ),
      _Row(
        'ask-ai',
        '',
        '',
        const SizedBox(),
        below: Text(
          !helpersKnown
              ? 'Helpers: not available in this version'
              : ready.isEmpty
              ? 'Helpers: none is installed and signed in'
              : 'Helpers: ${ready.map((h) => '${h['name'] ?? h['id']}${h['local'] == true ? ' (on this PC)' : ''}').join(', ')}',
          style: hintStyle(context),
        ),
      ),
      if (helpers.isNotEmpty)
        _Row(
          'ask-ai',
          'Helper',
          'The first ready one unless you choose',
          _dropdown<String>('${settings['ask_ai_helper'] ?? ''}', [
            ('', 'First ready one'),
            for (final h in helpers)
              (
                '${h['id']}',
                '${h['name'] ?? h['id']}${h['local'] == true ? ' (on this PC)' : ''}${h['signed_in'] == false ? ' — not signed in' : ''}',
              ),
          ], (v) => set('ask_ai_helper', v.isEmpty ? null : v)),
        ),
      _Row(
        'ask-ai',
        'Maprisma hints',
        'A ? here and on the Ask AI page opens the note on easy AI setup with Maprisma.',
        _switch(settings['maprisma_hints'] != false, (on) => set('maprisma_hints', on)),
      ),
    ];
    final helper = health['helper'] as Map?, applet = health['applet'] as Map?, keys = health['shortcuts'] as Map?;
    final core = health['core'] as Map?;
    out.addAll([
      _Row(
        'integration',
        'maprisma-theme-helper',
        'Applies themes to COSMIC and reads the workspaces.',
        status(helper?['ok'] == true, helper?['ok'] == true ? 'Found' : 'Not found'),
      ),
      _Row(
        'integration',
        'maprisma-theme-core',
        'The panel applet and the keyboard shortcuts run it.',
        status(core?['ok'] == true, core?['ok'] == true ? 'Found' : 'Not found'),
      ),
      _Row(
        'integration',
        'Panel applet',
        applet?['in_panel'] == true
            ? 'In the panel: click toggles this window, scroll changes the wallpaper, right-click shows your favorites'
            : 'Add “Maprisma Theme” in COSMIC Settings → Desktop → Panel → Applets',
        status(
          applet?['ok'] == true && applet?['in_panel'] == true,
          applet?['ok'] != true
              ? 'Not installed'
              : applet?['in_panel'] == true
              ? 'Ready'
              : 'Not in the panel',
        ),
      ),
      _Row(
        'integration',
        'Shortcut file',
        '${keys?['note'] ?? ''}'.isNotEmpty
            ? '${keys!['note']}'
            : "${keys?['keys'] ?? 0} key(s) in COSMIC's custom shortcuts",
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            status(keys?['ok'] == true, keys?['ok'] == true ? 'OK' : 'Needs attention'),
            const SizedBox(width: 8),
            _small('Repair', _repair),
          ],
        ),
      ),
      _Row(
        'integration',
        'Backup and restore',
        'Includes settings, lists, workspace assignments, presets and shortcuts; themes and wallpapers remain in their folders.',
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [_small('Export…', _export), const SizedBox(width: 6), _small('Restore…', _restore)],
        ),
      ),
    ]);
    return out;
  }

  String _sectionName(String key) => _sections.firstWhere((s) => s.$1 == key).$2;

  bool _matches(_Row r) {
    final q = search.trim().toLowerCase();
    if (q.isEmpty) return r.section == section;
    final name = _sectionName(r.section).toLowerCase();
    return name.contains(q) || '${r.title} ${r.hint}'.toLowerCase().contains(q);
  }

  /// A line as the plugin's: the dim 11 px label in a 130 px column, the
  /// control beside it; the explanation is the tooltip of both.
  Widget _rowWidget(_Row r) {
    final look = Look.of(context);
    if (r.title.isEmpty && r.below != null) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: r.below!);
    }
    Widget tip(Widget w) => r.hint.isEmpty ? w : Tooltip(message: r.hint, child: w);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: tip(Text(r.title, style: TextStyle(fontSize: 11, color: look.dim))),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: tip(r.control)),
          ),
        ],
      ),
    );
  }

  Widget _heading(String key) {
    final look = Look.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Tooltip(
        message: _sectionHints[key] ?? '',
        child: Text(
          _sectionName(key),
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1, color: look.fg),
        ),
      ),
    );
  }

  Widget _content() {
    final shown = rows().where(_matches).toList();
    final children = <Widget>[];
    String? last;
    for (final r in shown) {
      if (r.section != last) {
        last = r.section;
        children.add(_heading(r.section));
      }
      children.add(_rowWidget(r));
    }
    if (shown.isEmpty && search.trim().isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('No setting matches your search.', style: hintStyle(context)),
        ),
      );
    }
    return ListView(padding: const EdgeInsets.fromLTRB(0, 2, 4, 12), children: children);
  }

  void _select(String key) => setState(() {
    section = key;
    search = '';
    _search.clear();
  });

  @override
  Widget build(BuildContext context) {
    final look = Look.of(context);
    final r = corners(context);
    final reset = _small(
      'Reset to defaults',
      _reset,
      key: const ValueKey('settings-reset'),
      tooltip:
          'Resets corners, sorting, header button order, schedule, wallpaper rotation, and screenshot key and folder. '
          'Keeps favorites, hidden themes, shortcuts and saved workspace assignments; themes per workspace turn off.',
    );
    return SubPage(
      title: 'Settings',
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Focus(
              autofocus: true,
              // Typing anywhere on the page searches, as in the plugin.
              onKeyEvent: (node, e) {
                final ch = e.character;
                if (e is! KeyDownEvent ||
                    typingInTextField() ||
                    ch == null ||
                    ch.length != 1 ||
                    ch.codeUnitAt(0) < 33 ||
                    ch.codeUnitAt(0) == 127 ||
                    HardwareKeyboard.instance.isControlPressed ||
                    HardwareKeyboard.instance.isAltPressed) {
                  return KeyEventResult.ignored;
                }
                _search.text += ch;
                _search.selection = TextSelection.collapsed(offset: _search.text.length);
                _searchFocus.requestFocus();
                setState(() => search = _search.text);
                return KeyEventResult.handled;
              },
              child: LayoutBuilder(
                builder: (context, size) {
                  final wide = size.maxWidth >= 640;
                  final field = Focus(
                    onKeyEvent: (node, e) {
                      if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.backspace && _search.text.isEmpty) {
                        Navigator.of(context).maybePop();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: TextField(
                      key: const ValueKey('settings-search'),
                      controller: _search,
                      focusNode: _searchFocus,
                      style: const TextStyle(fontSize: 14),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search, size: 18),
                        hintText: 'Find in Settings',
                      ),
                      onChanged: (v) => setState(() => search = v),
                    ),
                  );
                  Widget navButton(String key, String name, {bool chip = false}) {
                    final active = search.isEmpty && section == key;
                    return Material(
                      color: active ? look.selection : Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(r),
                        side: chip && !active ? BorderSide(color: look.fg.withValues(alpha: .25)) : BorderSide.none,
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(r),
                        onTap: () => _select(key),
                        child: Padding(
                          padding: chip
                              ? const EdgeInsets.symmetric(horizontal: 9, vertical: 4)
                              : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          child: Text(
                            name,
                            style: TextStyle(
                              fontSize: chip ? 11 : 12,
                              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                              color: active ? look.selectionFg : look.fg,
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  final content = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      field,
                      const SizedBox(height: 6),
                      if (!wide) ...[
                        SizedBox(
                          height: 30,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final (key, name) in _sections)
                                Padding(
                                  padding: const EdgeInsets.only(right: 5),
                                  child: navButton(key, name, chip: true),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      Expanded(child: _content()),
                      if (!wide) Align(alignment: Alignment.centerLeft, child: reset),
                    ],
                  );
                  if (!wide) return content;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 158,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: look.fg.withValues(alpha: .04),
                          borderRadius: BorderRadius.circular(r),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final (key, name) in _sections)
                              Padding(padding: const EdgeInsets.only(bottom: 4), child: navButton(key, name)),
                            const Spacer(),
                            Align(alignment: Alignment.centerLeft, child: reset),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: content),
                    ],
                  );
                },
              ),
            ),
    );
  }
}
