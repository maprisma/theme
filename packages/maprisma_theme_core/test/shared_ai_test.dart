import 'dart:convert';
import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory dir;
  late String file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('maprisma-theme-shared-ai-');
    file = p.join(dir.path, 'config/maprisma-ai/settings.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void put(String text) => File(file)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  test('the file sits in XDG_CONFIG_HOME (else ~/.config)/maprisma-ai', () {
    final home = p.join(dir.path, 'home');
    expect(Paths.fromEnvironment({'HOME': home}, share: dir.path).sharedAiSettings,
        '$home/.config/maprisma-ai/settings.json');
    expect(Paths.fromEnvironment({'HOME': home, 'XDG_CONFIG_HOME': '/x/cfg'}, share: dir.path).sharedAiSettings,
        '/x/cfg/maprisma-ai/settings.json');
    expect(Paths.fromEnvironment({'HOME': home, 'XDG_CONFIG_HOME': 'relative'}, share: dir.path).sharedAiSettings,
        '$home/.config/maprisma-ai/settings.json');
  });

  test('read: missing file is null; broken file or values are auto; ids pass', () {
    expect(readSharedHelper(file), isNull);
    for (final (text, want) in [
      ('not json', 'auto'),
      ('[1,2]', 'auto'),
      ('{}', 'auto'),
      ('{"helper": 7}', 'auto'),
      ('{"helper": ""}', 'auto'),
      ('{"helper": "-rf"}', 'auto'),
      ('{"helper": "has space"}', 'auto'),
      ('{"helper": "${'a' * 162}"}', 'auto'),
      ('{"helper": "auto"}', 'auto'),
      ('{"helper": "claude"}', 'claude'),
      ('{"helper": "pi:ollama/qwen3:8b"}', 'pi:ollama/qwen3:8b'),
      ('{"helper": "x@y+z.1-2_3"}', 'x@y+z.1-2_3'),
      ('{"helper": "${'a' * 161}"}', 'a' * 161),
    ]) {
      put(text);
      expect(readSharedHelper(file), want, reason: text);
    }
  });

  test('migration: the old own choice counts only while the shared file is absent', () {
    expect(effectiveSharedHelper(file, 'codex'), 'codex');
    expect(effectiveSharedHelper(file, null), 'auto');
    expect(effectiveSharedHelper(file, 'bad id!'), 'auto');
    expect(File(file).existsSync(), isFalse, reason: 'reading never writes the shared file');
    put('{"helper": "auto"}');
    expect(effectiveSharedHelper(file, 'codex'), 'auto');
    put('{"helper": "nope nope"}');
    expect(effectiveSharedHelper(file, 'codex'), 'auto', reason: 'a present file wins, even broken');
  });

  test('write: atomic, private, keeps unknown keys, refuses bad values', () {
    writeSharedHelper(file, 'gemini');
    expect(jsonDecode(File(file).readAsStringSync()), {'helper': 'gemini'});
    expect(File(file).statSync().mode & 511, 384);
    expect(Directory(p.dirname(file)).statSync().mode & 511, 448);
    put('{"helper": "x", "model": {"a": 1}, "other": [1]}');
    Process.runSync('chmod', ['755', p.dirname(file)]);
    writeSharedHelper(file, 'auto');
    expect(jsonDecode(File(file).readAsStringSync()), {'helper': 'auto', 'model': {'a': 1}, 'other': [1]});
    expect(Directory(p.dirname(file)).statSync().mode & 511, 448);
    expect(Directory(p.dirname(file)).listSync().map((e) => p.basename(e.path)), unorderedEquals(['settings.json', 'settings.lock']),
        reason: 'no temporary file left');
    for (final bad in ['', 'a b', '-x', '../x', 'a' * 162]) {
      expect(() => writeSharedHelper(file, bad), throwsArgumentError, reason: bad);
    }
    expect(readSharedHelper(file), 'auto');
  });

  test('resolve: a ready choice, else the first ready one, else none', () {
    expect(resolveSharedHelper('auto', ['a', 'b']), 'a');
    expect(resolveSharedHelper('b', ['a', 'b']), 'b');
    expect(resolveSharedHelper('gone', ['a', 'b']), 'a');
    expect(resolveSharedHelper('auto', []), isNull);
    expect(resolveSharedHelper('b', []), isNull);
  });

  group('routes', () {
    late TestEnv env;
    late String shared;
    setUp(() {
      env = TestEnv.create();
      shared = env.paths.sharedAiSettings;
      expect(shared, startsWith(env.root.path), reason: 'never the real config');
      for (final c in ['copilot', 'cursor-agent']) {
        final f = File('${env.paths.home}/.local/bin/$c')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('#!/bin/sh\n');
        Process.runSync('chmod', ['755', f.path]);
      }
    });
    tearDown(() => env.dispose());

    Future<List<String>> readyIds() async {
      final h = await env.core.call('ask.helpers');
      return [for (final x in (h['helpers'] as List).cast<Map>()) if (x['signed_in'] == true) x['id'] as String];
    }

    test('ask.helpers follows the shared file, falls back to the first ready one', () async {
      final ready = await readyIds();
      expect(ready, containsAll(['cursor-agent', 'copilot']));
      var h = await env.core.call('ask.helpers');
      expect((h['choice'], h['chosen']), ('auto', ready.first));

      await env.core.call('settings.set', {'key': 'ask_ai_helper', 'value': 'copilot'});
      h = await env.core.call('ask.helpers');
      expect((h['choice'], h['chosen']), ('copilot', 'copilot'), reason: 'old own choice while no shared file');
      expect(File(shared).existsSync(), isFalse);

      File(shared)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"helper": "cursor-agent"}');
      h = await env.core.call('ask.helpers');
      expect((h['choice'], h['chosen']), ('cursor-agent', 'cursor-agent'), reason: 'read again on every call');

      File(shared).writeAsStringSync('{"helper": "grok"}');
      h = await env.core.call('ask.helpers');
      expect((h['choice'], h['chosen']), ('grok', ready.first), reason: 'not installed: auto');

      File(shared).writeAsStringSync('{"helper": "auto"}');
      h = await env.core.call('ask.helpers');
      expect((h['choice'], h['chosen']), ('auto', ready.first));
    });

    test('ask.choose writes the shared file (keeping its other keys), not the own settings', () async {
      File(shared)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{"helper": "auto", "manager": true}');
      await env.core.call('ask.choose', {'helper': 'copilot'});
      expect(jsonDecode(File(shared).readAsStringSync()), {'helper': 'copilot', 'manager': true});
      expect((await env.core.call('ask.helpers'))['chosen'], 'copilot');
      expect(env.core.ctx.settings.get('ask_ai_helper'), isNull);
      await env.core.call('ask.choose', {'helper': 'auto'});
      expect(jsonDecode(File(shared).readAsStringSync())['helper'], 'auto');
      await expectLater(env.core.call('ask.choose', {'helper': 'bad id'}), throwsA(anything));
      await expectLater(env.core.call('ask.choose', {}), throwsA(anything));
      expect(jsonDecode(File(shared).readAsStringSync())['helper'], 'auto');
    });
  });
}
