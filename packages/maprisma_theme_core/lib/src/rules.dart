/// Ask AI rules, shared by every Maprisma app (docs/ask-ai-rules.md): the `ask_ai` key of
/// `maprisma-ai/settings.json` (level, actions, sources, folders) and the log of what Ask AI
/// changed, `$XDG_STATE_HOME/maprisma-ai/actions.jsonl`. Only Settings writes `ask_ai`; every app
/// reads it and enforces it in its own core.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'paths.dart';
import 'shared_ai.dart';
import 'store.dart' show chmodPath;
import 'posix.dart';

/// Overall level: actions allowed by the switches (each with its review), or answers only.
const askAiLevels = ['review', 'answers'];

/// One switchable thing on the AI page.
typedef AskAiItem = ({String id, String app, String label});

/// Every action Ask AI can run (docs/ask-ai-rules.md); the page lists them in this order.
const List<AskAiItem> askAiActions = [
  (id: 'launcher.install', app: 'launcher', label: 'Install apps'),
  (id: 'launcher.remove', app: 'launcher', label: 'Uninstall apps'),
  (id: 'launcher.update', app: 'launcher', label: 'Update apps'),
  (id: 'launcher.update_system', app: 'launcher', label: 'Update the system'),
  (id: 'launcher.hide', app: 'launcher', label: 'Hide and unhide apps'),
  (
    id: 'launcher.shortcuts',
    app: 'launcher',
    label: 'Change keyboard shortcuts',
  ),
  (id: 'theme.apply', app: 'theme', label: 'Apply a theme or wallpaper'),
  (id: 'theme.install', app: 'theme', label: 'Install themes from the catalog'),
  (id: 'theme.edit', app: 'theme', label: 'Create and save custom themes'),
  (id: 'theme.generate', app: 'theme', label: 'Generate pictures'),
  (id: 'theme.wallpapers', app: 'theme', label: 'Add wallpapers'),
  (id: 'settings.updates', app: 'settings', label: 'Update Maprisma apps'),
];

/// Install sources of the Launcher's Ask AI.
const List<AskAiItem> askAiSources = [
  (id: 'pacman', app: 'launcher', label: 'Official repositories (pacman)'),
  (id: 'aur', app: 'launcher', label: 'AUR'),
  (id: 'flatpak', app: 'launcher', label: 'Flatpak'),
  (id: 'apt', app: 'launcher', label: 'apt'),
  (id: 'dnf', app: 'launcher', label: 'dnf'),
  (id: 'zypper', app: 'launcher', label: 'zypper'),
  (id: 'snap', app: 'launcher', label: 'Snap'),
  (id: 'github', app: 'launcher', label: 'GitHub releases'),
  (id: 'local', app: 'launcher', label: 'AppImages in Downloads'),
];

/// Folders Ask AI may look into.
const List<AskAiItem> askAiFolders = [
  (id: 'downloads', app: 'launcher', label: 'Downloads (AppImages to install)'),
];

/// Steps that only answer (no switch; listed so the page shows the whole picture).
const List<AskAiItem> askAiAnswers = [
  (id: 'launcher.answers', app: 'launcher', label: 'Suggest and explain apps'),
  (id: 'theme.answers', app: 'theme', label: 'Suggest themes and wallpapers'),
  (id: 'notifier.check', app: 'notifier', label: 'Check a crash notification'),
  (id: 'playground.chat', app: 'playground', label: 'Chat'),
];

final _id = RegExp(r'^[a-z][a-z0-9_.]{0,63}$');

