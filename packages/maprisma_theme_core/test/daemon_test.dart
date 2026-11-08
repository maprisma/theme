import 'dart:collection';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'support.dart';

import 'package:maprisma_theme_core/src/daemon.dart';
import 'package:maprisma_theme_core/src/shortcuts_kde.dart';
import 'package:test/test.dart';

void main() {
  test('native window limits skip even already queued overflow jobs', () async {
    final env = TestEnv.create();
    addTearDown(env.dispose);
    env.desktop.enforcesWindowLimits = true;
    final bus = DBusClient(DBusAddress('unix:path=${env.root.path}/unused-bus'));
    addTearDown(bus.close);
    final daemon = Daemon(env.core, bus);
    await daemon.run(OverflowJob('new', 1));
    expect(env.desktop.calls, isEmpty);
  });

  group('window limits (the applet rule)', () {
    final t = TilingRules.fromJson({'active': true, 'default_limit': 2, 'limits': {'3': 1}});
    SplayTreeMap<int, int> c(Map<int, int> m) => SplayTreeMap.of(m);

    test('limits are 1..4, default 2', () {
      expect(t.limit(1), 2);
      expect(t.limit(3), 1);
      expect(TilingRules.fromJson({'active': true, 'default_limit': 9}).limit(1), 4);
      expect(TilingRules.fromJson({'active': true, 'default_limit': 0}).limit(1), 1);
      expect(TilingRules.fromJson(null).active, isFalse);
    });

    test('a full workspace sends the new window forward, wrapping once', () {
      expect(overflowTarget(1, c({1: 2, 2: 0}), t), isNull); // at the limit: stays
      expect(overflowTarget(1, c({1: 3, 2: 0}), t), 2);
      expect(overflowTarget(2, c({1: 0, 2: 3, 3: 1}), t), 1); // 3 is full (limit 1): wraps to 1
      expect(overflowTarget(1, c({1: 3, 2: 2, 3: 1}), t), isNull); // no room anywhere
      expect(overflowTarget(1, c({1: 5}), TilingRules()), isNull); // not active
    });
  });

  group('queue and events', () {
    test('a newer workspace switch or tick replaces the waiting one; at most 64', () {
      final q = JobQueue();
      q.add(CoreJob('auto.workspace', {'workspace': 1}));
      q.add(CoreJob('auto.tick'));
      q.add(CoreJob('auto.workspace', {'workspace': 2}));
      expect([for (final j in q.jobs) (j as CoreJob).params['workspace']], [null, 2]);
      for (var i = 0; i < 100; i++) {
        q.add(CoreJob('themes.apply', {'slug': '$i'}));
      }
      expect(q.jobs.length, 64);
    });

    test('a new window waits for its first workspace; moved by hand it stays', () {
      final r = EventRouter(), q = JobQueue();
      List<Job> route(Map<String, dynamic> e) => r.route(e, workspaceEvents: true, tilingActive: true, queue: q);
      expect(route({'event': 'workspace', 'index': 3}).single, isA<CoreJob>());
      expect(route({'event': 'window_new', 'id': 'a', 'workspace': null}), isEmpty);
      final j = route({'event': 'window_moved', 'id': 'a', 'workspace': 2}).single as OverflowJob;
      expect((j.id, j.workspace), ('a', 2));
      expect(route({'event': 'window_moved', 'id': 'a', 'workspace': 4}), isEmpty); // only the first
      q.add(OverflowJob('b', 1));
      route({'event': 'window_moved', 'id': 'b', 'workspace': 2});
      expect(q.jobs, isEmpty);
      expect(r.route({'event': 'workspace', 'index': 1}, workspaceEvents: false, tilingActive: true), isEmpty);
      expect(r.route({'event': 'window_new', 'id': 'c', 'workspace': 1}, workspaceEvents: true, tilingActive: false), isEmpty);
    });

    test('autostart is claimed once per session', () {
      final dir = Directory.systemTemp.createTempSync('maprisma-run-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final env = {'XDG_RUNTIME_DIR': dir.path, 'XDG_SESSION_ID': '7'};
      expect(claimAutostart(env), isTrue);
      expect(claimAutostart(env), isFalse);
      expect(claimAutostart({'XDG_RUNTIME_DIR': dir.path, 'XDG_SESSION_ID': '8'}), isTrue);
      expect(claimAutostart(const {}), isFalse);
    });
  });

  group('KDE keys', () {
    test('combos as Qt key codes and back from kglobalshortcutsrc', () {
      expect(qtCombo({'mods': ['SUPER', 'CTRL'], 'key': 'T'}), 0x10000000 | 0x04000000 | 0x54);
      expect(qtCombo({'mods': ['SUPER'], 'key': 'F5'}), 0x10000000 | 0x01000034);
      expect(qtCombo({'mods': ['ALT'], 'key': 'bracketleft'}), 0x08000000 | 0x5b);
      expect(parseQtKey('Meta+Ctrl+T'), {'mods': ['SUPER', 'CTRL'], 'key': 'T'});
      expect(parseQtKey('Ctrl+PgUp'), {'mods': ['CTRL'], 'key': 'Page_Up'});
      expect(parseQtKey('none'), isNull);
      expect(kdeKeyId({'mods': ['CTRL', 'SUPER'], 'key': 'T'}), kdeKeyId({'mods': ['SUPER', 'CTRL'], 'key': 't'}));
    });

    test('take and give back touch only the one borrowed sequence', () {
      final a = [0x10000031, 0, 0, 0], b = [0x10000032, 0, 0, 0], chord = [0x04000041, 0x04000042, 0, 0];
      // an action with A, B and a two-stroke chord: taking A keeps B and the chord whole
      expect(withoutSeq([a, b, chord], a), [b, chord]);
      // giving A back while B is still taken does not bring B back
      expect(withSeq([chord], a), [chord, a]);
      expect(withSeq([a, chord], a), [a, chord]); // already there: unchanged
      expect(withoutSeq([[0x10000031]], a), isEmpty); // short and padded forms are the same
    });

    test('owners: every component and service, ours left out', () {
      final owners = kdeKeyOwners('[kwin]\n_k_friendly_name=KWin\nSwitch to Desktop 1=Meta+1\\tCtrl+F1,Ctrl+F1,Switch to Desktop 1\n'
          'Window Close=none,Alt+F4,Close Window\n\n[services][org.kde.konsole.desktop]\n_launch=Ctrl+Alt+T\n\n'
          '[services][maprisma-theme-key-open.desktop]\n_launch=Meta+Ctrl+B\n');
      expect(owners[kdeKeyId({'mods': ['SUPER'], 'key': '1'})], ('kwin', 'Switch to Desktop 1', 'Switch to Desktop 1'));
      expect(owners[kdeKeyId({'mods': ['CTRL'], 'key': 'F1'})]?.$1, 'kwin');
      expect(owners[kdeKeyId({'mods': ['CTRL', 'ALT'], 'key': 'T'})]?.$1, 'org.kde.konsole.desktop');
      expect(owners[kdeKeyId({'mods': ['SUPER', 'CTRL'], 'key': 'B'})], isNull);
      expect(owners[kdeKeyId({'mods': ['ALT'], 'key': 'F4'})], isNull); // set to none
    });
  });
}
