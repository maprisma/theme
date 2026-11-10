import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:maprisma_theme_core/src/created_pictures.dart';
import 'package:maprisma_theme_core/src/theme_ai.dart';
import 'package:test/test.dart';

import 'support.dart';

final _png = Uint8List.fromList(tinyPng)..[36] = 0x0A;
String _sum(List<int> b) => sha256.convert(b).toString();

/// Serves [files] by URL (from an offset), in small chunks; never the network.
final class FakeDownloader implements Downloader {
  FakeDownloader(this.files, {this.hold});
  final Map<String, List<int>> files;
  final calls = <String>[];

  /// While set, a download waits on it before its first byte (to cancel during it).
  Completer<void>? hold;
  bool cancelled = false;

  @override
  Stream<List<int>> open(String url, {int from = 0, required int maxBytes}) async* {
    calls.add('$url@$from');
    final h = hold;
    if (h != null) await h.future;
    if (cancelled) throw StateError('download failed: cancelled');
    final data = files[url];
    if (data == null) throw StateError('download failed: 404');
    for (var i = from; i < data.length; i += 7) {
      yield data.sublist(i, i + 7 > data.length ? data.length : i + 7);
    }
  }

  @override
  Future<String?> text(String url, {required int maxBytes}) async {
    calls.add(url);
    final d = files[url];
    return d == null ? null : utf8.decode(d);
  }

  @override
  void cancel() {
    cancelled = true;
    hold?.complete();
    hold = null;
  }
}

List<int> _zip(Map<String, List<int>> entries, {Map<String, int> modes = const {}}) {
  final a = Archive();
  for (final e in entries.entries) {
    final f = ArchiveFile.bytes(e.key, e.value);
    if (modes[e.key] != null) f.mode = modes[e.key]!;
    a.addFile(f);
  }
  return ZipEncoder().encodeBytes(a);
}

String _sdCli(String picture) =>
    '#!/bin/sh\nwhile [ \$# -gt 0 ]; do [ "\$1" = -o ] && cp "$picture" "\$2"; [ "\$1" = -p ] && printf %s "\$2" > "\$(dirname "\$0")/last-prompt"; shift; done\n';

