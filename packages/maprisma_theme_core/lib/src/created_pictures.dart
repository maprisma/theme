import 'proposals.dart';
import 'i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'context.dart';
import 'images.dart';
import 'posix.dart';
import 'store.dart' show chmodPath, ensurePrivateCache;

/// Wallpapers made on this computer: Z-Image Turbo through stable-diffusion.cpp
/// (Vulkan), all in Maprisma Theme's own folder ($XDG_DATA_HOME/maprisma-theme/
/// generator), set up here and never needing another app:
///  * the program: GitHub's latest leejet/stable-diffusion.cpp release, its
///    Linux Vulkan zip, checked against the digest GitHub lists, unpacked only
///    after every entry was checked (plain names, no links, no folders, size);
///  * the models: three files from Hugging Face with their exact sizes and
///    SHA-256 sums written here.
/// Downloads go through curl (HTTPS only, also on redirects, resumable
/// `.part`, a size cap, stalled transfers end) and are kept only when the
/// checksum matches. One setup at a time (a lock file), cancellable.
///
/// Space: when Maprisma Playground already holds the same files complete
/// (its ~/.local/share/maprisma-playground), the models are hardlinked after
/// their sums were checked and its program folder is copied; otherwise, or
/// when that fails, they are downloaded. Nothing of Playground's is used later.
///
/// A picture is made by running our `sd-cli`, no shell, the prompt one
/// argument; the result is checked and kept in the cache.

/// Model files: Hugging Face repository, path there, size, SHA-256.
const generatorModels = <(String, String, int, String)>[
  ('leejet/Z-Image-Turbo-GGUF', 'z_image_turbo-Q8_0.gguf', 6577440704,
      'df1c5baa86d1398c979495a6072dbcee79444fdb884a2445582ba0769c44e9a1'),
  ('Comfy-Org/z_image_turbo', 'split_files/vae/ae.safetensors', 335304388,
      'afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38'),
  ('unsloth/Qwen3-4B-Instruct-2507-GGUF', 'Qwen3-4B-Instruct-2507-Q8_0.gguf', 4280405600,
      '391c1e410fd9f4cf2de2b510273b56a84c19ce18f4fa3bfb3774031dac4ef068'),
];

String _base(String path) => path.split('/').last;

/// Wallpaper size: 16:9 at 1920 wide (multiples of 64 for the model).
const createdWidth = 1920, createdHeight = 1088;
const maxPicturePrompt = 2000;
const maxCreatedCached = 60;
const createTimeout = Duration(minutes: 5);
const releaseApi = 'https://api.github.com/repos/leejet/stable-diffusion.cpp/releases/latest';
const maxReleaseBytes = 512 * 1024 * 1024, maxUnpacked = 1024 * 1024 * 1024;
final releaseTag = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final releaseAsset = RegExp(r'^sd-[A-Za-z0-9.-]+-bin-Linux-Ubuntu-[0-9.]+-x86_64-vulkan\.zip$');
final _sha = RegExp(r'^[0-9a-f]{64}$');
final _entryName = RegExp(r'^[A-Za-z0-9._+\-]{1,128}$');

/// The setup was cancelled.
final class SetupCancelled implements Exception {
  const SetupCancelled();
}

/// One HTTPS download as a byte stream from [from] bytes on (curl by default);
/// [cancel] ends it.
abstract class Downloader {
  Stream<List<int>> open(String url, {int from = 0, required int maxBytes});
  Future<String?> text(String url, {required int maxBytes});
  void cancel();
}

final class CurlDownloader implements Downloader {
  CurlDownloader(this.environment);
  final Map<String, String> environment;
  final _running = <Process>{};

  @override
  Stream<List<int>> open(String url, {int from = 0, required int maxBytes}) async* {
    final process = await Process.start('curl', [
      '-fsSL', '--proto', '=https', '--proto-redir', '=https', '--max-redirs', '5',
      '--max-filesize', '$maxBytes', '--speed-limit', '1024', '--speed-time', '120',
      // A whole deadline too: an hour plus the time the size needs at 256 KiB/s.
      '--max-time', '${3600 + maxBytes ~/ (256 * 1024)}',
      if (from > 0) ...['-C', '$from'],
      '--', url,
    ], environment: environment);
    _running.add(process);
    final err = <int>[];
    process.stderr.listen((c) {
      if (err.length < 4096) err.addAll(c);
    });
    try {
      yield* process.stdout;
      final code = await process.exitCode;
      if (code != 0) {
        throw StateError(trf("download failed: {0}", [_line(utf8.decode(err, allowMalformed: true), 300)]));
      }
    } finally {
      _running.remove(process);
    }
  }

