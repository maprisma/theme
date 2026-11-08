/// Global keys on KDE Plasma (docs/multi-desktop.md, step 4): each key of
/// Maprisma Theme is a hidden desktop file `maprisma-theme-key-<n>.desktop`
/// whose `_launch` action kglobalaccel runs itself (as System Settings'
/// "Add Command" does; verified live on Plasma 6.8). The files are the wanted
/// state, written at once; [syncKdeShortcuts] makes kglobalaccel match them
/// over D-Bus (right after a change, and again when the daemon starts or sees
/// shortcuts.json change). A key another action had is taken from it while
/// ours exists and given back after (kde-shadowed.json).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'paths.dart';
import 'shortcuts.dart';
import 'store.dart';

const kdeKeyPrefix = 'maprisma-theme-key-';

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
  'Return': 0x01000004, 'space': 0x20, 'BackSpace': 0x01000003, 'Delete': 0x01000007, 'Home': 0x01000010,
  'End': 0x01000011, 'Page_Up': 0x01000016, 'Page_Down': 0x01000017, 'Insert': 0x01000006, 'Tab': 0x01000001,
  'minus': 0x2d, 'equal': 0x3d, 'bracketleft': 0x5b, 'bracketright': 0x5d, 'semicolon': 0x3b, 'apostrophe': 0x27,
  'backslash': 0x5c, 'grave': 0x60, 'comma': 0x2c, 'period': 0x2e, 'slash': 0x2f,
};

