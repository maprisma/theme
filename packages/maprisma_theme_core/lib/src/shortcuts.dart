/// Global keyboard shortcuts on COSMIC (the plugin's theme_shortcuts.py, with
/// Maprisma Launcher's COSMIC shortcut file code): the keys are kept in
/// ~/.config/maprisma-theme/shortcuts.json ({"apply:nord": {"mods": [...],
/// "key": "U"}}) and written as `Spawn(...)` entries of COSMIC's custom
/// shortcuts file (com.system76.CosmicSettings.Shortcuts/v1/custom), marked
/// by their description. A key the user's own entry had is shadowed while
/// ours exists and put back when ours goes ("Rebind"); a COSMIC default is
/// simply overridden by the custom entry, and works again when it goes.
library;

import 'i18n.dart';

import 'dart:io';

import 'context.dart';
import 'posix.dart';
import 'store.dart';
import 'themes.dart';

typedef Combo = Map<String, dynamic>;

const modBits = {'SHIFT': 1, 'CTRL': 4, 'ALT': 8, 'SUPER': 64};
const modOrder = ['SUPER', 'SHIFT', 'CTRL', 'ALT'];
const modLabels = {'SUPER': 'Super', 'SHIFT': 'Shift', 'CTRL': 'Ctrl', 'ALT': 'Alt'};
const defaultShortcutMods = ['SUPER', 'CTRL'];

// Who has a key, from harmless to taken.
const levelFree = 'free', levelSame = 'same', levelOurs = 'ours', levelCustom = 'custom', levelDesktop = 'desktop';

/// The global targets (besides `apply:<slug>`), with their labels.
Map<String, String> get shortcutTargets => {
  'open': tr("Open Maprisma Theme"),
  'bg:next': tr("Next wallpaper"),
  'bg:prev': tr("Previous wallpaper"),
  'theme:next': tr("Next favorite theme"),
};

/// The plugin's action names (backups made with Theme Manager).
const legacyTargets = {'next-wallpaper': 'bg:next', 'prev-wallpaper': 'bg:prev', 'next-favorite': 'theme:next'};
const applyPrefix = 'apply:';

/// COSMIC's built-in shortcuts (tests point it elsewhere).
String cosmicShortcutDefaults = '/usr/share/cosmic/com.system76.CosmicSettings.Shortcuts/v1/defaults';
const ownTag = ' (Maprisma Theme)';

/// The keys the key map offers (keysym names, as COSMIC spells them).
const keyMapRows = [
  ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'minus', 'equal'],
  ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 'bracketleft', 'bracketright'],
  ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'semicolon', 'apostrophe', 'backslash'],
  ['grave', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', 'comma', 'period', 'slash'],
  ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'],
  ['Return', 'space', 'BackSpace', 'Delete', 'Home', 'End', 'Page_Up', 'Page_Down', 'Insert', 'Tab'],
];
final keyMapKeys = [for (final row in keyMapRows) ...row];

String? keyMapKey(Object? name) {
  if (name is! String) return null;
  for (final key in keyMapKeys) {
    if (key.toLowerCase() == name.toLowerCase()) return key;
  }
  return null;
}

bool validTarget(Object? t) =>
    t is String && (shortcutTargets.containsKey(t) || (t.startsWith(applyPrefix) && slugRe.hasMatch(t.substring(applyPrefix.length))));

String? themeOfTarget(String target) => target.startsWith(applyPrefix) ? target.substring(applyPrefix.length) : null;

String targetLabel(String target, {String? themeName}) {
  final slug = themeOfTarget(target);
  return slug != null ? 'Apply ${themeName ?? displayName(slug)}' : shortcutTargets[target] ?? target;
}

// --- combos ------------------------------------------------------------------

final _keyRe = RegExp(r'^[A-Za-z0-9_]{1,32}$');

String? cleanKey(Object? key) {
  final text = key is String ? key.trim() : '';
  if (!_keyRe.hasMatch(text)) return null;
  return text.length == 1 && RegExp(r'^[A-Za-z]$').hasMatch(text) ? text.toUpperCase() : text;
}

