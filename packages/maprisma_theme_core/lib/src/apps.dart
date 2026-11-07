/// The terminal and editor colors from Omarchy's templates (docs/plan.md,
/// "App colors"): each installed app's template is rendered into
/// ~/.config/maprisma-theme/`current/<file>` (as Omarchy's
/// ~/.local/state/omarchy/`current/theme/<file>`), and the app's own config gets
/// one marked include line (a backup is kept once) while the user has the app
/// switched on (settings `apps`: null = every installed app).
library;

import 'dart:convert';
import 'dart:io';

import 'colors.dart';
import 'context.dart';
import 'posix.dart';
import 'store.dart';
import 'themes.dart';

const appMarker = 'Maprisma Theme colors (remove this and the next line to stop)';
const backupSuffix = '.before-maprisma-theme';

final class AppSpec {
  const AppSpec(this.id, this.label, this.template, this.output, this.programs, this.configDir);
  final String id, label, template, output, configDir;
  final List<String> programs;
}

const appSpecs = [
  AppSpec('alacritty', 'Alacritty', 'alacritty.toml.tpl', 'alacritty.toml', ['alacritty'], 'alacritty'),
  AppSpec('kitty', 'Kitty', 'kitty.conf.tpl', 'kitty.conf', ['kitty'], 'kitty'),
  AppSpec('ghostty', 'Ghostty', 'ghostty.conf.tpl', 'ghostty.conf', ['ghostty'], 'ghostty'),
  AppSpec('foot', 'foot', 'foot.ini.tpl', 'foot.ini', ['foot'], 'foot'),
  AppSpec('btop', 'btop', 'btop.theme.tpl', 'btop.theme', ['btop'], 'btop'),
  AppSpec('neovim', 'Neovim', 'neovim.lua.tpl', 'neovim.lua', ['nvim'], 'nvim'),
  AppSpec('helix', 'Helix', 'helix.toml.tpl', 'helix.toml', ['hx', 'helix'], 'helix'),
  AppSpec('vscode', 'VS Code', 'vscode-theme.json.tpl', 'vscode-theme.json', ['code', 'codium', 'code-oss'], 'Code'),
];

AppSpec? appSpec(String id) => appSpecs.where((a) => a.id == id).firstOrNull;

/// The user's ~/.config (XDG_CONFIG_HOME).
String configHome(Ctx ctx) => File(ctx.paths.config).parent.path;
String currentAppsDir(Ctx ctx) => '${ctx.paths.config}/current';
String _appsStateFile(Ctx ctx) => ctx.paths.file('apps-state.json');

bool appInstalled(Ctx ctx, AppSpec a) =>
    a.programs.any((p) => which(p, ctx.environment) != null) || Directory('${configHome(ctx)}/${a.configDir}').existsSync();

/// Apps whose colors are only rendered: nothing of theirs can be switched
/// on (VS Code needs an extension, which Maprisma Theme does not install).
bool appSupported(AppSpec a) => a.id != 'vscode';

bool appEnabled(Ctx ctx, AppSpec a) {
  if (!appSupported(a)) return false;
  final apps = ctx.settings.get('apps');
  return apps is List ? apps.contains(a.id) : appInstalled(ctx, a);
}

// --- reading and writing the user's files -----------------------------------------

/// A config file's text (at most 1 MiB, a regular file), '' when missing,
/// null when it cannot be read (then it is never written).
String? _readConfig(String path) {
  if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) return '';
  final bytes = Posix.instance.readRegular(path, 1024 * 1024);
  return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
}

/// Writes through a dotfiles link to the file it points at, keeping its mode;
/// the first change keeps a copy as `<file>.before-maprisma-theme`.
bool _writeConfig(String path, String text, {required bool existed}) {
  var target = path;
  try {
    if (FileSystemEntity.isLinkSync(path)) target = File(path).resolveSymbolicLinksSync();
    if (existed && Posix.instance.ownerOf(target) != Posix.instance.uid) return false;
    int mode = 420;
    if (existed) {
      mode = File(target).statSync().mode & 0x1ff;
      final backup = '$path$backupSuffix';
      if (FileSystemEntity.typeSync(backup, followLinks: false) == FileSystemEntityType.notFound) {
        File(target).copySync(backup);
        chmodPath(backup, mode);
      }
    } else {
      Directory(File(target).parent.path).createSync(recursive: true);
    }
    writeText(target, text, mode: mode);
    return true;
  } on FileSystemException {
    return false;
  }
}

