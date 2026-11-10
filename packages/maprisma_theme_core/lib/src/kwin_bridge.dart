import 'i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

const kwinCallbackInterface = 'io.github.maprisma.KWinBridge';

/// Injectable script transport. The bridge owns scripts, but never the bus.
abstract class KWinScripting {
  String get uniqueName;
  Stream<bool> get ownerChanges;
  Future<void> register(DBusObject object);
  Future<void> unregister(DBusObject object);
  Future<int> loadScript(String path, String pluginName);
  Future<void> run(int id);
  Future<void> unload(String pluginName);
}

class _BusScripting implements KWinScripting {
  final DBusClient bus;
  _BusScripting(this.bus);
  @override
  String get uniqueName => bus.uniqueName;
  @override
  Stream<bool> get ownerChanges => bus.nameOwnerChanged
      .where((e) => e.name == 'org.kde.KWin')
      .map((e) => e.newOwner?.isNotEmpty ?? false);
  @override
  Future<void> register(DBusObject object) => bus.registerObject(object);
  @override
  Future<void> unregister(DBusObject object) => bus.unregisterObject(object);
  DBusRemoteObject object(String path) =>
      DBusRemoteObject(bus, name: 'org.kde.KWin', path: DBusObjectPath(path));
  @override
  Future<int> loadScript(String path, String pluginName) async =>
      (await object('/Scripting').callMethod(
        'org.kde.kwin.Scripting',
        'loadScript',
        [DBusString(path), DBusString(pluginName)],
        replySignature: DBusSignature('i'),
      )).returnValues.single.asInt32();
  @override
  Future<void> run(int id) async {
    await object(
      '/Scripting/Script$id',
    ).callMethod('org.kde.kwin.Script', 'run', []);
  }

  @override
  Future<void> unload(String pluginName) async {
    await object('/Scripting').callMethod(
      'org.kde.kwin.Scripting',
      'unloadScript',
      [DBusString(pluginName)],
    );
  }
}

class _Callback extends DBusObject {
  final KWinBridge bridge;
  _Callback(this.bridge, String path) : super(DBusObjectPath(path));
  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != kwinCallbackInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    try {
      if (call.name == 'Reply' && call.signature.value == 'ss') {
        bridge.handleReply(
          call.values[0].asString(),
          call.values[1].asString(),
        );
      } else if (call.name == 'Event' && call.signature.value == 's') {
        bridge.handleEvent(call.values.single.asString());
      } else {
        return DBusMethodErrorResponse.unknownMethod();
      }
      return DBusMethodSuccessResponse();
    } catch (_) {
      return DBusMethodErrorResponse.invalidArgs();
    }
  }
}

/// JSON callbacks are correlated by request id; requests execute one at a time.
class KWinBridge {
  static int _sequence = 0;
  final KWinScripting _scripting;
  final String scriptDir;
  late final String callbackPath;
  late final _Callback _callback;
  Future<void>? _registration;
  Future<void> _queue = Future.value();
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  StreamController<Map<String, dynamic>>? _events;
  StreamSubscription<bool>? _owners;
  String? _watchPlugin;
  File? _watchFile;
  bool _disposed = false;

  KWinBridge(DBusClient bus, {String? scriptDir})
    : this.withScripting(_BusScripting(bus), scriptDir: scriptDir);

  KWinBridge.withScripting(this._scripting, {String? scriptDir})
    : scriptDir =
          scriptDir ??
          '${Platform.environment['XDG_RUNTIME_DIR'] ?? Directory.systemTemp.path}/maprisma-theme' {
    callbackPath = '/io/github/maprisma/KWinBridge/b${pid}_${_sequence++}';
    _callback = _Callback(this, callbackPath);
  }

