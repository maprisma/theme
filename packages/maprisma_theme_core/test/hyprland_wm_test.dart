import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/hyprland_wm.dart' show floatingGeometry;
import 'package:maprisma_theme_core/src/workspace_state.dart' show cleanWorkspaceState;
import 'package:test/test.dart';

Map<String, dynamic> win(String addr, int ws,
        {List<int> at = const [0, 0], List<int> size = const [960, 1080], bool floating = false, List<String> tags = const [], int monitor = 0}) =>
    {
      'address': addr,
      'workspace': {'id': ws, 'name': '$ws'},
      'mapped': true,
      'hidden': false,
      'floating': floating,
      'fullscreen': 0,
      'at': at,
      'size': size,
      'tags': tags,
      'monitor': monitor,
      'class': 'kitty',
      'title': 'shell',
      'grouped': <String>[],
    };

String rule(int ws, String layout, [String? o]) => o == null
    ? 'hl.workspace_rule({ workspace = "$ws", layout = "$layout" })'
    : 'hl.workspace_rule({ workspace = "$ws", layout = "$layout", layout_opts = { orientation = "$o" } })';
String layout(String m) => 'hl.dispatch(hl.dsp.layout("$m"))';
String removeMasters(int n) => 'for _ = 1, $n do pcall(function() hl.dispatch(hl.dsp.layout("removemaster")) end) end';
String focusWs(int ws) => 'hl.dispatch(hl.dsp.focus({ workspace = $ws }))';
String toggleOf(String a) => '(function() local w = hl.get_window("address:$a") '
    'if w then hl.dispatch(hl.dsp.focus({ window = w })) pcall(function() hl.dispatch(hl.dsp.layout("togglesplit")) end) end end)()';
const toggle = 'hl.dispatch(hl.dsp.layout("togglesplit"))';

const monitor = {
  'id': 0, 'name': 'DP-1', 'width': 1920, 'height': 1080, 'scale': 1.0, 'x': 0, 'y': 0, 'reserved': [0, 30, 0, 0],
  'activeWorkspace': {'id': 3},
};