/// The `ask_ai` object (unknown boolean ids kept); missing defaults, malformed restrictive.
({
  String level,
  Map<String, bool> actions,
  Map<String, bool> sources,
  Map<String, bool> folders,
  bool broken,
})
readAskAiRules(Paths paths) {
  // An existing file that can't be read, or an ask_ai that isn't an object: restrictive.
  final whole = readSharedObject(paths);
  if (whole == null &&
      FileSystemEntity.typeSync(paths.sharedAiSettings, followLinks: false) !=
          FileSystemEntityType.notFound) {
    return (
      level: 'answers',
      actions: {},
      sources: {},
      folders: {},
      broken: true,
    );
  }
  final raw = whole?['ask_ai'];
  if (whole == null || !whole.containsKey('ask_ai')) {
    return (
      level: 'review',
      actions: {},
      sources: {},
      folders: {},
      broken: false,
    );
  }
  if (raw is! Map) {
    return (
      level: 'answers',
      actions: {},
      sources: {},
      folders: {},
      broken: true,
    );
  }
  var broken = false;
  // Malformed values are restrictive (docs/ask-ai-rules.md): a map that isn't an object switches
  // all of its kind off, a known id with a non-boolean value is off.
  Map<String, bool> map(Object? v, List<AskAiItem> known) {
    if (v == null) {
      broken = true;
      return {for (final i in known) i.id: false};
    }
    if (v is! Map) {
      broken = true;
      return {for (final i in known) i.id: false};
    }
    final out = <String, bool>{};
    for (final e in v.entries) {
      if (e.key is! String || !_id.hasMatch(e.key as String)) continue;
      if (e.value is bool) {
        out[e.key as String] = e.value as bool;
      } else if (known.any((i) => i.id == e.key)) {
        broken = true;
        out[e.key as String] = false;
      }
    }
    return out;
  }

  final level = raw['level'];
  final actions = raw.containsKey('actions')
          ? map(raw['actions'], askAiActions)
          : <String, bool>{},
      sources = raw.containsKey('sources')
          ? map(raw['sources'], askAiSources)
          : <String, bool>{},
      folders = raw.containsKey('folders')
          ? map(raw['folders'], askAiFolders)
          : <String, bool>{};
  if (raw.containsKey('level') && !askAiLevels.contains(level)) broken = true;
  return (
    level: !raw.containsKey('level')
        ? 'review'
        : (askAiLevels.contains(level) ? level as String : 'answers'),
    actions: actions,
    sources: sources,
    folders: folders,
    broken: broken,
  );
}

/// The decision every app makes (here for Settings' own AI updates and the page's summary).
bool askAiAllowed(Paths paths, String action, {String? source}) {
  final r = readAskAiRules(paths);
  return r.level != 'answers' &&
      r.actions[action] != false &&
      (source == null || r.sources[source] != false) &&
      (source != 'local' || r.folders['downloads'] != false);
}

// ---------------------------------------------------------------- the log

const askAiLogMax = 1000, askAiLogKeep = 500, askAiLogBytes = 1 << 20;

String askAiLogFile(Paths paths) =>
    p.join(p.dirname(paths.state), sharedAiDir, 'actions.jsonl');

String askAiLogLock(Paths paths) =>
    p.join(p.dirname(paths.state), sharedAiDir, 'actions.lock');

/// Appends one entry under the log's lock (docs/ask-ai-rules.md: lock first, then open the data
/// file; trim to the newest [askAiLogKeep] above [askAiLogMax]). A failure never stops a step.
void appendAskAiLog(
  Paths paths, {
  required String op,
  required String app,
  required String action,
  required String target,
  required String result,
}) {
  final path = askAiLogFile(paths);
  try {
    final dir = Directory(p.dirname(path))..createSync(recursive: true);
    // a real folder of the user (no link), else nothing is logged
    if (FileSystemEntity.typeSync(dir.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        Posix.instance.ownerOf(dir.path, follow: false) != Posix.instance.uid) {
      return;
    }
    chmodPath(dir.path, 0x1c0);
    Posix.instance.withFlock(askAiLogLock(paths), () {
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link) {
        return;
      }
      final entry = {
        'time': DateTime.now().toUtc().toIso8601String().replaceFirst(
          RegExp(r'\.\d+Z$'),
          'Z',
        ),
        'op': op,
        'app': app,
        'action': action,
        'target': target.length > 200 ? target.substring(0, 200) : target,
        'result': result,
      };
      if (!Posix.instance.appendPrivate(
        path,
        utf8.encode('${jsonEncode(entry)}\n'),
        trimIncompleteLine: true,
      )) {
        return;
      }
      final data = File(path);
      final lines = data.readAsStringSync().split('\n');
      final complete = lines.sublist(
        0,
        lines.length - 1,
      ); // the part after the last newline is incomplete
      if (complete.length > askAiLogMax || data.lengthSync() > askAiLogBytes) {
        final keep = complete.length > askAiLogKeep
            ? complete.sublist(complete.length - askAiLogKeep)
            : complete;
        final tmp = File(
          p.join(
            dir.path,
            '.actions.${DateTime.now().microsecondsSinceEpoch}.tmp',
          ),
        );
        if (!Posix.instance.writeNewPrivate(
          tmp.path,
          utf8.encode('${keep.join('\n')}\n'),
        )) {
          return;
        }
        tmp.renameSync(path);
      }
    });
  } on Object {
    // Logging is best effort and must never change the outcome of a step.
  }
}
