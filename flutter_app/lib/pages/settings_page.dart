import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

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

const _sections = [
  ('general', 'General', Icons.tune),
  ('themes', 'Themes', Icons.palette_outlined),
  ('day-night', 'Day and night', Icons.brightness_6_outlined),
  ('wallpapers', 'Wallpapers', Icons.wallpaper_outlined),
  ('shortcuts', 'Keyboard shortcuts', Icons.keyboard_outlined),
  ('ask-ai', 'Ask AI', Icons.auto_awesome_outlined),
  ('integration', 'Integration and backup', Icons.health_and_safety_outlined),
];

const _sectionHints = {
  'wallpapers': 'Scroll on the panel icon for the next or previous wallpaper; right-click it for your favorite themes.',
  'shortcuts': "Give a theme its own key in its ⋮ menu → Shortcut…. Keys are COSMIC custom shortcuts; "
      "a key taken from another shortcut works again when you remove yours.",
  'themes': 'Apps get the theme colors through one marked include line in their own config (a backup is kept). '
      'Switching an app off removes that line again.',
};

const _headerNames = {
  'ask': 'Ask AI',
  'import': 'Import themes',
  'hidden': 'Show hidden themes',
  'presets': 'Presets',
  'info': 'Information',
};

const _slideshow = [
  (0, 'Never'), (5, 'Every 5 minutes'), (10, 'Every 10 minutes'), (15, 'Every 15 minutes'),
  (30, 'Every 30 minutes'), (60, 'Every hour'), (120, 'Every 2 hours'),
];