void main() {
  List<String> plan(String preset, List<Map<String, dynamic>> clients, {int ws = 1, int? active = 1, int cap = 2, double? split}) =>
      planPreset(workspace: ws, preset: preset, clients: clients, monitors: [monitor], activeWorkspace: active, cap: cap, split: split);

  group('planPreset (golden Lua, as simple_tile.py)', () {
    final vertical = [win('0xa1', 1), win('0xa2', 1, at: [0, 540])];
    final horizontal = [win('0xa1', 1), win('0xa2', 1, at: [960, 0])];

    test('none: only the dwindle rule, the windows left as they are', () {
      expect(plan('none', horizontal), [rule(1, 'dwindle')]);
      expect(plan('none', []), [rule(1, 'dwindle')]);
    });

    test('side-by-side and stacked: the split turned where needed, the left/top share', () {
      expect(plan('side-by-side', vertical), [rule(1, 'dwindle'), rule(1, 'dwindle'), toggle, layout('splitratio 1.00 exact')]);
      expect(plan('side-by-side', horizontal, split: 0.35), [rule(1, 'dwindle'), rule(1, 'dwindle'), layout('splitratio 0.70 exact')]);
      expect(plan('stacked', horizontal), [rule(1, 'dwindle'), rule(1, 'dwindle'), toggle, layout('splitratio 1.00 exact')]);
      expect(plan('stacked', vertical, split: 0.8), [rule(1, 'dwindle'), rule(1, 'dwindle'), layout('splitratio 1.60 exact')]);
      expect(plan('side-by-side', [win('0xa1', 1)]), [rule(1, 'dwindle')]); // one window: nothing to arrange
    });

    test('master-left/right: masters removed, orientation, the master share; focus there and back', () {
      final three = [win('0xa1', 1), win('0xa2', 1, at: [960, 0]), win('0xa3', 1, at: [960, 540])];
      expect(plan('master-left', three, active: 2, split: 0.6), [
        rule(1, 'master', 'left'),
        focusWs(1),
        removeMasters(4),
        layout('orientationleft'),
        layout('mfact exact 0.60'),
        focusWs(2),
      ]);
      expect(plan('master-right', horizontal), [rule(1, 'master', 'right'), removeMasters(3), layout('orientationright'), layout('mfact exact 0.50')]);
      expect(plan('master-right', [...three, win('0xa4', 1)], active: null),
          [rule(1, 'master', 'right'), removeMasters(4), layout('orientationright'), layout('mfact exact 0.50')]);
    });

    test('columns: 2 like side-by-side, 3 a centred master, 4 dwindle columns', () {
      final three = [win('0xa1', 1), win('0xa2', 1, at: [640, 0]), win('0xa3', 1, at: [1280, 0])];
      expect(plan('columns', vertical, cap: 3), [rule(1, 'master', 'center'), rule(1, 'dwindle'), toggle]);
      expect(plan('columns', three, cap: 3, split: 0.7), [
        rule(1, 'master', 'center'),
        rule(1, 'master', 'center'),
        removeMasters(4),
        layout('orientationcenter'),
        layout('mfact exact 0.60'), // Columns' middle column: at most 0.60
      ]);
      expect(plan('columns', three, cap: 3).last, layout('mfact exact 0.33'));
      expect(plan('columns', three, cap: 4).last, layout('orientationcenter')); // no split with a limit of 4
      expect(plan('columns', [win('0xa1', 1)], cap: 4), [rule(1, 'dwindle')]);
      final stacked = [
        win('0xa1', 1, size: [960, 540]),
        win('0xa2', 1, at: [0, 540], size: [960, 540]),
        win('0xa3', 1, at: [960, 0], size: [960, 540]),
        win('0xa4', 1, at: [960, 540], size: [960, 540]),
      ];
      expect(plan('columns', stacked, cap: 4), [rule(1, 'dwindle'), rule(1, 'dwindle'), toggleOf('0xa1'), toggleOf('0xa3')]);
      final tall = [for (var i = 0; i < 4; i++) win('0xb$i', 1, at: [480 * i, 0])];
      expect(plan('columns', tall, cap: 4), [rule(1, 'dwindle'), rule(1, 'dwindle'), 'pcall(function() $toggle end)']);
    });

    test('grid: dwindle', () {
      expect(plan('grid', horizontal, cap: 4), [rule(1, 'dwindle')]);
      final three = [win('0xa1', 1), win('0xa2', 1), win('0xa3', 1)];
      expect(plan('grid', three, cap: 4), [rule(1, 'dwindle'), rule(1, 'dwindle')]);
      expect(plan('grid', [...three, win('0xa4', 1)], cap: 4), [rule(1, 'dwindle'), rule(1, 'dwindle')]);
    });

    test('floating: tiled windows floated, tagged, centred and cascaded (Python rounding)', () {
      expect(floatingGeometry(monitor, 0), (1152, 735, 320, 124)); // 157.5 rounds to 158 (even)
      expect(plan('floating', horizontal), [
        'hl.dispatch(hl.dsp.window.float({window="address:0xa1", action="on"}))',
        'hl.dispatch(hl.dsp.window.tag({window="address:0xa1", tag="+maprisma-presets-floating"}))',
        'hl.dispatch(hl.dsp.window.resize({window="address:0xa1", x=1152, y=735, relative=false}))',
        'hl.dispatch(hl.dsp.window.move({window="address:0xa1", x=320, y=124, relative=false}))',
        'hl.dispatch(hl.dsp.window.float({window="address:0xa2", action="on"}))',
        'hl.dispatch(hl.dsp.window.tag({window="address:0xa2", tag="+maprisma-presets-floating"}))',
        'hl.dispatch(hl.dsp.window.resize({window="address:0xa2", x=1152, y=735, relative=false}))',
        'hl.dispatch(hl.dsp.window.move({window="address:0xa2", x=352, y=156, relative=false}))',
      ]);
      // a window floating already stays, and the next one cascades past it
      final mixed = plan('floating', [win('0xf0', 1, floating: true), win('0xa1', 1), win('0xa9', 2)]);
      expect(mixed.where((l) => l.contains('0xf0')), isEmpty);
      expect(mixed.where((l) => l.contains('0xa9')), isEmpty); // another workspace
      expect(mixed.last, 'hl.dispatch(hl.dsp.window.move({window="address:0xa1", x=352, y=156, relative=false}))');
      // no monitor known: floated and tagged only
      expect(planPreset(workspace: 1, preset: 'floating', clients: [win('0xa1', 1)], monitors: const []), hasLength(2));
    });

    test('no layout message for the windows there: the workspace is not focused for nothing', () {
      expect(plan('side-by-side', [win('0xa1', 1)], active: 2), [rule(1, 'dwindle')]);
      expect(plan('grid', horizontal, cap: 4, active: 2), [rule(1, 'dwindle')]);
      expect(plan('columns', [win('0xa1', 1)], cap: 4, active: 2), [rule(1, 'dwindle')]);
      // with something to do, focus goes there and back
      expect(plan('master-right', horizontal, active: 2),
          [rule(1, 'master', 'right'), focusWs(1), removeMasters(3), layout('orientationright'), layout('mfact exact 0.50'), focusWs(2)]);
    });

    test('floating geometry: a bad scale counts as 1, a bad size gives no geometry', () {
      final good = floatingGeometry(monitor, 0);
      for (final scale in [0, -1, -0.5, double.nan, double.infinity, double.negativeInfinity, 'x', null]) {
        expect(floatingGeometry({...monitor, 'scale': scale}, 0), good, reason: '$scale');
      }
      for (final size in [0, -1920, double.nan, double.infinity, '1920', null]) {
        expect(floatingGeometry({...monitor, 'width': size}, 0), isNull, reason: 'width $size');
        expect(floatingGeometry({...monitor, 'height': size}, 0), isNull, reason: 'height $size');
      }
      // reserved space bigger than the screen: nothing usable left
      expect(floatingGeometry({...monitor, 'reserved': [0, 2000, 0, 0]}, 0), isNull);
      expect(floatingGeometry({...monitor, 'reserved': [-50, double.nan, 0, 0]}, 0), floatingGeometry({...monitor, 'reserved': [0, 0, 0, 0]}, 0));
      expect(floatingGeometry({...monitor, 'x': double.nan, 'y': double.infinity}, 0), floatingGeometry({...monitor, 'x': 0, 'y': 0}, 0));
      // a monitor without a usable size: the windows are floated and tagged only
      final lines = planPreset(workspace: 1, preset: 'floating', clients: [win('0xa1', 1)], monitors: [{...monitor, 'width': double.nan}]);
      expect(lines, hasLength(2));
      for (final l in lines) {
        expect(l, isNot(contains('NaN')));
        expect(l, isNot(contains('Infinity')));
      }
    });

    test('leaving floating: only windows it floated are tiled again, and take part', () {
      final clients = [win('0xa1', 1), win('0xa2', 1, at: [100, 100], floating: true, tags: [hyprFloatTag]), win('0xa3', 1, floating: true)];
      const off = [
        'hl.dispatch(hl.dsp.window.float({window="address:0xa2", action="off"}))',
        'hl.dispatch(hl.dsp.window.tag({window="address:0xa2", tag="-maprisma-presets-floating"}))',
      ];
      expect(plan('side-by-side', clients), [...off, rule(1, 'dwindle'), rule(1, 'dwindle'), toggle, layout('splitratio 1.00 exact')]);
      expect(plan('scrolling', clients), [...off, rule(1, 'scrolling')]);
      expect(plan('none', clients), [...off, rule(1, 'dwindle')]);
    });

    test('only valid workspaces, presets and addresses; no text of a window ever enters the Lua', () {
      for (final ws in [0, 11, -1]) {
        expect(() => planPreset(workspace: ws, preset: 'grid', clients: const [], monitors: const []), throwsArgumentError);
      }
      expect(() => planPreset(workspace: 1, preset: 'tabs', clients: const [], monitors: const []), throwsArgumentError);
      final evil = {
        ...win('0x1"}) hl.exec("rm', 1),
        'title': '"); os.execute("x") --',
      };
      final long = win('0x${'1' * 17}', 1);
      final lines = plan('floating', [evil, long, win('0xa1', 1, size: [960, 540])]);
      expect(lines, hasLength(4)); // only 0xa1
      for (final presetName in presetNames) {
        for (final l in plan(presetName, [evil, long, win('0xa1', 1), win('0xa2', 1, at: [960, 0])], cap: 3, split: 0.42)) {
          expect(l, isNot(contains('exec')));
          expect(l, isNot(contains('11111111111111111')));
        }
      }
    });
  });

  group('addresses and events', () {
    test('addresses: 0x and 1–16 hex digits', () {
      expect(hyprAddress('0x55d0c0a8b0c0'), '0x55d0c0a8b0c0');
      expect(hyprAddress('55D0C0A8B0C0'), '0x55d0c0a8b0c0'); // socket2 sends them bare
      for (final bad in ['', '0x', '0xg1', '0x${'f' * 17}', '1 2', '0x1;', null, 12]) {
        expect(hyprAddress(bad), isNull, reason: '$bad');
      }
      expect(hyprAddressPattern.hasMatch('0x1234abcd'), isTrue);
    });

    test('socket2 lines as watch events', () {
      expect(parseHyprEvent('openwindow>>55d0c0a8b0c0,2,kitty,a, title'), {'event': 'window_new', 'id': '0x55d0c0a8b0c0', 'workspace': 2});
      expect(parseHyprEvent('openwindow>>abc,special:magic,kitty,t'), {'event': 'window_new', 'id': '0xabc', 'workspace': null});
      expect(parseHyprEvent('openwindow>>zz,1,kitty,t'), isNull);
      expect(parseHyprEvent('closewindow>>abc'), {'event': 'window_closed', 'id': '0xabc'});
      expect(parseHyprEvent('movewindowv2>>abc,4,4'), {'event': 'window_moved', 'id': '0xabc', 'workspace': 4});
      expect(parseHyprEvent('movewindowv2>>abc,-98,special:magic'), {'event': 'window_moved', 'id': '0xabc', 'workspace': null});
      expect(parseHyprEvent('workspacev2>>5,5'), {'event': 'workspace', 'index': 5});
      expect(parseHyprEvent('workspacev2>>-98,special:magic'), isNull);
      expect(parseHyprEvent('configreloaded>>'), {'event': 'config_reloaded'});
      for (final other in ['activewindow>>kitty,t', 'garbage', '>>x', '']) {
        expect(parseHyprEvent(other), isNull, reason: other);
      }
    });

    test('lines over 64 KiB are dropped whole; lines may come in pieces', () {
      final s = BoundedLineSplitter();
      expect(s.add(utf8.encode('workspacev2>>1,')), isEmpty);
      expect(s.add(utf8.encode('1\nclosewindow>>a')), ['workspacev2>>1,1']);
      expect(s.add(utf8.encode('b\n')), ['closewindow>>ab']);
      expect(s.add(List.filled(hyprEventLineMax + 1, 0x61)), isEmpty);
      expect(s.add(utf8.encode('still the long line\nconfigreloaded>>\n')), ['configreloaded>>']);
      final exact = 'x' * hyprEventLineMax;
      expect(s.add(utf8.encode('$exact\n')), [exact]);
    });

    test('watch: events from socket2, connected again with backoff 0.5 s … 10 s', () async {
      final sleeps = <Duration>[];
      final paths = <String>[];
      var attempt = 0;
      final first = StreamController<List<int>>(), second = StreamController<List<int>>();
      Future<Stream<List<int>>> connect(String path) async {
        paths.add(path);
        attempt++;
        if (attempt <= 6) throw const SocketException('not yet');
        if (attempt == 7) return first.stream;
        return second.stream;
      }

      final wm = HyprWm(
        environment: const {'XDG_RUNTIME_DIR': '/run/user/1000', 'HYPRLAND_INSTANCE_SIGNATURE': 'abc_123'},
        configHome: '/nowhere',
        connect: connect,
        sleep: (d) async => sleeps.add(d),
      );
      final events = <Map<String, dynamic>>[];
      final sub = wm.watch()!.listen(events.add);
      await pumpUntil(() => attempt == 7);
      first.add(utf8.encode('openwindow>>abc,2,kitty,t\nclosew'));
      first.add(utf8.encode('indow>>abc\n${'y' * (hyprEventLineMax + 5)}\nworkspacev2>>3,3\n'));
      await pumpUntil(() => events.length == 3);
      expect(events, [
        {'event': 'window_new', 'id': '0xabc', 'workspace': 2},
        {'event': 'window_closed', 'id': '0xabc'},
        {'event': 'workspace', 'index': 3},
      ]);
      await first.close();
      await pumpUntil(() => attempt == 8);
      second.add(utf8.encode('configreloaded>>\n'));
      await pumpUntil(() => events.length == 4);
      expect(events.last, {'event': 'config_reloaded'});
      expect(paths.toSet(), {'/run/user/1000/hypr/abc_123/.socket2.sock'});
      const ms = Duration(milliseconds: 1);
      expect(sleeps, [ms * 500, ms * 1000, ms * 2000, ms * 4000, ms * 8000, ms * 10000, ms * 500]); // reset once connected
      await sub.cancel();
      expect(HyprWm(environment: const {}, configHome: '/x').watch(), isNull);
      expect(HyprWm(environment: const {'XDG_RUNTIME_DIR': '/run', 'HYPRLAND_INSTANCE_SIGNATURE': '../x'}, configHome: '/x').watch(), isNull);
    });

    test('watch cancelled while connecting: the connection made meanwhile is closed', () async {
      final pending = Completer<Stream<List<int>>>();
      var cancelled = false;
      final arrived = StreamController<List<int>>(onCancel: () => cancelled = true);
      final wm = HyprWm(
        environment: const {'XDG_RUNTIME_DIR': '/run/user/1000', 'HYPRLAND_INSTANCE_SIGNATURE': 'abc'},
        configHome: '/nowhere',
        connect: (_) => pending.future,
        sleep: (_) async {},
      );
      final sub = wm.watch()!.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      pending.complete(arrived.stream);
      await pumpUntil(() => cancelled);
      expect(arrived.hasListener, isFalse);
    });

    test('watch cancelled while connecting to a real socket: the socket is destroyed', () async {
      final dir = Directory.systemTemp.createTempSync('maprisma-socket2-');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/hypr/sig').createSync(recursive: true);
      final server = await ServerSocket.bind(InternetAddress('${dir.path}/hypr/sig/.socket2.sock', type: InternetAddressType.unix), 0);
      addTearDown(server.close);
      final wm = HyprWm(
        environment: {'XDG_RUNTIME_DIR': dir.path, 'HYPRLAND_INSTANCE_SIGNATURE': 'sig'},
        configHome: '/nowhere',
        sleep: (_) async {},
      );
      final sub = wm.watch()!.listen((_) {});
      await sub.cancel(); // before the connect finishes
      final peer = await server.first.timeout(const Duration(seconds: 2));
      // the client side closes: the server sees the end of the stream
      await peer.drain<void>().timeout(const Duration(seconds: 2));
      peer.destroy();
    });
  });

  group('wm commands', () {
    late List<List<String>> calls;
    late Map<String, Object?> data;
    late Map<String, dynamic> state;
    HyprWm wm({String? configHome}) => HyprWm(
          environment: const {},
          configHome: configHome ?? '/nowhere',
          command: (a) async {
            calls.add(a);
            if (a.first == '-j') return jsonEncode(data[a[1]]);
            return a.first == 'eval' ? 'ok' : null;
          },
          state: () => state,
          sleep: (_) async {},
        );
    List<String> evals() => [for (final c in calls) if (c.first == 'eval') c[1]];

    setUp(() {
      calls = [];
      state = cleanWorkspaceState({
        'workspacePresets': {'1': 'grid', '2': 'master-left'},
        'workspaceSplits': {'1': 0.3},
      });
      data = {
        'workspaces': [
          {'id': 3, 'name': '3', 'monitor': 'DP-1', 'windows': 0},
          {'id': 1, 'name': '1', 'monitor': 'DP-1', 'windows': 2},
          {'id': -98, 'name': 'special:magic', 'monitor': 'DP-1', 'windows': 1},
          {'id': 2, 'name': '2\u0007', 'monitor': 'HDMI-A-1', 'windows': 2},
        ],
        'clients': [
          win('0xa1', 1),
          {...win('0xa2', 2), 'title': 'bell\u0007here', 'grouped': ['0xa2', '0xa3']},
          win('0xa3', 2, at: [960, 0]),
          win('0xa4', -98),
          win('0xnot', 1),
        ],
        'monitors': [monitor],
        'activeworkspace': {'id': 3},
      };
    });

    test('workspaces: real ones only, with preset, split and what is shown', () async {
      final r = await wm().wm(['workspaces']);
      expect(r!['can_tile'], isTrue);
      final list = r['workspaces'] as List;
      expect([for (final w in list) w['index']], [1, 2, 3]);
      expect(list[0], {
        'index': 1, 'name': '1', 'active': false, 'tiling': true, 'preset': 'grid', 'split': 0.3, 'output': 'DP-1', 'windows': 2,
      });
      expect(list[1]['name'], '2 ');
      expect(list[1]['preset'], 'master-left');
      expect(list[2]['active'], isTrue);
      expect(list[2]['preset'], 'side-by-side');
      expect(calls.every((c) => c.first == '-j'), isTrue);
    });

    test('windows: valid addresses on real workspaces, titles without control characters', () async {
      final list = (await wm().wm(['windows']))!['windows'] as List;
      expect([for (final w in list) w['id']], ['0xa1', '0xa2', '0xa3']);
      expect(list[1], {
        'id': '0xa2', 'app_id': 'kitty', 'title': 'bell here', 'workspace': 2, 'floating': false, 'at': [0, 0], 'size': [960, 1080],
        'grouped': true,
      });
    });

    test('move, close, activate: validated, fixed Lua; a move counts once Hyprland shows it', () async {
      expect(await wm().wm(['move', '0xa1', '1']), {'done': true});
      expect(evals(), ['hl.dispatch(hl.dsp.window.move({window="address:0xa1", workspace="1", follow=false}))']);
      expect((await wm().wm(['move', '0xa1', '5']))!['done'], isFalse); // not there afterwards
      calls.clear();
      await wm().wm(['close', '0xa2']);
      await wm().wm(['activate', '0xa3']);
      expect(evals(), ['hl.dispatch(hl.dsp.window.close({window="address:0xa2"}))', 'hl.dispatch(hl.dsp.focus({window="address:0xa3"}))']);
      calls.clear();
      for (final bad in [
        ['move', 'a1', '1'],
        ['move', '0xa1"', '1'],
        ['move', '0xa1', '0'],
        ['move', '0xa1', '101'],
        ['move', '0xa1', '1; x'],
        ['close', '0x'],
        ['activate', '0x${'a' * 17}'],
        ['set-preset', '11', 'grid'],
        ['set-preset', '1', 'tabs'],
        ['set-preset', '1', 'grid', 'half'],
        ['set-split', '1', 'nan'],
        ['set-tiling', '1', 'maybe'],
      ]) {
        final r = await wm().wm(bad);
        expect(r?['error'], isNotNull, reason: '$bad');
      }
      expect(evals(), isEmpty);
    });

    test('set-preset / set-split / set-tiling run the plan', () async {
      await wm().wm(['set-preset', '2', 'master-left', '0.9']);
      expect(evals(), [
        rule(2, 'master', 'left'), focusWs(2), removeMasters(3), layout('orientationleft'), layout('mfact exact 0.80'), focusWs(3),
      ]);
      calls.clear();
      await wm().wm(['set-split', '2', '0.4']); // the workspace's own preset
      expect(evals(), contains(layout('mfact exact 0.40')));
      calls.clear();
      await wm().wm(['set-tiling', '1', 'off']);
      expect(evals().first, 'hl.dispatch(hl.dsp.window.float({window="address:0xa1", action="on"}))');
      calls.clear();
      final r = await wm().wm(['set-tiling', '2', 'on']);
      expect(r!['preset'], 'side-by-side');
      expect(r['done'], isTrue);
    });

    test('apply-all / write-rules: maprisma-workspaces.lua and one line in hypr-user.lua', () async {
      final dir = Directory.systemTemp.createTempSync('maprisma-hyprwm-');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect((await wm(configHome: dir.path).wm(['write-rules']))!['done'], isFalse); // no hypr/ folder
      Directory('${dir.path}/hypr').createSync();
      File('${dir.path}/hypr/hypr-user.lua').writeAsStringSync('pcall(require, "hypr-theme")');
      expect((await wm(configHome: dir.path).wm(['apply-all']))!['done'], isTrue);
      expect(await wm(configHome: dir.path).wm(['write-rules']), {'done': true});
      final rules = File('${dir.path}/hypr/maprisma-workspaces.lua').readAsLinesSync();
      expect(rules.where((l) => !l.startsWith('--')), [rule(1, 'dwindle'), rule(2, 'master', 'left')]);
      final user = File('${dir.path}/hypr/hypr-user.lua').readAsStringSync();
      expect(user, startsWith('pcall(require, "hypr-theme")\n'));
      expect(RegExp(RegExp.escape(HyprWm.requireLine)).allMatches(user), hasLength(1));
    });

    test('write-rules never writes through a link and refuses a hypr-user.lua it cannot read', () async {
      final dir = Directory.systemTemp.createTempSync('maprisma-hyprwm-');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/hypr').createSync();
      final elsewhere = File('${dir.path}/elsewhere.txt')..writeAsStringSync('keep me');
      final rulesPath = '${dir.path}/hypr/maprisma-workspaces.lua', userPath = '${dir.path}/hypr/hypr-user.lua';
      // a planted link in place of the rules file
      Link(rulesPath).createSync(elsewhere.path);
      expect((await wm(configHome: dir.path).wm(['write-rules']))!['done'], isFalse);
      expect(elsewhere.readAsStringSync(), 'keep me');
      expect(FileSystemEntity.isLinkSync(rulesPath), isTrue);
      Link(rulesPath).deleteSync();
      // a link in place of hypr-user.lua
      Link(userPath).createSync(elsewhere.path);
      expect((await wm(configHome: dir.path).wm(['write-rules']))!['done'], isFalse);
      expect(elsewhere.readAsStringSync(), 'keep me');
      expect(FileSystemEntity.isLinkSync(userPath), isTrue);
      Link(userPath).deleteSync();
      // hypr-user.lua there but not readable as a small regular file (a folder here)
      Directory(userPath).createSync();
      expect((await wm(configHome: dir.path).wm(['write-rules']))!['done'], isFalse);
      Directory(userPath).deleteSync();
      // the rules file there already: replaced as a regular file, its mode kept
      File(rulesPath).writeAsStringSync('-- old\n');
      chmodPath(rulesPath, 416 /* 0640 */);
      expect((await wm(configHome: dir.path).wm(['write-rules']))!['done'], isTrue);
      expect(FileSystemEntity.typeSync(rulesPath, followLinks: false), FileSystemEntityType.file);
      expect(File(rulesPath).statSync().mode & 511, 416);
      expect(File(rulesPath).readAsStringSync(), contains(rule(1, 'dwindle')));
      expect(File(userPath).readAsStringSync(), contains(HyprWm.requireLine));
      expect(dir.listSync(recursive: true).where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('Columns after Floating: the retry loop counts the windows the plan tiles again', () async {
      state = cleanWorkspaceState({
        'workspaceCaps': {'1': 4},
        'workspacePresets': {'1': 'columns'},
      });
      data['clients'] = [
        for (var i = 0; i < 4; i++) win('0xc$i', 1, at: [100 * i, 100 * i], size: [960, 540], floating: true, tags: [hyprFloatTag]),
      ];
      await wm().wm(['set-preset', '1', 'columns']);
      // clients read once for the plan, then again by the retry loop
      expect(calls.where((c) => c.length == 2 && c[0] == '-j' && c[1] == 'clients'), hasLength(greaterThan(1)));
      expect(evals().last, focusWs(3)); // focus given back
    });
  });

  test('the rules file: one rule per workspace whose preset has a layout', () {
    final text = workspaceRulesLua(
      {1: 'master-left', 2: 'none', 3: 'floating', 4: 'columns', 5: 'columns', 6: 'scrolling', 7: 'grid', 8: 'stacked', 11: 'grid'},
      caps: {4: 3, 5: 4},
    );
    expect(text.split('\n').where((l) => l.isNotEmpty && !l.startsWith('--')), [
      rule(1, 'master', 'left'),
      rule(4, 'master', 'center'),
      rule(5, 'dwindle'),
      rule(6, 'scrolling'),
      rule(7, 'dwindle'),
      rule(8, 'dwindle'),
    ]);
  });

  test('Workspace Presets (Simple Tile) in an Omarchy bar: Maprisma Theme leaves the windows alone', () {
    final dir = Directory.systemTemp.createTempSync('maprisma-simple-tile-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final env = {'HOME': dir.path};
    final shell = File('${dir.path}/.config/omarchy/shell.json')..createSync(recursive: true);
    expect(simpleTileConflict(env), isFalse); // empty file
    void write(Object v) => shell.writeAsStringSync(jsonEncode(v));
    write({
      'bar': {
        'layout': {
          'left': [
            {'id': 'other'},
          ],
          'center': [
            {'id': 'ubruckhaus.simple-tile', 'maxWindows': 2},
          ],
        },
      },
    });
    expect(simpleTileConflict(env), isTrue);
    write({
      'bar': {
        'layout': {
          'right': [
            {'id': 'ubruckhaus.simple-tile', 'active': false},
          ],
        },
      },
    });
    expect(simpleTileConflict(env), isFalse); // paused
    write({'bar': 'odd'});
    expect(simpleTileConflict(env), isFalse);
    // XDG_CONFIG_HOME wins over HOME
    final xdg = Directory('${dir.path}/xdg/omarchy')..createSync(recursive: true);
    File('${xdg.path}/shell.json').writeAsStringSync(jsonEncode({
      'bar': {
        'layout': {
          'right': [
            {'id': 'ubruckhaus.simple-tile'},
          ],
        },
      },
    }));
    expect(simpleTileConflict({...env, 'XDG_CONFIG_HOME': '${dir.path}/xdg'}), isTrue);
    expect(simpleTileConflict(const {}), isFalse);
  });
}

/// Lets microtasks and zero timers run until [done] (at most 2 s).
Future<void> pumpUntil(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 2));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(Duration.zero);
  }
}
