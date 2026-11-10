/// COSMIC's custom shortcuts file (com.system76.CosmicSettings.Shortcuts/v1/custom):
/// our keys are `Spawn(...)` entries marked by [ownTag]; a key of the user's
/// own entry is shadowed (cosmic-shadowed.json) while ours exists.
library;

import 'i18n.dart';

import 'dart:convert';
import 'dart:io';

import 'context.dart';
import 'paths.dart';
import 'posix.dart';
import 'shortcuts.dart';
import 'store.dart';

final class CosmicShortcutBinder implements ShortcutBinder {
  CosmicShortcutBinder(this.paths);
  final Paths paths;

  String get shadowFile => paths.file('cosmic-shadowed.json');
  String get customFile => '${paths.cosmicConfig}/com.system76.CosmicSettings.Shortcuts/v1/custom';

  /// COSMIC's shortcut settings are there (its defaults file).
  @override
  bool get available => File(cosmicShortcutDefaults).existsSync();

  @override
  String keyId(Map combo) => cosmicSlug(combo);

  static String? _read(String path) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) return null;
    final bytes = Posix.instance.readRegular(path, 1024 * 1024);
    if (bytes == null) throw RouteError('not_available', trf("cannot read {0}", [path]));
    return utf8.decode(bytes, allowMalformed: true);
  }

  (String, List<Map<String, dynamic>>, String) _custom() {
    try {
      return parseCosmicShortcuts(_read(customFile) ?? '{\n}\n');
    } on FormatException catch (e) {
      throw RouteError('not_available', trf("COSMIC's custom shortcuts file cannot be read: {0}", [e.message]));
    }
  }

  bool _isOwn(Map e) => e['combo'] != null && (e['description'] as String).endsWith(ownTag);

  Map<String, String> _shadowed() => {
    for (final e in readJsonMap(shadowFile).entries)
      if (e.value is String) e.key: e.value as String,
  };

  /// {cosmic slug: (level, description)} for keys COSMIC or the user bind now.
  @override
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
      found[slug] = (levelCustom, description.isNotEmpty ? description : command ?? cosmicActionLabel(e['action'] as String));
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

  @override
  void write(List<Binding> bindings, String stateFile, Map<String, dynamic> state) {
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

    for (final e in [
      for (final e in entries)
        if (_isOwn(e)) e,
    ]) {
      remove(e);
    }
    final wanted = <String, Binding>{};
    for (final b in bindings) {
      wanted[cosmicSlug(b.combo)] = b;
    }
    for (final MapEntry(key: slug, value: b) in wanted.entries) {
      final other = entries.where((e) => e['combo'] != null && cosmicSlug(e['combo']) == slug && !_isOwn(e)).firstOrNull;
      if (other != null) {
        shadowed.putIfAbsent(slug, () => other['raw'] as String);
        remove(other);
      }
      add('${bindingText(b.combo, plainText(b.label(), 100) + ownTag)}: Spawn(${ronQuote(b.command())})');
    }
    for (final slug in [
      for (final s in shadowed.keys)
        if (!wanted.containsKey(s)) s,
    ]) {
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
      writeJson(stateFile, state);
      writeJson(shadowFile, shadowed);
    } catch (_) {
      _restore(stateFile, oldState);
      _restore(shadowFile, oldShadow);
      if (text != original) _restore(customFile, utf8.encode(original), mode: mode);
      rethrow;
    }
  }

  /// A small file's bytes as they are now (null: none, or not a regular file
  /// of at most 4 MiB): checked on the opened descriptor, never blocks on a FIFO.
  static List<int>? _raw(String path) => Posix.instance.readRegular(path, 4 * 1024 * 1024);

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

  @override
  Map<String, dynamic> check(int expected) {
    var fileOk = true;
    var written = 0;
    String note = '';
    try {
      final text = readSmall(customFile, limit: 1024 * 1024);
      if (text != null) {
        final entries = parseCosmicShortcuts(text).$2;
        written = entries.where((e) => e['combo'] != null && (e['description'] as String).endsWith(ownTag)).length;
      }
    } on FormatException catch (e) {
      fileOk = false;
      note = trf("COSMIC's custom shortcuts file cannot be read: {0}", [e.message]);
    }
    if (fileOk && written != expected) {
      fileOk = false;
      note = trf("{0} key(s) set, {1} in COSMIC's file: Repair writes them again", [expected, written]);
    }
    return {'ok': fileOk, 'written': written, 'note': note};
  }
}
