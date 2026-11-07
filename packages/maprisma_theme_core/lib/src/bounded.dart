import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// launcher_core.read_bounded_output: a command's stdout, at most [maxBytes],
/// within [timeout]; null when it fails, runs too long or says too much.
/// An empty [okCodes] accepts any exit code (pacman -Qo counts its misses).
/// Stderr is discarded; the process is killed when a bound is hit.
Future<Uint8List?> readBoundedBytes(
  List<String> command, {
  int maxBytes = 64 * 1024,
  Duration timeout = const Duration(seconds: 1),
  Set<int> okCodes = const {0},
  Map<String, String>? environment,
}) async {
  Process process;
  try {
    process = await Process.start(
      command.first,
      command.sublist(1),
      environment: environment,
      includeParentEnvironment: environment == null,
    );
  } on ProcessException {
    return null;
  }
  process.stdin.close().ignore();
  final err = process.stderr.drain<void>();
  final out = BytesBuilder(copy: false);
  var tooMuch = false;
  final done = Completer<void>();
  late StreamSubscription<List<int>> sub;
  sub = process.stdout.listen(
    (chunk) {
      if (out.length + chunk.length > maxBytes) {
        tooMuch = true;
        process.kill(ProcessSignal.sigkill);
        sub.cancel();
        if (!done.isCompleted) done.complete();
        return;
      }
      out.add(chunk);
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
    onError: (_) {
      if (!done.isCompleted) done.complete();
    },
  );
  try {
    await done.future.timeout(timeout);
    final code = await process.exitCode.timeout(timeout);
    await err.timeout(timeout, onTimeout: () {});
    if (tooMuch || !(okCodes.contains(code) || okCodes.isEmpty)) return null;
    return out.takeBytes();
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await sub.cancel();
    return null;
  }
}

Future<String?> readBoundedText(
  List<String> command, {
  int maxBytes = 64 * 1024,
  Duration timeout = const Duration(seconds: 1),
  Set<int> okCodes = const {0},
  Map<String, String>? environment,
}) async {
  final bytes = await readBoundedBytes(
    command,
    maxBytes: maxBytes,
    timeout: timeout,
    okCodes: okCodes,
    environment: environment,
  );
  return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
}

/// updates.run_bounded: (exit code, stdout + stderr) under one byte cap and
/// one deadline; the code is null when the command could not start, ran
/// too long or said too much (then it is killed).
Future<(int?, String)> runBounded(
  List<String> command, {
  int maxBytes = 64 * 1024,
  Duration timeout = const Duration(seconds: 1),
  Map<String, String>? environment,
}) async {
  Process process;
  try {
    process = await Process.start(
      command.first,
      command.sublist(1),
      environment: environment,
      includeParentEnvironment: environment == null,
    );
  } on ProcessException {
    return (null, '');
  }
  process.stdin.close().ignore();
  final out = BytesBuilder(copy: false);
  var tooMuch = false;
  void take(List<int> chunk) {
    if (tooMuch) return;
    if (out.length + chunk.length > maxBytes) {
      tooMuch = true;
      process.kill(ProcessSignal.sigkill);
      return;
    }
    out.add(chunk);
  }

  final streams = [process.stdout.listen(take).asFuture<void>(), process.stderr.listen(take).asFuture<void>()];
  try {
    final code = await process.exitCode.timeout(timeout);
    await Future.wait(streams).timeout(timeout, onTimeout: () => const []);
    return (tooMuch ? null : code, utf8.decode(out.takeBytes(), allowMalformed: true));
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    return (null, utf8.decode(out.takeBytes(), allowMalformed: true));
  }
}