void main() {
  test('the picture prompt only when the answer asks to create', () {
    expect(verifyPicturePrompt({'create': true, 'picture_prompt': 'A misty fjord at dawn, soft blue light'}),
        'A misty fjord at dawn, soft blue light');
    expect(verifyPicturePrompt({'create': false, 'picture_prompt': 'x y z'}), isNull);
    expect(verifyPicturePrompt({'create': true, 'picture_prompt': 42}), isNull);
    expect(verifyPicturePrompt({'create': true, 'picture_prompt': 'a' * 5000})!.length, lessThanOrEqualTo(maxPicturePromptChars + 1));
  });

  test('the wallpaper prompt: count, pictures already shown, create', () {
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

  group('downloads', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('maprisma-dl-'));
    tearDown(() => dir.deleteSync(recursive: true));
    final data = List<int>.generate(100, (i) => i);

    test('kept only with the right sum; a wrong one leaves nothing', () async {
      final dl = FakeDownloader({'https://x.example.com/f': data});
      final ok = '${dir.path}/ok.bin', bad = '${dir.path}/bad.bin';
      await downloadChecked(dl, 'https://x.example.com/f', ok, 100, _sum(data), (_) {});
      expect(File(ok).readAsBytesSync(), data);
      await expectLater(downloadChecked(dl, 'https://x.example.com/f', bad, 100, _sum([1]), (_) {}),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('checksum'))));
      expect(File(bad).existsSync(), isFalse);
      expect(File('$bad.part').existsSync(), isFalse);
      await expectLater(downloadChecked(dl, 'http://x.example.com/f', bad, 100, _sum(data), (_) {}), throwsArgumentError);
    });

    test('larger than announced stops; a .part is resumed from where it ended', () async {
      final dl = FakeDownloader({'https://x.example.com/f': data});
      await expectLater(downloadChecked(dl, 'https://x.example.com/f', '${dir.path}/small', 50, _sum(data.sublist(0, 50)), (_) {}),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('larger'))));
      final target = '${dir.path}/resumed';
      File('$target.part').writeAsBytesSync(data.sublist(0, 40));
      await downloadChecked(dl, 'https://x.example.com/f', target, 100, _sum(data), (_) {});
      expect(dl.calls.last, 'https://x.example.com/f@40');
      expect(File(target).readAsBytesSync(), data);
    });

    test('the release: links, folders and odd names are refused before anything is written', () {
      void check(List<int> zip, Matcher m) {
        final z = '${dir.path}/r.zip', out = '${dir.path}/out';
        File(z).writeAsBytesSync(zip);
        if (Directory(out).existsSync()) Directory(out).deleteSync(recursive: true);
        expect(() => unpackRelease(z, out), m);
      }

      check(_zip({'sd-cli': [1, 2], 'libx.so': [3]}), returnsNormally);
      expect(File('${dir.path}/out/sd-cli').statSync().mode & 0x49, isNot(0));
      check(_zip({'sd-cli': [1], 'evil': [1]}, modes: {'evil': 0xa1ff}), throwsStateError);
      check(_zip({'../x': [1]}), throwsStateError);
      check(_zip({'bin/sd-cli': [1]}), throwsStateError);
      check(_zip({'.hidden': [1]}), throwsStateError);
      expect(Directory('${dir.path}/out').existsSync(), isFalse, reason: 'nothing written when one entry is bad');
    });
  });

  group('generator', () {
    late TestEnv env;
    late String gen, pg, picture;
    late List<(String, String, int, String)> models;
    late FakeDownloader dl;
    setUp(() {
      env = TestEnv.create();
      gen = '${env.root.path}/home/.local/share/maprisma-theme/generator';
      pg = '${env.root.path}/home/.local/share/maprisma-playground';
      picture = '${env.root.path}/pic.png';
      File(picture).writeAsBytesSync(_png);
      final blobs = [for (var i = 0; i < 3; i++) List<int>.generate(30 + i, (j) => j * (i + 1) % 256)];
      models = [for (var i = 0; i < 3; i++) ('r/m$i', 'path/m$i.bin', blobs[i].length, _sum(blobs[i]))];
      final cli = utf8.encode(_sdCli(picture));
      final zip = _zip({'sd-cli': cli, 'libstable-diffusion.so': [0]}, modes: {'sd-cli': 0x81ed});
      dl = FakeDownloader({
        releaseApi: utf8.encode(jsonEncode({
          'tag_name': 'master-1',
          'assets': [
            {
              'name': 'sd-master-1-bin-Linux-Ubuntu-24.04-x86_64-vulkan.zip',
              'digest': 'sha256:${_sum(zip)}',
              'browser_download_url': 'https://github.com/leejet/stable-diffusion.cpp/releases/download/master-1/sd.zip',
              'size': zip.length,
            },
          ],
        })),
        'https://github.com/leejet/stable-diffusion.cpp/releases/download/master-1/sd.zip': zip,
        for (var i = 0; i < 3; i++) 'https://huggingface.co/r/m$i/resolve/main/path/m$i.bin': blobs[i],
      });
    });
    tearDown(() => env.dispose());

    CreatedPictures gp() => CreatedPictures(env.core.ctx, downloader: dl, models: models, playgroundData: pg);

    test('set up from the web into its own folder, then a picture is made', () async {
      expect(gp().status()['ready'], isFalse);
      expect(gp().status()['download_bytes'], models.fold<int>(0, (n, m) => n + m.$3));
      await gp().setup();
      expect(gp().status()['ready'], isTrue);
      expect(gp().binary, '$gen/sd/master-1/sd-cli');
      expect(dl.calls.where((c) => c.contains('huggingface')), hasLength(3));
      final made = await gp().make('a misty fjord\nat dawn', 7);
      expect(File(made).readAsBytesSync(), _png);
      expect(File('$gen/sd/master-1/last-prompt').readAsStringSync(), 'a misty fjord at dawn');
    });

    test('a complete copy of Maprisma Playground is reused: models hardlinked, program copied, no download', () async {
      Directory('$pg/sd/master-0').createSync(recursive: true);
      Link('$pg/sd/current').createSync('master-0');
      File('$pg/sd/master-0/sd-cli').writeAsStringSync(_sdCli(picture));
      Process.runSync('chmod', ['755', '$pg/sd/master-0/sd-cli']);
      Directory('$pg/models/z-image-turbo').createSync(recursive: true);
      for (final m in models) {
        File('$pg/models/z-image-turbo/${m.$2.split('/').last}').writeAsBytesSync(dl.files['https://huggingface.co/${m.$1}/resolve/main/${m.$2}']!);
      }
      await gp().setup();
      expect(dl.calls, isEmpty);
      expect(gp().binary, '$gen/sd/master-0/sd-cli');
      String inode(String p) => (Process.runSync('stat', ['-c', '%i', p]).stdout as String).trim();
      for (final m in models) {
        final name = m.$2.split('/').last;
        expect(inode('$gen/models/z-image-turbo/$name'), inode('$pg/models/z-image-turbo/$name'), reason: 'hardlinked');
      }
      // Playground removed afterwards: ours still works.
      Directory(pg).deleteSync(recursive: true);
      expect(gp().status()['ready'], isTrue);
      expect(File(await gp().make('fjord', 1)).existsSync(), isTrue);
    });

    test('a copy with a wrong sum is not reused but downloaded', () async {
      Directory('$pg/models/z-image-turbo').createSync(recursive: true);
      final m = models.first;
      File('$pg/models/z-image-turbo/${m.$2.split('/').last}').writeAsBytesSync(List.filled(m.$3, 9));
      await gp().setup();
      expect(dl.calls.where((c) => c.contains('huggingface')), hasLength(3));
    });

    test('Cancel stops the setup; a later setup goes on', () async {
      dl.hold = Completer<void>();
      final c = gp();
      c.startSetup();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.status()['setting_up'], isTrue);
      c.cancelSetup();
      for (var i = 0; i < 50 && c.status()['setting_up'] == true; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(c.status()['setting_up'], isFalse);
      expect(c.status()['ready'], isFalse);
      expect(c.status()['error'], isNotEmpty);
      dl.cancelled = false;
      await gp().setup();
      expect(gp().status()['ready'], isTrue);
    });

    test('routes: not ready, add only from its own cache', () async {
      env.addTheme('nord', wallpapers: const []);
      await expectLater(env.core.call('create.make', {'prompt': 'fjord'}), throwsA(isA<RouteError>().having((e) => e.code, 'code', 'not_ready')));
      await expectLater(env.core.call('create.add', {'slug': 'nord', 'path': picture}), throwsA(isA<RouteError>()));
      await expectLater(env.core.call('create.add', {'slug': 'nord', 'path': '/etc/passwd'}), throwsA(isA<RouteError>()));
      expect((await env.core.call('create.status')).containsKey('playground'), isFalse);
    });
  });
}
