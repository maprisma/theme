/// `maprisma-theme-core daemon` (docs/multi-desktop.md, step 3): on desktops
/// without Maprisma Theme's own panel applet (KDE Plasma) it does what the
/// COSMIC applet does — the tray icon (click: window, scroll: wallpaper,
/// menu: favorite themes) and the automation of automation.json (workspace
/// themes, the minute tick, window limits, autostart once per session). On
/// COSMIC the applet stays the only owner: the daemon does nothing there.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

import 'context.dart';
import 'core.dart';
import 'desktop.dart';
import 'desktop_kde.dart';
import 'shortcuts_kde.dart';
import 'store.dart';

// --- automation (pure; tests drive it) ----------------------------------------------------

/// automation.json's tiling part.
final class TilingRules {
  TilingRules({this.active = false, this.defaultLimit = 2, this.limits = const {}});
  factory TilingRules.fromJson(Object? v) {
    if (v is! Map) return TilingRules();
    final limits = <int, int>{};
    if (v['limits'] is Map) {
      for (final e in (v['limits'] as Map).entries) {
        final k = int.tryParse('${e.key}'), n = e.value;
        if (k != null && n is int) limits[k] = n;
      }
    }
    return TilingRules(active: v['active'] == true, defaultLimit: v['default_limit'] is int ? v['default_limit'] as int : 2, limits: limits);
  }
  final bool active;
  final int defaultLimit;
  final Map<int, int> limits;

  /// Windows a workspace takes (1–4, as the applet).
  int limit(int ws) => (limits[ws] ?? defaultLimit).clamp(1, 4);
}

/// Where a new window on [source] goes when that workspace is over its limit
/// (counts include the new window): the next workspace with room after it,
/// wrapping once; null = it stays. The applet's rule
/// (cosmic/helper/src/automation.rs); no workspace is ever created.
int? overflowTarget(int source, SplayTreeMap<int, int> counts, TilingRules t) {
  if (!t.active || (counts[source] ?? 0) <= t.limit(source)) return null;
  for (final e in [...counts.entries.where((e) => e.key > source), ...counts.entries.where((e) => e.key < source)]) {
    if (e.value < t.limit(e.key)) return e.key;
  }
  return null;
}

/// One job of the daemon's queue.
sealed class Job {}

final class CoreJob extends Job {
  CoreJob(this.method, [this.params = const {}]);
  final String method;
  final Map<String, dynamic> params;
}

final class OverflowJob extends Job {
  OverflowJob(this.id, this.workspace);
  final String id;
  final int workspace;
}

/// The applet's queue: one job at a time, at most 64 waiting; a newer
/// workspace switch or tick replaces a waiting one of its kind; a window
/// that moved or closed drops its waiting overflow job.
final class JobQueue {
  final _q = Queue<Job>();
  Queue<Job> get jobs => _q;

  void add(Job j) {
    if (j is CoreJob && (j.method == 'auto.workspace' || j.method == 'auto.tick')) {
      _q.removeWhere((o) => o is CoreJob && o.method == j.method);
    }
    if (_q.length < 64) _q.add(j);
  }

  void dropOverflow(String id) => _q.removeWhere((o) => o is OverflowJob && o.id == id);
  Job? take() => _q.isEmpty ? null : _q.removeFirst();
}

/// Turns watch events into jobs (overflow waits for a new window's first
/// workspace, as the applet's overflow_event).
final class EventRouter {
  final _pending = <String>{};

  List<Job> route(Map<String, dynamic> e, {required bool workspaceEvents, required bool tilingActive, JobQueue? queue}) {
    final out = <Job>[];
    final id = e['id'] is String ? e['id'] as String : null;
    switch (e['event']) {
      case 'workspace':
        if (workspaceEvents && e['index'] is int) out.add(CoreJob('auto.workspace', {'workspace': e['index']}));
      case 'window_closed':
        if (id != null) {
          _pending.remove(id);
          queue?.dropOverflow(id);
        }
      case 'window_new':
        if (id != null && tilingActive) {
          if (e['workspace'] is int) {
            out.add(OverflowJob(id, e['workspace'] as int));
          } else {
            _pending.add(id);
          }
        }
      case 'window_moved':
        if (id != null) {
          queue?.dropOverflow(id); // moved by hand: it stays
          if (_pending.remove(id) && tilingActive && e['workspace'] is int) out.add(OverflowJob(id, e['workspace'] as int));
        }
    }
    return out;
  }
}