Combo? makeCombo(Object? mods, Object? key) {
  final clean = cleanKey(key);
  if (clean == null) return null;
  final names = mods is List ? mods.whereType<String>().toSet() : <String>{};
  return {
    'mods': [
      for (final m in modOrder)
        if (names.contains(m)) m,
    ],
    'key': clean,
  };
}

int modmask(Map combo) => (combo['mods'] as List).fold(0, (a, m) => a + modBits[m]!);
String comboId(Map combo) => '${modmask(combo)}|${(combo['key'] as String).toLowerCase()}';

const _pretty = {
  'RETURN': 'Enter',
  'SPACE': 'Space',
  'ESCAPE': 'Esc',
  'BACKSPACE': 'Backspace',
  'TAB': 'Tab',
  'COMMA': ',',
  'PERIOD': '.',
  'SLASH': '/',
  'MINUS': '-',
  'EQUAL': '=',
  'SEMICOLON': ';',
  'APOSTROPHE': "'",
  'GRAVE': '`',
  'BRACKETLEFT': '[',
  'BRACKETRIGHT': ']',
  'BACKSLASH': r'\',
  'PAGE_UP': 'Page Up',
  'PAGE_DOWN': 'Page Down',
  'DELETE': 'Delete',
  'INSERT': 'Insert',
  'HOME': 'Home',
  'END': 'End',
};

String keyLabel(String key) => _pretty[key.toUpperCase()] ?? (key.length > 1 ? key : key.toUpperCase());
String comboLabel(Map combo) => [for (final m in combo['mods'] as List) modLabels[m]!, keyLabel(combo['key'] as String)].join(' + ');

// --- COSMIC's shortcut file (Maprisma Launcher's shortcuts.dart) ------------------

int ronSkip(String text, int index) {
  while (index < text.length) {
    if (RegExp(r'\s').hasMatch(text[index])) {
      index++;
    } else if (text.startsWith('//', index)) {
      final end = text.indexOf('\n', index);
      index = end < 0 ? text.length : end + 1;
    } else if (text.startsWith('/*', index)) {
      final end = text.indexOf('*/', index);
      if (end < 0) throw FormatException(tr("unterminated comment"));
      index = end + 2;
    } else {
      break;
    }
  }
  return index;
}

int ronFind(String text, int index, String stops) {
  var depth = 0;
  while (index < text.length) {
    final char = text[index];
    if (char == '"' || char == "'") {
      index++;
      while (index < text.length && text[index] != char) {
        index += text[index] == r'\' ? 2 : 1;
      }
      if (index >= text.length) throw FormatException(tr("unterminated string"));
    } else if (text.startsWith('//', index) || text.startsWith('/*', index)) {
      index = ronSkip(text, index);
      continue;
    } else if (depth == 0 && stops.contains(char)) {
      return index;
    } else if ('([{'.contains(char)) {
      depth++;
    } else if (')]}'.contains(char)) {
      depth--;
    }
    index++;
  }
  throw FormatException(tr("unterminated map"));
}

String ronQuote(String text) => '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
String ronUnquote(String text) => text.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);

/// A map entry of a shortcut file, read; the text stays as it was.
Map<String, dynamic> cosmicEntry(String gap, String raw) {
  final colon = ronFind(raw, 0, ':');
  final binding = raw.substring(0, colon), action = raw.substring(colon + 1).trim();
  final mods = RegExp(r'modifiers:\s*\[([^\]]*)\]').firstMatch(binding);
  final key = RegExp(r'key:\s*"((?:[^"\\]|\\.)*)"').firstMatch(binding);
  final description = RegExp(r'description:\s*Some\(\s*"((?:[^"\\]|\\.)*)"').firstMatch(binding);
  Combo? combo;
  if (mods != null && key != null) {
    final names = {for (final m in RegExp('[A-Za-z]+').allMatches(mods[1]!)) m[0]!.toUpperCase()};
    combo = makeCombo(names.toList(), ronUnquote(key[1]!));
  }
  return {'gap': gap, 'raw': raw, 'combo': combo, 'action': action, 'description': description != null ? ronUnquote(description[1]!) : ''};
}

