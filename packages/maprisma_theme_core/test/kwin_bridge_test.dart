import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:maprisma_theme_core/src/kwin_bridge.dart';
import 'package:test/test.dart';

const id = '{12345678-1234-1234-1234-123456789abc}';
Map<String, dynamic> state() => {
  'desktops': [
    {'index': 1, 'id': 'one', 'name': 'Main', 'active': true},
    {'index': 2, 'id': 'two', 'name': 'Other', 'active': false},
  ],
  'windows': [
    {
      'id': id,
      'app_id': 'terminal',
      'title': 'Title',
      'desktops': ['two'],
      'all': false,
      'active': true,
    },
  ],
};

class FakeScripting implements KWinScripting {
  final owners = StreamController<bool>.broadcast();
  final sources = <int, String>{};
  final files = <String>[];
  final unloaded = <String>[];
  final operations = <String>[];
  DBusObject? callback;
  bool answer = true;
  bool failRun = false;
  Completer<void>? gate;
  int next = 0;
  @override
  String get uniqueName => ':1.123';
  @override
  Stream<bool> get ownerChanges => owners.stream;
  @override
  Future<void> register(DBusObject object) async {
    callback = object;
  }

  @override
  Future<void> unregister(DBusObject object) async {
    callback = null;
  }

  @override
  Future<int> loadScript(String path, String pluginName) async {
    files.add(path);
    sources[++next] = await File(path).readAsString();
    final stat = await File(path).stat();
    expect(stat.mode & 0x1ff, 0x180);
    return next;
  }

  @override
  Future<void> run(int script) async {
    if (failRun) throw StateError('run failed');
    await gate?.future;
    final source = sources[script]!;
    if (!source.contains('var input = ')) return;
    final input = jsonDecode(
      RegExp(r'var input = (.*);').firstMatch(source)![1]!,
    );
    operations.add(input['op'] as String);
    if (answer) {
      await callback!.handleMethodCall(
        DBusMethodCall(
          sender: ':1.42',
          interface: kwinCallbackInterface,
          name: 'Reply',
          values: [
            DBusString(input['request'] as String),
            DBusString(
              jsonEncode(input['op'] == 'state' ? state() : {'done': true}),
            ),
          ],
        ),
      );
    }
  }

