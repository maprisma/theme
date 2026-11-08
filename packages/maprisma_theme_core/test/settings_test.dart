import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('header buttons in the plugin order; reset brings back the order and the screenshot folder', () async {
    final env = TestEnv.create();
    addTearDown(env.dispose);
    final first = await env.core.call('settings.get', {});
    expect(first['settings']['header_order'], ['import', 'hidden', 'presets', 'ask', 'info']);
    await env.core.call('settings.set', {'key': 'header_order', 'value': ['info', 'ask', 'import', 'hidden', 'presets']});
    await env.core.call('settings.set', {'key': 'screenshot_dir', 'value': '${env.paths.home}/Shots'});
    await env.core.call('settings.set', {'key': 'ask_ai', 'value': true});
    final reset = await env.core.call('settings.reset', {});
    expect(reset['settings']['header_order'], ['import', 'hidden', 'presets', 'ask', 'info']);
    expect(reset['settings']['screenshot_dir'], isNull);
    expect(reset['settings']['ask_ai'], isTrue);
  });
}
