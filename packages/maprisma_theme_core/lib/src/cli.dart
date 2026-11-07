import 'dart:convert';
import 'dart:io';

import 'context.dart';
import 'core.dart';

/// `maprisma-theme-core <command> [args]` for the panel applet and keyboard
/// shortcuts (docs/cosmic-interface.md). Prints one JSON object.
Future<int> runCli(List<String> args, {CoreService? service}) async {
  final core = service ?? CoreService(environment: Platform.environment);
  if (args.isEmpty) {
    stderr.writeln('usage: maprisma-theme-core apply <slug> | bg next|prev | theme next|prev | workspace <n> | tick | menu | autostart | status');
    return 2;
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
    _ => ('', <String, dynamic>{}),
  };
  if (method.isEmpty) {
    stdout.writeln(jsonEncode({'error': 'bad_args'}));
    return 2;
  }
  try {
    stdout.writeln(jsonEncode(await core.call(method, params)));
    return 0;
  } on RouteError catch (e) {
    stdout.writeln(jsonEncode({'error': e.code, 'message': e.message}));
    return 1;
  }
}
