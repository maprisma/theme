/// The AI helper chosen for every Maprisma app (Maprisma Settings → AI):
/// `${XDG_CONFIG_HOME:-$HOME/.config}/maprisma-ai/settings.json`.
library;

import 'dart:io';

import 'package:maprisma_core_kit/ai.dart' as kit;
import 'package:maprisma_core_kit/ai.dart' show sharedHelperAuto, validSharedHelperId;

import 'paths.dart';

export 'package:maprisma_core_kit/ai.dart'
    show resolveSharedHelper, sharedAiSettingsFile, sharedHelperAuto, validSharedHelperId, writeSharedHelper;

const sharedAiDir = 'maprisma-ai';

/// The shared choice: "auto" or a helper id; null when the file does not exist (or is no
/// regular file) — then the app's own old choice may count.
String? readSharedHelper(String path) {
  if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) return null;
  return kit.readSharedHelper(path);
}

/// The shared choice, else [legacy] (the app's old own one) when the file is absent and it is
/// valid, else "auto".
String effectiveSharedHelper(String path, Object? legacy) =>
    readSharedHelper(path) ?? (validSharedHelperId(legacy) ? legacy as String : sharedHelperAuto);

Map<String, dynamic>? readSharedObjectPath(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) return null;
  return kit.readSharedObject(path);
}

Map<String, dynamic>? readSharedObject(Paths paths) => readSharedObjectPath(paths.sharedAiSettings);

bool sharedFileBroken(Paths paths) =>
    FileSystemEntity.typeSync(paths.sharedAiSettings, followLinks: false) != FileSystemEntityType.notFound &&
    readSharedObject(paths) == null;