/// (text before the entries, entries, text after); FormatException when it
/// is not a map: such a file is never rewritten.
(String, List<Map<String, dynamic>>, String) parseCosmicShortcuts(String text) {
  final start = ronSkip(text, 0);
  if (!text.startsWith('{', start)) throw FormatException(tr('not a map'));
  final headEnd = start + 1;
  var position = headEnd;
  final entries = <Map<String, dynamic>>[];
  while (true) {
    final begin = ronSkip(text, position);
    if (begin >= text.length) throw FormatException(tr('unterminated map'));
    if (text[begin] == '}') return (text.substring(0, headEnd), entries, text.substring(position));
    final end = ronFind(text, ronFind(text, begin, ':') + 1, ',}');
    final raw = text.substring(begin, end).trimRight();
    entries.add(cosmicEntry(text.substring(position, begin), raw));
    position = begin + raw.length;
    position = ronSkip(text, position);
    if (text.startsWith(',', position)) {
      position++;
    } else {
      position = begin + raw.length;
    }
  }
}

String cosmicSlug(Map combo) => [
  for (final m in combo['mods'] as List) (m as String).toLowerCase(),
  (combo['key'] as String).toLowerCase().replaceAll('_', '-'),
].join('-');

/// "System(Terminal)" → "Terminal", "Focus(Left)" → "Focus Left".
String cosmicActionLabel(String action) {
  final inner = RegExp(r'^System\((.*)\)$').firstMatch(action);
  final text = inner != null ? inner[1]! : action;
  final words = text.replaceAll(RegExp('[()]'), ' ').replaceAll(RegExp('(?<=[a-z])(?=[A-Z])'), ' ');
  return words.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
}

String? spawned(Map entry) {
  final m = RegExp(r'^Spawn\(\s*"((?:[^"\\]|\\.)*)"').firstMatch(entry['action'] as String);
  return m == null ? null : ronUnquote(m[1]!);
}

String bindingText(Map combo, [String description = '']) {
  final names = [for (final m in combo['mods'] as List) modLabels[m]!].join(', ');
  final key = combo['key'] as String;
  final extra = description.isNotEmpty ? ', description: Some(${ronQuote(description)})' : '';
  return '(modifiers: [$names], key: ${ronQuote(key.length == 1 ? key.toLowerCase() : key)}$extra)';
}

// --- the store ------------------------------------------------------------------------

final _safePath = RegExp(r'^/[A-Za-z0-9/._-]+$');
final _safeWord = RegExp(r'^[A-Za-z0-9._+-]+$');

/// One key Maprisma Theme wants bound, in the order they are written. The
/// label and command are worked out only when the binder writes the key
/// (after it has read the desktop's file, so its errors come first).
typedef Binding = ({Combo combo, String target, String Function() label, String Function() command});

/// Where a desktop keeps global keys (docs/multi-desktop.md): COSMIC's custom
/// shortcuts file (shortcuts_cosmic.dart); others later.
abstract interface class ShortcutBinder {
  /// The desktop's shortcut settings are there.
  bool get available;

  /// The id [owners] uses for a combo.
  String keyId(Map combo);

  /// {keyId: (level, description)} for keys the desktop or the user bind now
  /// (ours left out).
  Map<String, (String, String)> owners();

  /// Writes [bindings] as the desktop's keys of Maprisma Theme and [state] to
  /// [stateFile] together: when one fails, both stay as before.
  void write(List<Binding> bindings, String stateFile, Map<String, dynamic> state);

  /// {ok, written, note}: are the [expected] keys of ours written?
  Map<String, dynamic> check(int expected);
}

/// [s] without control characters, at most [max] characters.
String plainText(String s, int max) {
  final flat = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  return flat.length <= max ? flat : flat.substring(0, max);
}

/// Maprisma Theme's shortcuts and the desktop's keys, read fresh on every call.
final class ThemeShortcuts {
  ThemeShortcuts(this.ctx) : binder = ctx.desktop.shortcutBinder(ctx.paths);
  final Ctx ctx;

  /// Null: the desktop has no keys Maprisma Theme can set.
  final ShortcutBinder? binder;

  String get stateFile => ctx.paths.file('shortcuts.json');

  bool get available => binder?.available ?? false;

  /// {target: {mods, key, replaces?}} for valid targets; the plugin's names too.
  Map<String, Combo> load() => cleanShortcuts(readJson(stateFile));

