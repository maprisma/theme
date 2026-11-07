import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('cosmic-bg source is replaced whole: colors, gradients, paths', () {
    const color = '(\n    output: "all",\n    source: Color(Single((0.1, 0.2, 0.3))),\n    filter_by_theme: true,\n)';
    const gradient = '(\n    source: Color(Gradient((colors: [(0.1,0.2,0.3), (0.4,0.5,0.6)], radius: 270.0))),\n    x: 1,\n)';
    const path = '(\n    source: Path("/a \\"b\\".png"),\n)';
    expect(replaceRonValue(color, 'source', 'Path("/x.png")'),
        '(\n    output: "all",\n    source: Path("/x.png"),\n    filter_by_theme: true,\n)');
    expect(replaceRonValue(gradient, 'source', 'Path("/x.png")'), '(\n    source: Path("/x.png"),\n    x: 1,\n)');
    expect(replaceRonValue(path, 'source', 'Path("/x.png")'), '(\n    source: Path("/x.png"),\n)');
    expect(replaceRonValue('(source: Path("/a.png"', 'source', 'Path("/x")'), isNull);
  });

  test('COSMIC default monospace font comes back after a themed font', () async {
    final env = TestEnv.create();
    addTearDown(env.dispose);
    env.addTheme('fonty');
    File('${env.paths.userThemes}/fonty/theme-manager.json').writeAsStringSync('{"font": "Fira Code"}');
    env.addTheme('plain');
    expect(env.desktop.monospaceFont(), isNull); // COSMIC default, no config entry
    await env.core.call('themes.apply', {'slug': 'fonty'});
    expect(env.desktop.monospaceFont(), 'Fira Code');
    await env.core.call('themes.apply', {'slug': 'plain'});
    expect(env.desktop.monospaceFont(), isNull);
    expect(env.desktop.calls, contains('font reset'));
  });

  test('CLI prints JSON for unexpected failures too', () async {
    final env = TestEnv.create();
    addTearDown(env.dispose);
    expect(await runCli(['bg', 'sideways'], service: env.core), 2);
  });
}