/// Claims this login session's autostart once (a marker in
/// XDG_RUNTIME_DIR/maprisma-theme, cleared at logout); always consumed.
bool claimAutostart(Map<String, String> env) {
  final runtime = env['XDG_RUNTIME_DIR'];
  if (runtime == null || runtime.isEmpty) return false;
  var session = env['XDG_SESSION_ID'] ?? '';
  if (session.isEmpty) {
    try {
      session = File('/proc/sys/kernel/random/boot_id').readAsStringSync().trim();
    } on FileSystemException {
      return false;
    }
  }
  final safe = session.replaceAll(RegExp('[^A-Za-z0-9-]'), '');
  if (safe.isEmpty) return false;
  try {
    Directory('$runtime/maprisma-theme').createSync(recursive: true);
    File('$runtime/maprisma-theme/autostart-$safe').createSync(exclusive: true);
    return true;
  } on FileSystemException {
    return false;
  }
}

// --- the tray icon: StatusNotifierItem + com.canonical.dbusmenu ---------------------------------

final class _Tray extends DBusObject {
  _Tray(this.d) : super(DBusObjectPath('/StatusNotifierItem'));
  final Daemon d;

  static const _iface = 'org.kde.StatusNotifierItem';

  Map<String, DBusValue> get _props => {
    'Category': const DBusString('ApplicationStatus'),
    'Id': const DBusString('maprisma-theme'),
    'Title': const DBusString('Maprisma Theme'),
    'Status': const DBusString('Active'),
    'IconName': const DBusString('com.maprisma.Theme'),
    'IconThemePath': const DBusString(''),
    'ItemIsMenu': const DBusBoolean(false),
    'Menu': DBusObjectPath('/MenuBar'),
    'ToolTip': DBusStruct([
      const DBusString('com.maprisma.Theme'),
      DBusArray(DBusSignature('(iiay)'), const []),
      const DBusString('Maprisma Theme'),
      DBusString(d.theme.isEmpty ? 'Scroll: wallpaper · right-click: favorites' : '${d.theme} · scroll: wallpaper'),
    ]),
  };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final v = interface == _iface ? _props[name] : null;
    return v == null ? DBusMethodErrorResponse.unknownProperty() : DBusGetPropertyResponse(v);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(interface == _iface ? _props : {});

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall c) async {
    if (c.interface != _iface) return DBusMethodErrorResponse.unknownInterface();
    switch (c.name) {
      case 'Activate' || 'SecondaryActivate':
        d.toggleWindow();
      case 'Scroll':
        final delta = c.values.first.asInt32();
        if (delta != 0) d.scroll(delta);
      case 'ContextMenu':
        break; // hosts show the Menu
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodSuccessResponse();
  }

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(_iface, methods: [
      DBusIntrospectMethod('Activate', args: [DBusIntrospectArgument(DBusSignature('i'), DBusArgumentDirection.in_), DBusIntrospectArgument(DBusSignature('i'), DBusArgumentDirection.in_)]),
      DBusIntrospectMethod('SecondaryActivate', args: [DBusIntrospectArgument(DBusSignature('i'), DBusArgumentDirection.in_), DBusIntrospectArgument(DBusSignature('i'), DBusArgumentDirection.in_)]),
      DBusIntrospectMethod('ContextMenu', args: [DBusIntrospectArgument(DBusSignature('i'), DBusArgumentDirection.in_), DBusIntrospectArgument(DBusSignature('i'), DBusArgumentDirection.in_)]),
      DBusIntrospectMethod('Scroll', args: [DBusIntrospectArgument(DBusSignature('i'), DBusArgumentDirection.in_), DBusIntrospectArgument(DBusSignature('s'), DBusArgumentDirection.in_)]),
    ], signals: [
      DBusIntrospectSignal('NewToolTip'),
      DBusIntrospectSignal('NewIcon'),
    ], properties: [
      for (final e in _props.entries) DBusIntrospectProperty(e.key, e.value.signature, access: DBusPropertyAccess.read),
    ]),
  ];
}

/// The menu: favorite themes (radio items, the current one checked), then
/// Next wallpaper and Open, from the core's `auto.menu`.
final class _Menu extends DBusObject {
  _Menu(this.d) : super(DBusObjectPath('/MenuBar'));
  final Daemon d;
  static const _iface = 'com.canonical.dbusmenu';
  var revision = 1;
  Map<String, dynamic> data = const {};

