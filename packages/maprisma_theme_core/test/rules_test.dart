import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_theme_core/src/rules.dart';
import 'package:maprisma_theme_core/src/proposals.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'support.dart';

void main() {
  late TestEnv e;
  setUp(() => e = TestEnv.create());
  tearDown(() => e.dispose());
  void rules(Object? value) {
    final f = File(e.paths.sharedAiSettings)
      ..parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({'helper': 'auto', 'ask_ai': value}));
  }

  List<Map> log() => File(
    askAiLogFile(e.paths),
  ).readAsLinesSync().map((s) => jsonDecode(s) as Map).toList();
  test('defaults and restrictive malformed values', () {
    expect(askAiAllowed(e.paths, 'theme.apply'), isTrue);
    for (final value in [
      null,
      [],
      false,
      {'level': null},
      {'level': 'typo'},
      {'actions': null},
      {'actions': []},
      {
        'actions': {'theme.apply': 'yes'},
      },
      {
        'actions': {'theme.apply': false},
      },
    ]) {
      rules(value);
      expect(askAiAllowed(e.paths, 'theme.apply'), isFalse, reason: '$value');
    }
    for (final value in [
      {'sources': []},
      {'folders': null},
      {
        'folders': {'downloads': false},
      },
    ]) {
      rules(value);
      expect(askAiAllowed(e.paths, 'theme.apply', source: 'local'), isFalse);
    }
    rules({});
    expect(askAiAllowed(e.paths, 'theme.apply'), isTrue);
    File(e.paths.sharedAiSettings).writeAsStringSync('{broken');
    expect(askAiAllowed(e.paths, 'theme.apply'), isFalse);
    File(e.paths.sharedAiSettings).writeAsStringSync(' ' * 65537);
    expect(askAiAllowed(e.paths, 'theme.apply'), isFalse);
  });
  test('helper writer preserves rules and refuses broken file', () {
    rules({
      'actions': {'theme.apply': false},
    });
    writeSharedHelper(e.paths.sharedAiSettings, 'claude');
    expect(askAiAllowed(e.paths, 'theme.apply'), isFalse);
    expect(
      File(
        '${File(e.paths.sharedAiSettings).parent.path}/settings.lock',
      ).existsSync(),
      isTrue,
    );
    File(e.paths.sharedAiSettings).writeAsStringSync('{broken');
    expect(
      () => writeSharedHelper(e.paths.sharedAiSettings, 'auto'),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(e.paths.sharedAiSettings).readAsStringSync(), '{broken');
  });
  test(
    'proposal binds target, action and source; unknown refuses; blocked logged',
    () async {
      e.addTheme('nord');
      e.addTheme('other');
      final id = e.core.ctx.proposals.issue({'theme.apply'}, 'nord');
      for (final p in [
        {'proposal': 'unknown', 'slug': 'nord'},
        {'proposal': id, 'slug': 'other'},
        {
          'proposal': e.core.ctx.proposals.issue({'theme.edit'}, 'nord'),
          'slug': 'nord',
        },
      ]) {
        await expectLater(
          e.core.call('themes.apply', p),
          throwsA(
            isA<RouteError>().having((x) => x.code, 'code', 'ask_ai_blocked'),
          ),
        );
      }
      expect(log().map((x) => x['result']), everyElement('blocked'));
      final install = e.core.ctx.proposals.issue(
        {'theme.install'},
        'nord',
        source: 'cosmic',
      );
      await expectLater(
        e.core.call('import.omarchy_install', {
          'proposal': install,
          'name': 'nord',
        }),
        throwsA(isA<RouteError>()),
      );
    },
  );
  test(
    'compound denied before first change, manual bypass and outcome records',
    () async {
      final id = e.core.ctx.proposals.issue(
        {'theme.install', 'theme.apply'},
        'nord',
        source: 'omarchy',
      );
      rules({
        'actions': {'theme.apply': false},
      });
      var changes = 0;
      Future<Map<String, dynamic>> handler(Map<String, dynamic> _) async {
        changes++;
        return {};
      }

      final p = {'proposal': id, 'name': 'nord', 'apply': true};
      await expectLater(
        e.core.ctx.proposals.execute(
          e.core.ctx,
          'import.omarchy_install',
          p,
          handler,
        ),
        throwsA(isA<RouteError>()),
      );
      expect(changes, 0);
      expect(
        log().map((x) => x['action']),
        containsAll(['theme.install', 'theme.apply']),
      );
      await e.core.ctx.proposals.execute(e.core.ctx, 'import.omarchy_install', {
        'name': 'nord',
        'apply': true,
      }, handler);
      expect(changes, 1);
      rules({});
      await e.core.ctx.proposals.execute(
        e.core.ctx,
        'import.omarchy_install',
        p,
        handler,
      );
      expect(log().last['result'], 'done');
      await expectLater(
        e.core.ctx.proposals.execute(
          e.core.ctx,
          'import.omarchy_install',
          p,
          (_) async => throw StateError('failure'),
        ),
        throwsStateError,
      );
      expect(log().last['result'], 'failed');
      expect(log().last['op'], id);
      await expectLater(
        e.core.ctx.proposals.execute(
          e.core.ctx,
          'import.omarchy_install',
          p,
          (_) async => throw RouteError('cancelled'),
        ),
        throwsA(isA<RouteError>()),
      );
      expect(log().last['result'], 'cancelled');
    },
  );
  test(
    'revocation after async preparation; manual request is isolated',
    () async {
      final id = e.core.ctx.proposals.issue({'theme.apply'}, 'nord');
      final ready = Completer<void>();
      var changes = 0;
      final running = e.core.ctx.proposals.execute(
        e.core.ctx,
        'themes.apply',
        {'proposal': id, 'slug': 'nord'},
        (_) async {
          await ready.future;
          checkAskAiBoundary();
          changes++;
          return {};
        },
      );
      rules({'level': 'answers'});
      checkAskAiBoundary();
      ready.complete();
      await expectLater(running, throwsA(isA<RouteError>()));
      expect(changes, 0);
      expect(log().last['result'], 'blocked');
    },
  );
  test(
    'every contract execution route refuses unknown proposals before preparing',
    () async {
      for (final route in [
        'themes.apply',
        'wallpapers.set',
        'custom.save',
        'import.omarchy_install',
        'import.cosmic_install',
        'import.kde_install',
        'create.make',
        'create.setup',
        'wallhaven.add',
        'webimg.add',
        'create.add',
      ]) {
        await expectLater(
          e.core.call(route, {'proposal': 'expired'}),
          throwsA(
            isA<RouteError>().having((x) => x.code, route, 'ask_ai_blocked'),
          ),
        );
      }
      expect(log(), hasLength(11));
    },
  );
  test(
    'proposal scope is issued from candidate and expires with core session',
    () async {
      final c = e.core.ctx.proposals.candidate({
        'kind': 'installed',
        'theme': 'nord',
      });
      final p = {'proposal': c['proposal'], 'slug': 'nord'};
      var changes = 0;
      Future<Map<String, dynamic>> handler(Map<String, dynamic> _) async {
        changes++;
        return {};
      }

      await e.core.ctx.proposals.execute(
        e.core.ctx,
        'themes.apply',
        p,
        handler,
      );
      e.core.dispose();
      await expectLater(
        e.core.ctx.proposals.execute(e.core.ctx, 'themes.apply', p, handler),
        throwsA(isA<RouteError>()),
      );
      expect(changes, 1);
    },
  );
  test(
    'generation binds its prompt and editor proposals allow user target edits',
    () async {
      final generation = e.core.ctx.proposals.candidate({
        'kind': 'installed',
        'theme': 'nord',
        'picture_prompt': 'forest',
      });
      var changes = 0;
      Future<Map<String, dynamic>> handler(Map<String, dynamic> _) async {
        changes++;
        return {};
      }

      await expectLater(
        e.core.ctx.proposals.execute(e.core.ctx, 'create.make', {
          'proposal': generation['proposal'],
          'prompt': 'different',
        }, handler),
        throwsA(isA<RouteError>()),
      );
      await e.core.ctx.proposals.execute(e.core.ctx, 'create.make', {
        'proposal': generation['proposal'],
        'prompt': 'forest',
      }, handler);
      final edit = e.core.ctx.proposals.candidate({
        'kind': 'custom',
        'theme': 'nord',
      });
      await e.core.ctx.proposals.execute(e.core.ctx, 'custom.save', {
        'proposal': edit['proposal'],
        'name': 'User name',
      }, handler);
      expect(changes, 2);
    },
  );
  test('current-theme custom save also requires apply', () async {
    e.core.ctx.current.save(slug: 'nord');
    rules({
      'actions': {'theme.apply': false},
    });
    final id = e.core.ctx.proposals.issue(
      {'theme.edit', 'theme.apply'},
      'nord',
      editable: true,
    );
    await expectLater(
      e.core.call('custom.save', {'proposal': id, 'edit': 'nord'}),
      throwsA(
        isA<RouteError>().having((x) => x.code, 'code', 'ask_ai_blocked'),
      ),
    );
  });
  test(
    'libc flock interoperates with another process for settings and log',
    () async {
      rules({});
      final worker = File('${e.root.path}/writer.dart')
        ..writeAsStringSync(r'''
import 'dart:io';
import 'package:maprisma_theme_core/src/shared_ai.dart';
import 'package:maprisma_theme_core/src/rules.dart';
import 'package:maprisma_theme_core/src/paths.dart';
void main(List<String> args) {
  final paths = Paths.fromEnvironment({'HOME': args[0]}, share: args[0]);
  if (args[1] == 'settings') { writeSharedHelper(paths.sharedAiSettings, 'claude'); }
  else { appendAskAiLog(paths, op: 'child', app: 'theme', action: 'theme.apply', target: 'nord', result: 'done'); }
}
''');
      for (final kind in ['settings', 'log']) {
        final lock = kind == 'settings'
            ? '${File(e.paths.sharedAiSettings).parent.path}/settings.lock'
            : askAiLogLock(e.paths);
        File(lock).parent.createSync(recursive: true);
        final holder = await Process.start('python3', [
          '-c',
          'import fcntl,sys; f=open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); print("locked", flush=True); sys.stdin.readline()',
          lock,
        ]);
        await holder.stdout.transform(utf8.decoder).first;
        final child = await Process.start(Platform.resolvedExecutable, [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          worker.path,
          e.paths.home,
          kind,
        ]);
        var finished = false;
        child.exitCode.then((_) => finished = true);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(
          finished,
          isFalse,
          reason: '$kind must wait for the shared flock',
        );
        if (kind == 'settings') {
          rules({
            'actions': {'theme.apply': false},
          });
        } else {
          // Simulate the lock holder dying mid-record while the next writer waits.
          File(askAiLogFile(e.paths)).writeAsStringSync('{"time":');
        }
        holder.stdin.writeln('release');
        await holder.stdin.flush();
        expect(await holder.exitCode, 0);
        expect(
          await child.exitCode,
          0,
          reason: await child.stderr.transform(utf8.decoder).join(),
        );
        if (kind == 'settings') {
          expect(askAiAllowed(e.paths, 'theme.apply'), isFalse);
        } else {
          expect(log(), hasLength(1));
          expect(log().last['op'], 'child');
        }
      }
    },
  );
  test('log append removes an unterminated tail and preserves complete records', () {
    final file = File(askAiLogFile(e.paths))
      ..parent.createSync(recursive: true);
    final complete = '${jsonEncode({'op': 'previous'})}\n';
    for (final prefix in ['', complete]) {
      for (final tail in ['{"time":', 'x' * 9000, '{"target":"é']) {
        file.writeAsStringSync('$prefix$tail');
        appendAskAiLog(
          e.paths,
          op: 'next',
          app: 'theme',
          action: 'theme.apply',
          target: 'nord',
          result: 'done',
        );
        expect(log().map((entry) => entry['op']).toList(), [
          if (prefix.isNotEmpty) 'previous',
          'next',
        ]);
        expect(file.readAsStringSync().startsWith(prefix), isTrue);
        expect(file.readAsStringSync().endsWith('\n'), isTrue);
      }
    }
  });
  test('log rotation, private modes, stable lock and symlink refusal', () {
    for (var i = 0; i < 1002; i++) {
      appendAskAiLog(
        e.paths,
        op: '$i',
        app: 'theme',
        action: 'theme.apply',
        target: 'nord',
        result: 'done',
      );
    }
    expect(log().length, 501);
    expect(log().last['op'], '1001');
    expect(FileStat.statSync(askAiLogFile(e.paths)).mode & 511, 384);
    expect(FileStat.statSync(askAiLogLock(e.paths)).mode & 511, 384);
    File(askAiLogFile(e.paths)).deleteSync();
    final victim = File('${e.root.path}/victim')
      ..writeAsStringSync('untouched');
    Link(askAiLogFile(e.paths)).createSync(victim.path);
    appendAskAiLog(
      e.paths,
      op: 'x',
      app: 'theme',
      action: 'theme.apply',
      target: 'nord',
      result: 'done',
    );
    expect(victim.readAsStringSync(), 'untouched');
  });
}