String _comment(AppSpec a) => a.id == 'neovim' ? '--' : '#';

/// [lines] at the top or the end, marked; true when they are (now) there.
bool _addLines(String path, AppSpec a, String line, {bool top = false}) {
  final text = _readConfig(path);
  if (text == null) return false;
  if (text.split('\n').any((l) => l.trim() == line)) return true;
  final marked = '${_comment(a)} $appMarker\n$line\n';
  String out;
  if (top) {
    out = '$marked${text.isEmpty ? '' : '\n'}$text';
  } else {
    out = text.isEmpty ? marked : '$text${text.endsWith('\n') ? '' : '\n'}\n$marked';
  }
  return _writeConfig(path, out, existed: text.isNotEmpty || File(path).existsSync());
}

/// Takes the marked lines out again; true when something was removed.
bool _removeLines(String path, AppSpec a, bool Function(String line) isOurs) {
  final text = _readConfig(path);
  if (text == null || text.isEmpty) return false;
  final lines = text.split('\n');
  final kept = <String>[];
  var changed = false;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() == '${_comment(a)} $appMarker') {
      changed = true;
      if (i + 1 < lines.length && isOurs(lines[i + 1])) i++;
      // a blank line we put before the marker goes too
      if (kept.isNotEmpty && kept.last.trim().isEmpty) kept.removeLast();
      continue;
    }
    if (isOurs(lines[i])) {
      changed = true;
      continue;
    }
    kept.add(lines[i]);
  }
  if (!changed) return false;
  var out = kept.join('\n');
  if (text.endsWith('\n') && !out.endsWith('\n')) out += '\n';
  if (out.startsWith('\n')) out = out.substring(1);
  return _writeConfig(path, out, existed: true);
}

Map<String, dynamic> _appsState(Ctx ctx) => readJsonMap(_appsStateFile(ctx));
void _saveAppsState(Ctx ctx, Map<String, dynamic> s) => writeJson(_appsStateFile(ctx), s);

// --- per app ------------------------------------------------------------------------

String _ghosttyConfig(Ctx ctx) {
  final dir = '${configHome(ctx)}/ghostty';
  return File('$dir/config.ghostty').existsSync() && !File('$dir/config').existsSync() ? '$dir/config.ghostty' : '$dir/config';
}

final _tomlTable = RegExp(r'^\s*\[');

/// The value of a top-level `key = "value"` line of a TOML/btop file and its index.
(int, String?) _topLevelValue(List<String> lines, String key, {bool tables = true}) {
  final re = RegExp('^\\s*${RegExp.escape(key)}\\s*=\\s*"?([^"#]*)"?');
  for (var i = 0; i < lines.length; i++) {
    if (tables && _tomlTable.hasMatch(lines[i])) break;
    final m = re.firstMatch(lines[i]);
    if (m != null) return (i, m[1]!.trim());
  }
  return (-1, null);
}

/// Sets a top-level `key = "maprisma"` (btop's color_theme, Helix's theme),
/// remembering the value it had so removing the colors puts it back.
bool _setValue(Ctx ctx, AppSpec a, String path, String key, String value, {bool tables = true}) {
  final text = _readConfig(path);
  if (text == null) return false;
  final lines = text.isEmpty ? <String>[] : text.split('\n');
  final (index, previous) = _topLevelValue(lines, key, tables: tables);
  final line = '$key = "$value"';
  if (index >= 0 && previous == value) return true;
  final state = _appsState(ctx);
  state[a.id] = {'previous': previous};
  _saveAppsState(ctx, state);
  if (index >= 0) {
    lines[index] = line;
  } else {
    lines.insertAll(0, ['${_comment(a)} $appMarker', line]);
  }
  var out = lines.join('\n');
  if (!out.endsWith('\n')) out += '\n';
  return _writeConfig(path, out, existed: text.isNotEmpty || File(path).existsSync());
}