  /// id → (label, action, toggle state or null, enabled).
  Map<int, (String, Future<void> Function()?, bool?, bool)> get _items {
    final out = <int, (String, Future<void> Function()?, bool?, bool)>{};
    var id = 1;
    out[id++] = ('${data['title'] ?? 'Favorite themes'}', null, null, false);
    final themes = data['themes'] is List ? data['themes'] as List : const [];
    if (themes.isEmpty) out[id++] = ('${data['empty_note'] ?? 'No favorites yet'}', null, null, false);
    for (final t in themes.take(30)) {
      if (t is! Map || t['slug'] is! String) continue;
      final slug = t['slug'] as String;
      out[id++] = ('${t['name'] ?? slug}', () => d.run(CoreJob('themes.apply', {'slug': slug})), t['current'] == true, true);
    }
    out[id++] = ('-', null, null, false);
    for (final i in data['items'] is List ? data['items'] as List : const []) {
      if (i is! Map) continue;
      final action = switch (i['id']) {
        'next_wallpaper' => () => d.run(CoreJob('auto.step_background', {'direction': 1})),
        'open' => () async => d.toggleWindow(),
        _ => null,
      };
      if (action != null) out[id++] = ('${i['label']}', action, null, true);
    }
    return out;
  }

  DBusStruct _node(int id, (String, Future<void> Function()?, bool?, bool) it) {
    final props = <String, DBusValue>{
      if (it.$1 == '-') 'type': const DBusString('separator') else 'label': DBusString(it.$1.replaceAll('_', '__')),
      if (!it.$4 && it.$1 != '-') 'enabled': const DBusBoolean(false),
      if (it.$3 != null) 'toggle-type': const DBusString('radio'),
      if (it.$3 != null) 'toggle-state': DBusInt32(it.$3! ? 1 : 0),
    };
    return DBusStruct([DBusInt32(id), DBusDict.stringVariant(props), DBusArray.variant(const [])]);
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall c) async {
    if (c.interface != _iface) return DBusMethodErrorResponse.unknownInterface();
    final items = _items;
    switch (c.name) {
      case 'GetLayout':
        final root = DBusStruct([
          const DBusInt32(0),
          DBusDict.stringVariant({'children-display': const DBusString('submenu')}),
          DBusArray.variant([for (final e in items.entries) _node(e.key, e.value)]),
        ]);
        return DBusMethodSuccessResponse([DBusUint32(revision), root]);
      case 'GetGroupProperties':
        final ids = c.values.first.asInt32Array();
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature('(ia{sv})'), [
            for (final id in ids)
              if (items[id] case final it?) DBusStruct([DBusInt32(id), (_node(id, it).children[1])]),
          ]),
        ]);
      case 'GetProperty':
        return DBusMethodSuccessResponse([const DBusVariant(DBusString(''))]);
      case 'Event':
        final id = c.values[0].asInt32(), kind = c.values[1].asString();
        if (kind == 'clicked') unawaited(items[id]?.$2?.call());
        return DBusMethodSuccessResponse();
      case 'EventGroup':
        // a(isvu): each (id, event, data, time); unknown ids come back as errors
        final errors = <int>[];
        for (final e in c.values.first.asArray()) {
          final f = e.asStruct();
          final id = f[0].asInt32();
          if (!items.containsKey(id)) {
            errors.add(id);
          } else if (f[1].asString() == 'clicked') {
            unawaited(items[id]!.$2?.call());
          }
        }
        return DBusMethodSuccessResponse([DBusArray.int32(errors)]);
      case 'AboutToShow':
        await d.refreshMenu();
        return DBusMethodSuccessResponse([const DBusBoolean(true)]);
      case 'AboutToShowGroup':
        await d.refreshMenu();
        return DBusMethodSuccessResponse([DBusArray.int32(const []), DBusArray.int32(const [])]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async => switch (name) {
    'Version' => DBusGetPropertyResponse(const DBusUint32(3)),
    'Status' => DBusGetPropertyResponse(const DBusString('normal')),
    'TextDirection' => DBusGetPropertyResponse(const DBusString('ltr')),
    'IconThemePath' => DBusGetPropertyResponse(DBusArray.string(const [])),
    _ => DBusMethodErrorResponse.unknownProperty(),
  };

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async => DBusGetAllPropertiesResponse({
    'Version': const DBusUint32(3),
    'Status': const DBusString('normal'),
    'TextDirection': const DBusString('ltr'),
    'IconThemePath': DBusArray.string(const []),
  });
}

// --- the daemon ---------------------------------------------------------------------------------

