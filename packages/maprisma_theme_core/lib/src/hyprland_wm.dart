/// Hyprland's part of the wm contract (docs/cosmic-interface.md): workspaces,
/// windows, move/close/activate and layout presets through `hyprctl`, events
/// from Hyprland's socket2. Ported from Workspace Presets (omarchy-simple-tile,
/// simple_tile.py). Only validated integers, validated hexadecimal window
/// addresses, whitelisted preset names and formatted numbers ever enter the
/// Lua code given to `hyprctl eval`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:maprisma_core_kit/process.dart';

import 'posix.dart';
import 'store.dart';
import 'workspace_state.dart';

/// `hyprctl` with these arguments: its stdout, or null (failed, timed out, too large).
typedef HyprCommand = Future<String?> Function(List<String> args);

/// A connection to a Unix socket at this path (its bytes until it closes).
typedef HyprConnector = Future<Stream<List<int>>> Function(String path);

/// A Hyprland window address as Hyprland prints it.
final hyprAddressPattern = RegExp(r'^0x[0-9a-f]{1,16}$');

/// The tag on windows the Floating preset floated (tiled again when it is left).
const hyprFloatTag = 'maprisma-presets-floating';

/// A floated window's size, as part of the usable screen; each further one
/// cascades this far right and down.
const _floatWidth = 0.6, _floatHeight = 0.7, _floatCascade = 32;

/// The longest socket2 line read; longer ones are dropped whole.
const hyprEventLineMax = 64 * 1024;

/// [value] as `0x…` lower-case hex (with or without the prefix, as socket2
/// sends it), or null.
String? hyprAddress(Object? value) {
  if (value is! String) return null;
  var v = value.trim().toLowerCase();
  if (!v.startsWith('0x')) v = '0x$v';
  return hyprAddressPattern.hasMatch(v) ? v : null;
}

int? _workspaceId(Object? value, {int max = 100}) {
  final n = value is int ? value : (value is String ? int.tryParse(value.trim()) : null);
  return n != null && n >= 1 && n <= max ? n : null;
}