  @override
  Future<String?> text(String url, {required int maxBytes}) async {
    final out = BytesBuilder(copy: false);
    try {
      await for (final c in open(url, maxBytes: maxBytes)) {
        out.add(c);
        if (out.length > maxBytes) return null;
      }
    } on StateError {
      return null;
    }
    return utf8.decode(out.takeBytes(), allowMalformed: true);
  }

  @override
  void cancel() {
    for (final p in [..._running]) {
      p.kill(ProcessSignal.sigterm);
    }
  }
}

String _line(String s, [int max = 200]) {
  final one = s.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  return one.length > max ? '${one.substring(0, max)}…' : one;
}

bool _plainFile(String path) => FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file;

Future<String> sha256Of(String path, {bool Function()? cancelled}) async {
  final sink = _DigestSink();
  final hash = sha256.startChunkedConversion(sink);
  await for (final c in File(path).openRead()) {
    if (cancelled?.call() ?? false) throw const SetupCancelled();
    hash.add(c);
  }
  hash.close();
  return sink.value.toString();
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Downloads [url] to [target] (kept only when [size] and [digest] match);
/// a `.part` left by an earlier try is continued.
Future<void> downloadChecked(
  Downloader dl,
  String url,
  String target,
  int size,
  String digest,
  void Function(double) progress, {
  bool Function()? cancelled,
}) async {
  if (!_sha.hasMatch(digest) || size <= 0) throw StateError(tr("no checksum: nothing is downloaded"));
  if (!url.startsWith('https://')) throw ArgumentError(tr("HTTPS required"));
  Directory(File(target).parent.path).createSync(recursive: true);
  final partPath = '$target.part';
  final type = FileSystemEntity.typeSync(partPath, followLinks: false);
  if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) {
    throw StateError(trf("{0} is not a plain file; remove it and try again", [_base(partPath)]));
  }
  final part = File(partPath).openSync(mode: FileMode.append);
  try {
    var have = part.lengthSync();
    if (have > size) {
      part.truncateSync(0);
      have = 0;
    }
    if (have < size) {
      await for (final chunk in dl.open(url, from: have, maxBytes: size)) {
        if (cancelled?.call() ?? false) throw const SetupCancelled();
        if (have + chunk.length > size) {
          throw StateError(trf("{0} is larger than announced", [_base(target)]));
        }
        part.writeFromSync(chunk);
        have += chunk.length;
        progress(have / size);
      }
    }
    if (cancelled?.call() ?? false) throw const SetupCancelled();
    if (have != size) throw StateError(trf("{0}: download incomplete", [_base(target)]));
    part.flushSync();
  } finally {
    part.closeSync();
  }
  final actual = await sha256Of(partPath, cancelled: cancelled);
  if (actual != digest) {
    File(partPath).deleteSync();
    throw StateError(trf("{0} does not match its checksum; it was not kept", [_base(target)]));
  }
  File(partPath).renameSync(target);
  chmodPath(target, 420);
  progress(1);
}

/// Unpacks the release zip into [folder]: every entry checked first (plain
/// names, no folders, no links, sizes), nothing written before.
void unpackRelease(String archivePath, String folder) {
  if (File(archivePath).lengthSync() > maxReleaseBytes) throw StateError(tr("the release is too large"));
  final archive = ZipDecoder().decodeBytes(File(archivePath).readAsBytesSync(), verify: true);
  var total = 0;
  final names = <String>{};
  for (final file in archive.files) {
    final name = file.name;
    final mode = file.mode;
    if (name.startsWith('.') || !_entryName.hasMatch(name) || !names.add(name) || !file.isFile) {
      throw StateError(trf("unexpected entry in the release: {0}", [_line(name, 80)]));
    }
    if (file.isSymbolicLink || mode & 0xf000 == 0xa000) throw StateError(trf("a link in the release: {0}", [name]));
    total += file.size;
    if (total > maxUnpacked) throw StateError(tr("the release unpacks too large"));
  }
  Directory(folder).createSync(recursive: true);
  for (final file in archive.files) {
    final out = File('$folder/${file.name}');
    out.createSync(exclusive: true);
    out.writeAsBytesSync(file.content as List<int>);
    chmodPath(out.path, const {'sd-cli', 'sd-server'}.contains(file.name) ? 493 : 420);
  }
}

final class CreatedPictures {
  CreatedPictures(this.ctx, {Downloader? downloader, String? playgroundData, this.models = generatorModels})
      : downloader = downloader ?? CurlDownloader(ctx.environment),
        _playgroundData = playgroundData;
  final Ctx ctx;
  final List<(String, String, int, String)> models;
  final Downloader downloader;
  final String? _playgroundData;

  static bool _settingUp = false;
  static Process? _making;
  static double setupFraction = 0;
  static String setupText = '', setupError = '';
  static bool _cancelSetup = false, _cancelled = false;

