import 'dart:io';

import 'package:maprisma_theme_core/maprisma_theme_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('colors', () {
    test('parses colors.toml and derives like omarchy-theme-color', () {
      final raw = parseColorsToml('mode = "dark"\nbackground = "#2e3440" # c\nforeground = \'#d8dee9\'\nred = "#bf616a"\n[x]\n');
      expect(raw, {'mode': 'dark', 'background': '#2e3440', 'foreground': '#d8dee9', 'red': '#bf616a'});
      final c = resolveColors(raw);
      expect(c['bright_red'], mixColor('#bf616a', '#ffffff', 0.2));
      expect(c['dark_background'], mixColor('#2e3440', '#000000', 0.25));
      expect(c['color1'], '#bf616a');
      expect(c['theme_type'], 'dark');
    });
    test('mode from the background when missing', () {
      expect(resolveColors({'background': '#eff1f5'})['mode'], 'light');
      expect(resolveColors({'background': '#101010'})['mode'], 'dark');
    });
    test('templates render tokens, strips, rgb and mixes', () {
      final c = resolveColors({'background': '#000000', 'foreground': '#ffffff'});
      expect(renderTemplate('{{ background }} {{ foreground_strip }} {{ background_rgb }} {{ mix background foreground 50% }}', c),
          '#000000 ffffff 0,0,0 #808080');
      expect(renderTemplate('{{ nope }}', c), isNull);
    });
    test('colors.toml round trip keeps hex keys', () {
      final text = writeColorsToml({'mode': 'light', 'background': '#FFFFFF', 'accent': '#123456'});
      expect(parseColorsToml(text), {'mode': 'light', 'accent': '#123456', 'background': '#ffffff'});
    });
  });

  group('themes', () {
    late TestEnv env;
    setUp(() => env = TestEnv.create());
    tearDown(() => env.dispose());

    test('user copy wins over system theme; favorites first', () async {
      env.addTheme('nord', system: true);
      env.addTheme('nord', bg: '#000000');
      env.addTheme('alpha', system: true);
      env.addTheme('zeta');
      await env.core.call('themes.favorite', {'slug': 'zeta', 'favorite': true});
      final list = (await env.core.call('themes.list'))['themes'] as List;
      expect(list.map((t) => t['slug']), ['zeta', 'alpha', 'nord']);
      final nord = list.firstWhere((t) => t['slug'] == 'nord');
      expect(nord['scope'], 'user');
      expect(nord['colors']['background'], '#000000');
    });

    test('apply sets COSMIC, wallpaper, terminal, current and recent; unhides', () async {
      env.addTheme('nord', system: true, wallpapers: ['b.png', 'a.png']);
      await env.core.call('themes.hide', {'slug': 'nord', 'hidden': true});
      final r = await env.core.call('themes.apply', {'slug': 'nord'});
      expect(r['done'], containsAll(['cosmic', 'wallpaper', 'terminal']));
      expect(env.desktop.lastColors!['background'], '#2e3440');
      expect(env.desktop.wallpaper(), endsWith('/a.png'));
      expect(Current(env.paths).slug, 'nord');
      expect(Lists(env.paths).hidden, isNot(contains('nord')));
      expect(Lists(env.paths).recent.keys, contains('nord'));
    });

    test('hidden wallpapers are skipped for the start wallpaper', () async {
      env.addTheme('nord', system: true, wallpapers: ['a.png', 'b.png']);
      saveHiddenWallpapers(env.paths, {'nord': {'a.png'}});
      await env.core.call('themes.apply', {'slug': 'nord'});
      expect(env.desktop.wallpaper(), endsWith('/b.png'));
    });

    test('a theme font is applied and the own font restored after', () async {
      env.addTheme('fonty');
      File('${env.paths.userThemes}/fonty/theme-manager.json').writeAsStringSync('{"font": "Fira Code"}');
      env.addTheme('plain');
      await env.desktop.setMonospaceFont('JetBrains Mono');
      await env.core.call('themes.apply', {'slug': 'fonty'});
      expect(env.desktop.monospaceFont(), 'Fira Code');
      await env.core.call('themes.apply', {'slug': 'plain'});
      expect(env.desktop.monospaceFont(), 'JetBrains Mono');
    });

    test('unknown routes and bad slugs are refused', () async {
      expect(await env.core.handleAsync('{"id":1,"protocol":1,"method":"nope"}'), contains('unknown_route'));
      expect(await env.core.handleAsync('{"id":2,"protocol":1,"method":"themes.apply","params":{"slug":"../x"}}'),
          contains('not_found'));
    });
  });
}