bool _resetValue(Ctx ctx, AppSpec a, String path, String key, String value, {bool tables = true}) {
  final text = _readConfig(path);
  if (text == null || text.isEmpty) return false;
  final lines = text.split('\n');
  final (index, now) = _topLevelValue(lines, key, tables: tables);
  if (index < 0 || now != value) return false;
  final state = _appsState(ctx);
  final previous = (state[a.id] is Map ? state[a.id]['previous'] : null) as String?;
  if (previous != null && previous.isNotEmpty) {
    lines[index] = '$key = "$previous"';
  } else {
    lines.removeAt(index);
    if (index > 0 && lines[index - 1].trim() == '${_comment(a)} $appMarker') lines.removeAt(index - 1);
  }
  state.remove(a.id);
  _saveAppsState(ctx, state);
  return _writeConfig(path, lines.join('\n'), existed: true);
}

/// Who a file we would write in an app's own folder belongs to: 'free'
/// (nothing there), 'ours' (a regular file whose first line is our marker, or,
/// from before the marker, exactly [legacy]) or 'foreign' (the user's own file,
/// a link, anything else: never overwritten or deleted).
String _ownership(String path, String comment, {List<int>? legacy}) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return 'free';
  if (type != FileSystemEntityType.file) return 'foreign';
  final bytes = Posix.instance.readRegular(path, 1024 * 1024);
  if (bytes == null) return 'foreign';
  final text = utf8.decode(bytes, allowMalformed: true);
  if (text.split('\n').first.trim() == '$comment $appMarker') return 'ours';
  if (legacy != null && bytes.length == legacy.length) {
    var same = true;
    for (var i = 0; i < bytes.length && same; i++) {
      same = bytes[i] == legacy[i];
    }
    if (same) return 'ours';
  }
  return 'foreign';
}

/// Copies our rendered file, marked, into an app's own themes folder: 'ok',
/// 'manual' (a file of the user's is there) or 'failed'.
String _copyInto(String source, String target, String comment) {
  final bytes = Posix.instance.readRegular(source, 1024 * 1024);
  if (bytes == null) return 'failed';
  if (_ownership(target, comment, legacy: bytes) == 'foreign') return 'manual';
  try {
    writeAtomic(target, utf8.encode('$comment $appMarker\n${utf8.decode(bytes, allowMalformed: true)}'), mode: 420);
    return 'ok';
  } on FileSystemException {
    return 'failed';
  }
}

