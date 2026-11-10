import 'i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'context.dart';
import 'images.dart';
import 'posix.dart';

/// Wallpapers made on this computer with Maprisma Playground's picture
/// generator (Z-Image Turbo through stable-diffusion.cpp, Vulkan): one copy
/// for both apps. Its files are Playground's (~/.local/share/maprisma-playground);
/// setting it up goes through Playground's own core (`maprisma-playground-core
/// call generate.setup`, checksummed downloads), so nothing is downloaded here.
/// A picture is made by running Playground's `sd-cli` directly, no shell, the
/// prompt one argument; the result is checked and kept in the cache.

/// Playground's model files (its picture_gen.dart modelFiles): name, size.
const playgroundModelFiles = <(String, int)>[
  ('z_image_turbo-Q8_0.gguf', 6577440704),
  ('ae.safetensors', 335304388),
  ('Qwen3-4B-Instruct-2507-Q8_0.gguf', 4280405600),
];

/// Wallpaper size: 16:9 at 1920 wide (multiples of 64 for the model).
const createdWidth = 1920, createdHeight = 1088;
const maxPicturePrompt = 2000;
const maxCreatedCached = 60;
const createTimeout = Duration(minutes: 5);
final _tagRe = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

final class CreatedPictures {
  CreatedPictures(this.ctx);
  final Ctx ctx;

  Process? _setup, _making;
  double setupFraction = 0;
  String setupText = '', setupError = '';
  bool _cancelled = false;

  Map<String, String> get env => ctx.environment;
  String get home => env['HOME'] ?? '/';
  String get data {
    final xdg = env['XDG_DATA_HOME'];
    return '${xdg != null && xdg.startsWith('/') ? xdg : '$home/.local/share'}/maprisma-playground';
  }

  String get cacheDir => '${ctx.paths.cache}/created';

  String model(String name) => '$data/models/z-image-turbo/$name';

  /// Playground's sd-cli (its `sd/current` release), an own executable file.
  String? get binary {
    try {
      final tag = Link('$data/sd/current').targetSync();
      if (!_tagRe.hasMatch(tag) || tag == '.' || tag == '..') return null;
      final path = '$data/sd/$tag/sd-cli';
      final stat = File(path).statSync();
      return FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file && stat.mode & 0x49 != 0
          ? path
          : null;
    } on Object {
      return null;
    }
  }

  bool get modelsReady => playgroundModelFiles.every((f) {
    final file = File(model(f.$1));
    return FileSystemEntity.typeSync(file.path, followLinks: false) == FileSystemEntityType.file && file.lengthSync() == f.$2;
  });

  String? get playgroundCore => which('maprisma-playground-core', env);

  Map<String, dynamic> status() => {
    'ready': binary != null && modelsReady,
    'playground': playgroundCore != null,
    'setting_up': _setup != null,
    'fraction': setupFraction,
    'text': setupText,
    'error': setupError,
    'download_bytes': playgroundModelFiles.fold<int>(0, (n, f) {
      final file = File(model(f.$1));
      return n + (file.existsSync() && file.lengthSync() == f.$2 ? 0 : f.$2);
    }),
    'busy': _making != null,
  };

  /// Starts Playground's setup in the background; [status] reports progress.
  Map<String, dynamic> startSetup() {
    if (_setup != null) return status();
    final core = playgroundCore;
    if (core == null) throw RouteError('not_available', tr("Maprisma Playground is not installed"));
    setupFraction = 0;
    setupText = '';
    setupError = '';
    () async {
      try {
        final process = _setup = await Process.start(core, ['call', 'generate.setup', '{}'], environment: env);
        process.stderr.drain<void>().ignore();
        await for (final line in process.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
          Object? msg;
          try {
            msg = jsonDecode(line);
          } on FormatException {
            continue;
          }
          if (msg is! Map) continue;
          final d = msg['data'];
          if (msg['event'] == 'progress' && d is Map) {
            if (d['fraction'] is num) setupFraction = (d['fraction'] as num).toDouble().clamp(0, 1);
            if (d['text'] is String) setupText = _line(d['text'] as String);
          } else if (msg['error'] is Map) {
            setupError = _line('${(msg['error'] as Map)['message'] ?? (msg['error'] as Map)['code'] ?? ''}');
          }
        }
        final code = await process.exitCode;
        if (code != 0 && setupError.isEmpty) setupError = trf("the setup stopped (exit {0})", [code]);
      } on Object catch (e) {
        setupError = _line('$e');
      } finally {
        _setup = null;
      }
    }();
    return status();
  }

  void cancelSetup() => _setup?.kill(ProcessSignal.sigterm);

  static String _line(String s) {
    final one = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
    return one.length > 200 ? '${one.substring(0, 200)}…' : one;
  }

  /// One wallpaper from [prompt] with [seed]; its path in the cache.
  Future<String> make(String prompt, int seed) async {
    final exe = binary;
    if (exe == null || !modelsReady) throw RouteError('not_ready', tr("the picture generator is not set up"));
    if (_making != null) throw RouteError('busy', tr("another picture is being made"));
    final text = prompt.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
    if (text.isEmpty) throw RouteError('bad_params', 'prompt');
    final words = text.length > maxPicturePrompt ? text.substring(0, maxPicturePrompt) : text;
    Directory(cacheDir).createSync(recursive: true);
    final out = '$cacheDir/created-${DateTime.now().millisecondsSinceEpoch}-${seed & 0x7fffffff}.png';
    _cancelled = false;
    final argv = [
      '--diffusion-model', model(playgroundModelFiles[0].$1),
      '--vae', model(playgroundModelFiles[1].$1),
      '--llm', model(playgroundModelFiles[2].$1),
      '--cfg-scale', '1.0', '--steps', '8',
      '-W', '$createdWidth', '-H', '$createdHeight',
      '-s', '${seed & 0x7fffffff}',
      '--offload-to-cpu', '--flash-attn', 'off,diffusion=on',
      '-o', out, '-p', words,
    ];
    try {
      final process = _making = await Process.start(exe, argv, environment: env, workingDirectory: cacheDir);
      process.stdout.drain<void>().ignore();
      final err = <int>[];
      process.stderr.listen((c) {
        err.addAll(c);
        if (err.length > 8192) err.removeRange(0, err.length - 8192);
      });
      final code = await process.exitCode.timeout(createTimeout, onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      });
      if (_cancelled) throw RouteError('cancelled', tr('Cancelled'));
      if (code != 0) {
        final tail = utf8.decode(err, allowMalformed: true).trim().split('\n').lastOrNull ?? '';
        throw RouteError('failed', code == -1 ? tr("the picture took too long") : _line(tail.isEmpty ? 'exit $code' : tail));
      }
    } on ProcessException catch (e) {
      throw RouteError('failed', _line(e.message));
    } finally {
      _making = null;
    }
    final problem = imageSizeProblem(out);
    if (problem != null) {
      try {
        File(out).deleteSync();
      } on FileSystemException {
        // gone already
      }
      throw RouteError('bad_image', problem);
    }
    _prune();
    return out;
  }

  void cancel() {
    if (_making == null) return;
    _cancelled = true;
    _making!.kill(ProcessSignal.sigterm);
  }

  void _prune() {
    try {
      final files = Directory(cacheDir).listSync(followLinks: false).whereType<File>().map((f) => (f, f.statSync().modified)).toList()
        ..sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < files.length - maxCreatedCached; i++) {
        files[i].$1.deleteSync();
      }
    } on FileSystemException {
      // best effort
    }
  }
}
