import 'i18n.dart';
import 'dart:convert';
import 'dart:io';

import 'context.dart';
import 'core.dart';

/// `maprisma-theme-core <command> [args]` for the panel applet and keyboard
/// shortcuts (docs/cosmic-interface.md). Prints one JSON object.
Future<int> runCli(List<String> args, {CoreService? service}) async {
  final core = service ?? CoreService(environment: Platform.environment);
  languageSetting = core.ctx.settings.get('language') as String? ?? 'auto';
  if (args.isEmpty) {
    stderr.writeln(trf('Usage: {0}', ['maprisma-theme-core apply <slug> | bg next|prev | theme next|prev | workspace <n> | tick | menu | autostart | status | list | call <method> [<json>]']));
    return 2;
  }
  if (args.first == 'call') {
    final call = cliCallRequest(args.sublist(1));
    if (call.error != null) {
      stdout.writeln(jsonEncode({'error': call.error}));
      return 2;
    }
    return _run(core, call.method!, call.params!);
  }
  final (method, params) = switch (args) {
    ['apply', final slug] => ('themes.apply', <String, dynamic>{'slug': slug}),
    ['bg', final dir] when dir == 'next' || dir == 'prev' => ('auto.step_background', <String, dynamic>{'direction': dir == 'next' ? 1 : -1}),
    ['theme', final dir] when dir == 'next' || dir == 'prev' => ('auto.step_theme', <String, dynamic>{'direction': dir == 'next' ? 1 : -1}),
    ['workspace', final n] when int.tryParse(n) != null => ('auto.workspace', <String, dynamic>{'workspace': int.parse(n)}),
    ['tick'] => ('auto.tick', <String, dynamic>{}),
    ['menu'] => ('auto.menu', <String, dynamic>{}),
    ['autostart'] => ('presets.autostart', <String, dynamic>{}),
    ['status'] => ('core.hello', <String, dynamic>{}),
    ['list'] => ('themes.brief', <String, dynamic>{}),
    _ => ('', <String, dynamic>{}),
  };
  if (method.isEmpty) {
    stdout.writeln(jsonEncode({'error': 'bad_args'}));
    return 2;
  }
  return _run(core, method, params);
}

/// The routes `call` may reach (Maprisma Settings' workspace page and the like).
const cliCallMethods = {
  'core.hello', 'desktop.info',
  'workspaces.get', 'workspaces.set', 'workspaces.bulk', 'workspaces.looks', 'workspaces.set_look',
  'workspaces.reset', 'workspaces.apply', 'workspaces.undo',
  'tiling.style', 'tiling.style.set',
  'apppresets.launchers', 'apppresets.list', 'apppresets.add', 'apppresets.save', 'apppresets.remove',
  'apppresets.remove_all', 'apppresets.autostart', 'apppresets.restore',
  'presets.list', 'presets.save', 'presets.delete', 'presets.apply', 'presets.assign', 'presets.undo',
  'themes.list', 'wallpapers.list',
};

/// The largest `<json>` argument of `call` (bytes).
const cliCallMaxParams = 64 * 1024;

/// `call <method> [<json>]`: the method (allowed ones only) and its params (a
/// JSON object of at most [cliCallMaxParams] bytes), or the error code.
({String? method, Map<String, dynamic>? params, String? error}) cliCallRequest(List<String> args) {
  if (args.isEmpty || args.length > 2) return (method: null, params: null, error: 'bad_args');
  final method = args.first;
  if (!cliCallMethods.contains(method)) return (method: null, params: null, error: 'not_allowed');
  if (args.length == 1) return (method: method, params: <String, dynamic>{}, error: null);
  final raw = args[1];
  if (utf8.encode(raw).length > cliCallMaxParams) return (method: null, params: null, error: 'too_large');
  try {
    final v = jsonDecode(raw);
    if (v is Map<String, dynamic>) return (method: method, params: v, error: null);
  } on FormatException {
    // below
  }
  return (method: null, params: null, error: 'bad_args');
}

Future<int> _run(CoreService core, String method, Map<String, dynamic> params) async {
  try {
    stdout.writeln(jsonEncode(await core.call(method, params)));
    return 0;
  } on RouteError catch (e) {
    // A theme's key whose theme was deleted outside the app: say so and drop the key.
    if (method == 'themes.apply' && e.code == 'not_found') {
      try {
        await core.call('themes.forget', params);
      } on RouteError {
        // nothing to drop
      }
    }
    stdout.writeln(jsonEncode({'error': e.code, 'message': e.message}));
    return 1;
  } catch (e) {
    // Always JSON for the applet, never a bare stack trace.
    stdout.writeln(jsonEncode({'error': 'internal', 'message': '$e'}));
    return 1;
  }
}