const daemonBusName = 'com.maprisma.Theme.Daemon';

final class Daemon {
  Daemon(this.core, this.bus);
  final CoreService core;
  final DBusClient bus;
  Ctx get ctx => core.ctx;

  final queue = JobQueue();
  final router = EventRouter();
  var _busy = false;
  Map<String, dynamic> automation = const {};
  String theme = '';
  late final _tray = _Tray(this);
  late final _menu = _Menu(this);
  final _subs = <StreamSubscription<dynamic>>[];
  final _timers = <Timer>[];
  DateTime? _automationStamp, _shortcutsStamp;
  DateTime _lastScroll = DateTime.fromMillisecondsSinceEpoch(0);

  TilingRules get tiling => TilingRules.fromJson(automation['tiling']);

  void _readAutomation() {
    final f = File(ctx.paths.automationFile);
    final stamp = f.existsSync() ? f.lastModifiedSync() : null;
    if (stamp == _automationStamp && automation.isNotEmpty) return;
    _automationStamp = stamp;
    automation = readJsonMap(ctx.paths.automationFile);
  }

  /// shortcuts.json changed (or first start): kglobalaccel made to match.
  Future<void> _syncShortcuts() async {
    if (!ctx.desktop.caps.contains(Cap.shortcuts) || ctx.desktop.id != 'kde') return;
    final f = File(ctx.paths.file('shortcuts.json'));
    final stamp = f.existsSync() ? f.lastModifiedSync() : DateTime.fromMillisecondsSinceEpoch(0);
    if (stamp == _shortcutsStamp) return;
    _shortcutsStamp = stamp;
    await syncKdeShortcuts(ctx.paths, ctx.environment);
  }

  Future<void> run(Job j) async {
    queue.add(j);
    await _next();
  }