  Map<String, String> get env => ctx.environment;
  String get home => env['HOME'] ?? '/';
  String get _dataHome {
    final xdg = env['XDG_DATA_HOME'];
    return xdg != null && xdg.startsWith('/') ? xdg : '$home/.local/share';
  }

  /// Our own folder: everything the generator needs lives here.
  String get data => '$_dataHome/maprisma-theme/generator';
  String get playgroundData => _playgroundData ?? '$_dataHome/maprisma-playground';

  String get cacheDir => '${ctx.paths.cache}/created';

  String model((String, String, int, String) f, [String? root]) => '${root ?? data}/models/z-image-turbo/${_base(f.$2)}';

  /// Our sd-cli (the `sd/current` release), an own executable file.
  String? binaryIn(String root) {
    try {
      final tag = Link('$root/sd/current').targetSync();
      if (!releaseTag.hasMatch(tag) || tag == '.' || tag == '..') return null;
      final path = '$root/sd/$tag/sd-cli';
      return _plainFile(path) && File(path).statSync().mode & 0x49 != 0 ? path : null;
    } on Object {
      return null;
    }
  }

  String? get binary => binaryIn(data);

  bool _complete((String, String, int, String) f, String root) {
    final path = model(f, root);
    return _plainFile(path) && File(path).lengthSync() == f.$3;
  }

  List<(String, String, int, String)> get missing => [for (final f in models) if (!_complete(f, data)) f];

  Map<String, dynamic> status() => {
    'ready': binary != null && missing.isEmpty,
    'setting_up': _settingUp,
    'fraction': setupFraction,
    'text': setupText,
    'error': setupError,
    'download_bytes': missing.fold<int>(0, (n, f) {
      final part = File('${model(f)}.part');
      final have = _plainFile(part.path) ? part.lengthSync() : 0;
      return n + f.$3 - (have <= f.$3 ? have : 0);
    }),
    'busy': _making != null,
  };

  /// Starts the setup in the background; [status] reports progress.
  Map<String, dynamic> startSetup() {
    if (_settingUp) return status();
    _settingUp = true;
    setupFraction = 0;
    setupText = '';
    setupError = '';
    () async {
      try {
        await setup();
        reportAskAiOutcome('done');
      } on SetupCancelled {
        reportAskAiOutcome('cancelled');
        setupError = tr('Cancelled');
      } on Object catch (e) {
        reportAskAiOutcome(e is RouteError && e.code == 'ask_ai_blocked' ? 'blocked' : 'failed');
        setupError = _line('$e'.replaceFirst(RegExp(r'^(Bad state|Invalid argument\(s\)|FileSystemException): '), ''));
      } finally {
        _settingUp = false;
      }
    }();
    return status();
  }

  void cancelSetup() {
    if (!_settingUp) return;
    _cancelSetup = true;
    downloader.cancel();
  }

  bool _isCancelled() => _cancelSetup;

  void _progress(double f, String text) {
    setupFraction = f.clamp(0, 1).toDouble();
    setupText = text;
  }

  /// The whole setup (also used directly by tests): program, then models.
  Future<void> setup() async {
    _cancelSetup = false;
    checkAskAiBoundary();
    Directory(data).createSync(recursive: true);
    chmodPath(data, 448);
    final lockFile = File('$data/.setup.lock').openSync(mode: FileMode.write);
    try {
      try {
        lockFile.lockSync(FileLock.exclusive);
      } on FileSystemException {
        throw StateError(tr("it is being set up already"));
      }
      if (binary == null && !_copyPlaygroundProgram()) await _downloadProgram();
      if (_isCancelled()) throw const SetupCancelled();
      final todo = missing;
      final total = todo.fold<int>(0, (n, f) => n + f.$3);
      var done = 0;
      for (final f in todo) {
        if (await _linkFromPlayground(f, (x) => _progress((done + x * f.$3) / total, tr("(checking a copy found on this computer)")))) {
          done += f.$3;
          continue;
        }
        await downloadChecked(
          downloader,
          'https://huggingface.co/${f.$1}/resolve/main/${f.$2}',
          model(f),
          f.$3,
          f.$4,
          (x) {
            final fraction = (done + x * f.$3) / total;
            _progress(fraction, '(${(fraction * 100).round()} %)');
          },
          cancelled: _isCancelled,
        );
        done += f.$3;
      }
      _progress(1, '');
    } finally {
      lockFile.closeSync();
    }
  }

