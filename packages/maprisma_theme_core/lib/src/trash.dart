import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'posix.dart';
import 'store.dart';

/// The freedesktop.org trash (theme_core.py): deleted wallpapers and themes
/// go to `~/.local/share/Trash/` (`files/` plus a `.trashinfo` in `info/`,
/// claimed exclusively, 0600), so Undo, or later the file manager, brings
/// them back.

final class TrashReceipt {
  TrashReceipt(this.original, this.trashed, this.info);

  /// Where the file or folder was, where it is now, and its .trashinfo.
  final String original, trashed, info;
}

final class TrashException implements Exception {
  TrashException(this.message);
  final String message;
  @override
  String toString() => message;
}

final _unsafeNameChars = RegExp(r'''[\x00-\x1f\x7f<>"'|:*?\\/]''');

/// A safe file name from untrusted input: one element, no control
/// characters, no path separators ("image" when nothing is left).
String sanitizeName(String name) {
  var n = name.substring(name.lastIndexOf('/') + 1);
  if (n.isEmpty || n == '.' || n == '..') n = 'image';
  n = n.replaceAll(_unsafeNameChars, '_').trim();
  n = n.replaceAll(RegExp(r'^\.+|\.+$'), '');
  return n.isEmpty ? 'image' : n;
}

String _privateDir(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
    chmodPath(path, 448 /* 0700 */);
  }
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type != FileSystemEntityType.directory || Posix.instance.ownerOf(path, follow: false) != Posix.instance.uid) {
    throw TrashException('$path is not a private trash directory');
  }
  return path;
}

/// Python's urllib.parse.quote: everything but unreserved characters and `/`.
String _quote(String path) {
  final out = StringBuffer();
  for (final b in utf8.encode(path)) {
    final c = String.fromCharCode(b);
    if (RegExp(r'[A-Za-z0-9_.\-~/]').hasMatch(c)) {
      out.write(c);
    } else {
      out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

String _two(int n) => n.toString().padLeft(2, '0');

bool _exists(String path) => FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

/// Moves [target] (a file, or a folder as a whole) into [trash]: the
/// .trashinfo is claimed first (O_EXCL), then the item is renamed next to it.
/// Throws a [FileSystemException] with errno 18 (EXDEV) when the trash is on
/// another filesystem; nothing is moved then.
TrashReceipt moveToTrash(String trash, String target, {DateTime? now}) {
  final files = _privateDir('$trash/files');
  final infoDir = _privateDir('$trash/info');
  final original = File(target).absolute.path;
  final isDir = FileSystemEntity.typeSync(original, followLinks: false) == FileSystemEntityType.directory;
  final base = sanitizeName(original.substring(original.lastIndexOf('/') + 1));
  final dot = base.indexOf('.');
  final (stem, ext) = (isDir || dot < 0) ? (base, '') : (base.substring(0, dot), base.substring(dot));
  final t = now ?? DateTime.now();
  final date = '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  for (var n = 1; n < 1000; n++) {
    final name = n == 1 ? base : '$stem.$n$ext';
    final info = '$infoDir/$name.trashinfo';
    final dest = '$files/$name';
    if (_exists(info)) continue;
    final text = '[Trash Info]\nPath=${_quote(original)}\nDeletionDate=$date\n';
    if (!Posix.instance.writeNewPrivate(info, utf8.encode(text))) {
      if (_exists(info)) continue;
      throw TrashException('Could not write to the trash');
    }
    if (_exists(dest)) {
      _remove(info);
      continue;
    }
    try {
      if (isDir) {
        Directory(original).renameSync(dest);
      } else {
        File(original).renameSync(dest);
      }
    } catch (_) {
      _remove(info);
      rethrow;
    }
    return TrashReceipt(original, dest, info);
  }
  throw TrashException('The trash has too many items with this name');
}

/// Undo [moveToTrash]: the item goes back where it was, if that place is still free.
String restoreFromTrash(TrashReceipt r) {
  final name = r.original.substring(r.original.lastIndexOf('/') + 1);
  if (_exists(r.original)) throw TrashException('$name exists again; restore it from the trash by hand');
  if (!_exists(r.trashed)) throw TrashException('$name is no longer in the trash');
  Directory(File(r.original).parent.path).createSync(recursive: true);
  if (FileSystemEntity.typeSync(r.trashed, followLinks: false) == FileSystemEntityType.directory) {
    Directory(r.trashed).renameSync(r.original);
  } else {
    File(r.trashed).renameSync(r.original);
  }
  _remove(r.info);
  return r.original;
}

void _remove(String path) {
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // gone
  }
}

/// Trashes [target] (a receipt for Undo), or deletes it when the trash is
/// on another filesystem (null then). A symlink is always just unlinked.
TrashReceipt? discard(String trash, String target) {
  final type = FileSystemEntity.typeSync(target, followLinks: false);
  if (type == FileSystemEntityType.link) {
    Link(target).deleteSync();
    return null;
  }
  try {
    return moveToTrash(trash, target);
  } on FileSystemException catch (e) {
    if (e.osError?.errorCode != 18) rethrow;
  }
  if (type == FileSystemEntityType.directory) {
    Directory(target).deleteSync(recursive: true);
  } else {
    File(target).deleteSync();
  }
  return null;
}

/// Receipts handed to the GUI as opaque ids, kept for the life of the core.
final class ReceiptBook {
  final _byId = <String, List<TrashReceipt>>{};
  final _random = Random.secure();

  String keep(List<TrashReceipt> receipts) {
    final id = List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    _byId[id] = receipts;
    while (_byId.length > 64) {
      _byId.remove(_byId.keys.first);
    }
    return id;
  }

  List<TrashReceipt>? take(String id) => _byId.remove(id);
}
