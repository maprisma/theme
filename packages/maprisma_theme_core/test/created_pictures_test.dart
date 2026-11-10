import 'dart:io';
import 'dart:typed_data';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/created_pictures.dart';
import 'package:maprisma_theme_core/src/theme_ai.dart';
import 'package:test/test.dart';

import 'support.dart';

final _png = Uint8List.fromList(tinyPng)..[36] = 0x0A;

/// Playground's files under the test HOME: sparse model files of the right
/// size and an sd-cli script that copies [picture] to its -o argument.
void fakePlayground(TestEnv env, {required String picture, bool models = true}) {
  final data = '${env.root.path}/home/.local/share/maprisma-playground';
  Directory('$data/sd/v1').createSync(recursive: true);
  Link('$data/sd/current').createSync('v1');
  File('$data/sd/v1/sd-cli').writeAsStringSync('#!/bin/sh\nwhile [ \$# -gt 0 ]; do [ "\$1" = -o ] && cp "$picture" "\$2"; '
        '[ "\$1" = -p ] && printf %s "\$2" > "$data/last-prompt"; shift; done\n');
  Process.runSync('chmod', ['755', '$data/sd/v1/sd-cli']);
  if (!models) return;
  Directory('$data/models/z-image-turbo').createSync(recursive: true);
  for (final (name, size) in playgroundModelFiles) {
    final f = File('$data/models/z-image-turbo/$name').openSync(mode: FileMode.write);
    f.truncateSync(size);
    f.closeSync();
  }
}

void main() {
  test('the picture prompt only when the answer asks to create', () {
    expect(verifyPicturePrompt({'create': true, 'picture_prompt': 'A misty fjord at dawn, soft blue light'}),
        'A misty fjord at dawn, soft blue light');
    expect(verifyPicturePrompt({'create': false, 'picture_prompt': 'x y z'}), isNull);
    expect(verifyPicturePrompt({'create': true, 'picture_prompt': 42}), isNull);
    expect(verifyPicturePrompt({'create': true, 'picture_prompt': 'a' * 5000})!.length, lessThanOrEqualTo(maxPicturePromptChars + 1));
  });

  test('the wallpaper prompt: count, pictures already shown, create only when possible', () {
    final nord = ThemeFacts(slug: 'nord', name: 'Nord', colors: completeColors({'background': '#2e3440', 'foreground': '#d8dee9', 'accent': '#81a1c1'}));
    final p = buildWallpaperPrompt('paint me a fjord', nord, web: true, count: 5, seen: ['https://a.example.com/1.jpg'], canCreate: true);
    expect(p, allOf(contains('up to 5 fitting'), contains('https://a.example.com/1.jpg'), contains('"create"'), contains('picture_prompt')));
    expect(buildWallpaperPrompt('fjord', nord), isNot(contains('picture_prompt')));
  });

  test('wallpaper_count is 5, 10 or 20', () async {
    final env = TestEnv.create();
    addTearDown(env.dispose);
    await env.core.call('settings.set', {'key': 'wallpaper_count', 'value': 20});
    await expectLater(env.core.call('settings.set', {'key': 'wallpaper_count', 'value': 7}), throwsA(isA<RouteError>()));
  });

  group('generator', () {
    test('not set up without Playground files; made and added with them', () async {
      final env = TestEnv.create();
      addTearDown(env.dispose);
      env.addTheme('nord', wallpapers: const []);
      expect((await env.core.call('create.status'))['ready'], isFalse);
      await expectLater(env.core.call('create.make', {'prompt': 'fjord'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_ready')));

      final picture = '${env.root.path}/pic.png';
      File(picture).writeAsBytesSync(_png);
      fakePlayground(env, picture: picture);
      final status = await env.core.call('create.status');
      expect(status['ready'], isTrue);
      expect(status['download_bytes'], 0);
      final made = await env.core.call('create.make', {'prompt': 'a misty fjord\nat dawn', 'seed': 7});
      expect(made['seed'], 7);
      expect(File(made['path'] as String).readAsBytesSync(), _png);
      expect(File('${env.root.path}/home/.local/share/maprisma-playground/last-prompt').readAsStringSync(), 'a misty fjord at dawn');

      final added = await env.core.call('create.add', {'slug': 'nord', 'path': made['path']});
      expect(File(added['path'] as String).existsSync(), isTrue);
      for (final bad in [picture, '${made['path']}/../../x.png', '/etc/passwd']) {
        await expectLater(env.core.call('create.add', {'slug': 'nord', 'path': bad}), throwsA(isA<RouteError>()), reason: bad);
      }
    });

    test('missing models count as download; setup needs Playground', () async {
      final env = TestEnv.create();
      addTearDown(env.dispose);
      fakePlayground(env, picture: '/nonexistent', models: false);
      final s = await env.core.call('create.status');
      expect(s['ready'], isFalse);
      expect(s['download_bytes'], playgroundModelFiles.fold<int>(0, (n, f) => n + f.$2));
      expect(s['playground'], isFalse); // the test PATH has no maprisma-playground-core
      await expectLater(env.core.call('create.setup'), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_available')));
    });
  });
}
