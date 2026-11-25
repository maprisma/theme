import 'dart:convert';
import 'dart:io';

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

  test('window_position: [x, y] (may be negative) is kept, also by reset; broken values are refused', () async {
    final env = TestEnv.create();
    addTearDown(env.dispose);
    expect((await env.core.call('settings.get', {}))['settings']['window_position'], isNull);
    await env.core.call('settings.set', {'key': 'window_position', 'value': [-20, 42]});
    expect((await env.core.call('settings.get', {}))['settings']['window_position'], [-20, 42]);
    for (final broken in [[1], [1.5, 2], [200000, 2], 'left']) {
      await expectLater(env.core.call('settings.set', {'key': 'window_position', 'value': broken}), throwsA(anything));
    }
    final reset = await env.core.call('settings.reset', {});
    expect(reset['settings']['window_position'], [-20, 42]);
  });

  test('skin defaults to native, persists non-native values, omits native on save, rejects invalid, and resets to native', () async {
    final env = TestEnv.create();
    addTearDown(env.dispose);

    expect((await env.core.call('settings.get', {}))['settings']['skin'], 'native');

    for (final skin in ['synthwave', 'cozy', 'terminal', 'disco', 'zen']) {
      final res = await env.core.call('settings.set', {'key': 'skin', 'value': skin});
      expect(res['settings']['skin'], skin);
      final raw = jsonDecode(File(env.paths.settingsFile).readAsStringSync()) as Map;
      expect(raw['skin'], skin);
    }

    final nativeRes = await env.core.call('settings.set', {'key': 'skin', 'value': 'native'});
    expect(nativeRes['settings']['skin'], 'native');
    final rawNative = jsonDecode(File(env.paths.settingsFile).readAsStringSync()) as Map;
    expect(rawNative.containsKey('skin'), isFalse);

    await expectLater(
      env.core.call('settings.set', {'key': 'skin', 'value': 'neon'}),
      throwsA(anything),
    );

    await env.core.call('settings.set', {'key': 'skin', 'value': 'disco'});
    final reset = await env.core.call('settings.reset', {});
    expect(reset['settings']['skin'], 'native');
  });
}