final _times = [for (var h = 0; h < 24; h++) for (final m in [0, 30]) '${'$h'.padLeft(2, '0')}:${'$m'.padLeft(2, '0')}'];

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
      helpers = [for (final x in h is List ? h : const []) if (x is Map && x['installed'] != false) x];
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
        app.notify("${a['label']}'s config is laid out so that a line cannot be added safely: include "
            '~/.config/maprisma-theme/current/ yourself');
      case 'failed':
        app.notify("${a['label']}'s config could not be changed");
      case 'ok':
        app.notify(on ? '${a['label']} uses the theme colors' : '${a['label']} keeps its own colors');
      default:
        if (!on) app.notify('${a['label']} keeps its own colors');
    }
  }

  // --- controls -----------------------------------------------------------------

  Widget _switch(bool value, ValueChanged<bool>? onChanged, {Key? key}) => Switch(key: key, value: value, onChanged: onChanged);

  Widget _dropdown<T>(T value, List<(T, String)> choices, ValueChanged<T> onChanged, {Key? key}) => DropdownButton<T>(
    key: key,
    value: choices.any((c) => c.$1 == value) ? value : choices.first.$1,
    underline: const SizedBox(),
    items: [for (final (v, label) in choices) DropdownMenuItem(value: v, child: Text(label))],
    onChanged: (v) => v == null ? null : onChanged(v),
  );

  Widget _caps(String label) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(spacing: 3, children: [
      for (final part in label.split(' + '))
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(5),
            color: scheme.surfaceContainerHighest,
          ),
          child: Text(part, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
    ]);
  }

  Future<void> _openShortcut(String target, String title) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShortcutPage(target: target, title: title)));
    load();
  }

  Widget _headerOrder() {
    final order = [for (final x in settings['header_order'] as List? ?? const []) '$x'];
    for (final k in _headerNames.keys) {
      if (!order.contains(k)) order.add(k);
    }
    void move(int i, int by) {
      final next = [...order];
      final item = next.removeAt(i);
      next.insert(i + by, item);
      set('header_order', next);
    }

    return Column(children: [
      for (var i = 0; i < order.length; i++)
        Row(children: [
          Expanded(child: Text(_headerNames[order[i]] ?? order[i])),
          IconButton(
            tooltip: 'Move left',
            icon: const Icon(Icons.arrow_upward, size: 18),
            onPressed: i == 0 ? null : () => move(i, -1),
          ),
          IconButton(
            tooltip: 'Move right',
            icon: const Icon(Icons.arrow_downward, size: 18),
            onPressed: i == order.length - 1 ? null : () => move(i, 1),
          ),
        ]),
    ]);
  }

  Future<void> _chooseScreenshotFolder() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Choose', initialDirectory: settings['screenshot_dir'] as String?);
    if (dir != null) await set('screenshot_dir', dir);
  }

  Future<void> _export() async {
    final name = await _try('backup.default_name');
    final where = await getSaveLocation(
      suggestedName: '${name?['name'] ?? 'maprisma-theme-backup.json'}',
      initialDirectory: name?['folder'] as String?,
      acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])],
    );
    if (where == null) return;
    final r = await app.run('backup.export', {'path': where.path});
    if (r != null) app.notify('Backup saved: ${r['path']}');
  }

  Future<void> _restore() async {
    final file = await openFile(acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])]);
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
      'Corners like the windows, sorted by name, no day/night switching (07:00 / 19:00), a wallpaper for '
          'each workspace on, the wallpaper never changes. Shortcuts, favorites, hidden themes and the chosen '
          'day and night themes stay.',
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

  List<_Row> rows() {
    final marks = markColors(context);
    Widget status(bool ok, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(ok ? Icons.check_circle_outline : Icons.error_outline, size: 18, color: ok ? marks.running : marks.update),
      const SizedBox(width: 6),
      Text(text),
    ]);
    final themeChoices = <(String, String)>[('', 'Choose…'), for (final t in themes) ('${t['slug']}', '${t['name']}')];
    final shotDir = settings['screenshot_dir'] as String?;
    final out = <_Row>[
      _Row('general', 'Corners', "The window's and theme tiles' corners: Like windows follows the COSMIC theme's corner radius.",
          _dropdown('${settings['corners'] ?? 'windows'}', const [('windows', 'Like windows'), ('rounded', 'Rounded'), ('square', 'Square')],
              (v) => set('corners', v))),
      _Row('general', 'Sort the list', "Favorites (★ in a theme's menu) always come first.",
          _dropdown('${settings['sort'] ?? 'name'}', const [('name', 'By name'), ('recent', 'Recently used first')], (v) => set('sort', v))),
      _Row('general', 'Header buttons', 'The order of the buttons in the header.', const SizedBox(), below: _headerOrder()),
      _Row('general', 'F12 saves a screenshot', 'Save a picture of the Maprisma Theme window while it is open.',
          _switch(settings['screenshot_key'] != false, (on) => set('screenshot_key', on))),
      _Row(
        'general',
        'Screenshots go to',
        shotDir ?? '~/Pictures/MaprismaTheme',
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (shotDir != null) TextButton(onPressed: () => set('screenshot_dir', null), child: const Text('Default')),
          IconButton(tooltip: 'Choose folder…', icon: const Icon(Icons.folder_open_outlined), onPressed: _chooseScreenshotFolder),
        ]),
      ),
      for (final a in apps)
        _Row(
          'themes',
          'App colors: ${a['label']}',
          a['installed'] == true
              ? '${a['note']}${a['enabled'] == true && a['included'] != true && a['id'] != 'vscode' ? ' · not set up yet (applied with the next theme)' : ''}'
              : 'Not installed',
          _switch(a['enabled'] == true, a['installed'] == true ? (on) => setApp(a, on) : null, key: ValueKey('app-${a['id']}')),
        ),
      _Row('day-night', 'Switch themes by time of day', 'At the times below. A theme you pick by hand stays until the next switch.',
          _switch(plan['enabled'] == true, (on) => setSchedule({'enabled': on}))),
      for (final (k, at, label) in const [('day', 'day_at', 'Day theme'), ('night', 'night_at', 'Night theme')])
        _Row(
          'day-night',
          label,
          '',
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _dropdown('${plan[k] ?? ''}', themeChoices, (v) => setSchedule({k: v})),
            _dropdown('${plan[at] ?? (k == 'day' ? '07:00' : '19:00')}',
                [for (final t in _times) (t, 'from $t'), if (!_times.contains(plan[at]) && plan[at] is String) ('${plan[at]}', 'from ${plan[at]}')],
                (v) => setSchedule({at: v})),
          ]),
        ),
      _Row('wallpapers', 'A wallpaper for each workspace',
          "Choose workspaces in a wallpaper's ☰ menu → Show on workspace. Workspaces without one keep the theme's background.",
          _switch(settings['workspace_wallpapers'] == true, (on) => set('workspace_wallpapers', on))),
      _Row('wallpapers', 'A theme for each workspace',
          "Switches COSMIC's theme when you focus a workspace with an assigned theme. Switching takes a moment and changes "
              'every monitor. Leaving the workspace goes back to the theme you used before.',
          _switch(settings['workspace_themes'] == true, (on) => set('workspace_themes', on))),
      _Row('wallpapers', 'Change the wallpaper', "Goes through the current theme's visible wallpapers.",
          _dropdown(settings['slideshow_minutes'] is int ? settings['slideshow_minutes'] as int : 0, _slideshow, (v) => set('slideshow_minutes', v))),
      if (shortcuts['available'] == false)
        _Row('shortcuts', 'Keyboard shortcuts', "COSMIC's keyboard settings were not found, so shortcuts cannot be set here.", const SizedBox()),
      for (final s in [...shortcuts['globals'] as List? ?? const [], ...shortcuts['themes'] as List? ?? const []].cast<Map>())
        _Row(
          'shortcuts',
          '${s['title']}',
          s['label'] == null ? 'No key' : (s['replaces'] ?? '') != '' ? 'Overrides “${s['replaces']}”' : '',
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (s['label'] != null) _caps('${s['label']}'),
            const SizedBox(width: 6),
            TextButton(
              key: ValueKey('shortcut-${s['target']}'),
              onPressed: shortcuts['available'] == true ? () => _openShortcut('${s['target']}', '${s['title']}') : null,
              child: Text(s['label'] == null ? 'Set…' : 'Change…'),
            ),
          ]),
        ),
      _Row('ask-ai', 'Ask AI',
          'Describe a theme and an installed, signed-in AI helper (Claude Code, Codex, pi, Hermes or a local model) suggests it. '
              'Off until you turn it on; it runs only when you click Ask.',
          _switch(settings['ask_ai'] == true, (on) => set('ask_ai', on))),
      _Row(
        'ask-ai',
        'Helper',
        !helpersKnown
            ? 'Not available in this version'
            : helpers.isEmpty
            ? 'No helper is installed and signed in'
            : 'The first ready one unless you choose',
        helpers.isEmpty
            ? const SizedBox()
            : _dropdown<String>(
                '${settings['ask_ai_helper'] ?? ''}',
                [
                  ('', 'First ready one'),
                  for (final h in helpers)
                    ('${h['id']}', '${h['name'] ?? h['id']}${h['local'] == true ? ' (on this PC)' : ''}${h['signed_in'] == false ? ' — not signed in' : ''}'),
                ],
                (v) => set('ask_ai_helper', v.isEmpty ? null : v),
              ),
      ),
      _Row('ask-ai', 'Maprisma hints', 'A ? here and on the Ask AI page opens the note on easy AI setup with Maprisma.',
          _switch(settings['maprisma_hints'] != false, (on) => set('maprisma_hints', on))),
    ];
    final helper = health['helper'] as Map?, applet = health['applet'] as Map?, keys = health['shortcuts'] as Map?;
    final core = health['core'] as Map?;
    out.addAll([
      _Row('integration', 'maprisma-theme-helper', 'Applies themes to COSMIC and reads the workspaces.',
          status(helper?['ok'] == true, helper?['ok'] == true ? 'Found' : 'Not found')),
      _Row('integration', 'maprisma-theme-core', 'The panel applet and the keyboard shortcuts run it.',
          status(core?['ok'] == true, core?['ok'] == true ? 'Found' : 'Not found')),
      _Row(
        'integration',
        'Panel applet',
        applet?['in_panel'] == true
            ? 'In the panel: click toggles this window, scroll changes the wallpaper, right-click shows your favorites'
            : 'Add “Maprisma Theme” in COSMIC Settings → Desktop → Panel → Applets',
        status(applet?['ok'] == true && applet?['in_panel'] == true,
            applet?['ok'] != true ? 'Not installed' : applet?['in_panel'] == true ? 'Ready' : 'Not in the panel'),
      ),
      _Row(
        'integration',
        'Shortcut file',
        '${keys?['note'] ?? ''}'.isNotEmpty ? '${keys!['note']}' : '${keys?['keys'] ?? 0} key(s) in COSMIC\'s custom shortcuts',
        Row(mainAxisSize: MainAxisSize.min, children: [
          status(keys?['ok'] == true, keys?['ok'] == true ? 'OK' : 'Needs attention'),
          const SizedBox(width: 8),
          TextButton(onPressed: _repair, child: const Text('Repair')),
        ]),
      ),
      _Row(
        'integration',
        'Backup and restore',
        'Includes settings, lists, workspace assignments, presets and shortcuts; themes and wallpapers remain in their folders.',
        Row(mainAxisSize: MainAxisSize.min, children: [
          TextButton(onPressed: _export, child: const Text('Export…')),
          TextButton(onPressed: _restore, child: const Text('Restore…')),
        ]),
      ),
    ]);
    return out;
  }

  bool _matches(_Row r) {
    final q = search.trim().toLowerCase();
    if (q.isEmpty) return r.section == section;
    final name = _sections.firstWhere((s) => s.$1 == r.section).$2;
    return '${r.title} ${r.hint} $name'.toLowerCase().contains(q);
  }

  Widget _rowWidget(_Row r) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (r.hint.isNotEmpty)
                  Text(r.hint, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              ]),
            ),
            const SizedBox(width: 12),
            r.control,
          ]),
          if (r.below != null) Padding(padding: const EdgeInsets.only(top: 4), child: r.below!),
        ],
      ),
    );
  }

  Widget _content() {
    final all = rows();
    final shown = all.where(_matches).toList();
    final scheme = Theme.of(context).colorScheme;
    final searching = search.trim().isNotEmpty;
    final children = <Widget>[];
    if (!searching) {
      final hint = _sectionHints[section];
      children.add(Text(_sections.firstWhere((s) => s.$1 == section).$2, style: Theme.of(context).textTheme.titleMedium));
      if (hint != null) {
        children.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(hint, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ));
      }
      children.addAll(shown.map(_rowWidget));
    } else {
      String? last;
      for (final r in shown) {
        if (r.section != last) {
          last = r.section;
          children.add(Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_sections.firstWhere((s) => s.$1 == r.section).$2, style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)),
          ));
        }
        children.add(_rowWidget(r));
      }
      if (shown.isEmpty) children.add(const Padding(padding: EdgeInsets.all(8), child: Text('No setting matches your search.')));
    }
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: children);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SubPage(
      title: 'Settings',
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (context, size) {
              final wide = size.maxWidth >= 720;
              final field = Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  key: const ValueKey('settings-search'),
                  controller: _search,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 18), hintText: 'Search settings'),
                  onChanged: (v) => setState(() => search = v),
                ),
              );
              final reset = Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton.icon(
                  key: const ValueKey('settings-reset'),
                  onPressed: _reset,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('Reset to defaults'),
                ),
              );
              if (wide) {
                return Row(children: [
                  SizedBox(
                    width: 230,
                    child: Column(children: [
                      field,
                      Expanded(
                        child: ListView(children: [
                          for (final (key, name, icon) in _sections)
                            ListTile(
                              dense: true,
                              leading: Icon(icon, size: 18),
                              title: Text(name),
                              selected: search.isEmpty && section == key,
                              selectedTileColor: scheme.secondaryContainer.withValues(alpha: .5),
                              onTap: () => setState(() {
                                section = key;
                                search = '';
                                _search.clear();
                              }),
                            ),
                        ]),
                      ),
                      reset,
                    ]),
                  ),
                  VerticalDivider(width: 1, color: scheme.outlineVariant),
                  Expanded(child: _content()),
                ]);
              }
              return Column(children: [
                field,
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final (key, name, _) in _sections)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(name),
                            selected: search.isEmpty && section == key,
                            onSelected: (_) => setState(() {
                              section = key;
                              search = '';
                              _search.clear();
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(child: _content()),
                Align(alignment: Alignment.centerLeft, child: reset),
              ]);
            }),
    );
  }
}
