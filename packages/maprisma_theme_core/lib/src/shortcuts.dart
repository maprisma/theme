/// Global keyboard shortcuts on COSMIC (the plugin's theme_shortcuts.py, with
/// Maprisma Launcher's COSMIC shortcut file code): the keys are kept in
/// ~/.config/maprisma-theme/shortcuts.json ({"apply:nord": {"mods": [...],
/// "key": "U"}}) and written as `Spawn(...)` entries of COSMIC's custom
/// shortcuts file (com.system76.CosmicSettings.Shortcuts/v1/custom), marked
/// by their description. A key the user's own entry had is shadowed while
/// ours exists and put back when ours goes ("Rebind"); a COSMIC default is
/// simply overridden by the custom entry, and works again when it goes.
library;

import 'dart:convert';
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
const shortcutTargets = {
  'open': 'Open Maprisma Theme',
  'bg:next': 'Next wallpaper',
  'bg:prev': 'Previous wallpaper',
  'theme:next': 'Next favorite theme',
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
  return {'mods': [for (final m in modOrder) if (names.contains(m)) m], 'key': clean};
}

int modmask(Map combo) => (combo['mods'] as List).fold(0, (a, m) => a + modBits[m]!);
String comboId(Map combo) => '${modmask(combo)}|${(combo['key'] as String).toLowerCase()}';

const _pretty = {
  'RETURN': 'Enter', 'SPACE': 'Space', 'ESCAPE': 'Esc', 'BACKSPACE': 'Backspace', 'TAB': 'Tab', 'COMMA': ',',
  'PERIOD': '.', 'SLASH': '/', 'MINUS': '-', 'EQUAL': '=', 'SEMICOLON': ';', 'APOSTROPHE': "'", 'GRAVE': '`',
  'BRACKETLEFT': '[', 'BRACKETRIGHT': ']', 'BACKSLASH': r'\', 'PAGE_UP': 'Page Up', 'PAGE_DOWN': 'Page Down',
  'DELETE': 'Delete', 'INSERT': 'Insert', 'HOME': 'Home', 'END': 'End',
};

String keyLabel(String key) => _pretty[key.toUpperCase()] ?? (key.length > 1 ? key : key.toUpperCase());
String comboLabel(Map combo) =>
    [for (final m in combo['mods'] as List) modLabels[m]!, keyLabel(combo['key'] as String)].join(' + ');

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
      if (end < 0) throw const FormatException('unterminated comment');
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
      if (index >= text.length) throw const FormatException('unterminated string');
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
  throw const FormatException('unterminated map');
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
  return {
    'gap': gap,
    'raw': raw,
    'combo': combo,
    'action': action,
    'description': description != null ? ronUnquote(description[1]!) : '',
  };
}

