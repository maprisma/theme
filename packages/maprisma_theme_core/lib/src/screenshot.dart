import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'posix.dart';

/// F12 (Maprisma Playground's screenshot.dart): a picture of Maprisma Theme's window goes to
/// `<pictures>/MaprismaTheme` (XDG_PICTURES_DIR from user-dirs.dirs, else ~/Pictures) or the
/// folder chosen in Settings, as `maprisma-theme-<date>-<time>.png`, never over an older picture
/// or note. An optional note goes next to it as a .txt of the same name. Only a real folder of
/// this account's that others cannot write to is used (0700 when it is made), checked on its
/// opened handle; files are made relative to that handle (0600, O_EXCL|O_NOFOLLOW), written
/// completely and synced, or removed again.

/// Characters of a note: a few sentences, not a document.
const screenshotNoteLimit = 4000;

final _libc = DynamicLibrary.open('libc.so.6');
final _open = _libc
    .lookupFunction<Int32 Function(Pointer<Utf8>, Int32, Uint32), int Function(Pointer<Utf8>, int, int)>('open');
final _openAt = _libc.lookupFunction<
  Int32 Function(Int32, Pointer<Utf8>, Int32, Uint32),
  int Function(int, Pointer<Utf8>, int, int)
>('openat');
final _unlinkAt = _libc
    .lookupFunction<Int32 Function(Int32, Pointer<Utf8>, Int32), int Function(int, Pointer<Utf8>, int)>('unlinkat');
final _mkdir = _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('mkdir');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _write = _libc
    .lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr), int Function(int, Pointer<Uint8>, int)>('write');
final _fsync = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
final _statx = _libc.lookupFunction<
  Int32 Function(Int32, Pointer<Utf8>, Int32, Uint32, Pointer<Uint8>),
  int Function(int, Pointer<Utf8>, int, int, Pointer<Uint8>)
>('statx');
final _errno = _libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno_location');
final _strerror = _libc.lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('strerror');

OSError _lastError() {
  final code = _errno().value;
  return OSError(_strerror(code).toDartString(), code);
}

Pointer<Utf8> _name(String text) {
  if (text.contains('\x00')) throw ArgumentError.value(text, 'path', 'contains NUL');
  return text.toNativeUtf8();
}

/// (uid, mode) of [name] relative to [fd] (AT_FDCWD = -100), never following a link; with an empty
/// name the descriptor itself (AT_EMPTY_PATH).
(int, int)? _identity(String name, {int fd = -100}) {
  final cName = _name(name), buffer = calloc<Uint8>(256);
  try {
    if (_statx(fd, cName, (name.isEmpty ? 0x1000 : 0) | 0x100, 0x7ff, buffer) != 0) return null;
    final b = ByteData.sublistView(buffer.asTypedList(256));
    return (b.getUint32(20, Endian.host), b.getUint16(28, Endian.host));
  } finally {
    calloc.free(cName);
    calloc.free(buffer);
  }
}

/// Tests only: a write of a new file fails after this many bytes (a full disk, an I/O error).
int? debugFailWriteAfter;

/// A folder of this account's that only it can open (0700 from the start); its parents are made
/// as usual. An existing folder is left as it is; a link or a file in its place is refused.
void makePrivateFolder(String path) {
  final there = FileSystemEntity.typeSync(path, followLinks: false);
  if (there == FileSystemEntityType.directory) return;
  if (there != FileSystemEntityType.notFound) {
    throw FileSystemException('mkdir', path, const OSError('File exists', 17));
  }
  Directory(p.dirname(path)).createSync(recursive: true);
  final cName = _name(path);
  try {
    if (_mkdir(cName, 0x1c0) != 0) {
      final error = _lastError(); // before any other call can change errno
      // Made meanwhile by someone else: fine when it is a real folder (checked again on open).
      if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.directory) {
        throw FileSystemException('mkdir', path, error);
      }
    }
  } finally {
    calloc.free(cName);
  }
}

/// A handle on a folder of this account's that only it may write to: made 0700 when missing; used
/// only when it is a real folder (O_NOFOLLOW|O_DIRECTORY, so no link), owned by this account and
/// not writable by group or others (checked on the opened handle). Files are made relative to the
/// handle, so the folder cannot be swapped between the check and the write.
final class PrivateFolder {
  PrivateFolder._(this.path, this._fd);

  factory PrivateFolder.open(String path) {
    makePrivateFolder(path);
    final cName = _name(path);
    int fd;
    try {
      fd = _open(cName, 0x10000 | 0x20000 | 0x80000, 0); // O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC
    } finally {
      calloc.free(cName);
    }
    if (fd < 0) throw FileSystemException('open', path, _lastError());
    final info = _identity('', fd: fd);
    if (info == null || info.$2 & 0xf000 != 0x4000 || info.$1 != Posix.instance.uid || info.$2 & 0x12 != 0) {
      _close(fd);
      throw FileSystemException('not a private folder of yours', path, const OSError('Permission denied', 13));
    }
    return PrivateFolder._(path, fd);
  }

  final String path;
  int _fd;

  static void _plain(String name) {
    if (name.isEmpty || name == '.' || name == '..' || name.contains('/')) {
      throw ArgumentError.value(name, 'name', 'not a plain file name');
    }
  }