  Future<void> _ready() => _registration ??= _scripting.register(_callback);
  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _queue.then((_) => work());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace s) {});
    return result;
  }

  void handleReply(String requestId, String json) {
    final pending = _pending[requestId];
    if (pending == null || pending.isCompleted) return;
    try {
      pending.complete(Map<String, dynamic>.from(jsonDecode(json) as Map));
    } catch (e, s) {
      pending.completeError(e, s);
    }
  }

  void handleEvent(String json) {
    final event = Map<String, dynamic>.from(jsonDecode(json) as Map);
    if (_watchPlugin != null) _events?.add(event);
  }

  Future<File> _write(String plugin, String source) async {
    await Directory(scriptDir).create(recursive: true);
    final file = File('$scriptDir/$plugin.js');
    // Create with restrictive permissions before writing any script contents.
    await file.create(exclusive: true);
    final mode = await Process.run('chmod', ['600', file.path]);
    if (mode.exitCode != 0) {
      await file.delete();
      throw FileSystemException(tr('Cannot secure KWin script'), file.path);
    }
    try {
      await file.writeAsString(source);
      return file;
    } catch (_) {
      await file.delete();
      rethrow;
    }
  }

  Future<void> _clean(String plugin, File? file) async {
    try {
      await _scripting.unload(plugin);
    } finally {
      if (file != null && await file.exists()) await file.delete();
    }
  }

  Future<Map<String, dynamic>> request(
    String op,
    Map<String, dynamic> args, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    // The deadline counts from the call: a request that waited its time out
    // behind others is never run late (a move or close after its caller
    // gave up).
    final started = DateTime.now();
    return _serial(() async {
    if (_disposed) throw StateError(tr('Bridge disposed'));
    final left = timeout - DateTime.now().difference(started);
    if (left <= Duration.zero) throw TimeoutException('KWin $op (queued)', timeout);
    timeout = left;
    final id = 'r${pid}_${_sequence++}';
    final plugin = 'maprisma_$id';
    final reply = Completer<Map<String, dynamic>>();
    _pending[id] = reply;
    File? file;
    // Start the deadline before registration/load/run, not just the callback.
    final timer = Timer(timeout, () {
      if (!reply.isCompleted) {
        reply.completeError(TimeoutException('KWin $op', timeout));
      }
    });
    try {
      final work = () async {
        await _ready().timeout(timeout);
        file = await _write(
          plugin,
          kwinRequestScript(_scripting.uniqueName, callbackPath, id, op, args),
        );
        final script = await _scripting
            .loadScript(file!.path, plugin)
            .timeout(timeout);
        if (script < 0) throw StateError(tr('KWin refused script'));
        await _scripting.run(script).timeout(timeout);
      }();
      // Consume setup errors even if the callback deadline wins.
      unawaited(
        work.catchError((Object e, StackTrace s) {
          if (!reply.isCompleted) reply.completeError(e, s);
        }),
      );
      try {
        return await reply.future;
      } finally {
        // Do not race cleanup against a still-running load/run operation.
        await work;
      }
    } finally {
      timer.cancel();
      _pending.remove(id);
      await _clean(plugin, file).timeout(const Duration(seconds: 5), onTimeout: () {});
    }
  });
  }

  /// Repeated calls share one broadcast stream and one compositor script.
  Stream<Map<String, dynamic>> watch() {
    if (_disposed) throw StateError(tr('Bridge disposed'));
    return (_events ??= StreamController<Map<String, dynamic>>.broadcast(
      onListen: () {
        _owners = _scripting.ownerChanges.listen((available) {
          _watchAction(() async {
            await _stopWatch();
            if (available && _events!.hasListener) await _startWatch();
          });
        });
        _watchAction(_startWatch);
      },
      onCancel: () async {
        await _owners?.cancel();
        _owners = null;
        await _serial(_stopWatch);
      },
    )).stream;
  }

  void _watchAction(Future<void> Function() action) {
    unawaited(
      _serial(action).catchError((Object e, StackTrace s) {
        if (_events?.hasListener ?? false) _events!.addError(e, s);
      }),
    );
  }

  Future<void> _startWatch() async {
    if (_disposed || !_events!.hasListener || _watchPlugin != null) return;
    await _ready();
    final plugin = 'maprisma_watch_${pid}_${_sequence++}';
    _watchPlugin = plugin;
    try {
      _watchFile = await _write(
        plugin,
        kwinWatchScript(_scripting.uniqueName, callbackPath),
      );
      final id = await _scripting.loadScript(_watchFile!.path, plugin);
      if (id < 0) throw StateError(tr('KWin refused watch script'));
      await _scripting.run(id);
    } catch (_) {
      await _stopWatch();
      rethrow;
    }
  }

  Future<void> _stopWatch() async {
    final plugin = _watchPlugin;
    final file = _watchFile;
    _watchPlugin = null;
    _watchFile = null;
    if (plugin != null) {
      // A vanished compositor cannot unload its old script.
      try {
        await _clean(plugin, file);
      } catch (_) {
        /* restart */
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _owners?.cancel();
    await _serial(_stopWatch);
    await _events?.close();
    if (_registration != null) {
      await _registration;
      await _scripting.unregister(_callback);
    }
  }
}

String _js(Object? value) => jsonEncode(
  value,
).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');

String _preamble(String service, String path) =>
    '''
var target = ${_js([service, path, kwinCallbackInterface])};
function send(method, value, request) {
  if (method === 'Reply') callDBus(target[0], target[1], target[2], method, request, JSON.stringify(value));
  else callDBus(target[0], target[1], target[2], method, JSON.stringify(value));
}
function wid(w) { return String(w.internalId); }
function index(d) { return workspace.desktops.indexOf(d) + 1; }
function location(w) { return w.onAllDesktops || w.desktops.length !== 1 ? null : index(w.desktops[0]); }
''';

String kwinRequestScript(
  String service,
  String path,
  String requestId,
  String op,
  Map<String, dynamic> args,
) =>
    '''
${_preamble(service, path)}
var input = ${_js({'request': requestId, 'op': op, 'args': args})};
try {
  var result;
  var windows = workspace.windowList().filter(function(w) { return w.normalWindow; });
  if (input.op === 'state') {
    result = {desktops: workspace.desktops.map(function(d, i) {
      return {index:i+1, id:String(d.id), name:d.name, active:d === workspace.currentDesktop};
    }), windows: windows.map(function(w) {
      return {id:wid(w), app_id:String(w.resourceClass), title:w.caption,
        desktops:w.desktops.map(function(d) { return String(d.id); }),
        all:w.onAllDesktops, active:w === workspace.activeWindow};
    })};
  } else {
    var w = windows.filter(function(w) { return wid(w) === input.args.id; })[0];
    if (!w) result = {error:'not_found'};
    else if (input.op === 'move') {
      var d = workspace.desktops[input.args.index - 1];
      if (!d) result = {error:'bad_args'};
      else { w.desktops = [d]; result = {done:true}; }
    } else if (input.op === 'close') { w.closeWindow(); result = {done:true}; }
    else if (input.op === 'activate') {
      if (!w.onAllDesktops && w.desktops.length) workspace.currentDesktop = w.desktops[0];
      workspace.activeWindow = w; result = {done:true};
    } else result = {error:'bad_args'};
  }
  send('Reply', result, input.request);
} catch (e) { send('Reply', {error:'unavailable', message:String(e)}, input.request); }
''';

String kwinWatchScript(String service, String path) =>
    '''
${_preamble(service, path)}
function desktopEvent() { send('Event', {event:'workspace', index:index(workspace.currentDesktop)}); }
function track(w) {
  if (!w.normalWindow) return;
  w.desktopsChanged.connect(function() {
    send('Event', {event:'window_moved', id:wid(w), workspace:location(w)});
  });
}
workspace.currentDesktopChanged.connect(desktopEvent);
workspace.windowAdded.connect(function(w) {
  if (!w.normalWindow) return;
  track(w);
  send('Event', {event:'window_new', id:wid(w), app_id:String(w.resourceClass), workspace:location(w)});
});
workspace.windowRemoved.connect(function(w) {
  if (w.normalWindow) send('Event', {event:'window_closed', id:wid(w)});
});
workspace.windowList().forEach(track);
desktopEvent();
''';

Map<String, dynamic> wmWorkspaces(Map state) => {
  'workspaces': [
    for (final d in state['desktops'] as List)
      {
        'index': d['index'],
        'name': d['name'],
        'active': d['active'],
        'tiling': false,
        'output': '',
      },
  ],
  'can_tile': false,
};

Map<String, dynamic> wmWindows(Map state) {
  final desktops = state['desktops'] as List;
  return {
    'windows': [
      for (final w in state['windows'] as List)
        {
          'id': w['id'],
          'app_id': w['app_id'],
          'title': w['title'],
          'workspace': _workspace(w as Map, desktops),
          'output': '',
          'active': w['active'],
        },
    ],
  };
}

int? _workspace(Map window, List desktops) {
  final ids = window['desktops'] as List;
  if (window['all'] == true || ids.length != 1) return null;
  for (final d in desktops) {
    if (d['id'] == ids.single) return d['index'] as int;
  }
  return null;
}

Future<Map<String, dynamic>> kdeWm(KWinBridge b, List<String> args) async {
  Map<String, dynamic> error(String code, String message) => {
    'error': code,
    'message': message,
  };
  if (args.isEmpty) return error('bad_args', tr('Missing command'));
  final op = args.first;
  if (op == 'set-tiling') return {'error': 'not_available'};
  final length = switch (op) {
    'workspaces' || 'windows' => 1,
    'move' => 3,
    'close' || 'activate' => 2,
    _ => 0,
  };
  if (length == 0 || args.length != length) {
    return error('bad_args', tr('Invalid command arguments'));
  }
  if (length > 1 &&
      !RegExp(
        r'^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$',
      ).hasMatch(args[1])) {
    return error('bad_args', tr('Invalid window id'));
  }
  final index = op == 'move' ? int.tryParse(args[2]) : null;
  if (op == 'move' && (index == null || index < 1)) {
    return error('bad_args', tr('Invalid workspace index'));
  }
  try {
    final state = await b.request('state', {});
    if (state.containsKey('error')) {
      return error('unavailable', '${state['message'] ?? state['error']}');
    }
    if (op == 'workspaces') return wmWorkspaces(state);
    if (op == 'windows') return wmWindows(state);
    if (op == 'move' &&
        !(state['desktops'] as List).any((d) => d['index'] == index)) {
      return error('bad_args', tr('Workspace index out of range'));
    }
    if (!(state['windows'] as List).any((w) => w['id'] == args[1])) {
      return error('not_found', tr('Window not found'));
    }
    final result = await b.request(op, {'id': args[1], 'index': ?index});
    if (result.containsKey('error')) {
      return error(
        '${result['error']}',
        '${result['message'] ?? result['error']}',
      );
    }
    return {'done': true};
  } catch (e) {
    return error('unavailable', e.toString());
  }
}
