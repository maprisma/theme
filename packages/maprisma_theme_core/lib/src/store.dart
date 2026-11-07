import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';

/// Small files read with a cap (settings, state, config).
const smallFileMax = 4 * 1024 * 1024;

/// The text of a regular file of at most [limit] bytes, or null.
String? readSmall(String path, {int limit = smallFileMax}) {
  try {
    final f = File(path);
    final stat = f.statSync();
    if (stat.type != FileSystemEntityType.file || stat.size > limit) return null;
    final raf = f.openSync();
    try {
      final bytes = raf.readSync(limit + 1);
      if (bytes.length > limit) return null;
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      raf.closeSync();
    }
  } on FileSystemException {
    return null;
  }
}

/// JSON from [path], or [fallback] when missing, too large or not JSON.
Object? readJson(String path, {Object? fallback}) {
  final text = readSmall(path);
  if (text == null) return fallback;
  try {
    return jsonDecode(text);
  } on FormatException {
    return fallback;
  }
}

Map<String, dynamic> readJsonMap(String path) {
  final v = readJson(path);
  return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
}

final _random = Random();

/// Writes [bytes] atomically (a temporary file in the same folder, then
/// rename), creating the folder (0700 for private files). [mode] is octal.
void writeAtomic(String path, List<int> bytes, {int mode = 384 /* 0600 */}) {
  // A dotfiles link stays a link: the file it points at is replaced.
  if (FileSystemEntity.isLinkSync(path)) {
    try {
      path = File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      // a dangling link: replaced by the file
    }
  }
  final file = File(path);
  final dir = file.parent;
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
    if (mode == 384) _chmod(dir.path, 448 /* 0700 */);
  }
  final tmp = File('${dir.path}/.${file.uri.pathSegments.last}.$pid.${_random.nextInt(1 << 32)}.tmp');
  try {
    tmp.writeAsBytesSync(bytes, flush: true);
    _chmod(tmp.path, mode);
    tmp.renameSync(path);
  } catch (_) {
    try {
      tmp.deleteSync();
    } on FileSystemException {
      // already gone
    }
    rethrow;
  }
}

void writeText(String path, String text, {int mode = 384}) => writeAtomic(path, utf8.encode(text), mode: mode);

void writeJson(String path, Object? value, {int mode = 384}) =>
    writeText(path, '${const JsonEncoder.withIndent('  ').convert(value)}\n', mode: mode);

final _libcChmod = DynamicLibrary.open('libc.so.6')
    .lookupFunction<Int Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('chmod');

/// chmod(2); false when it failed.
bool chmodPath(String path, int mode) {
  final p = path.toNativeUtf8();
  try {
    return _libcChmod(p, mode) == 0;
  } finally {
    malloc.free(p);
  }
}

void _chmod(String path, int mode) => chmodPath(path, mode);

/// A JSON object file with typed access, re-read on every [load].
final class JsonFile {
  JsonFile(this.path);
  final String path;
  Map<String, dynamic> load() => readJsonMap(path);
  void save(Map<String, dynamic> value) => writeJson(path, value);
  void update(void Function(Map<String, dynamic> data) change) {
    final data = load();
    change(data);
    save(data);
  }
}
