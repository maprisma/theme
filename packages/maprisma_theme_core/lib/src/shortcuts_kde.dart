/// Global keys on KDE Plasma (docs/multi-desktop.md, step 4): each key of
/// Maprisma Theme is a hidden desktop file `maprisma-theme-key-<n>.desktop`
/// whose `_launch` action kglobalaccel runs itself (as System Settings'
/// "Add Command" does; verified live on Plasma 6.8). The files are the wanted
/// state, written at once; [syncKdeShortcuts] makes kglobalaccel match them
/// over D-Bus (right after a change, and again when the daemon starts or sees
/// shortcuts.json change). A key another action had is taken from it while
/// ours exists and given back after (kde-shadowed.json).
library;

import 'i18n.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'paths.dart';
import 'posix.dart';
import 'bounded.dart';
import 'shortcuts.dart';
import 'store.dart';

/// Caps for the files shortcut sync reads back: our own .desktop files and its state.
const maxDesktopFileBytes = 64 * 1024;
const maxStateFileBytes = 4 * 1024 * 1024;

const kdeKeyPrefix = 'maprisma-theme-key-';

/// The desktop file of a shortcut's target, one per target: letters, digits and '-' stay,
/// every other byte (also '_') becomes `_XX` (hex), so `apply:a.b`, `apply:a+b` and `apply:a_b`
/// never share a file. Files of the older name scheme are no longer wanted and go with the next
/// write (their kglobalaccel entries with the next sync).
String kdeKeyFileName(String target) {
  final out = StringBuffer(kdeKeyPrefix);
  for (final b in utf8.encode(target)) {
    final c = String.fromCharCode(b);
    if (RegExp(r'^[A-Za-z0-9-]$').hasMatch(c)) {
      out.write(c);
    } else {
      out.write('_${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return '$out.desktop';
}

/// The session bus of [environment] (never the process's own when the
/// environment has none: tests and other sessions stay apart), or null.
DBusClient? sessionBus(Map<String, String> environment) {
  final address = environment['DBUS_SESSION_BUS_ADDRESS'];
  if (address == null || address.isEmpty) return null;
  try {
    return DBusClient(DBusAddress(address));
  } on Object {
    return null;
  }
}

// Qt key codes (QKeySequence as kglobalaccel's a(ai) carries them).
const _qtMods = {'SUPER': 0x10000000, 'CTRL': 0x04000000, 'ALT': 0x08000000, 'SHIFT': 0x02000000};
const _qtModNames = {'META': 'SUPER', 'CTRL': 'CTRL', 'ALT': 'ALT', 'SHIFT': 'SHIFT'};
const _qtKeys = {
  'Return': 0x01000004,
  'space': 0x20,
  'BackSpace': 0x01000003,
  'Delete': 0x01000007,
  'Home': 0x01000010,
  'End': 0x01000011,
  'Page_Up': 0x01000016,
  'Page_Down': 0x01000017,
  'Insert': 0x01000006,
  'Tab': 0x01000001,
  'minus': 0x2d,
  'equal': 0x3d,
  'bracketleft': 0x5b,
  'bracketright': 0x5d,
  'semicolon': 0x3b,
  'apostrophe': 0x27,
  'backslash': 0x5c,
  'grave': 0x60,
  'comma': 0x2c,
  'period': 0x2e,
  'slash': 0x2f,
};

/// How Qt spells the keys of the key map in kglobalshortcutsrc.
const _qtKeyNames = {
  'RETURN': 'Return',
  'ENTER': 'Return',
  'SPACE': 'space',
  'BACKSPACE': 'BackSpace',
  'DEL': 'Delete',
  'DELETE': 'Delete',
  'HOME': 'Home',
  'END': 'End',
  'PGUP': 'Page_Up',
  'PGDOWN': 'Page_Down',
  'INS': 'Insert',
  'INSERT': 'Insert',
  'TAB': 'Tab',
  '-': 'minus',
  '=': 'equal',
  '[': 'bracketleft',
  ']': 'bracketright',
  ';': 'semicolon',
  "'": 'apostrophe',
  r'\': 'backslash',
  '`': 'grave',
  ',': 'comma',
  '.': 'period',
  '/': 'slash',
};

/// The Qt key code of a key map key, or null.
int? qtKeyCode(String key) {
  if (_qtKeys[key] case final c?) return c;
  final u = key.toUpperCase();
  if (RegExp(r'^[A-Z0-9]$').hasMatch(u)) return u.codeUnitAt(0);
  final f = RegExp(r'^F([1-9]|1[0-2])$').firstMatch(u);
  if (f != null) return 0x01000030 + int.parse(f[1]!) - 1;
  return null;
}

/// [combo] as one QKeySequence key (modifiers + key), or null.
int? qtCombo(Map combo) {
  final key = qtKeyCode(combo['key'] as String);
  if (key == null) return null;
  return (combo['mods'] as List).fold<int>(key, (a, m) => a | (_qtMods[m] ?? 0));
}

/// The same id for a combo and for a Qt key string ("Meta+Ctrl+T").
String kdeKeyId(Map combo) {
  final mods = [for (final m in combo['mods'] as List) m as String]..sort();
  return '${mods.join('+')}|${(combo['key'] as String).toLowerCase()}';
}

/// A Qt key string of kglobalshortcutsrc as a combo, or null (other keys).
Map<String, dynamic>? parseQtKey(String text) {
  final t = text.trim();
  if (t.isEmpty || t == 'none') return null;
  // "Ctrl++" ends in the + key: split before the last character.
  final parts = t.endsWith('++') ? [...t.substring(0, t.length - 2).split('+'), '+'] : t.split('+');
  final mods = <String>[];
  for (final p in parts.take(parts.length - 1)) {
    final m = _qtModNames[p.toUpperCase()];
    if (m == null) return null;
    mods.add(m);
  }
  final last = parts.last;
  final key =
      _qtKeyNames[last.toUpperCase()] ??
      _qtKeyNames[last] ??
      (RegExp(r'^([A-Za-z0-9]|F([1-9]|1[0-2]))$').hasMatch(last) ? last.toUpperCase() : null);
  if (key == null) return null;
  return {'mods': mods, 'key': key};
}

/// {keyId: (component, action, friendly name)} for every key of
/// kglobalshortcutsrc that is not Maprisma Theme's.
Map<String, (String, String, String)> kdeKeyOwners(String text) {
  final out = <String, (String, String, String)>{};
  String? group;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trimRight();
    if (line.startsWith('[') && line.endsWith(']')) {
      // [component] or [services][file.desktop]
      final g = line.substring(1, line.length - 1);
      group = g.startsWith('services][') ? g.substring('services]['.length) : g;
      continue;
    }
    final eq = line.indexOf('=');
    if (group == null || eq <= 0 || group.startsWith(kdeKeyPrefix) || group == 'services') continue;
    final action = line.substring(0, eq);
    if (action.startsWith('_k_friendly_name')) continue;
    final fields = line.substring(eq + 1).split(',');
    if (fields.isEmpty) continue;
    final friendly = fields.length >= 3 ? fields.sublist(2).join(',') : action;
    // several keys: KConfig writes the tab between them as `\t`
    for (final k in fields.first.split(RegExp(r'\\t|\t'))) {
      final combo = parseQtKey(k);
      if (combo != null) out[kdeKeyId(combo)] = (group, action, friendly == '_launch' ? group : friendly);
    }
  }
  return out;
}

final class KdeShortcutBinder implements ShortcutBinder {
  KdeShortcutBinder(this.paths, this.environment);
  final Paths paths;
  final Map<String, String> environment;

  String get _apps => '${paths.data}/applications';
  String get _rc => '${File(paths.cosmicConfig).parent.path}/kglobalshortcutsrc';
  String get shadowFile => paths.file('kde-shadowed.json');

  @override
  bool get available => (environment['DBUS_SESSION_BUS_ADDRESS'] ?? '').isNotEmpty;

  @override
  String keyId(Map combo) => kdeKeyId(combo);

  @override
  Map<String, (String, String)> owners() {
    final text = readSmall(_rc, limit: 2 * 1024 * 1024) ?? '';
    final shadowed = readJsonMap(shadowFile);
    return {
      for (final e in kdeKeyOwners(text).entries) e.key: (levelDesktop, e.value.$3),
      // A key ours took stays the other action's.
      for (final e in shadowed.entries)
        if (e.value is Map) e.key: (levelDesktop, '${(e.value as Map)['friendly'] ?? e.key}'),
    };
  }

  /// The desktop files of ours: {file name: text}.
  Map<String, String> _ours() {
    final out = <String, String>{};
    try {
      for (final f in Directory(_apps).listSync()) {
        final name = f.path.substring(f.path.lastIndexOf('/') + 1);
        if (f is! File || !name.startsWith(kdeKeyPrefix) || !name.endsWith('.desktop')) continue;
        // bounded, never through a link or a FIFO; anything else is skipped (and written again)
        final bytes = Posix.instance.readRegular(f.path, maxDesktopFileBytes, follow: false);
        if (bytes != null) out[name] = utf8.decode(bytes, allowMalformed: true);
      }
    } on FileSystemException {
      // none yet
    }
    return out;
  }

  @override
  void write(List<Binding> bindings, String stateFile, Map<String, dynamic> state) {
    final wanted = <String, String>{};
    for (final b in bindings) {
      final code = qtCombo(b.combo);
      if (code == null) continue;
      final name = kdeKeyFileName(b.target);
      final label = plainText(b.label(), 100).replaceAll(RegExp(r'[\[\]=]'), '');
      wanted[name] =
          '[Desktop Entry]\nType=Application\nName=$label\nExec=${b.command()}\nNoDisplay=true\n'
          'X-KDE-GlobalAccel-CommandShortcut=true\nX-Maprisma-Key=$code\nX-Maprisma-KeyId=${kdeKeyId(b.combo)}\n';
    }
    final before = _ours();
    final oldState = Posix.instance.readRegular(stateFile, maxStateFileBytes);
    try {
      writeJson(stateFile, state);
      for (final e in wanted.entries) {
        if (before[e.key] != e.value) writeText('$_apps/${e.key}', e.value, mode: 420);
      }
      for (final name in before.keys) {
        if (!wanted.containsKey(name)) File('$_apps/$name').deleteSync();
      }
    } catch (_) {
      // back as it was: the state and the files
      for (final e in before.entries) {
        writeText('$_apps/${e.key}', e.value, mode: 420);
      }
      for (final name in wanted.keys) {
        if (!before.containsKey(name)) {
          try {
            File('$_apps/$name').deleteSync();
          } on FileSystemException {
            // gone
          }
        }
      }
      if (oldState != null) writeAtomic(stateFile, oldState);
      rethrow;
    }
    unawaited(syncKdeShortcuts(paths, environment).catchError((_) => false));
  }

  @override
  Map<String, dynamic> check(int expected) {
    final written = _ours().length;
    final ok = written == expected;
    return {'ok': ok, 'written': written, 'note': ok ? '' : trf("{0} key(s) set, {1} in KDE's shortcuts: Repair writes them again", [expected, written])};
  }
}

/// A QKeySequence as kglobalaccel carries it: up to four strokes.
typedef KeySeq = List<int>;

DBusArray _keys(List<KeySeq> seqs) => DBusArray(DBusSignature('(ai)'), [
  for (final q in seqs)
    DBusStruct([
      DBusArray.int32([...q, 0, 0, 0, 0].take(4).toList()),
    ]),
]);

/// Every sequence whole (multi-stroke ones too).
List<KeySeq> _seqs(DBusValue v) => [
  for (final s in v.asArray())
    if (s is DBusStruct && s.children.isNotEmpty) s.children.first.asInt32Array().toList(),
];

bool _sameSeq(KeySeq a, KeySeq b) {
  for (var i = 0; i < 4; i++) {
    if ((i < a.length ? a[i] : 0) != (i < b.length ? b[i] : 0)) return false;
  }
  return true;
}

/// One stroke [code] as a sequence.
KeySeq _single(int code) => [code, 0, 0, 0];

/// What a sync does with the wanted keys and the shadow records; pure, so
/// tests check it. [taken] → sequences an other action keeps, [giveBack] →
/// its sequences with ours added back.
List<KeySeq> withoutSeq(List<KeySeq> keys, KeySeq q) => [
  for (final k in keys)
    if (!_sameSeq(k, q)) k,
];
List<KeySeq> withSeq(List<KeySeq> keys, KeySeq q) => keys.any((k) => _sameSeq(k, q)) ? keys : [...keys, q];

Future<void> _syncChain = Future.value();

/// Makes kglobalaccel match the desktop files of ours. In order: ours no
/// longer wanted are unbound; a key another action has is taken from it
/// (only that one sequence, recorded in kde-shadowed.json before it is
/// taken); ours are bound; recorded keys ours no longer use are given back,
/// and a record goes only once kglobalaccel shows the key back. One sync at a
/// time (in this process and across processes). True when every call went
/// through.
Future<bool> syncKdeShortcuts(Paths paths, Map<String, String> environment, {DBusClient? client}) {
  final done = _syncChain.then((_) => _syncLocked(paths, environment, client));
  _syncChain = done.then<void>((_) {}, onError: (Object _) {});
  return done;
}

Future<bool> _syncLocked(Paths paths, Map<String, String> environment, DBusClient? client) async {
  RandomAccessFile? lock;
  try {
    Directory(paths.runtime).createSync(recursive: true);
    lock = File('${paths.runtime}/kde-shortcuts.lock').openSync(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
  } on FileSystemException {
    await lock?.close();
    return false;
  }
  try {
    return await _sync(paths, environment, client).timeout(const Duration(seconds: 30), onTimeout: () => false);
  } finally {
    try {
      await lock.unlock();
      await lock.close();
    } on FileSystemException {
      // closed with the process
    }
  }
}

Future<bool> _sync(Paths paths, Map<String, String> environment, DBusClient? client) async {
  final bus = client ?? sessionBus(environment);
  if (bus == null) return false;
  final apps = '${paths.data}/applications';
  final shadowFile = paths.file('kde-shadowed.json');
  try {
    final ga = DBusRemoteObject(bus, name: 'org.kde.kglobalaccel', path: DBusObjectPath('/kglobalaccel'));
    Future<DBusMethodSuccessResponse> c(String m, List<DBusValue> args) => ga.callMethod('org.kde.KGlobalAccel', m, args);
    DBusArray id(String component, String action, [String cf = '', String af = '']) => DBusArray.string([component, action, cf, af]);
    Future<List<KeySeq>> keysOf(String component, String action) async =>
        _seqs((await c('shortcutKeys', [id(component, action)])).values.first);

    final wanted = <String, (int, String, String)>{}; // file → (code, keyId, name)
    try {
      for (final f in Directory(apps).listSync()) {
        final name = f.path.substring(f.path.lastIndexOf('/') + 1);
        if (f is! File || !name.startsWith(kdeKeyPrefix) || !name.endsWith('.desktop')) continue;
        final bytes = Posix.instance.readRegular(f.path, maxDesktopFileBytes, follow: false);
        if (bytes == null) continue;
        final text = utf8.decode(bytes, allowMalformed: true);
        final code = int.tryParse(RegExp(r'^X-Maprisma-Key=(\d+)$', multiLine: true).firstMatch(text)?[1] ?? '');
        final keyId = RegExp(r'^X-Maprisma-KeyId=(.+)$', multiLine: true).firstMatch(text)?[1];
        final label = RegExp(r'^Name=(.*)$', multiLine: true).firstMatch(text)?[1] ?? name;
        if (code != null && keyId != null) wanted[name] = (code, keyId, label);
      }
    } on FileSystemException {
      // no folder: nothing wanted
    }
    final wantedIds = {for (final w in wanted.values) w.$2};

    // 1. Ours that are registered but no longer wanted: unbound and forgotten.
    final components = (await c('allComponents', [])).values.first.asArray();
    for (final p in components) {
      if (!RegExp('^/component/${kdeKeyPrefix.replaceAll('-', '_')}.*_desktop\$').hasMatch(p.asObjectPath().value)) continue;
      final comp = DBusRemoteObject(bus, name: 'org.kde.kglobalaccel', path: p.asObjectPath());
      final unique = (await comp.getProperty('org.kde.kglobalaccel.Component', 'uniqueName')).asString();
      if (wanted.containsKey(unique)) continue;
      await c('setForeignShortcutKeys', [id(unique, '_launch'), _keys(const [])]);
      await c('unregister', [DBusString(unique), DBusString('_launch')]);
    }

    // 2. A key another action has: that one sequence is taken (recorded first).
    final shadow = readJsonMap(shadowFile);
    final owners = kdeKeyOwners(readSmall('${File(paths.cosmicConfig).parent.path}/kglobalshortcutsrc', limit: 2 * 1024 * 1024) ?? '');
    for (final w in wanted.values) {
      final other = owners[w.$2];
      if (other == null || shadow.containsKey(w.$2)) continue;
      final keys = await keysOf(other.$1, other.$2);
      final seq = _single(w.$1);
      if (!keys.any((k) => _sameSeq(k, seq))) continue; // not really its key (any more)
      shadow[w.$2] = {'component': other.$1, 'action': other.$2, 'friendly': other.$3, 'seq': seq};
      writeJson(shadowFile, shadow); // before the key is taken: never lost
      await c('setForeignShortcutKeys', [id(other.$1, other.$2), _keys(withoutSeq(keys, seq))]);
    }

    // 3. Ours bound (a changed key frees the old one here). KDE's shortcut
    // service sees a new desktop file only after its service cache is updated
    // and it looks again (a moment later): a key it dropped is read back and
    // registered again after a pause (seen live in Maprisma Launcher).
    final sycoca = which('kbuildsycoca6', environment);
    var dropped = false;
    for (final e in wanted.entries) {
      final aid = id(e.key, '_launch', 'Maprisma Theme', e.value.$3);
      for (var attempt = 0; ; attempt++) {
        if (sycoca != null) await runBounded([sycoca], timeout: const Duration(seconds: 30), environment: environment);
        await c('doRegister', [aid]);
        await c('setForeignShortcutKeys', [
          aid,
          _keys([_single(e.value.$1)]),
        ]);
        if ((await keysOf(e.key, '_launch')).any((q) => _sameSeq(q, _single(e.value.$1)))) {
          // Active now: a service shortcut registered at runtime stays inactive
          // (a pressed key does nothing) until marked present, as an app does
          // with setShortcutKeys and SetPresent (2) | NoAutoloading (4).
          await c('setShortcutKeys', [
            aid,
            _keys([_single(e.value.$1)]),
            const DBusUint32(6),
          ]);
          break;
        }
        if (attempt >= 3) {
          dropped = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
    }

    // 4. Recorded keys ours no longer uses: given back; the record goes only
    // once the other action has the key again.
    var allBack = true;
    for (final k in [...shadow.keys]) {
      if (wantedIds.contains(k)) continue;
      final s = shadow[k];
      if (s is! Map || s['component'] is! String || s['action'] is! String || s['seq'] is! List) {
        shadow.remove(k);
        continue;
      }
      final comp = s['component'] as String, action = s['action'] as String;
      final seq = [
        for (final v in s['seq'] as List)
          if (v is int) v,
      ];
      await c('setForeignShortcutKeys', [id(comp, action), _keys(withSeq(await keysOf(comp, action), seq))]);
      if ((await keysOf(comp, action)).any((q) => _sameSeq(q, seq))) {
        shadow.remove(k);
      } else {
        allBack = false;
      }
    }
    writeJson(shadowFile, shadow);
    return allBack && !dropped;
  } on DBusMethodResponseException {
    return false;
  } on FileSystemException {
    return false;
  } finally {
    if (client == null) await bus.close();
  }
}
