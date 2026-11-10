import 'i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart' show Posix;

import 'app.dart';

/// F12 (the plugin's screenshots.py, Maprisma Launcher's window_shots.dart):
/// the window paints itself (RepaintBoundary `app.shotKey`) into a PNG (0600)
/// in ~/Pictures/MaprismaTheme or the folder chosen in Settings, then a
/// small dialog says where it went and asks "What is wrong? (optional)".
final class WindowShots {
  WindowShots(this.folder);
  final String folder;

  static String defaultFolder(Map<String, String> environment) => '${environment['HOME'] ?? ''}/Pictures/MaprismaTheme';

  /// maprisma-theme-2026-11-07-08-26-31.png, then -2 within the same second.
  String pathFor(DateTime time) {
    String two(int n) => '$n'.padLeft(2, '0');
    final stem = 'maprisma-theme-${time.year}-${two(time.month)}-${two(time.day)}'
        '-${two(time.hour)}-${two(time.minute)}-${two(time.second)}';
    var path = '$folder/$stem.png';
    for (var n = 2; FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound; n++) {
      path = '$folder/$stem-$n.png';
    }
    return path;
  }

  /// The folder must be ours, a real folder and closed to others' writes.
  bool _safeFolder() {
    final dir = Directory(folder);
    if (!dir.existsSync()) {
      try {
        dir.createSync(recursive: true);
      } on FileSystemException {
        return false;
      }
    }
    if (FileSystemEntity.isLinkSync(folder)) return false;
    final stat = dir.statSync();
    return stat.type == FileSystemEntityType.directory &&
        Posix.instance.ownerOf(folder) == Posix.instance.uid &&
        stat.mode & 0x12 == 0;
  }

  /// Created exclusively (never through a link), 0600.
  String? save(Uint8List png, DateTime time) {
    if (!_safeFolder()) return null;
    for (var attempt = 0; attempt < 5; attempt++) {
      final path = pathFor(time);
      if (Posix.instance.writeNewPrivate(path, png)) return path;
    }
    return null;
  }

  /// The note goes next to its picture, with the same name; no note, no file.
  static bool note(String picture, String text) {
    if (text.trim().isEmpty) return false;
    final stem = picture.substring(0, picture.length - '.png'.length);
    return Posix.instance.writeNewPrivate('$stem.txt', utf8.encode('${text.trim()}\n'));
  }
}

/// The picture of the window, or null.
Future<Uint8List?> paintWindow(GlobalKey key) async {
  final context = key.currentContext;
  final boundary = context?.findRenderObject();
  if (context == null || boundary is! RenderRepaintBoundary) return null;
  final image = await boundary.toImage(pixelRatio: MediaQuery.devicePixelRatioOf(context));
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

var _busy = false;

/// F12: saves the picture and shows the note dialog.
Future<void> takeScreenshot(MaprismaThemeAppState app) async {
  if (_busy) return;
  _busy = true;
  try {
    final png = await paintWindow(app.shotKey);
    if (png == null) {
      app.notify(tr("Could not take a screenshot"));
      return;
    }
    final chosen = app.settings['screenshot_dir'] as String?;
    final fallback = WindowShots.defaultFolder(Platform.environment);
    var path = WindowShots(chosen ?? fallback).save(png, DateTime.now());
    if (path == null && chosen != null) path = WindowShots(fallback).save(png, DateTime.now());
    if (path == null) {
      app.notify(tr("Screenshot not saved: the folder is not yours or open to others"));
      return;
    }
    final context = app.navigator.currentContext;
    if (context == null || !context.mounted) {
      app.notify(trf("Screenshot saved: {0}", [path]));
      return;
    }
    final saved = path;
    final text = await showDialog<String>(context: context, builder: (_) => ShotNote(saved));
    if (text != null) WindowShots.note(saved, text);
  } finally {
    _busy = false;
  }
}

/// After F12: where the picture went, and an optional note. Done or Enter
/// saves the note beside it, Esc skips it, Open folder shows the folder.
class ShotNote extends StatefulWidget {
  const ShotNote(this.path, {super.key});
  final String path;
  @override
  State<ShotNote> createState() => _ShotNoteState();
}

class _ShotNoteState extends State<ShotNote> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _openFolder() {
    final folder = File(widget.path).parent.path;
    Process.start('xdg-open', [folder], mode: ProcessStartMode.detached).ignore();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context)},
    child: AlertDialog(
      title: Text(tr("Screenshot saved")),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(widget.path),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('screenshot-note'),
            controller: _note,
            autofocus: true,
            maxLength: 2000,
            decoration: InputDecoration(labelText: tr("What is wrong? (optional)")),
            onSubmitted: (text) => Navigator.pop(context, text),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _openFolder, child: Text(tr("Open folder"))),
        FilledButton(onPressed: () => Navigator.pop(context, _note.text), child: Text(tr("Done"))),
      ],
    ),
  );
}