/// How Qt spells the keys of the key map in kglobalshortcutsrc.
const _qtKeyNames = {
  'RETURN': 'Return', 'ENTER': 'Return', 'SPACE': 'space', 'BACKSPACE': 'BackSpace', 'DEL': 'Delete', 'DELETE': 'Delete',
  'HOME': 'Home', 'END': 'End', 'PGUP': 'Page_Up', 'PGDOWN': 'Page_Down', 'INS': 'Insert', 'INSERT': 'Insert', 'TAB': 'Tab',
  '-': 'minus', '=': 'equal', '[': 'bracketleft', ']': 'bracketright', ';': 'semicolon', "'": 'apostrophe',
  r'\': 'backslash', '`': 'grave', ',': 'comma', '.': 'period', '/': 'slash',
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
  final key = _qtKeyNames[last.toUpperCase()] ?? _qtKeyNames[last] ?? (RegExp(r'^([A-Za-z0-9]|F([1-9]|1[0-2]))$').hasMatch(last) ? last.toUpperCase() : null);
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
        if (f is File && name.startsWith(kdeKeyPrefix) && name.endsWith('.desktop')) out[name] = f.readAsStringSync();
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
      final name = '$kdeKeyPrefix${b.target.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_')}.desktop';
      final label = plainText(b.label(), 100).replaceAll(RegExp(r'[\[\]=]'), '');
      wanted[name] = '[Desktop Entry]\nType=Application\nName=$label\nExec=${b.command()}\nNoDisplay=true\n'
          'X-KDE-GlobalAccel-CommandShortcut=true\nX-Maprisma-Key=$code\nX-Maprisma-KeyId=${kdeKeyId(b.combo)}\n';
    }
    final before = _ours();
    final oldState = File(stateFile).existsSync() ? File(stateFile).readAsBytesSync() : null;
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
    return {'ok': ok, 'written': written, 'note': ok ? '' : '$expected key(s) set, $written in KDE\'s shortcuts: Repair writes them again'};
  }
}

DBusArray _keys(List<int> codes) =>
    DBusArray(DBusSignature('(ai)'), [for (final c in codes) DBusStruct([DBusArray.int32([c, 0, 0, 0])])]);

List<int> _codes(DBusValue v) => [
  for (final s in v.asArray())
    if (s is DBusStruct && s.children.isNotEmpty) s.children.first.asInt32Array().first,
];

/// Makes kglobalaccel match the desktop files of ours: registers and binds
/// each, unbinds and forgets keys whose file is gone, takes a key from
/// another action (remembered) and gives it back when ours goes. True when
/// every call went through.
Future<bool> syncKdeShortcuts(Paths paths, Map<String, String> environment, {DBusClient? client}) async {
  final bus = client ?? sessionBus(environment);
  if (bus == null) return false;
  final apps = '${paths.data}/applications';
  final shadowFile = paths.file('kde-shadowed.json');
  try {
    final ga = DBusRemoteObject(bus, name: 'org.kde.kglobalaccel', path: DBusObjectPath('/kglobalaccel'));
    Future<DBusMethodSuccessResponse> c(String m, List<DBusValue> args) => ga.callMethod('org.kde.KGlobalAccel', m, args);
    DBusArray id(String component, String action, [String cf = '', String af = '']) =>
        DBusArray.string([component, action, cf, af]);

    final wanted = <String, (int, String, String)>{}; // file → (code, keyId, name)
    try {
      for (final f in Directory(apps).listSync()) {
        final name = f.path.substring(f.path.lastIndexOf('/') + 1);
        if (f is! File || !name.startsWith(kdeKeyPrefix) || !name.endsWith('.desktop')) continue;
        final text = f.readAsStringSync();
        final code = int.tryParse(RegExp(r'^X-Maprisma-Key=(\d+)$', multiLine: true).firstMatch(text)?[1] ?? '');
        final keyId = RegExp(r'^X-Maprisma-KeyId=(.+)$', multiLine: true).firstMatch(text)?[1];
        final label = RegExp(r'^Name=(.*)$', multiLine: true).firstMatch(text)?[1] ?? name;
        if (code != null && keyId != null) wanted[name] = (code, keyId, label);
      }
    } on FileSystemException {
      // no folder: nothing wanted
    }

    // Ours that are registered but no longer wanted: unbind and forget.
    final components = (await ga.callMethod('org.kde.KGlobalAccel', 'allComponents', [])).values.first.asArray();
    for (final p in components) {
      final path = p.asObjectPath().value;
      final m = RegExp('^/component/${kdeKeyPrefix.replaceAll('-', '_')}(.*)_desktop\$').firstMatch(path);
      if (m == null) continue;
      final comp = DBusRemoteObject(bus, name: 'org.kde.kglobalaccel', path: p.asObjectPath());
      final unique = (await comp.getProperty('org.kde.kglobalaccel.Component', 'uniqueName')).asString();
      if (wanted.containsKey(unique)) continue;
      await c('setForeignShortcutKeys', [id(unique, '_launch'), _keys(const [])]);
      await c('unregister', [DBusString(unique), DBusString('_launch')]);
    }

    // Keys others had: taken while ours wants them, given back after.
    final shadow = readJsonMap(shadowFile);
    final wantedIds = {for (final w in wanted.values) w.$2};
    for (final k in [...shadow.keys]) {
      if (wantedIds.contains(k)) continue;
      final s = shadow[k];
      if (s is Map && s['component'] is String && s['action'] is String && s['keys'] is List) {
        await c('setForeignShortcutKeys', [
          id(s['component'] as String, s['action'] as String),
          _keys([for (final v in s['keys'] as List) if (v is int) v]),
        ]);
      }
      shadow.remove(k);
    }
    final owners = kdeKeyOwners(readSmall('${File(paths.cosmicConfig).parent.path}/kglobalshortcutsrc', limit: 2 * 1024 * 1024) ?? '');
    for (final w in wanted.values) {
      final other = owners[w.$2];
      if (other == null || shadow.containsKey(w.$2)) continue;
      final otherId = id(other.$1, other.$2);
      final keys = _codes((await c('shortcutKeys', [otherId])).values.first);
      shadow[w.$2] = {'component': other.$1, 'action': other.$2, 'friendly': other.$3, 'keys': keys};
      writeJson(shadowFile, shadow); // before the key is taken: never lost
      await c('setForeignShortcutKeys', [otherId, _keys([for (final k in keys) if (k != w.$1) k])]);
    }
    writeJson(shadowFile, shadow);

    for (final e in wanted.entries) {
      final aid = id(e.key, '_launch', 'Maprisma Theme', e.value.$3);
      await c('doRegister', [aid]);
      await c('setForeignShortcutKeys', [aid, _keys([e.value.$1])]);
    }
    return true;
  } on DBusMethodResponseException {
    return false;
  } on FileSystemException {
    return false;
  } finally {
    if (client == null) await bus.close();
  }
}