  @override
  Future<void> unload(String pluginName) async {
    unloaded.add(pluginName);
  }
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory directory;
  late FakeScripting fake;
  late KWinBridge bridge;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('kwin_test_');
    fake = FakeScripting();
    bridge = KWinBridge.withScripting(fake, scriptDir: directory.path);
  });
  tearDown(() async {
    await bridge.dispose();
    await fake.owners.close();
    await directory.delete(recursive: true);
  });

  test('maps workspaces and single/multiple/all/unknown desktop windows', () {
    final s = state();
    expect(wmWorkspaces(s), {
      'workspaces': [
        {
          'index': 1,
          'name': 'Main',
          'active': true,
          'tiling': false,
          'output': '',
        },
        {
          'index': 2,
          'name': 'Other',
          'active': false,
          'tiling': false,
          'output': '',
        },
      ],
      'can_tile': false,
    });
    Map window() => (s['windows'] as List).single as Map;
    expect((wmWindows(s)['windows'] as List).single, {
      'id': id,
      'app_id': 'terminal',
      'title': 'Title',
      'workspace': 2,
      'output': '',
      'active': true,
    });
    for (final ids in [
      [],
      ['one', 'two'],
      ['missing'],
    ]) {
      window()['desktops'] = ids;
      expect((wmWindows(s)['windows'] as List).single['workspace'], isNull);
    }
    window()['desktops'] = ['one'];
    window()['all'] = true;
    expect((wmWindows(s)['windows'] as List).single['workspace'], isNull);
  });

  test('argv validates before action and preserves errors', () async {
    for (final args in <List<String>>[
      [],
      ['oops'],
      ['windows', 'extra'],
      ['close', 'bad'],
      ['move', id, '0'],
      ['move', id, 'NaN'],
      ['activate'],
    ]) {
      expect((await kdeWm(bridge, args))['error'], 'bad_args');
    }
    expect(fake.files, isEmpty);
    expect(await kdeWm(bridge, ['set-tiling', '1', 'on']), {
      'error': 'not_available',
    });
    expect((await kdeWm(bridge, ['move', id, '3']))['error'], 'bad_args');
    expect(
      (await kdeWm(bridge, [
        'close',
        '{aaaaaaaa-1234-1234-1234-123456789abc}',
      ]))['error'],
      'not_found',
    );
    for (final args in [
      ['move', id, '2'],
      ['close', id],
      ['activate', id],
    ]) {
      expect(await kdeWm(bridge, args), {'done': true});
    }
    expect((await kdeWm(bridge, ['windows']))['windows'], isNotEmpty);
    expect((await kdeWm(bridge, ['workspaces']))['can_tile'], false);
    fake.failRun = true;
    expect((await kdeWm(bridge, ['windows']))['error'], 'unavailable');
  });

  test('scripts embed hostile values only in JSON and wire signals', () {
    const evil = '"; throw new Error("injected"); //\n\\\u2028';
    final js = kwinRequestScript(evil, '/path', evil, 'move', {
      'id': evil,
      'title': evil,
    });
    final input = jsonDecode(RegExp(r'var input = (.*);').firstMatch(js)![1]!);
    expect(input['args']['id'], evil);
    expect(input['args']['title'], evil);
    expect(js, isNot(contains('\u2028')));
    expect(js, contains('w.desktops = [d]'));
    expect(js, contains('w.closeWindow()'));
    expect(js, contains('workspace.activeWindow = w'));
    final watch = kwinWatchScript(':1.2', '/path');
    for (final signal in [
      'currentDesktopChanged',
      'windowAdded',
      'windowRemoved',
      'desktopsChanged',
    ]) {
      expect(watch, contains('$signal.connect'));
    }
    expect(watch, contains('desktopEvent();'));
  });

  test('requests serialize and clean up private files and plugins', () async {
    fake.gate = Completer<void>();
    final first = bridge.request('state', {});
    final second = bridge.request('close', {'id': id});
    await settle();
    expect(fake.files.length, 1);
    fake.gate!.complete();
    await Future.wait([first, second]);
    expect(fake.operations, ['state', 'close']);
    expect(fake.unloaded.toSet().length, 2);
    expect(await directory.list().toList(), isEmpty);
  });

  test('callback timeout and run failure both clean up', () async {
    fake.answer = false;
    await expectLater(
      bridge.request('state', {}, timeout: const Duration(milliseconds: 30)),
      throwsA(isA<TimeoutException>()),
    );
    bridge.handleReply('late', '{}');
    expect(await directory.list().toList(), isEmpty);
    fake.failRun = true;
    await expectLater(bridge.request('state', {}), throwsStateError);
    expect(fake.unloaded.length, 2);
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'one watcher, event delivery, restart reload and cancel cleanup',
    () async {
      final events = <Map<String, dynamic>>[];
      final stream = bridge.watch();
      final other = bridge.watch().listen((_) {});
      final subscription = stream.listen(events.add);
      await settle();
      expect(fake.files.length, 1);
      bridge.handleEvent('{"event":"workspace","index":2}');
      await settle();
      expect(events.single['index'], 2);
      fake.owners.add(false);
      fake.owners.add(true);
      await settle();
      expect(fake.files.length, 2);
      expect(fake.unloaded.length, 1);
      await other.cancel();
      expect(fake.unloaded.length, 1);
      await subscription.cancel();
      await settle();
      expect(fake.unloaded.length, 2);
      expect(await directory.list().toList(), isEmpty);
    },
  );
}