  Future<void> _next() async {
    if (_busy) return;
    _busy = true;
    try {
      for (var j = queue.take(); j != null; j = queue.take()) {
        try {
          switch (j) {
            // As the applet's runner: no job holds the queue longer than 60 s.
            case CoreJob(:final method, :final params):
              await core.call(method, params).timeout(const Duration(seconds: 60));
            case OverflowJob(:final id, :final workspace):
              await _overflow(id, workspace).timeout(const Duration(seconds: 60));
          }
        } on Object catch (e) {
          stderr.writeln('maprisma-theme daemon: $e');
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _overflow(String id, int source) async {
    _readAutomation();
    final t = tiling;
    if (!t.active) return;
    final ws = await ctx.desktop.wm(['workspaces']);
    final wins = await ctx.desktop.wm(['windows']);
    if (ws?['workspaces'] is! List || wins?['windows'] is! List) return;
    final counts = SplayTreeMap<int, int>();
    for (final w in ws!['workspaces'] as List) {
      if (w is Map && w['index'] is int) counts[w['index'] as int] = 0;
    }
    final list = (wins!['windows'] as List).whereType<Map>().toList();
    if (!list.any((w) => w['id'] == id && w['workspace'] == source)) return; // moved meanwhile
    for (final w in list) {
      if (w['workspace'] is int && counts.containsKey(w['workspace'])) counts[w['workspace'] as int] = counts[w['workspace']]! + 1;
    }
    final dest = overflowTarget(source, counts, t);
    if (dest == null) return;
    final moved = await ctx.desktop.wm(['move', id, '$dest']);
    // The new window is what the user just opened: follow it to its workspace.
    if (moved?['done'] == true) await ctx.desktop.wm(['activate', id]);
  }

  void toggleWindow() {
    final gui = findProgram(ctx.paths, ctx.environment, 'maprisma-theme');
    if (gui == null) return;
    Process.start(gui, ['--toggle'], mode: ProcessStartMode.detached, environment: ctx.environment).ignore();
  }

  void scroll(int delta) {
    final now = DateTime.now();
    if (now.difference(_lastScroll) < const Duration(milliseconds: 300)) return;
    _lastScroll = now;
    unawaited(run(CoreJob('auto.step_background', {'direction': delta > 0 ? -1 : 1})));
  }

  /// The menu from the core; when it changed, hosts are told (LayoutUpdated),
  /// so a cached menu never maps a click to an old entry.
  Future<void> refreshMenu() async {
    try {
      final data = await core.call('auto.menu').timeout(const Duration(seconds: 10));
      if (jsonEncode(data) == jsonEncode(_menu.data)) return;
      _menu.data = data;
      _menu.revision++;
      if (_trayRegistered) {
        await _menu.emitSignal('com.canonical.dbusmenu', 'LayoutUpdated', [DBusUint32(_menu.revision), const DBusInt32(0)]);
      }
    } on Object {
      // keep the last menu
    }
  }

  var _trayRegistered = false;

  /// Exports the tray objects once, then (again after a tray host restart)
  /// registers the item with the watcher.
  Future<void> _registerTray() async {
    if (!_trayRegistered) {
      await bus.registerObject(_tray);
      await bus.registerObject(_menu);
      _trayRegistered = true;
    }
    final watcher = DBusRemoteObject(bus, name: 'org.kde.StatusNotifierWatcher', path: DBusObjectPath('/StatusNotifierWatcher'));
    await watcher.callMethod('org.kde.StatusNotifierWatcher', 'RegisterStatusNotifierItem', [DBusString(bus.uniqueName)]);
  }

  /// Runs until the session ends (or [stop]).
  Future<void> start({Stream<Map<String, dynamic>>? events}) async {
    _readAutomation();
    await refreshMenu();
    theme = ctx.current.slug;
    try {
      await _registerTray();
    } on DBusMethodResponseException catch (e) {
      stderr.writeln('maprisma-theme daemon: no tray ($e)');
    }
    // The tray host may come later (plasmashell restart): register again then.
    _subs.add(DBusSignalStream(bus, interface: 'org.freedesktop.DBus', name: 'NameOwnerChanged', signature: DBusSignature('sss'))
        .listen((s) {
      if (s.values[0].asString() == 'org.kde.StatusNotifierWatcher' && s.values[2].asString().isNotEmpty) {
        unawaited(_registerTray().catchError((_) {}));
      }
    }));
    if (claimAutostart(ctx.environment) && automation['autostart'] == true) unawaited(run(CoreJob('presets.autostart')));
    unawaited(_syncShortcuts().catchError((_) {}));
    if (events != null) {
      _subs.add(events.listen((e) {
        _readAutomation();
        for (final j in router.route(e,
            workspaceEvents: automation['workspace_events'] == true, tilingActive: tiling.active, queue: queue)) {
          unawaited(run(j));
        }
      }));
    }
    var minute = 0;
    _timers.add(Timer.periodic(const Duration(seconds: 5), (_) {
      _readAutomation();
      unawaited(_syncShortcuts());
      final now = ctx.current.slug;
      if (now != theme) {
        theme = now;
        unawaited(_tray.emitSignal('org.kde.StatusNotifierItem', 'NewToolTip'));
      }
      if (++minute >= 12) {
        minute = 0;
        if (automation['tick'] == true) unawaited(run(CoreJob('auto.tick')));
      }
    }));
  }

  Future<void> stop() async {
    for (final t in _timers) {
      t.cancel();
    }
    for (final s in _subs) {
      await s.cancel();
    }
  }
}

/// The `daemon` command: exits at once on COSMIC (its applet owns this) or
/// when another daemon of this session runs.
Future<int> runDaemon(Map<String, String> environment) async {
  final core = CoreService(environment: environment);
  if (core.ctx.desktop.id == 'cosmic') {
    stdout.writeln(jsonEncode({'daemon': false, 'reason': 'COSMIC: the panel applet does this'}));
    return 0;
  }
  final bus = sessionBus(environment);
  if (bus == null) {
    stderr.writeln('maprisma-theme daemon: no session bus');
    return 1;
  }
  final reply = await bus.requestName(daemonBusName, flags: {DBusRequestNameFlag.doNotQueue});
  if (reply != DBusRequestNameReply.primaryOwner) {
    stdout.writeln(jsonEncode({'daemon': false, 'reason': 'already running'}));
    await bus.close();
    return 0;
  }
  final daemon = Daemon(core, bus);
  await daemon.start(events: core.ctx.desktop.watch());
  final done = Completer<void>();
  final signals = [
    for (final sig in [ProcessSignal.sigterm, ProcessSignal.sigint])
      sig.watch().listen((_) {
        if (!done.isCompleted) done.complete();
      }),
  ];
  await done.future;
  for (final s in signals) {
    await s.cancel();
  }
  // Cleanup gets a few seconds; the caller exits the process after it.
  await Future.wait<void>([
    daemon.stop(),
    if (core.ctx.desktop case final KdeDesktop kde) kde.close(),
    bus.close(),
  ]).timeout(const Duration(seconds: 3), onTimeout: () => const []);
  return 0;
}