  static Map<String, Combo> cleanShortcuts(Object? raw) {
    final out = <String, Combo>{};
    if (raw is! Map) return out;
    for (final e in raw.entries) {
      final target = legacyTargets[e.key] ?? e.key;
      if (!validTarget(target) || e.value is! Map) continue;
      final v = e.value as Map;
      final combo = makeCombo(v['mods'] ?? const [], v['key']);
      if (combo == null || (combo['mods'] as List).isEmpty) continue;
      final replaces = v['replaces'];
      if (replaces is String && replaces.isNotEmpty) combo['replaces'] = _plain(replaces, 80);
      if (out.values.any((c) => comboId(c) == comboId(combo))) continue;
      out[target as String] = combo;
    }
    return out;
  }

  static String _plain(String s, int max) => plainText(s, max);

  String _name(String target) {
    final slug = themeOfTarget(target);
    return targetLabel(target, themeName: slug == null ? null : findTheme(ctx.paths, slug)?.name);
  }

  /// (level, who) for giving [combo] to [target].
  (String, String) classify(Combo combo, String target, {Map<String, Combo>? state, Map<String, (String, String)>? known}) {
    final cid = comboId(combo);
    for (final e in (state ?? load()).entries) {
      if (comboId(e.value) == cid) return e.key == target ? (levelSame, _name(e.key)) : (levelOurs, _name(e.key));
    }
    final b = binder;
    return b == null ? (levelFree, '') : (known ?? owners())[b.keyId(combo)] ?? (levelFree, '');
  }

  /// The program a key starts: ~/.local/bin first, then PATH.
  String? program(String name) {
    final local = '${ctx.paths.home}/.local/bin/$name';
    if (FileSystemEntity.isFileSync(local) && Posix.instance.executable(local)) return local;
    return which(name, ctx.environment);
  }

  /// The command line COSMIC runs for [target] (it goes through sh, so only
  /// plain paths and fixed words).
  String command(String target) {
    final slug = themeOfTarget(target);
    final List<String> argv;
    if (target == 'open') {
      final gui = program('maprisma-theme');
      if (gui == null) throw RouteError('not_installed', tr("maprisma-theme was not found in ~/.local/bin or on PATH"));
      argv = [gui, '--toggle'];
    } else {
      final core = program('maprisma-theme-core');
      if (core == null) throw RouteError('not_installed', tr("maprisma-theme-core was not found in ~/.local/bin or on PATH"));
      argv = switch (target) {
        'bg:next' => [core, 'bg', 'next'],
        'bg:prev' => [core, 'bg', 'prev'],
        'theme:next' => [core, 'theme', 'next'],
        _ => [core, 'apply', slug!],
      };
    }
    for (final part in argv) {
      if (part.startsWith('/') ? !_safePath.hasMatch(part) : !(_safeWord.hasMatch(part) && !part.startsWith('-') || part == '--toggle')) {
        throw RouteError('unsafe', trf("unsafe word for a key binding: {0}", [part]));
      }
    }
    return argv.join(' ');
  }

  /// {keyId: (level, description)} for keys the desktop or the user bind now.
  Map<String, (String, String)> owners() => binder?.owners() ?? {};

  /// Writes [state]: shortcuts.json and the desktop's keys together.
  /// Keys of themes that are gone are left out (they do nothing).
  void save(Map<String, Combo> state) {
    final json = {
      for (final e in state.entries)
        e.key: {'mods': e.value['mods'], 'key': e.value['key'], if (e.value['replaces'] != null) 'replaces': e.value['replaces']},
    };
    final b = binder;
    if (b == null) {
      writeJson(stateFile, json);
      return;
    }
    final installed = {for (final t in ctx.themes()) t.slug};
    final order = [
      for (final t in shortcutTargets.keys)
        if (state.containsKey(t)) t,
      ...([
        for (final t in state.keys)
          if (themeOfTarget(t) != null) t,
      ]..sort()),
    ];
    final bindings = <Binding>[];
    for (final target in order) {
      final slug = themeOfTarget(target);
      if (slug != null && !installed.contains(slug)) continue;
      bindings.add((combo: state[target]!, target: target, label: () => 'Maprisma Theme: ${_name(target)}', command: () => command(target)));
    }
    b.write(bindings, stateFile, json);
  }