/// Python's round(): halves to the even neighbour (as simple_tile.py).
int _roundHalfEven(double v) {
  final f = v.floorToDouble();
  final diff = v - f;
  if (diff > 0.5) return f.toInt() + 1;
  if (diff < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

Map _wsOf(Map c) => c['workspace'] is Map ? c['workspace'] as Map : const {};

bool _truthy(Object? v) => v == true || (v is num && v != 0);

/// A window the tiling layout places: mapped on a real workspace, not
/// floating, fullscreen or hidden.
bool hyprTiled(Map c) {
  final ws = _wsOf(c)['id'];
  return ws is int && ws > 0 && c['mapped'] == true && !_truthy(c['floating']) && !_truthy(c['fullscreen']) && !_truthy(c['hidden']);
}

List<int> _pair(Object? v) =>
    v is List && v.length >= 2 && v[0] is num && v[1] is num ? [(v[0] as num).toInt(), (v[1] as num).toInt()] : const [0, 0];

/// Size and position (layout pixels) of the [index]-th floated window on
/// [monitor] (`hyprctl -j monitors`): centred, later ones cascading; null
/// when the monitor's usable size is not a finite positive number.
(int, int, int, int)? floatingGeometry(Map monitor, int index) {
  final rawScale = monitor['scale'];
  final scale = rawScale is num && rawScale.isFinite && rawScale > 0 ? rawScale.toDouble() : 1.0;
  final reserved = [...(monitor['reserved'] is List ? (monitor['reserved'] as List) : const []), 0, 0, 0, 0]
      .take(4)
      .map((v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : 0.0)
      .toList();
  final (left, top, right, bottom) = (reserved[0], reserved[1], reserved[2], reserved[3]);
  final rawWidth = monitor['width'], rawHeight = monitor['height'];
  if (rawWidth is! num || rawHeight is! num || !rawWidth.isFinite || !rawHeight.isFinite || rawWidth <= 0 || rawHeight <= 0) {
    return null;
  }
  final width = rawWidth.toDouble() / scale - left - right;
  final height = rawHeight.toDouble() / scale - top - bottom;
  if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) return null;
  final w = _roundHalfEven(width * _floatWidth), h = _roundHalfEven(height * _floatHeight);
  final step = _floatCascade * (index % 6);
  final rawX = monitor['x'], rawY = monitor['y'];
  final mx = rawX is num && rawX.isFinite ? rawX.toInt() : 0;
  final my = rawY is num && rawY.isFinite ? rawY.toInt() : 0;
  final x = mx + left.round() + _roundHalfEven((width - w) / 2) - _floatCascade * 2 + step;
  final y = my + top.round() + _roundHalfEven((height - h) / 2) - _floatCascade * 2 + step;
  return (w, h, x, y);
}

String _target(String addr) => 'window="address:$addr"';

/// Floats every tiled window on [ws], tags it, and gives it a desktop-like
/// size and place; windows floating already stay where they are.
List<String> floatingActions(int ws, List<Map<String, dynamic>> clients, List<Map<String, dynamic>> monitors) {
  final out = <String>[];
  final already = clients.where((c) => _wsOf(c)['id'] == ws && _truthy(c['floating'])).length;
  final byId = {
    for (final m in monitors)
      if (m['width'] is num && m['height'] is num) m['id']: m,
  };
  var index = 0;
  for (final c in clients.where((c) => _wsOf(c)['id'] == ws && hyprTiled(c))) {
    final addr = hyprAddress(c['address']);
    if (addr == null) continue;
    final t = _target(addr);
    out
      ..add('hl.dispatch(hl.dsp.window.float({$t, action="on"}))')
      ..add('hl.dispatch(hl.dsp.window.tag({$t, tag="+$hyprFloatTag"}))');
    final monitor = byId[c['monitor']];
    final geometry = monitor == null ? null : floatingGeometry(monitor, already + index);
    if (geometry != null) {
      final (w, h, x, y) = geometry;
      out
        ..add('hl.dispatch(hl.dsp.window.resize({$t, x=$w, y=$h, relative=false}))')
        ..add('hl.dispatch(hl.dsp.window.move({$t, x=$x, y=$y, relative=false}))');
    }
    index++;
  }
  return out;
}

bool _floatedByUs(Map c) => _truthy(c['floating']) && c['tags'] is List && (c['tags'] as List).contains(hyprFloatTag);

/// Leaving the Floating preset: only the windows it floated are tiled again.
List<String> unfloatActions(int ws, List<Map<String, dynamic>> clients) => [
  for (final c in clients)
    if (_wsOf(c)['id'] == ws && _floatedByUs(c))
      if (hyprAddress(c['address']) case final addr?) ...[
        'hl.dispatch(hl.dsp.window.float({${_target(addr)}, action="off"}))',
        'hl.dispatch(hl.dsp.window.tag({${_target(addr)}, tag="-$hyprFloatTag"}))',
      ],
];

String _rule(int ws, String layout, [String? orientation]) => orientation == null
    ? 'hl.workspace_rule({ workspace = "$ws", layout = "$layout" })'
    : 'hl.workspace_rule({ workspace = "$ws", layout = "$layout", layout_opts = { orientation = "$orientation" } })';

String _removeMasters(int n) => 'for _ = 1, $n do pcall(function() hl.dispatch(hl.dsp.layout("removemaster")) end) end';
String _layout(String msg) => 'hl.dispatch(hl.dsp.layout("$msg"))';
String _focusWorkspace(int ws) => 'hl.dispatch(hl.dsp.focus({ workspace = $ws }))';
const _toggleSplit = 'hl.dispatch(hl.dsp.layout("togglesplit"))';

/// Focuses the window and turns its split (the Columns fix-up).
String toggleSplitOf(String addr) => '(function() local w = hl.get_window("address:$addr") '
    'if w then hl.dispatch(hl.dsp.focus({ window = w })) pcall(function() hl.dispatch(hl.dsp.layout("togglesplit")) end) end end)()';

/// The Lua (one `hyprctl eval` each) that gives workspace [workspace] (1–10)
/// the layout [preset], from the windows and monitors as Hyprland lists them.
/// [cap]: the workspace's window limit; [split]: the first/master window's
/// share (null: even). Throws [ArgumentError] for a bad workspace or preset.
List<String> planPreset({
  required int workspace,
  required String preset,
  required List<Map<String, dynamic>> clients,
  required List<Map<String, dynamic>> monitors,
  int? activeWorkspace,
  int cap = 2,
  double? split,
}) {
  final ws = workspace;
  if (ws < 1 || ws > 10) throw ArgumentError.value(workspace, 'workspace');
  if (!presetNames.contains(preset)) throw ArgumentError.value(preset, 'preset');
  // Only windows with a valid address take part.
  return _plan(ws, preset, [for (final c in clients) if (hyprAddress(c['address']) != null) c], monitors, activeWorkspace, cap, split);
}

List<String> _plan(int ws, String preset, List<Map<String, dynamic>> clients, List<Map<String, dynamic>> monitors, int? activeWorkspace,
    int cap, double? split) {
  final share = split == null ? null : cleanSplit(split);

  if (preset == 'scrolling') return [...unfloatActions(ws, clients), _rule(ws, 'scrolling')];
  if (preset == 'floating') return floatingActions(ws, clients, monitors);

  final wsClients = [for (final c in clients) if (_wsOf(c)['id'] == ws && hyprTiled(c)) c];
  final actions = unfloatActions(ws, clients);
  if (actions.isNotEmpty) {
    // The windows just tiled again take part in the layout below.
    wsClients.addAll([
      for (final c in clients)
        if (_wsOf(c)['id'] == ws && _floatedByUs(c) && c['mapped'] == true && !_truthy(c['fullscreen']) && !_truthy(c['hidden']))
          {...c, 'floating': false},
    ]);
  }
  final n = wsClients.length;

  // 1. The workspace's rule.
  actions.add(switch (preset) {
    'columns' when !(n >= 4 || (n < 2 && cap == 4)) => _rule(ws, 'master', 'center'),
    'master-left' => _rule(ws, 'master', 'left'),
    'master-right' => _rule(ws, 'master', 'right'),
    _ => _rule(ws, 'dwindle'),
  });
  if (wsClients.isEmpty || preset == 'none') return actions;

  // 2. The windows there now.
  final back = activeWorkspace != null && activeWorkspace != ws ? activeWorkspace : null;
  // Collected first: the workspace is focused (and focus given back) only when
  // a window there gets a layout message, so nothing flashes for nothing.
  final ops = <String>[];
  final master = preset == 'master-left' || preset == 'master-right';
  final orientation = preset == 'master-left' ? 'orientationleft' : 'orientationright';
  if (n == 2) {
    if (preset == 'side-by-side' || preset == 'stacked' || preset == 'columns') {
      ops.add(_rule(ws, 'dwindle'));
      final a = _pair(wsClients[0]['at']), b = _pair(wsClients[1]['at']);
      final dx = (a[0] - b[0]).abs(), dy = (a[1] - b[1]).abs();
      if (preset != 'stacked' && !(dx > dy)) ops.add(_toggleSplit);
      if (preset == 'stacked' && !(dy > dx)) ops.add(_toggleSplit);
    } else if (master) {
      ops
        ..add(_removeMasters(3))
        ..add(_layout(orientation));
    }
  } else if (n == 3) {
    if (preset == 'columns') {
      // A centred master with one master: Left | Centre | Right.
      ops
        ..add(_rule(ws, 'master', 'center'))
        ..add(_removeMasters(4))
        ..add(_layout('orientationcenter'));
    } else if (master) {
      ops
        ..add(_removeMasters(4))
        ..add(_layout(orientation));
    } else if (preset == 'grid') {
      ops.add(_rule(ws, 'dwindle'));
    }
  } else if (n >= 4) {
    if (preset == 'columns') {
      // Dwindle with every split horizontal: side-by-side columns.
      ops.add(_rule(ws, 'dwindle'));
      final stacked = [for (final c in wsClients) if (_pair(c['size'])[1] < 900) c];
      if (stacked.isNotEmpty) {
        final seen = <int>[];
        for (final c in stacked) {
          final x = _pair(c['at'])[0];
          if (seen.any((p) => (x - p).abs() < 30)) continue;
          seen.add(x);
          ops.add(toggleSplitOf(hyprAddress(c['address'])!));
        }
      } else {
        ops.add('pcall(function() $_toggleSplit end)');
      }
    } else if (master) {
      ops
        ..add(_removeMasters(4))
        ..add(_layout(orientation));
    } else if (preset == 'grid') {
      ops.add(_rule(ws, 'dwindle'));
    }
  }

  // The split: the master's share, the left/top window's (dwindle's ratio 1 is
  // even, so twice the share) or, with Columns of 3, the middle column's. No
  // split means even: sent too, so "Even" takes back a size set earlier.
  if (master && n >= 2) {
    ops.add(_layout('mfact exact ${(share ?? 0.5).toStringAsFixed(2)}'));
  } else if ((preset == 'side-by-side' || preset == 'stacked') && n == 2) {
    ops.add(_layout('splitratio ${(2 * (share ?? 0.5)).toStringAsFixed(2)} exact'));
  } else if (preset == 'columns' && cap == 3 && n == 3) {
    ops.add(_layout('mfact exact ${(share == null ? 0.33 : (share < columnsSplitMax ? share : columnsSplitMax)).toStringAsFixed(2)}'));
  }
  if (ops.isEmpty) return actions;
  if (back != null) actions.add(_focusWorkspace(ws));
  actions.addAll(ops);
  if (back != null) actions.add(_focusWorkspace(back));
  return actions;
}

/// The Hyprland layout a preset's workspace rule names (null: no rule).
(String, String?)? presetRuleLayout(String preset, {int cap = 2}) => switch (preset) {
  'side-by-side' || 'stacked' || 'grid' => ('dwindle', null),
  'master-left' => ('master', 'left'),
  'master-right' => ('master', 'right'),
  'columns' => cap == 4 ? ('dwindle', null) : ('master', 'center'),
  'scrolling' => ('scrolling', null),
  _ => null, // none: Hyprland's own; floating: done per window
};

/// maprisma-workspaces.lua: a workspace rule for each workspace 1–10 whose
/// preset has one, so the layouts hold after Hyprland restarts.
String workspaceRulesLua(Map<int, String> presets, {Map<int, int> caps = const {}}) {
  final b = StringBuffer()
    ..writeln('-- Written by Maprisma Theme (Workspaces). Changes made here by hand are replaced on the')
    ..writeln('-- next change there; delete this file to give the layouts back to your own config.');
  for (var ws = 1; ws <= 10; ws++) {
    final preset = presets[ws];
    if (preset == null || !presetNames.contains(preset)) continue;
    final layout = presetRuleLayout(preset, cap: caps[ws] ?? 2);
    if (layout == null) continue;
    b.writeln(_rule(ws, layout.$1, layout.$2));
  }
  return b.toString();
}

/// One socket2 line as a watch event (as the COSMIC helper's), or null.
Map<String, dynamic>? parseHyprEvent(String line) {
  final at = line.indexOf('>>');
  if (at <= 0) return null;
  final name = line.substring(0, at), data = line.substring(at + 2);
  final parts = data.split(',');
  switch (name) {
    case 'openwindow':
      final id = hyprAddress(parts[0]);
      if (id == null) return null;
      return {'event': 'window_new', 'id': id, 'workspace': parts.length > 1 ? _workspaceId(parts[1]) : null};
    case 'closewindow':
      final id = hyprAddress(parts[0]);
      return id == null ? null : {'event': 'window_closed', 'id': id};
    case 'movewindowv2':
      final id = hyprAddress(parts[0]);
      if (id == null) return null;
      return {'event': 'window_moved', 'id': id, 'workspace': parts.length > 1 ? _workspaceId(parts[1]) : null};
    case 'workspacev2':
      final ws = _workspaceId(parts[0]);
      return ws == null ? null : {'event': 'workspace', 'index': ws};
    case 'configreloaded':
      return {'event': 'config_reloaded'};
  }
  return null;
}

/// Splits bytes into lines of at most [max] bytes; longer lines are dropped
/// whole (up to their newline).
final class BoundedLineSplitter {
  BoundedLineSplitter({this.max = hyprEventLineMax});
  final int max;
  final _buf = BytesBuilder(copy: true);
  var _dropping = false;

  List<String> add(List<int> chunk) {
    final out = <String>[];
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 10) continue;
      _take(chunk, start, i);
      if (!_dropping) out.add(utf8.decode(_buf.takeBytes(), allowMalformed: true));
      _buf.clear();
      _dropping = false;
      start = i + 1;
    }
    _take(chunk, start, chunk.length);
    return out;
  }

  void _take(List<int> chunk, int start, int end) {
    if (_dropping || end <= start) return;
    if (_buf.length + end - start > max) {
      _dropping = true;
      _buf.clear();
      return;
    }
    _buf.add(chunk.sublist(start, end));
  }
}

