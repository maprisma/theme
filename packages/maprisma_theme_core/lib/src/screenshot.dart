import 'package:maprisma_core_kit/files.dart' show PrivateFolder;
import 'package:maprisma_core_kit/screenshot.dart' as kit;
import 'package:path/path.dart' as p;

export 'package:maprisma_core_kit/files.dart' show PrivateFolder, debugFailWriteAfter, makePrivateFolder;
export 'package:maprisma_core_kit/screenshot.dart' show homeShort, saveScreenshotNote, screenshotNoteLimit;

/// The pictures folder (XDG_PICTURES_DIR from user-dirs.dirs, read bounded and without following
/// a link; else ~/Pictures) with "MaprismaTheme" in it.
String screenshotFolder(Map<String, String> environment) =>
    kit.screenshotFolder(appName: 'MaprismaTheme', environment: environment);

/// `<date>-<time>` of a screenshot's name: 2026-11-07-08-26-31.
String screenshotStamp(DateTime at) {
  String two(int n) => '$n'.padLeft(2, '0');
  return '${at.year.toString().padLeft(4, '0')}-${two(at.month)}-${two(at.day)}'
      '-${two(at.hour)}-${two(at.minute)}-${two(at.second)}';
}

/// `maprisma-theme-<stamp>.png`, or -2, -3 … when a picture or a note already has that name.
String freeScreenshotName(PrivateFolder folder, String stamp) =>
    kit.freeScreenshotName(folder, stamp, filePrefix: 'maprisma-theme');

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
