/// The AI helper chosen for every Maprisma app (Maprisma Manager → AI):
/// `${XDG_CONFIG_HOME:-$HOME/.config}/maprisma-ai/settings.json`, a JSON object whose `helper` is
/// `"auto"` or a helper id. A missing or broken file or value is "auto"; unknown keys are kept
/// when it is written (atomically, folder 0700, file 0600).
///
/// "auto" is the first ready helper in the catalog's order; a chosen helper that is not
/// installed or not ready falls back to it. While the shared file does not exist yet, Maprisma
/// Theme's own old choice (`ask_ai_helper`) counts (the file is not written for that: Maprisma
/// Manager seeds it).
library;

import 'dart:io';

import 'store.dart';

const sharedHelperAuto = 'auto';
final _helperId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,160}$');

/// A helper id the shared file may hold (not "auto").
bool validSharedHelperId(Object? v) => v is String && v != sharedHelperAuto && _helperId.hasMatch(v);

/// The shared settings file below [configHome] (XDG_CONFIG_HOME or ~/.config).
String sharedAiSettingsFile(String configHome) => '$configHome/maprisma-ai/settings.json';

/// The shared choice: "auto" or a helper id; null when the file does not exist (or is no
/// regular file) — then the app's own old choice may count.
String? readSharedHelper(String path) {
  if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) return null;
  final v = readJsonMap(path)['helper'];
  return validSharedHelperId(v) ? v as String : sharedHelperAuto;
}

/// The shared choice, else [legacy] (the app's old own one) when the file is absent and it is
/// valid, else "auto".
String effectiveSharedHelper(String path, Object? legacy) =>
    readSharedHelper(path) ?? (validSharedHelperId(legacy) ? legacy as String : sharedHelperAuto);

/// Writes [helper] ("auto" or a valid id; else ArgumentError) and keeps the file's other keys.
void writeSharedHelper(String path, String helper) {
  if (helper != sharedHelperAuto && !validSharedHelperId(helper)) {
    throw ArgumentError.value(helper, 'helper');
  }
  final data = readJsonMap(path)..['helper'] = helper;
  writeJson(path, data);
  final dir = File(path).parent.path;
  if (FileSystemEntity.typeSync(dir, followLinks: false) == FileSystemEntityType.directory &&
      FileStat.statSync(dir).mode & 511 != 448) {
    chmodPath(dir, 448 /* 0700 */);
  }
}

/// The helper to use: [choice] when it is among [ready] (ids in the catalog's order), else the
/// first ready one (auto); null when none is ready.
String? resolveSharedHelper(String choice, List<String> ready) =>
    choice != sharedHelperAuto && ready.contains(choice) ? choice : ready.firstOrNull;
