import 'dart:io';

import 'translations.g.dart';

const languageNames = <String, String>{
  'en': 'English', 'de': 'Deutsch', 'fr': 'Français', 'es': 'Español',
  'it': 'Italiano', 'pt': 'Português', 'nl': 'Nederlands', 'pl': 'Polski',
};

String systemLanguage([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  for (final variable in ['LC_ALL', 'LC_MESSAGES', 'LANG']) {
    final value = env[variable] ?? '';
    if (value.isEmpty) continue;
    final code = value.toLowerCase().split(RegExp(r'[_\-.@]')).first;
    return languageNames.containsKey(code) ? code : 'en';
  }
  return 'en';
}

String languageSetting = 'auto';

/// The core's supplied environment; null in the Flutter UI isolate.
Map<String, String>? languageEnvironment;
String get currentLanguage => languageNames.containsKey(languageSetting)
    ? languageSetting : systemLanguage(languageEnvironment);
String tr(String english) {
  final translated = translationCatalogs[currentLanguage]?[english];
  return translated == null || translated.isEmpty ? english : translated;
}
String trf(String english, List<Object?> values) => tr(english).replaceAllMapped(
    RegExp(r'\{(\d+)\}'), (match) {
      final index = int.parse(match[1]!);
      return index < values.length ? '${values[index]}' : match[0]!;
    });