  Future<void> _downloadProgram() async {
    _progress(0, tr('(program)'));
    final raw = await downloader.text(releaseApi, maxBytes: 4000000);
    if (raw == null) throw StateError(tr("GitHub could not be reached"));
    Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      json = null;
    }
    final tag = json is Map ? json['tag_name'] : null;
    if (tag is! String || !releaseTag.hasMatch(tag) || tag == '.' || tag == '..') {
      throw StateError(tr("unexpected release list"));
    }
    Map? asset;
    for (final a in (json as Map)['assets'] is List ? json['assets'] as List : const []) {
      if (a is Map && a['name'] is String && releaseAsset.hasMatch(a['name'] as String)) {
        asset = a;
        break;
      }
    }
    if (asset == null) throw StateError(tr("the release has no Linux Vulkan build"));
    final digest = asset['digest'], url = asset['browser_download_url'], size = asset['size'];
    if (digest is! String ||
        !digest.startsWith('sha256:') ||
        !_sha.hasMatch(digest.substring(7)) ||
        url is! String ||
        !url.startsWith('https://github.com/') ||
        size is! int ||
        size <= 0 ||
        size > maxReleaseBytes) {
      throw StateError(tr("the release lists no checksum for its Linux build"));
    }
    final root = '$data/sd', archive = '$root/${asset['name']}';
    await downloadChecked(downloader, url, archive, size, digest.substring(7), (f) => _progress(f, tr('(program)')),
        cancelled: _isCancelled);
    final staging = Directory('$root/.$tag.partial');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    try {
      unpackRelease(archive, staging.path);
      _publishRelease(root, tag, staging);
    } finally {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      if (File(archive).existsSync()) File(archive).deleteSync();
    }
  }

  void _publishRelease(String root, String tag, Directory staging) {
    final dest = Directory('$root/$tag');
    if (dest.existsSync()) dest.deleteSync(recursive: true);
    staging.renameSync(dest.path);
    final fresh = Link('$root/.current.new');
    if (FileSystemEntity.typeSync(fresh.path, followLinks: false) != FileSystemEntityType.notFound) fresh.deleteSync();
    fresh.createSync(tag);
    fresh.renameSync('$root/current');
  }

  /// Maprisma Playground's program folder copied (plain files with plain names
  /// only), when it has one; false otherwise.
  bool _copyPlaygroundProgram() {
    try {
      final from = binaryIn(playgroundData);
      if (from == null) return false;
      final source = Directory(File(from).parent.path);
      final tag = _base(source.path);
      if (!releaseTag.hasMatch(tag)) return false;
      final entries = source.listSync(followLinks: false);
      var total = 0;
      for (final e in entries) {
        final name = _base(e.path);
        if (e is! File || !_plainFile(e.path) || name.startsWith('.') || !_entryName.hasMatch(name)) return false;
        total += e.lengthSync();
        if (total > maxUnpacked) return false;
      }
      _progress(0, tr('(program)'));
      final root = '$data/sd';
      final staging = Directory('$root/.$tag.partial');
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      staging.createSync(recursive: true);
      try {
        for (final e in entries.cast<File>()) {
          final name = _base(e.path);
          e.copySync('${staging.path}/$name');
          chmodPath('${staging.path}/$name', const {'sd-cli', 'sd-server'}.contains(name) ? 493 : 420);
        }
        _publishRelease(root, tag, staging);
      } finally {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      }
      return binary != null;
    } on Object {
      return false;
    }
  }

  /// A model Maprisma Playground already holds, complete and with the right
  /// sum, hardlinked here (same file system); false when there is none or the
  /// link fails (then it is downloaded).
  Future<bool> _linkFromPlayground((String, String, int, String) f, void Function(double) progress) async {
    final from = model(f, playgroundData), to = model(f);
    if (!_complete(f, playgroundData)) return false;
    if (await sha256Of(from, cancelled: _isCancelled) != f.$4) return false;
    progress(1);
    try {
      Directory(File(to).parent.path).createSync(recursive: true);
      final r = await Process.run('ln', ['--', from, to]);
      return r.exitCode == 0 && _complete(f, data);
    } on ProcessException {
      return false;
    }
  }

  /// One wallpaper from [prompt] with [seed]; its path in the cache.
  Future<String> make(String prompt, int seed) async {
    final exe = binary;
    if (exe == null || missing.isNotEmpty) throw RouteError('not_ready', tr("the picture generator is not set up"));
    if (_making != null) throw RouteError('busy', tr("another picture is being made"));
    final text = prompt.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
    if (text.isEmpty) throw RouteError('bad_params', 'prompt');
    final words = text.length > maxPicturePrompt ? text.substring(0, maxPicturePrompt) : text;
    checkAskAiBoundary();
    ensurePrivateCache(cacheDir, uid: Posix.instance.uid, ownerOf: Posix.instance.owner);
    final out = '$cacheDir/created-${DateTime.now().millisecondsSinceEpoch}-${seed & 0x7fffffff}.png';
    _cancelled = false;
    final argv = [
      '--diffusion-model', model(models[0]),
      '--vae', model(models[1]),
      '--llm', model(models[2]),
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