/// Workspace Presets (the Omarchy plugin `ubruckhaus.simple-tile`) is in a bar
/// and on: it arranges Hyprland's windows itself, so Maprisma Theme leaves them be.
bool simpleTileConflict(Map<String, String> environment) {
  final config = environment['XDG_CONFIG_HOME'];
  final home = environment['HOME'];
  final base = config != null && config.startsWith('/') ? config : (home == null ? null : '$home/.config');
  if (base == null) return false;
  final data = readJson('$base/omarchy/shell.json');
  final bar = data is Map ? data['bar'] : null;
  final layout = bar is Map ? bar['layout'] : null;
  if (layout is! Map) return false;
  for (final section in ['left', 'center', 'right']) {
    final entries = layout[section];
    for (final e in entries is List ? entries : const []) {
      if (e is Map && e['id'] == 'ubruckhaus.simple-tile' && e['active'] != false) return true;
    }
  }
  return false;
}

/// The wm contract on Hyprland. [command] and [connect] are replaced in tests.
final class HyprWm {
  HyprWm({
    required this.environment,
    required this.configHome,
    this.hyprctl,
    HyprCommand? command,
    HyprConnector? connect,
    Map<String, dynamic> Function()? state,
    this.retryDelay = const Duration(milliseconds: 80),
    Future<void> Function(Duration)? sleep,
  }) : _command = command,
       _connect = connect ?? _unixConnect,
       _state = state ?? (() => cleanWorkspaceState(null)),
       _sleep = sleep ?? Future<void>.delayed;

