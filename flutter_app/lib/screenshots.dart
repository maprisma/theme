import 'i18n.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart'
    show homeShort, saveScreenshot, saveScreenshotNote, screenshotFolder, screenshotNoteLimit;

import 'app.dart';

/// F12 (the plugin's screenshots.py, Maprisma Playground's F12): the window paints itself
/// (RepaintBoundary `app.shotKey`, dialogs included) into a PNG; the core writes it as a new
/// private file (0600, never over an older picture or note) into the folder chosen in Settings
/// or `<pictures>/MaprismaTheme` (a private 0700 folder of yours, checked on its handle). A small
/// dialog then says where it went and asks "What is wrong? (optional)"; the note goes next to
/// the picture when the dialog closes (Done, Enter, Esc or a click beside it).

/// F12 without Ctrl, Shift, Alt or Super, wherever the keyboard is (also in a dialog or a field).
bool isScreenshotKey(KeyEvent event) {
  if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.f12) return false;
  final keys = HardwareKeyboard.instance;
  return !(keys.isControlPressed || keys.isShiftPressed || keys.isAltPressed || keys.isMetaPressed);
}

/// The picture of the window, or null.
Future<Uint8List?> paintWindow(GlobalKey key) async {
  final context = key.currentContext;
  final boundary = context?.findRenderObject();
  if (context == null || boundary is! RenderRepaintBoundary || !boundary.hasSize || boundary.size.isEmpty) {
    return null;
  }
  final image = await boundary.toImage(pixelRatio: MediaQuery.devicePixelRatioOf(context));
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

String _why(Object error) => switch (error) {
  FileSystemException(:final osError?) => osError.message,
  FileSystemException(:final message) => message,
  _ => '$error',
};

var _busy = false;

/// F12: saves the picture and asks for the note. F12 again while the note is asked for takes no
/// second picture and opens no second dialog.
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
    final fallback = screenshotFolder(Platform.environment);
    String path;
    try {
      path = saveScreenshot(chosen ?? fallback, png);
    } on Object catch (e) {
      if (chosen == null) {
        app.notify(trf("The screenshot could not be saved: {0}", [_why(e)]));
        return;
      }
      try {
        path = saveScreenshot(fallback, png); // the chosen folder is gone or open to others
      } on Object catch (e) {
        app.notify(trf("The screenshot could not be saved: {0}", [_why(e)]));
        return;
      }
    }
    final context = app.navigator.currentContext;
    if (context == null || !context.mounted) {
      app.notify(trf("Screenshot saved: {0}", [path]));
      return;
    }
    final note = await showDialog<String>(context: context, builder: (_) => ShotNote(path));
    try {
      saveScreenshotNote(path, note ?? '');
    } on Object catch (e) {
      app.notify(trf("The note could not be saved: {0}", [_why(e)]));
    }
  } finally {
    _busy = false;
  }
}

/// After F12: where the picture went, and an optional note. Done, Enter, Esc and a click beside it
/// all close it with the text typed (the field's controller lives and goes with the dialog);
/// Open folder shows the folder.
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

  void _done() => Navigator.pop(context, _note.text);

  void _openFolder() {
    final folder = File(widget.path).parent.path;
    Process.start('xdg-open', [folder], mode: ProcessStartMode.detached).ignore();
  }

  @override
  Widget build(BuildContext context) => PopScope<String>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _done(); // Esc or a click beside it: the note is kept too
    },
    child: AlertDialog(
      title: Text(tr("Screenshot saved")),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(trf("Saved as {0}", [homeShort(widget.path, Platform.environment)])),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('screenshot-note'),
              controller: _note,
              autofocus: true,
              maxLength: screenshotNoteLimit,
              decoration: InputDecoration(labelText: tr("What is wrong? (optional)"), counterText: ''),
              onSubmitted: (_) => _done(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _openFolder, child: Text(tr("Open folder"))),
        FilledButton(onPressed: _done, child: Text(tr("Done"))),
      ],
    ),
  );
}