  void _writable() {
    if (!available) throw RouteError('not_available', trf("{0}'s keyboard settings were not found", [ctx.desktop.name]));
  }

  /// Gives [combo] to [target]; a key of another Maprisma Theme target moves
  /// here, a key of COSMIC or the user's own is taken while this one exists.
  Map<String, dynamic> assign(String target, Combo combo) {
    _writable();
    if (!validTarget(target)) throw RouteError('bad_params', 'target');
    final slug = themeOfTarget(target);
    if (slug != null) ctx.theme(slug);
    if ((combo['mods'] as List).isEmpty) throw RouteError('bad_params', 'mods');
    final state = load();
    final (level, owner) = classify(combo, target, state: state);
    if (level == levelSame) throw RouteError('refused', 'same');
    if (level == levelOurs) state.removeWhere((_, c) => comboId(c) == comboId(combo));
    final added = <String, dynamic>{...combo};
    if (level == levelCustom || level == levelDesktop) added['replaces'] = _plain(owner, 80);
    state[target] = added;
    save(state);
    return {'saved': true, 'level': level, 'owner': owner, 'label': comboLabel(combo)};
  }

  /// The key goes; one it took works again.
  Map<String, dynamic> remove(String target) {
    _writable();
    final state = load();
    final old = state.remove(target);
    if (old == null) return {'removed': false};
    save(state);
    return {'removed': true, 'replaces': old['replaces'] ?? ''};
  }

  /// A renamed theme keeps its key.
  void renameTheme(String old, String renamed) {
    final state = load();
    final combo = state.remove('$applyPrefix$old');
    if (combo == null) return;
    state['$applyPrefix$renamed'] = combo;
    if (available) {
      save(state);
    } else {
      writeJson(stateFile, state);
    }
  }

  /// A deleted theme's key is given back.
  bool dropTheme(String slug) {
    final state = load();
    if (state.remove('$applyPrefix$slug') == null) return false;
    if (available) {
      save(state);
    } else {
      writeJson(stateFile, state);
    }
    return true;
  }

  /// Keys of themes that no longer exist go, so the keys are free again.
  List<String> pruneMissing() {
    final state = load();
    final installed = {for (final t in ctx.themes()) t.slug};
    final gone = [
      for (final t in state.keys)
        if (themeOfTarget(t) case final s? when !installed.contains(s)) t,
    ];
    if (gone.isEmpty || !available) return const [];
    for (final t in gone) {
      state.remove(t);
    }
    save(state);
    return [for (final t in gone) themeOfTarget(t)!];
  }

  Map<String, dynamic> shown(String target, Combo c) => {
    'target': target,
    'title': _name(target),
    'mods': c['mods'],
    'key': c['key'],
    'label': comboLabel(c),
    'replaces': c['replaces'] ?? '',
  };

  /// What the shortcut page shows: the current key and every key of the map
  /// with [mods] coloured by its owner.
  Map<String, dynamic> view(String target, List<String> mods) {
    if (!validTarget(target)) throw RouteError('bad_params', 'target');
    final base = {'target': target, 'title': _name(target), 'desktop': ctx.desktop.name, 'default_mods': defaultShortcutMods};
    if (!available) return {...base, 'available': false};
    final state = load();
    final known = owners();
    final current = state[target];
    return {
      ...base,
      'available': true,
      'current': current == null ? null : shown(target, current),
      if (mods.isNotEmpty)
        'keys': [
          for (final key in keyMapKeys)
            if (makeCombo(mods, key) case final combo?)
              () {
                final (level, owner) = classify(combo, target, state: state, known: known);
                return {'key': key, 'label': keyLabel(key), 'level': level, 'owner': owner};
              }(),
        ],
    };
  }
}

/// Modifiers from a route's params (only the four, in order).
List<String> modsParam(Object? value) {
  if (value is! List || value.any((m) => !modOrder.contains(m))) throw RouteError('bad_params', 'mods');
  return [
    for (final m in modOrder)
      if (value.contains(m)) m,
  ];
}