  final Map<String, String> environment;

  /// ~/.config (XDG_CONFIG_HOME): hypr/ is below it.
  final String configHome;

  /// The hyprctl program.
  final String? hyprctl;
  final HyprCommand? _command;
  final HyprConnector _connect;
  final Map<String, dynamic> Function() _state;
  final Duration retryDelay;
  final Future<void> Function(Duration) _sleep;

  static Future<Stream<List<int>>> _unixConnect(String path) async =>
      await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0);

  String get rulesFile => '$configHome/hypr/maprisma-workspaces.lua';
  String get userLua => '$configHome/hypr/hypr-user.lua';
  static const requireLine = 'pcall(require, "maprisma-workspaces") -- Maprisma Theme: workspace presets';

  Future<String?> _run(List<String> args) async {
    if (_command != null) return _command(args);
    final h = hyprctl;
    if (h == null) return null;
    return readBoundedText([h, ...args],
        maxBytes: 4 * 1024 * 1024, timeout: const Duration(seconds: 3), environment: environment, includeParentEnvironment: false);
  }

  Future<Object?> _json(String what) async {
    final out = await _run(['-j', what]);
    if (out == null) return null;
    try {
      return jsonDecode(out);
    } on FormatException {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _list(String what) async {
    final v = await _json(what);
    return v is List ? [for (final e in v) if (e is Map) Map<String, dynamic>.from(e)] : [];
  }

  Future<List<Map<String, dynamic>>> clients() => _list('clients');
  Future<List<Map<String, dynamic>>> monitors() => _list('monitors');

  Future<int?> activeWorkspace() async {
    final v = await _json('activeworkspace');
    return v is Map && v['id'] is int ? v['id'] as int : null;
  }

  Future<bool> _eval(String lua) async => await _run(['eval', lua]) != null;

  static Map<String, dynamic> _bad(String what) => {'error': 'bad_params', 'message': what};

  /// The contract: `workspaces`, `windows`, `move`, `close`, `activate`,
  /// `set-tiling`, `set-preset`, `set-split`, `apply-all` / `write-rules`.
  Future<Map<String, dynamic>?> wm(List<String> args) async {
    if (args.isEmpty) return _bad('command');
    switch (args) {
      case ['workspaces']: {
        return _workspaces();
      }
      case ['windows']: {
        return _windows();
      }
      case ['move', final a, final w]: {
        final addr = hyprAddress(a), ws = _workspaceId(w);
        if (addr == null || addr != a.toLowerCase() || ws == null) return _bad('move');
        if (!await _eval('hl.dispatch(hl.dsp.window.move({window="address:$addr", workspace="$ws", follow=false}))')) {
          return {'error': 'failed', 'message': 'hyprctl'};
        }
        // hyprctl can succeed while Lua failed: the move counts once Hyprland shows it.
        final after = await clients();
        final moved = after.any((c) => hyprAddress(c['address']) == addr && _wsOf(c)['id'] == ws);
        return {'done': moved};
      }
      case ['close', final a]: {
        final addr = hyprAddress(a);
        if (addr == null || addr != a.toLowerCase()) return _bad('close');
        return {'done': await _eval('hl.dispatch(hl.dsp.window.close({window="address:$addr"}))')};
      }
      case ['activate', final a]: {
        final addr = hyprAddress(a);
        if (addr == null || addr != a.toLowerCase()) return _bad('activate');
        return {'done': await _eval('hl.dispatch(hl.dsp.focus({window="address:$addr"}))')};
      }
      case ['set-tiling', final w, final on] when on == 'on' || on == 'off': {
        return wm(['set-preset', w, on == 'on' ? 'side-by-side' : 'floating']);
      }
      case ['set-preset', final w, final preset, ...final rest] when rest.length <= 1: {
        final ws = _workspaceId(w, max: 10);
        if (ws == null || !presetNames.contains(preset)) return _bad('set-preset');
        double? split;
        if (rest.isNotEmpty) {
          final v = double.tryParse(rest.single);
          split = v == null ? null : cleanSplit(v);
          if (split == null) return _bad('split');
        }
        return setPreset(ws, preset, split: split);
      }
      case ['set-split', final w, final r]: {
        final ws = _workspaceId(w, max: 10);
        final v = double.tryParse(r);
        final split = v == null ? null : cleanSplit(v);
        if (ws == null || split == null) return _bad('set-split');
        return setPreset(ws, effectivePreset(_state(), ws), split: split);
      }
      case ['apply-all'] || ['write-rules']: {
        final s = _state();
        return {
          'done': writeRules({
            for (var ws = 1; ws <= 10; ws++)
              if (presetConfigured(s, ws)) ws: effectivePreset(s, ws),
          }, caps: {for (var ws = 1; ws <= 10; ws++) ws: effectiveLimit(s, ws)}),
        };
      }
    }
    return {'error': 'not_available', 'message': args.first};
  }

  Future<Map<String, dynamic>> _workspaces() async {
    final list = await _list('workspaces');
    final mons = await monitors();
    final shown = {
      for (final m in mons)
        if (m['activeWorkspace'] is Map && (m['activeWorkspace'] as Map)['id'] is int) (m['activeWorkspace'] as Map)['id'] as int,
    };
    if (shown.isEmpty) {
      final a = await activeWorkspace();
      if (a != null) shown.add(a);
    }
    final s = _state();
    final out = <Map<String, dynamic>>[];
    for (final w in list) {
      final id = w['id'];
      if (id is! int || id <= 0) continue; // special workspaces
      final preset = id <= 10 ? effectivePreset(s, id) : null;
      out.add({
        'index': id,
        'name': _plain(w['name'], 64),
        'active': shown.contains(id),
        'tiling': preset != 'floating',
        'preset': preset,
        'split': id <= 10 ? effectiveSplit(s, id) : null,
        'output': _plain(w['monitor'], 64),
        'windows': w['windows'] is int ? w['windows'] : 0,
      });
    }
    out.sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));
    return {'workspaces': out, 'can_tile': true};
  }

  Future<Map<String, dynamic>> _windows() async => {
    'windows': [
      for (final c in await clients())
        if (hyprAddress(c['address']) case final id? when _wsOf(c)['id'] is int && (_wsOf(c)['id'] as int) > 0)
          {
            'id': id,
            'app_id': _plain(c['class'], 255),
            'title': _plain(c['title'], 300),
            'workspace': _wsOf(c)['id'],
            'floating': _truthy(c['floating']),
            'at': _pair(c['at']),
            'size': _pair(c['size']),
            'grouped': c['grouped'] is List && (c['grouped'] as List).isNotEmpty,
          },
    ],
  };

  static String _plain(Object? v, int max) {
    final s = (v is String ? v : '').replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
    return s.length > max ? s.substring(0, max) : s;
  }

  /// [preset] on [ws] now, for the windows there; Columns with 4 or more
  /// windows is checked again (a split that did not turn is turned again).
  Future<Map<String, dynamic>> setPreset(int ws, String preset, {double? split}) async {
    final s = _state();
    final cap = effectiveLimit(s, ws);
    final all = await clients();
    final mons = preset == 'floating' ? await monitors() : const <Map<String, dynamic>>[];
    final active = preset == 'floating' || preset == 'scrolling' ? null : await activeWorkspace();
    final actions = planPreset(workspace: ws, preset: preset, clients: all, monitors: mons, activeWorkspace: active, cap: cap, split: split);
    var ok = 0;
    for (final lua in actions) {
      if (await _eval(lua)) ok++;
    }
    // As _plan counts them: the windows the Floating preset floated are tiled again first.
    final tiled = all
        .where((c) =>
            _wsOf(c)['id'] == ws &&
            (hyprTiled(c) || (_floatedByUs(c) && c['mapped'] == true && !_truthy(c['fullscreen']) && !_truthy(c['hidden']))))
        .length;
    if (preset == 'columns' && tiled >= 4) {
      for (var i = 0; i < 4; i++) {
        await _sleep(retryDelay);
        final still = [
          for (final c in await clients())
            if (_wsOf(c)['id'] == ws && hyprTiled(c) && _pair(c['size'])[1] < 900 && hyprAddress(c['address']) != null) c,
        ];
        if (still.isEmpty) break;
        await _eval(toggleSplitOf(hyprAddress(still.first['address'])!));
      }
      if (active != null && active != ws) await _eval(_focusWorkspace(active));
    }
    return {'done': ok == actions.length, 'workspace': ws, 'preset': preset, 'actions': actions.length};
  }

  /// Writes maprisma-workspaces.lua (only when it changes) and loads it from
  /// hypr-user.lua (one line, added once); false when a file could not be written.
  bool writeRules(Map<int, String> presets, {Map<int, int> caps = const {}}) {
    if (!Directory('$configHome/hypr').existsSync()) return false;
    final text = workspaceRulesLua(presets, caps: caps);
    try {
      // The rules file is ours: a link in its place is never followed.
      final rulesType = FileSystemEntity.typeSync(rulesFile, followLinks: false);
      if (rulesType == FileSystemEntityType.link) return false;
      final current = rulesType == FileSystemEntityType.notFound ? null : Posix.instance.readRegular(rulesFile, smallFileMax, follow: false);
      if (rulesType != FileSystemEntityType.notFound && current == null) return false;
      if (current == null || utf8.decode(current, allowMalformed: true) != text) {
        if (!_replaceNoFollow(rulesFile, utf8.encode(text), _modeOf(rulesFile))) return false;
      }
      final userType = FileSystemEntity.typeSync(userLua, followLinks: false);
      if (userType == FileSystemEntityType.link) return false;
      String now;
      if (userType == FileSystemEntityType.notFound) {
        now = '-- Personal Hyprland settings, loaded last (from hyprland.lua)\n';
      } else {
        final read = readSmall(userLua);
        if (read == null) return false;
        now = read;
      }
      if (!now.contains('require, "maprisma-workspaces")')) {
        if (!_replaceNoFollow(userLua, utf8.encode('${now.endsWith('\n') ? now : '$now\n'}\n$requireLine\n'), _modeOf(userLua))) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// [path] replaced by [bytes] (a new temporary file, never through a link,
  /// then renamed over it), given [mode]; false when it could not be written.
  static bool _replaceNoFollow(String path, List<int> bytes, int mode) {
    final dir = File(path).parent.path;
    final tmp = '$dir/.${path.substring(dir.length + 1)}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp';
    if (!Posix.instance.writeNewPrivate(tmp, bytes)) return false;
    try {
      chmodPath(tmp, mode);
      File(tmp).renameSync(path);
      return true;
    } on FileSystemException {
      try {
        File(tmp).deleteSync();
      } on FileSystemException {
        // gone
      }
      return false;
    }
  }

  static int _modeOf(String path) {
    final stat = FileStat.statSync(path);
    return stat.type == FileSystemEntityType.notFound ? 420 : stat.mode & 511;
  }

  /// socket2's path, or null outside a Hyprland session.
  String? get eventSocket {
    final runtime = environment['XDG_RUNTIME_DIR'], sig = environment['HYPRLAND_INSTANCE_SIGNATURE'];
    if (runtime == null || !runtime.startsWith('/') || sig == null || !RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(sig) || sig.contains('..')) {
      return null;
    }
    return '$runtime/hypr/$sig/.socket2.sock';
  }

  /// Hyprland's events as watch events, connected again (0.5 s, 1 s, … 10 s)
  /// whenever the socket closes; stops when the last listener goes.
  Stream<Map<String, dynamic>>? watch() {
    final path = eventSocket;
    if (path == null) return null;
    late StreamController<Map<String, dynamic>> out;
    var generation = 0;
    StreamSubscription<List<int>>? sub;
    Completer<void>? connected;
    Future<void> loop(int mine) async {
      bool live() => generation == mine && !out.isClosed;
      var backoff = const Duration(milliseconds: 500);
      while (live()) {
        try {
          final stream = await _connect(path);
          if (!live()) {
            // Cancelled while connecting: the socket is closed, not left open.
            if (stream is Socket) {
              stream.destroy();
            } else {
              await stream.listen(null).cancel();
            }
            break;
          }
          backoff = const Duration(milliseconds: 500);
          final lines = BoundedLineSplitter();
          final done = connected = Completer<void>();
          sub = stream.listen(
            (chunk) {
              for (final line in lines.add(chunk)) {
                final e = parseHyprEvent(line);
                if (e != null && live()) out.add(e);
              }
            },
            onDone: () => done.isCompleted ? null : done.complete(),
            onError: (Object _) => done.isCompleted ? null : done.complete(),
            cancelOnError: true,
          );
          await done.future;
        } on Object {
          // not there (yet): try again
        }
        if (!live()) break;
        await _sleep(backoff);
        final next = backoff * 2;
        backoff = next > const Duration(seconds: 10) ? const Duration(seconds: 10) : next;
      }
    }

    out = StreamController<Map<String, dynamic>>.broadcast(
      onListen: () => unawaited(loop(++generation)),
      onCancel: () async {
        generation++;
        final s = sub;
        sub = null;
        if (connected case final c? when !c.isCompleted) c.complete();
        await s?.cancel();
      },
    );
    return out.stream;
  }
}
