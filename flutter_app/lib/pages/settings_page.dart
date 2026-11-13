import '../i18n.dart';
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart' show flipDelayChoices, normalizeFlipDelay;

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
List<(String, String)> get _sections => [
  ('general', tr("General")),
  ('themes', tr("Themes")),
  ('day-night', tr("Day and night")),
  ('wallpapers', tr("Wallpapers")),
  ('shortcuts', tr("Keyboard shortcuts")),
  ('screenshots', tr("Screenshots")),
  ('ask-ai', tr("Ask AI")),
  ('integration', tr("Integration and backup")),
];

Map<String, String> get _sectionHints => {
  'wallpapers': tr("Scroll on the panel icon for the next or previous wallpaper; right-click it for your favorite themes."),
  'shortcuts':
      tr("Give a theme its own key in its ⋮ menu → Shortcut…. Keys are desktop custom shortcuts; a key taken from another shortcut works again when you remove yours."),
  'themes':
      tr("Apps get the theme colors through one marked include line in their own config (a backup is kept). Switching an app off removes that line again."),
};

List<(int, String)> get _slideshow => [
  (0, tr("Never")),
  (5, tr("Every 5 minutes")),
  (10, tr("Every 10 minutes")),
  (15, tr("Every 15 minutes")),
  (30, tr("Every 30 minutes")),
  (60, tr("Every hour")),
  (120, tr("Every 2 hours")),
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
  /// The helper every Maprisma app uses (Maprisma Settings → AI): the one in use, and whether
  /// that is automatic (the first ready one).
  String? helperInUse;
  bool helperAuto = true;
  Map<String, dynamic> shortcuts = {}, health = {}, animations = {};
  bool helpersKnown = false, loading = true, animationBusy = false;
  String section = 'general', search = '';

  /// The section shown: one the sidebar offers. Keyboard shortcuts leaves it when the desktop
  /// turns out to have none (Hyprland: the first caps are COSMIC's until desktop.info answers),
  /// and a pane chosen meanwhile would stay blank.
  String get _shown => section == 'shortcuts' && !app.can('shortcuts') ? 'general' : section;
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
      app.can('shortcuts') ? _try('shortcuts.list') : Future.value(null),
      _try('ask.helpers'),
      _try('health.get'),
      app.can('animations') ? _try('animations.get') : Future.value(null),
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
      helperInUse = results[5]?['chosen'] as String?;
      helperAuto = results[5]?['choice'] is! String || results[5]?['choice'] == 'auto' || results[5]?['choice'] != helperInUse;
      helpers = [
        for (final x in h is List ? h : const [])
          if (x is Map && x['installed'] != false) x,
      ];
      health = results[6] ?? const {};
      animations = results[7] ?? const {};
      loading = false;
    });
  }

  Future<void> set(String key, Object? value) async {
    final r = await app.run('settings.set', {'key': key, 'value': value});
    if (r == null || !mounted) return;
    setState(() => settings = Map<String, dynamic>.from(r['settings'] as Map));
    if (key == 'language') app.useLanguage(value as String);
    app.changed();
  }

  /// Turns a desktop animation on or off; KWin follows at once.
  /// While a change runs, or the state could not be read, the switches wait.
  Future<void> setAnimation(String key, bool on) async {
    setState(() => animationBusy = true);
    final r = await app.run('animations.set', {key: on}) ?? await _try('animations.get');
    if (!mounted) return;
    setState(() {
      animations = {'workspace': r?['workspace'], 'window': r?['window']};
      animationBusy = false;
    });
  }

  /// The switch for one animation: off while its state is unknown.
  Widget _animationSwitch(String key) {
    final v = animations[key];
    return _switch(v == true, v is bool && !animationBusy ? (on) => setAnimation(key, on) : null, key: ValueKey('anim-$key'));
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
          trf("{0}'s config is laid out so that a line cannot be added safely: include ~/.config/maprisma-theme/current/ yourself", [a['label']]),
        );
      case 'failed':
        app.notify(trf("{0}'s config could not be changed", [a['label']]));
      case 'ok':
        app.notify(on ? trf("{0} uses the theme colors", [a['label']]) : trf("{0} keeps its own colors", [a['label']]));
      default:
        if (!on) app.notify(trf("{0} keeps its own colors", [a['label']]));
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
        borderRadius: BorderRadius.circular(cornerSizes(context).control),
      ),
      child: DropdownButton<T>(
        key: key,
        value: choices.any((c) => c.$1 == value) ? value : choices.first.$1,
        isDense: true,
        underline: const SizedBox(),
        dropdownColor: look.bg,
        borderRadius: BorderRadius.circular(corners(context)), // the open list: a pop-up
        style: Theme.of(context).textTheme.bodySmall!.copyWith(color: look.fg),
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 24),
        side: BorderSide(color: look.fg.withValues(alpha: .35)),
        textStyle: Theme.of(context).textTheme.labelSmall,
      ),
      child: icon == null ? Text(label) : Icon(icon, size: 14),
    );
    return tooltip == null ? b : Tooltip(message: tooltip, child: b);
  }

  Widget _caps(String label) {
    final look = Look.of(context);
    final r = cornerSizes(context).control;
    return Wrap(
      spacing: 4,
      children: [
        for (final part in label.split(' + '))
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: look.fg.withValues(alpha: .35)),
              borderRadius: BorderRadius.circular(r),
              color: look.fg.withValues(alpha: .08),
            ),
            child: Text(part, style: textRole(Theme.of(context).textTheme.labelMedium).copyWith(fontWeight: FontWeight.w600)),
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
      confirmButtonText: tr("Choose"),
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
    if (r != null) app.notify(trf("Backup saved: {0}", [r['path']]));
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
      tr("Restore this backup?"),
      trf("Replaces: {0}.{1}\nA copy of the current state is saved in ~/.config/maprisma-theme/backups/ first.", [files.join(', '), removes.isEmpty ? '' : trf("\nRemoves (not in the backup): {0}.", [removes.join(', ')])]),
      action: tr("Restore"),
    );
    if (!ok) return;
    final r = await app.run('backup.restore', {'path': file.path});
    if (r == null) return;
    app.notify(trf("Backup restored. The previous state is in {0}", [r['safety_copy']]));
    app.changed();
  }

  Future<void> _repair() async {
    final r = await app.run('health.repair');
    if (r == null || !mounted) return;
    setState(() => health = r);
    app.notify(tr("Written again"));
  }

  Future<void> _reset() async {
    final ok = await confirm(
      context,
      tr("Reset to defaults?"),
      tr("Resets corners, sorting, header button order, schedule, wallpaper rotation, and screenshot key and folder. Keeps favorites, hidden themes, shortcuts and saved workspace assignments; themes per workspace turn off."),
      action: tr("Reset"),
    );
    if (!ok) return;
    final r = await app.run('settings.reset');
    if (r == null) return;
    app.changed();
    await load();
    app.notify(tr("Settings reset"));
  }

  // --- rows ------------------------------------------------------------------------

  String get _cornersTip =>
      tr("Corners of the window, its cards and every control (buttons, choice boxes, fields). “Like windows” follows the desktop's window rounding.");

  List<_Row> rows() {
    final marks = markColors(context);
    Widget status(bool ok, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(ok ? Icons.check_circle_outline : Icons.error_outline, size: 14, color: ok ? marks.running : marks.update),
        const SizedBox(width: 8),
        Text(text, style: textRole(Theme.of(context).textTheme.bodySmall)),
      ],
    );
    final themeChoices = <(String, String)>[('', tr("Choose…")), for (final t in themes) ('${t['slug']}', '${t['name']}')];
    final shotDir = settings['screenshot_dir'] as String?;
    final radius = app.windowRadius;
    final ready = [
      for (final h in helpers)
        if (h['signed_in'] != false) h,
    ];
    final out = <_Row>[
      _Row('general', tr('Language'), '',
        _dropdown(settings['language'] as String? ?? 'auto', [
          ('auto', trf('System ({0})', [languageNames[systemLanguage()]!])),
          ...languageNames.entries.map((e) => (e.key, e.value)),
        ], (value) => set('language', value))),
      _Row(
        'general',
        tr("Corners"),
        _cornersTip,
        _dropdown('${settings['corners'] ?? 'windows'}', [
          ('windows', radius == null ? tr("Like windows") : trf("Like windows ({0} px)", [radius])),
          ('slight', trf("Slightly rounded ({0} px)", [slightRadius])),
          ('rounded', trf("Rounded ({0} px)", [roundedRadius])),
          ('square', tr("Square")),
        ], (v) => set('corners', v)),
      ),
      if (app.can('animations')) ...[
        _Row(
          'general',
          tr("Workspace switch animation"),
          tr("The slide when you switch workspaces. Off switches at once."),
          _animationSwitch('workspace'),
        ),
        _Row(
          'general',
          tr("Window open animation"),
          tr("The zoom or fade when a window opens or closes. Off places a new tiled window at once."),
          _animationSwitch('window'),
        ),
      ],
      _Row(
        'themes',
        tr("Sort the list"),
        tr("Favorites (★ in a theme's menu) always come first."),
        _dropdown('${settings['sort'] ?? 'name'}', [
          ('name', tr("By name")),
          ('recent', tr("Recently used first")),
        ], (v) => set('sort', v)),
      ),
      _Row(
        'themes',
        tr("3D flip to wallpaper on hover"),
        tr("Hovering a theme card flips its preview in 3D to show the theme's wallpaper."),
        _switch(
          settings['preview_flip_3d'] != false,
          (on) => set('preview_flip_3d', on),
          key: const ValueKey('setting-preview-flip-3d'),
        ),
      ),
      _Row(
        'themes',
        tr("3D rotation delay"),
        tr("Seconds before a selected theme card starts rotating. 0 keeps the preview and shows left/right arrows immediately."),
        _dropdown<num>(
          settings['preview_flip_delay'] is num ? normalizeFlipDelay(settings['preview_flip_delay'] as num) : 2,
          [
            for (final s in flipDelayChoices)
              (s, s == 0 ? tr("0 s (arrows only)") : trf("{0} s", [s])),
          ],
          (v) => set('preview_flip_delay', v),
          key: const ValueKey('setting-preview-flip-delay'),
        ),
      ),
      _Row(
        'themes',
        tr("Apply theme when pinning wallpaper"),
        tr("On: pinning a wallpaper on another theme switches to that theme immediately. Off: only saves it as that theme’s current wallpaper."),
        _switch(
          settings['preview_pin_apply_theme'] != false,
          (on) => set('preview_pin_apply_theme', on),
          key: const ValueKey('setting-preview-pin-apply-theme'),
        ),
      ),
      _Row(
        'themes',
        tr("Big preview on click"),
        tr("Clicking or pressing Enter on a theme card opens a large interactive preview overlay inside the window. Off opens the theme’s wallpapers page directly."),
        _switch(
          settings['preview_big_card'] != false,
          (on) => set('preview_big_card', on),
          key: const ValueKey('setting-preview-big-card'),
        ),
      ),
      _Row(
        'themes',
        tr("Auto-rotate big preview"),
        tr("Automatically flips the big preview to its first wallpaper after the 3D rotation delay. Off keeps the theme preview until you use the arrows."),
        _switch(
          settings['preview_big_auto_rotate'] != false,
          (on) => set('preview_big_auto_rotate', on),
          key: const ValueKey('setting-preview-big-auto-rotate'),
        ),
      ),
      for (final a in apps)
        _Row(
          'themes',
          trf("App colors: {0}", [a['label']]),
          a['supported'] == false
              ? '${a['note']}'
              : a['installed'] == true
              ? '${a['note']}${a['enabled'] == true && a['included'] != true ? tr(" · not set up yet (applied with the next theme)") : ''}'
              : tr("Not installed"),
          _switch(
            a['enabled'] == true && a['supported'] != false,
            a['installed'] == true && a['supported'] != false ? (on) => setApp(a, on) : null,
            key: ValueKey('app-${a['id']}'),
          ),
        ),
      _Row(
        'day-night',
        tr("Switch themes by time of day"),
        tr("At the times below. A theme you pick by hand stays until the next switch."),
        _switch(plan['enabled'] == true, (on) => setSchedule({'enabled': on})),
      ),
      for (final (k, at, label) in [('day', 'day_at', tr("Day theme")), ('night', 'night_at', tr("Night theme"))])
        _Row(
          'day-night',
          label,
          '',
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _dropdown('${plan[k] ?? ''}', themeChoices, (v) => v.isEmpty ? null : setSchedule({k: v})),
              _dropdown('${plan[at] ?? (k == 'day' ? '07:00' : '19:00')}', [
                for (final t in _times) (t, trf("from {0}", [t])),
                if (!_times.contains(plan[at]) && plan[at] is String) ('${plan[at]}', trf("from {0}", [plan[at]])),
              ], (v) => setSchedule({at: v})),
            ],
          ),
        ),
      _Row(
        'wallpapers',
        tr("A wallpaper for each workspace"),
        tr("Choose workspaces in a wallpaper's ☰ menu → Show on workspace. Workspaces without one keep the theme's background."),
        _switch(settings['workspace_wallpapers'] == true, (on) => set('workspace_wallpapers', on)),
      ),
      _Row(
        'wallpapers',
        tr("A theme for each workspace"),
        trf("Switches {0}'s theme when you focus a workspace with an assigned theme. Switching takes a moment and changes every monitor. Leaving the workspace goes back to the theme you used before.", [app.desktopName]),
        _switch(settings['workspace_themes'] == true, (on) => set('workspace_themes', on)),
      ),
      _Row(
        'wallpapers',
        tr("Change the wallpaper"),
        tr("Goes through the current theme's visible wallpapers."),
        _dropdown(
          settings['slideshow_minutes'] is int ? settings['slideshow_minutes'] as int : 0,
          _slideshow,
          (v) => set('slideshow_minutes', v),
        ),
      ),
      if (shortcuts['available'] == false)
        _Row(
          'shortcuts',
          tr("Keyboard shortcuts"),
          trf("{0}'s keyboard settings were not found, so shortcuts cannot be set here.", [app.desktopName]),
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
              ? tr("No key yet")
              : (s['replaces'] ?? '') != ''
              ? trf("Overrides “{0}”", [s['replaces']])
              : '',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s['label'] != null) ...[_caps('${s['label']}'), const SizedBox(width: 8)],
              _small(
                s['label'] == null ? tr("Set…") : tr("Change…"),
                shortcuts['available'] == true ? () => _openShortcut('${s['target']}', '${s['title']}') : null,
                key: ValueKey('shortcut-${s['target']}'),
              ),
            ],
          ),
        ),
      _Row(
        'screenshots',
        tr("F12 saves a screenshot"),
        tr("Save a picture of the Maprisma Theme window while it is open."),
        _switch(settings['screenshot_key'] != false, (on) => set('screenshot_key', on)),
      ),
      _Row(
        'screenshots',
        tr("Screenshots go to"),
        shotDir ?? '~/Pictures/MaprismaTheme',
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                shotDir ?? '~/Pictures/MaprismaTheme',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textRole(Theme.of(context).textTheme.bodySmall),
              ),
            ),
            const SizedBox(width: 8),
            if (shotDir != null) ...[_small(tr("Default"), () => set('screenshot_dir', null)), const SizedBox(width: 8)],
            _small(
              tr("Choose folder…"),
              _chooseScreenshotFolder,
              icon: Icons.folder_open_outlined,
              tooltip: tr("Choose folder…"),
            ),
          ],
        ),
      ),
      _Row(
        'ask-ai',
        tr("Ask AI"),
        tr("Describe a theme and an installed, signed-in AI helper (Claude Code, Codex, Gemini CLI, pi, Hermes, another coding agent or a local model) suggests it. Off until you turn it on; it runs only when you click Ask."),
        _switch(settings['ask_ai'] == true, (on) => set('ask_ai', on)),
      ),
      _Row(
        'ask-ai',
        '',
        '',
        const SizedBox(),
        below: Text(
          !helpersKnown
              ? tr("Helpers: not available in this version")
              : ready.isEmpty
              ? tr("Helpers: none is installed and signed in")
              : trf("Helpers: {0}", [ready.map((h) => '${h['name'] ?? h['id']}${h['local'] == true ? tr(" (on this PC)") : ''}${h['verified'] == false ? tr(" (untested)") : ''}').join(', ')]),
          style: hintStyle(context),
        ),
      ),
      // One helper for every Maprisma app: chosen in Maprisma Settings (or on the Ask AI page).
      if (helpers.isNotEmpty)
        _Row(
          'ask-ai',
          tr("Helper"),
          tr("Set in Maprisma Settings → AI"),
          Text(
            [
              if (helperAuto) tr("First ready one"),
              ?helpers.where((h) => h['id'] == helperInUse).map((h) => '${h['name'] ?? h['id']}').firstOrNull,
            ].join(' · '),
            style: hintStyle(context),
          ),
        ),
      _Row(
        'ask-ai',
        tr("Search the web for wallpapers"),
        tr("A helper that can search the web (now Claude Code) also looks for wallpaper pictures beyond wallhaven.cc. It takes longer and uses more of your plan or tokens. The pictures are downloaded only from public https addresses and checked before they are shown."),
        _switch(settings['ask_ai_web'] != false, (on) => set('ask_ai_web', on)),
      ),
      _Row(
        'ask-ai',
        tr("Maprisma hints"),
        tr("A ? here and on the Ask AI page opens the note on easy AI setup with Maprisma."),
        _switch(settings['maprisma_hints'] != false, (on) => set('maprisma_hints', on)),
      ),
    ];
    final helper = health['helper'] as Map?, applet = health['applet'] as Map?, keys = health['shortcuts'] as Map?;
    final core = health['core'] as Map?;
    out.addAll([
      _Row(
        'integration',
        helper?['name'] as String? ?? (app.desktopName == 'COSMIC' ? 'maprisma-theme-helper' : trf("{0} integration", [app.desktopName])),
        app.can('workspaces') ? trf("Applies themes to {0} and reads the workspaces.", [app.desktopName]) : app.can('appearance') ? trf("Applies themes to {0}.", [app.desktopName]) : tr("App colors use templates; desktop integration is not available yet."),
        status(helper?['ok'] == true, !app.can('appearance') ? tr("Not available") : helper?['ok'] == true ? tr("Found") : tr("Not found")),
      ),
      _Row(
        'integration',
        'maprisma-theme-core',
        tr("Applies themes and manages app settings."),
        status(core?['ok'] == true, core?['ok'] == true ? tr("Found") : tr("Not found")),
      ),
      _Row(
        'integration',
        tr("Panel applet"),
        applet?['in_panel'] == true
            ? tr("In the panel: click toggles this window, scroll changes the wallpaper, right-click shows your favorites")
            : trf("Add “Maprisma Theme” in {0} Settings → Desktop → Panel → Applets", [app.desktopName]),
        status(
          applet?['ok'] == true && applet?['in_panel'] == true,
          applet?['ok'] != true
              ? tr("Not installed")
              : applet?['in_panel'] == true
              ? tr("Ready")
              : tr("Not in the panel"),
        ),
      ),
      _Row(
        'integration',
        tr("Shortcut file"),
        '${keys?['note'] ?? ''}'.isNotEmpty
            ? '${keys!['note']}'
            : trf("{0} key(s) in {1}'s custom shortcuts", [keys?['keys'] ?? 0, app.desktopName]),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            status(keys?['ok'] == true, keys?['ok'] == true ? 'OK' : tr("Needs attention")),
            const SizedBox(width: 8),
            _small(tr("Repair"), _repair),
          ],
        ),
      ),
      _Row(
        'integration',
        tr("Backup and restore"),
        tr("Includes settings, lists, workspace assignments, presets and shortcuts; themes and wallpapers remain in their folders."),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [_small(tr("Export…"), _export), const SizedBox(width: 8), _small(tr("Restore…"), _restore)],
        ),
      ),
    ]);
    out.removeWhere((r) =>
      (!app.can('shortcuts') && (r.section == 'shortcuts' || r.title == tr('Shortcut file'))) ||
      (!app.can('panel') && r.title == tr('Panel applet')) ||
      (!app.can('wallpaper') && r.title == tr('Change the wallpaper')) ||
      (!app.can('workspaces') && (r.title == tr('A wallpaper for each workspace') || r.title == tr('A theme for each workspace'))));
    return out;
  }

  String _sectionName(String key) => _sections.firstWhere((s) => s.$1 == key).$2;

  bool _matches(_Row r) {
    final q = search.trim().toLowerCase();
    if (q.isEmpty) return r.section == _shown;
    final name = _sectionName(r.section).toLowerCase();
    return name.contains(q) || '${r.title} ${r.hint}'.toLowerCase().contains(q);
  }

  /// A line as the plugin's: the dim 11 px label in a 130 px column, the
  /// control beside it; the explanation is the tooltip of both.
  Widget _rowWidget(_Row r) {
    final look = Look.of(context);
    if (r.title.isEmpty && r.below != null) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: r.below!);
    }
    Widget tip(Widget w) => r.hint.isEmpty ? w : Tooltip(message: r.hint, child: w);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: tip(Text(r.title, style: Theme.of(context).textTheme.labelMedium!.copyWith(color: look.dim))),
          ),
          const SizedBox(width: 8),
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
        message: (key == 'wallpapers' && !app.can('panel')) ? '' : _sectionHints[key] ?? '',
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
    if (search.trim().isEmpty && _shown == 'general' && !app.can('shortcuts')) {
      children.add(Text(trf("Keyboard shortcuts are not available on {0} yet.", [app.desktopName]), style: hintStyle(context)));
    }
    if (search.trim().isEmpty && _shown == 'wallpapers' && !app.can('workspaces')) {
      children.add(Text(trf("Workspaces are not available on {0} yet.", [app.desktopName]), style: hintStyle(context)));
    }
    if (shown.isEmpty && search.trim().isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(tr("No setting matches your search."), style: hintStyle(context)),
        ),
      );
    }
    return ListView(padding: const EdgeInsets.fromLTRB(0, 4, 4, 12), children: children);
  }

  void _select(String key) => setState(() {
    section = key;
    search = '';
    _search.clear();
  });

  @override
  Widget build(BuildContext context) {
    AppScope.of(context);
    final look = Look.of(context);
    final r = corners(context);
    final reset = _small(
      tr("Reset to defaults"),
      _reset,
      key: const ValueKey('settings-reset'),
      tooltip:
          tr("Resets corners, sorting, header button order, schedule, wallpaper rotation, and screenshot key and folder. Keeps favorites, hidden themes, shortcuts and saved workspace assignments; themes per workspace turn off."),
    );
    return SubPage(
      title: tr("Settings"),
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
                      style: textRole(Theme.of(context).textTheme.bodyMedium),
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.search, size: 18),
                        hintText: tr("Find in Settings"),
                      ),
                      onChanged: (v) => setState(() => search = v),
                    ),
                  );
                  Widget navButton(String key, String name, {bool chip = false}) {
                    final active = search.isEmpty && _shown == key;
                    final c = cornerSizes(context).control;
                    return Material(
                      color: active ? look.selection : Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(c),
                        side: chip && !active ? BorderSide(color: look.fg.withValues(alpha: .25)) : BorderSide.none,
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(c),
                        onTap: () => _select(key),
                        child: Padding(
                          padding: chip
                              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
                              : const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          child: Text(
                            name,
                            style: (chip ? Theme.of(context).textTheme.labelSmall! : Theme.of(context).textTheme.bodySmall!).copyWith(
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
                      const SizedBox(height: 8),
                      if (!wide) ...[
                        SizedBox(
                          height: 30,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final (key, name) in _sections.where((s) => s.$1 != 'shortcuts' || app.can('shortcuts')))
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: navButton(key, name, chip: true),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
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
                            for (final (key, name) in _sections.where((s) => s.$1 != 'shortcuts' || app.can('shortcuts')))
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