/// (text before the entries, entries, text after); FormatException when it
/// is not a map: such a file is never rewritten.
(String, List<Map<String, dynamic>>, String) parseCosmicShortcuts(String text) {
  final start = ronSkip(text, 0);
  if (!text.startsWith('{', start)) throw const FormatException('not a map');
  final headEnd = start + 1;
  var position = headEnd;
  final entries = <Map<String, dynamic>>[];
  while (true) {
    final begin = ronSkip(text, position);
    if (begin >= text.length) throw const FormatException('unterminated map');
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

/// Maprisma Theme's shortcuts and COSMIC's file, read fresh on every call.
final class ThemeShortcuts {
  ThemeShortcuts(this.ctx);
  final Ctx ctx;

  String get stateFile => ctx.paths.file('shortcuts.json');
  String get shadowFile => ctx.paths.file('cosmic-shadowed.json');
  String get customFile => '${ctx.paths.cosmicConfig}/com.system76.CosmicSettings.Shortcuts/v1/custom';

  /// COSMIC's shortcut settings are there (its defaults file).
  bool get available => File(cosmicShortcutDefaults).existsSync();

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

  static String _plain(String s, int max) {
    final flat = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
    return flat.length <= max ? flat : flat.substring(0, max);
  }

  static String? _read(String path) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) return null;
    final bytes = Posix.instance.readRegular(path, 1024 * 1024);
    if (bytes == null) throw RouteError('not_available', 'cannot read $path');
    return utf8.decode(bytes, allowMalformed: true);
  }

  (String, List<Map<String, dynamic>>, String) _custom() {
    try {
      return parseCosmicShortcuts(_read(customFile) ?? '{\n}\n');
    } on FormatException catch (e) {
      throw RouteError('not_available', "COSMIC's custom shortcuts file cannot be read: ${e.message}");
    }
  }

  bool _isOwn(Map e) => e['combo'] != null && (e['description'] as String).endsWith(ownTag);

  Map<String, String> _shadowed() => {
    for (final e in readJsonMap(shadowFile).entries)
      if (e.value is String) e.key: e.value as String,
  };

  /// {cosmic slug: (level, description)} for keys COSMIC or the user bind now.
  Map<String, (String, String)> owners() {
    final found = <String, (String, String)>{};
    try {
      final text = _read(cosmicShortcutDefaults);
      if (text != null) {
        for (final e in parseCosmicShortcuts(text).$2) {
          if (e['combo'] != null) found[cosmicSlug(e['combo'])] = (levelDesktop, cosmicActionLabel(e['action'] as String));
        }
      }
    } on FormatException {
      // unreadable defaults: nothing known
    }
    for (final e in _custom().$2) {
      if (e['combo'] == null || _isOwn(e)) continue;
      final slug = cosmicSlug(e['combo']);
      if (e['action'] == 'Disable') {
        found.remove(slug);
        continue;
      }
      final description = e['description'] as String;
      final command = spawned(e);
      found[slug] = (
        levelCustom,
        description.isNotEmpty ? description : command ?? cosmicActionLabel(e['action'] as String),
      );
    }
    // A key ours took from the user stays the user's.
    for (final e in _shadowed().entries) {
      try {
        final entry = cosmicEntry('', e.value);
        final description = entry['description'] as String;
        found[e.key] = (levelCustom, description.isNotEmpty ? description : spawned(entry) ?? cosmicActionLabel(entry['action'] as String));
      } on FormatException {
        continue;
      }
    }
    return found;
  }

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
    return (known ?? owners())[cosmicSlug(combo)] ?? (levelFree, '');
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
      if (gui == null) throw RouteError('not_installed', 'maprisma-theme was not found in ~/.local/bin or on PATH');
      argv = [gui, '--toggle'];
    } else {
      final core = program('maprisma-theme-core');
      if (core == null) throw RouteError('not_installed', 'maprisma-theme-core was not found in ~/.local/bin or on PATH');
      argv = switch (target) {
        'bg:next' => [core, 'bg', 'next'],
        'bg:prev' => [core, 'bg', 'prev'],
        'theme:next' => [core, 'theme', 'next'],
        _ => [core, 'apply', slug!],
      };
    }
    for (final part in argv) {
      if (part.startsWith('/') ? !_safePath.hasMatch(part) : !(_safeWord.hasMatch(part) && !part.startsWith('-') || part == '--toggle')) {
        throw RouteError('unsafe', 'unsafe word for a key binding: $part');
      }
    }
    return argv.join(' ');
  }

  /// Writes [state]: shortcuts.json and COSMIC's file in one atomic write.
  /// Keys of themes that are gone are left out (they do nothing).
  void save(Map<String, Combo> state) {
    final installed = {for (final t in ctx.themes()) t.slug};
    final (head, entries, tail0) = _custom();
    var tail = tail0;
    final original = head + entries.map((e) => '${e['gap']}${e['raw']},').join() + tail;
    final shadowed = _shadowed();

    void remove(Map<String, dynamic> entry) {
      final index = entries.indexOf(entry);
      entries.removeAt(index);
      final gap = entry['gap'] as String;
      if (gap.trim().isNotEmpty) {
        if (index < entries.length) {
          entries[index]['gap'] = gap + (entries[index]['gap'] as String);
        } else {
          tail = gap + tail;
        }
      }
    }

    void add(String raw) => entries.add(cosmicEntry('\n    ', raw));

    for (final e in [for (final e in entries) if (_isOwn(e)) e]) {
      remove(e);
    }
    final wanted = <String, (Combo, String)>{};
    final order = [
      for (final t in shortcutTargets.keys) if (state.containsKey(t)) t,
      ...([for (final t in state.keys) if (themeOfTarget(t) != null) t]..sort()),
    ];
    for (final target in order) {
      final slug = themeOfTarget(target);
      if (slug != null && !installed.contains(slug)) continue;
      wanted[cosmicSlug(state[target]!)] = (state[target]!, target);
    }
    for (final MapEntry(key: slug, value: (combo, target)) in wanted.entries) {
      final other = entries.where((e) => e['combo'] != null && cosmicSlug(e['combo']) == slug && !_isOwn(e)).firstOrNull;
      if (other != null) {
        shadowed.putIfAbsent(slug, () => other['raw'] as String);
        remove(other);
      }
      final label = 'Maprisma Theme: ${_name(target)}';
      add('${bindingText(combo, _plain(label, 100) + ownTag)}: Spawn(${ronQuote(command(target))})');
    }
    for (final slug in [for (final s in shadowed.keys) if (!wanted.containsKey(s)) s]) {
      add(shadowed.remove(slug)!);
    }
    final text = head + entries.map((e) => '${e['gap']}${e['raw']},').join() + tail;
    parseCosmicShortcuts(text); // never hand COSMIC a file that cannot be read back
    // COSMIC's file first: while it is not written, shortcuts.json and
    // cosmic-shadowed.json still describe it (a shadowed key of the user's
    // is never lost); when ours fail afterwards, all three go back.
    final mode = _modeOf(customFile) ?? 420;
    if (text != original) writeText(customFile, text, mode: mode);
    final oldState = _raw(stateFile), oldShadow = _raw(shadowFile);
    try {
      writeJson(stateFile, {
        for (final e in state.entries) e.key: {'mods': e.value['mods'], 'key': e.value['key'], if (e.value['replaces'] != null) 'replaces': e.value['replaces']},
      });
      writeJson(shadowFile, shadowed);
    } catch (_) {
      _restore(stateFile, oldState);
      _restore(shadowFile, oldShadow);
      if (text != original) _restore(customFile, utf8.encode(original), mode: mode);
      rethrow;
    }
  }

  /// A small file's bytes as they are now (null: none).
  static List<int>? _raw(String path) {
    try {
      return File(path).existsSync() ? File(path).readAsBytesSync() : null;
    } on FileSystemException {
      return null;
    }
  }

  /// Best effort: [path] as it was ([bytes] null: it did not exist).
  static void _restore(String path, List<int>? bytes, {int mode = 384}) {
    try {
      if (bytes == null) {
        if (File(path).existsSync()) File(path).deleteSync();
      } else {
        writeAtomic(path, bytes, mode: mode);
      }
    } on Object {
      // nothing more can be done
    }
  }

  static int? _modeOf(String path) {
    try {
      final s = File(path).statSync();
      return s.type == FileSystemEntityType.file ? s.mode & 0x1ff : null;
    } on FileSystemException {
      return null;
    }
  }

  void _writable() {
    if (!available) throw RouteError('not_available', "COSMIC's keyboard settings were not found");
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
    final gone = [for (final t in state.keys) if (themeOfTarget(t) case final s? when !installed.contains(s)) t];
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
    final base = {'target': target, 'title': _name(target), 'desktop': 'COSMIC', 'default_mods': defaultShortcutMods};
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
  return [for (final m in modOrder) if (value.contains(m)) m];
}