/// Deletes a file of ours in an app's own folder; true when it did.
bool _deleteOwned(String path, String comment) {
  if (_ownership(path, comment) != 'ours') return false;
  try {
    File(path).deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// The marked include in the app's own config. 'ok', 'manual' (the config
/// is laid out so that a line cannot be added safely), 'failed', or 'none'
/// (the app has nothing to include, VS Code).
String ensureInclude(Ctx ctx, AppSpec a) {
  final cfg = configHome(ctx);
  final out = '${currentAppsDir(ctx)}/${a.output}';
  switch (a.id) {
    case 'kitty':
      return _addLines('$cfg/kitty/kitty.conf', a, 'include $out') ? 'ok' : 'failed';
    case 'ghostty':
      return _addLines(_ghosttyConfig(ctx), a, 'config-file = ?"$out"') ? 'ok' : 'failed';
    case 'foot':
      return _addLines('$cfg/foot/foot.ini', a, 'include=$out', top: true) ? 'ok' : 'failed';
    case 'alacritty':
      final path = '$cfg/alacritty/alacritty.toml';
      final text = _readConfig(path);
      if (text == null) return 'failed';
      final line = 'general.import = ["$out"]';
      if (text.split('\n').any((l) => l.trim() == line)) return 'ok';
      // Another import or a [general] table: one more line would break the file.
      if (RegExp(r'^\s*((general\.)?import\s*=|\[\s*general\b)', multiLine: true).hasMatch(text)) return 'manual';
      return _addLines(path, a, line, top: true) ? 'ok' : 'failed';
    case 'btop':
      final copied = _copyInto(out, '$cfg/btop/themes/maprisma.theme', '#');
      if (copied != 'ok') return copied;
      return _setValue(ctx, a, '$cfg/btop/btop.conf', 'color_theme', 'maprisma', tables: false) ? 'ok' : 'failed';
    case 'helix':
      final copied = _copyInto(out, '$cfg/helix/themes/maprisma.toml', '#');
      if (copied != 'ok') return copied;
      return _setValue(ctx, a, '$cfg/helix/config.toml', 'theme', 'maprisma') ? 'ok' : 'failed';
    case 'neovim':
      // Only a lazy.nvim config (LazyVim, Omarchy's): a plugin spec of our own.
      final plugins = '$cfg/nvim/lua/plugins';
      if (!Directory(plugins).existsSync()) return 'manual';
      final text = readSmall(out, limit: 1024 * 1024);
      if (text == null) return 'failed';
      // a file of that name the user made is theirs
      if (_ownership('$plugins/maprisma-theme.lua', '--') == 'foreign') return 'manual';
      try {
        writeText('$plugins/maprisma-theme.lua', '-- $appMarker\n$text', mode: 420);
        return 'ok';
      } on FileSystemException {
        return 'failed';
      }
    default:
      return 'none';
  }
}

/// Takes the include out again (the value it replaced comes back).
bool removeInclude(Ctx ctx, AppSpec a) {
  final cfg = configHome(ctx);
  final out = '${currentAppsDir(ctx)}/${a.output}';
  switch (a.id) {
    case 'kitty':
      return _removeLines('$cfg/kitty/kitty.conf', a, (l) => l.trim() == 'include $out');
    case 'ghostty':
      return _removeLines(_ghosttyConfig(ctx), a, (l) => l.trim() == 'config-file = ?"$out"');
    case 'foot':
      return _removeLines('$cfg/foot/foot.ini', a, (l) => l.trim() == 'include=$out');
    case 'alacritty':
      return _removeLines('$cfg/alacritty/alacritty.toml', a, (l) => l.trim() == 'general.import = ["$out"]');
    case 'btop':
      final reset = _resetValue(ctx, a, '$cfg/btop/btop.conf', 'color_theme', 'maprisma', tables: false);
      return _deleteOwned('$cfg/btop/themes/maprisma.theme', '#') || reset;
    case 'helix':
      final reset = _resetValue(ctx, a, '$cfg/helix/config.toml', 'theme', 'maprisma');
      return _deleteOwned('$cfg/helix/themes/maprisma.toml', '#') || reset;
    case 'neovim':
      return _deleteOwned('$cfg/nvim/lua/plugins/maprisma-theme.lua', '--');
    default:
      return false;
  }
}

/// Is the include in place?
bool includeActive(Ctx ctx, AppSpec a) {
  final cfg = configHome(ctx);
  final out = '${currentAppsDir(ctx)}/${a.output}';
  bool has(String path, String line) => (_readConfig(path) ?? '').split('\n').any((l) => l.trim() == line);
  return switch (a.id) {
    'kitty' => has('$cfg/kitty/kitty.conf', 'include $out'),
    'ghostty' => has(_ghosttyConfig(ctx), 'config-file = ?"$out"'),
    'foot' => has('$cfg/foot/foot.ini', 'include=$out'),
    'alacritty' => has('$cfg/alacritty/alacritty.toml', 'general.import = ["$out"]'),
    'btop' => _topLevelValue((_readConfig('$cfg/btop/btop.conf') ?? '').split('\n'), 'color_theme', tables: false).$2 == 'maprisma',
    'helix' => _topLevelValue((_readConfig('$cfg/helix/config.toml') ?? '').split('\n'), 'theme').$2 == 'maprisma',
    'neovim' => (readSmall('$cfg/nvim/lua/plugins/maprisma-theme.lua', limit: 1024 * 1024) ?? '').startsWith('-- $appMarker'),
    _ => false,
  };
}

/// Renders every installed app's template; the apps the user has on get
/// their include. Returns the app ids whose colors were updated.
Future<List<String>> applyAppTemplates(Ctx ctx, ThemeInfo theme, Map<String, String> resolved) async {
  final updated = <String>[];
  for (final a in appSpecs) {
    if (!appInstalled(ctx, a)) continue;
    if (!renderApp(ctx, a, resolved)) continue;
    if (!appEnabled(ctx, a)) continue;
    if (ensureInclude(ctx, a) == 'ok') updated.add(a.id);
  }
  return updated;
}

/// One app's template into ~/.config/maprisma-theme/current/.
bool renderApp(Ctx ctx, AppSpec a, Map<String, String> resolved) {
  final tpl = readSmall('${ctx.paths.templates}/${a.template}', limit: 1024 * 1024);
  if (tpl == null) return false;
  final text = renderTemplate(tpl, resolved);
  if (text == null) return false;
  try {
    writeText('${currentAppsDir(ctx)}/${a.output}', text);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Takes every include out (all apps, or [ids]); returns the ids changed.
List<String> removeAppIncludes(Ctx ctx, [Iterable<String>? ids]) => [
  for (final a in appSpecs)
    if (ids == null || ids.contains(a.id))
      if (removeInclude(ctx, a)) a.id,
];

String _vscodeNote(Ctx ctx, AppSpec a) =>
    'colors are written to ${currentAppsDir(ctx)}/${a.output}; VS Code needs them installed as an extension, which Maprisma Theme does not do';

/// The Themes section of Settings: every app, installed or not.
List<Map<String, dynamic>> appsList(Ctx ctx) => [
  for (final a in appSpecs)
    () {
      final installed = appInstalled(ctx, a);
      return {
        'id': a.id,
        'label': a.label,
        'installed': installed,
        'supported': appSupported(a),
        'enabled': appEnabled(ctx, a),
        'included': includeActive(ctx, a),
        'note': switch (a.id) {
          'vscode' => 'Not supported: ${_vscodeNote(ctx, a)}',
          'neovim' => 'Needs a lazy.nvim config (~/.config/nvim/lua/plugins/)',
          'alacritty' => 'Adds general.import to alacritty.toml',
          'btop' => 'Sets color_theme in btop.conf (restart btop)',
          'helix' => 'Sets theme in config.toml (restart Helix)',
          _ => 'One include line in its config (new windows)',
        },
      };
    }(),
];

/// Switches an app's colors on or off (settings `apps`), and adds or
/// removes its include right away with [resolved] (the theme in use).
Map<String, dynamic> setAppEnabled(Ctx ctx, String id, bool on, Map<String, String>? resolved) {
  final a = appSpec(id);
  if (a == null) throw RouteError('bad_params', 'id');
  if (on && !appSupported(a)) throw RouteError('unsupported', '${a.label} cannot be switched on: ${_vscodeNote(ctx, a)}');
  final raw = ctx.settings.get('apps');
  final list = raw is List
      ? [for (final x in raw) if (x is String) x]
      : [for (final s in appSpecs) if (appInstalled(ctx, s) && appSupported(s)) s.id];
  list.remove(id);
  if (on) list.add(id);
  ctx.settings.set('apps', [for (final s in appSpecs) if (list.contains(s.id) && appSupported(s)) s.id]);
  var result = 'off';
  if (on) {
    if (resolved != null) renderApp(ctx, a, resolved);
    result = File('${currentAppsDir(ctx)}/${a.output}').existsSync() ? ensureInclude(ctx, a) : 'failed';
  } else {
    removeInclude(ctx, a);
  }
  return {'id': id, 'result': result, 'apps': appsList(ctx)};
}