  /// Something of that name is in the folder (also a link that points nowhere).
  bool taken(String name) {
    _plain(name);
    return _identity(name, fd: _fd) != null;
  }

  /// A new file of our own in the folder (0600, never through a link, never over an existing
  /// file), written completely (short writes continue; a write of 0 fails) and synced, or removed.
  void writeNew(String name, List<int> bytes) {
    _plain(name);
    final where = '$path/$name';
    final cName = _name(name);
    try {
      // O_WRONLY|O_NOFOLLOW|O_CLOEXEC|O_CREAT|O_EXCL
      final out = _openAt(_fd, cName, 1 | 0x20000 | 0x80000 | 0x40 | 0x80, 0x180);
      if (out < 0) throw FileSystemException('open', where, _lastError());
      final buffer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
      var ok = false;
      try {
        buffer.asTypedList(bytes.length).setAll(0, bytes);
        var offset = 0;
        while (offset < bytes.length) {
          final limit = debugFailWriteAfter;
          if (limit != null && offset >= limit) {
            throw FileSystemException('write', where, const OSError('No space left on device', 28));
          }
          final want = limit == null ? bytes.length - offset : (limit - offset).clamp(1, bytes.length - offset);
          final n = _write(out, buffer + offset, want);
          if (n <= 0) throw FileSystemException('write', where, n < 0 ? _lastError() : const OSError('Nothing written', 5));
          offset += n;
        }
        if (_fsync(out) != 0) throw FileSystemException('fsync', where, _lastError());
        ok = true;
      } finally {
        calloc.free(buffer);
        _close(out);
        if (!ok) _unlinkAt(_fd, cName, 0); // nothing half-written is left behind
      }
    } finally {
      calloc.free(cName);
    }
  }

  void close() {
    if (_fd >= 0) {
      _close(_fd);
      _fd = -1;
    }
  }
}

/// The pictures folder (XDG_PICTURES_DIR from user-dirs.dirs, read bounded and without following
/// a link; else ~/Pictures) with "MaprismaTheme" in it.
String screenshotFolder(Map<String, String> environment) {
  final home = environment['HOME'] ?? '/';
  final xdg = environment['XDG_CONFIG_HOME'];
  final config = xdg != null && p.isAbsolute(xdg) ? xdg : p.join(home, '.config');
  var pictures = p.join(home, 'Pictures');
  final bytes = Posix.instance.readRegular(p.join(config, 'user-dirs.dirs'), 64 * 1024, follow: false);
  if (bytes != null) {
    for (final line in const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true))) {
      final match = RegExp(r'^\s*XDG_PICTURES_DIR\s*=\s*"(.*)"\s*$').firstMatch(line);
      if (match == null) continue;
      final value = match[1]!.replaceFirst(RegExp(r'^\$HOME(?=/|$)'), home);
      // "$HOME/" alone means no pictures folder of its own; anything relative is not one either.
      if (p.isAbsolute(value) && p.normalize(value) != p.normalize(home)) pictures = p.normalize(value);
    }
  }
  return p.join(pictures, 'MaprismaTheme');
}

/// `<date>-<time>` of a screenshot's name: 2026-11-07-08-26-31.
String screenshotStamp(DateTime at) {
  String two(int n) => '$n'.padLeft(2, '0');
  return '${at.year.toString().padLeft(4, '0')}-${two(at.month)}-${two(at.day)}'
      '-${two(at.hour)}-${two(at.minute)}-${two(at.second)}';
}

/// `maprisma-theme-<stamp>.png`, or -2, -3 … when a picture or a note already has that name.
String freeScreenshotName(PrivateFolder folder, String stamp) {
  var name = 'maprisma-theme-$stamp.png';
  for (var n = 2; folder.taken(name) || folder.taken(p.setExtension(name, '.txt')); n++) {
    name = 'maprisma-theme-$stamp-$n.png';
  }
  return name;
}

/// The PNG into a new file of its own (0600) in the private folder; returns its path.
String saveScreenshot(String folder, List<int> png, {DateTime? at}) {
  final where = PrivateFolder.open(folder);
  try {
    final name = freeScreenshotName(where, screenshotStamp(at ?? DateTime.now()));
    where.writeNew(name, png);
    return p.join(folder, name);
  } finally {
    where.close();
  }
}

/// The note next to the picture (same name, .txt, at most [screenshotNoteLimit] characters);
/// no text, no file. The folder is checked again.
String? saveScreenshotNote(String picture, String text) {
  var note = text.trim();
  if (note.isEmpty) return null;
  if (note.length > screenshotNoteLimit) note = note.substring(0, screenshotNoteLimit);
  final where = PrivateFolder.open(p.dirname(picture));
  try {
    final name = p.setExtension(p.basename(picture), '.txt');
    where.writeNew(name, utf8.encode('$note\n'));
    return p.join(where.path, name);
  } finally {
    where.close();
  }
}

/// The path as the dialog says it: the home folder as ~.
String homeShort(String path, Map<String, String> environment) {
  final home = environment['HOME'];
  if (home == null || home.isEmpty || home == '/') return path;
  return path == home || path.startsWith('$home/') ? '~${path.substring(home.length)}' : path;
}
