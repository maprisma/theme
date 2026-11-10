import 'package:maprisma_theme_core/src/i18n.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  tearDown(() {
    languageSetting = 'auto';
    languageEnvironment = null;
  });

  test('first nonempty locale wins, with unknown locales falling back to English', () {
    expect(systemLanguage({}), 'en');
    expect(systemLanguage({'LC_ALL': '', 'LC_MESSAGES': '', 'LANG': 'pl_PL.UTF-8'}), 'pl');
    expect(systemLanguage({'LC_ALL': 'de_DE.UTF-8', 'LC_MESSAGES': 'fr_FR', 'LANG': 'es_ES'}), 'de');
    expect(systemLanguage({'LC_ALL': '', 'LC_MESSAGES': 'pt-BR.UTF-8', 'LANG': 'nl_NL'}), 'pt');
    expect(systemLanguage({'LC_ALL': 'unknown', 'LANG': 'fr_FR'}), 'en');
    expect(systemLanguage({'LC_ALL': 'C.UTF-8', 'LANG': 'fr_FR'}), 'en');
    expect(systemLanguage({'LC_ALL': 'POSIX', 'LANG': 'fr_FR'}), 'en');
    for (final code in languageNames.keys) {
      expect(systemLanguage({'LANG': '${code.toUpperCase()}_XX.UTF-8@variant'}), code);
    }
  });

  test('English fallback and values remain literal, including placeholder syntax', () {
    languageSetting = 'de';
    expect(tr('A deliberately uncataloged message'), 'A deliberately uncataloged message');
    expect(tr('Language'), 'Sprache');
    expect(trf('Failed: {0}', ['Theme {1}']), 'Fehlgeschlagen: Theme {1}');
    expect(trf('Missing {5}', ['x']), 'Missing {5}');
    languageSetting = 'en';
    expect(tr('Language'), 'Language');
  });

  test('language persists in app settings, survives reset and changes menu immediately', () async {
    final env = TestEnv.create();
    addTearDown(env.dispose);
    expect((await env.core.call('settings.get'))['settings']['language'], 'auto');
    await env.core.call('settings.set', {'key': 'language', 'value': 'de'});
    expect(env.core.ctx.settings.load()['language'], 'de');
    final dataSettings = (await env.core.call('settings.get'))['settings'];
    expect(dataSettings['header_order'], ['import', 'hidden', 'presets', 'ask', 'info']);
    env.addTheme('english-theme-name', system: true);
    final theme = ((await env.core.call('themes.list'))['themes'] as List).single;
    expect(theme['name'], 'English Theme Name');
    expect(theme['scope'], 'system');
    expect((await env.core.call('auto.menu'))['title'], tr('Recently used'));
    expect(languageSetting, 'de');
    await env.core.call('settings.reset');
    expect(env.core.ctx.settings.load()['language'], 'de');
    await env.core.call('settings.set', {'key': 'language', 'value': 'en'});
    expect((await env.core.call('auto.menu'))['items'][1]['label'], 'Open Maprisma Theme');
    env.core.ctx.environment['LC_MESSAGES'] = 'fr_FR.UTF-8';
    await env.core.call('settings.set', {'key': 'language', 'value': 'auto'});
    await env.core.call('auto.menu');
    expect(currentLanguage, 'fr');
    await expectLater(env.core.call('settings.set', {'key': 'language', 'value': 'xx'}), throwsA(isA<Exception>()));
  });
}
