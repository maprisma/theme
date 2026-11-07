import 'context.dart';
import 'shortcuts.dart';

/// Routes of the shortcut module: COSMIC custom shortcuts for the global
/// targets (open, bg:next, bg:prev, theme:next) and one per theme (`apply:<slug>`).
Map<String, Handler> shortcutRoutes(Ctx ctx) {
  final shortcuts = ThemeShortcuts(ctx);
  String target(Map<String, dynamic> p) {
    final t = str(p, 'target');
    if (!validTarget(t)) throw RouteError('bad_params', 'target');
    return t;
  }

  return {
    /// {labels: {target: [label]}}: what the theme tiles and settings show.
    'shortcuts.labels': (p) async {
      try {
        shortcuts.pruneMissing();
      } on RouteError {
        // the file cannot be written now: show what is stored
      }
      return {
        'labels': {for (final e in shortcuts.load().entries) e.key: [comboLabel(e.value)]},
      };
    },

    /// The four global keys (and every theme key) for the settings page.
    'shortcuts.list': (p) async {
      final state = shortcuts.load();
      return {
        'available': shortcuts.available,
        'desktop': 'COSMIC',
        'globals': [
          for (final t in shortcutTargets.keys)
            state[t] == null ? {'target': t, 'title': shortcutTargets[t]} : shortcuts.shown(t, state[t]!),
        ],
        'themes': [for (final e in state.entries) if (themeOfTarget(e.key) != null) shortcuts.shown(e.key, e.value)],
      };
    },

    /// The page: {available, title, current, keys: [{key, label, level, owner}]}.
    'shortcuts.state': (p) async => shortcuts.view(target(p), modsParam(p['mods'] ?? const [])),

    /// {target, mods, combo_key} → {saved, level, owner, label}.
    'shortcuts.set': (p) async {
      final key = keyMapKey(p['combo_key']);
      if (key == null) throw RouteError('bad_params', 'combo_key');
      final combo = makeCombo(modsParam(p['mods']), key)!;
      return shortcuts.assign(target(p), combo);
    },

    /// {target} → {removed, replaces}.
    'shortcuts.remove': (p) async => shortcuts.remove(target(p)),
  };
}
