/// Choosing the desktop backend (docs/multi-desktop.md, "Selection").
library;

import 'i18n.dart';

import 'desktop.dart';
import 'desktop_cosmic.dart';
import 'desktop_hyprland.dart';
import 'desktop_kde.dart';
import 'paths.dart';
import 'shortcuts.dart';

/// The backend ids `MAPRISMA_THEME_DESKTOP` accepts.
const desktopIds = ['cosmic', 'kde', 'hyprland', 'generic'];

/// The backend for this session: `MAPRISMA_THEME_DESKTOP` when set and not
/// blank (an unknown id is an [ArgumentError], never a silent fallback; a
/// blank one counts as unset, as usual for environment variables), else the
/// first token of `XDG_CURRENT_DESKTOP` (colon list, exact tokens, any case)
/// that has a backend, else [GenericDesktop]. Never guessed from installed
/// programs.
Desktop selectDesktop(Paths paths, Map<String, String> environment) {
  final override = environment['MAPRISMA_THEME_DESKTOP']?.trim().toLowerCase();
  if (override != null && override.isNotEmpty) {
    return switch (override) {
      'cosmic' => CosmicDesktop(paths, environment),
      'kde' => KdeDesktop(paths, environment),
      'hyprland' => HyprlandDesktop(paths, environment),
      'generic' => GenericDesktop(paths, environment),
      _ => throw ArgumentError.value(override, 'MAPRISMA_THEME_DESKTOP', trf("one of {0}", [desktopIds.join(', ')])),
    };
  }
  for (final token in (environment['XDG_CURRENT_DESKTOP'] ?? '').split(':')) {
    switch (token.trim().toUpperCase()) {
      case 'COSMIC':
        return CosmicDesktop(paths, environment);
      case 'KDE':
        return KdeDesktop(paths, environment);
      case 'HYPRLAND':
        return HyprlandDesktop(paths, environment);
    }
  }
  return GenericDesktop(paths, environment);
}

/// A desktop Maprisma Theme has no backend for: nothing of the desktop is
/// changed (every cap missing); themes, wallpapers files and the app
/// templates still work. RON files are still read through the helper.
final class GenericDesktop extends DesktopBase {
  GenericDesktop(super.paths, super.environment);

  @override
  String get id => 'generic';
  @override
  String get name => tr("your desktop");
  @override
  String? get terminalName => null;
  @override
  Set<Cap> get caps => const {};

  @override
  Future<bool> applyColors(Map<String, String> colors) async => false;
  @override
  Future<bool> applyRon(String path) async => false;
  @override
  Future<bool> applyKdeScheme(String path, {String? foreground}) async => false;
  @override
  Future<Map<String, dynamic>?> current() async => null;
  @override
  Future<bool> setWallpaper(String path) async => false;
  @override
  String? wallpaper() => null;
  @override
  Future<Object?> snapshotBackground() async => null;
  @override
  Future<bool> restoreBackground(Object? snapshot) async => false;
  @override
  Future<bool> setTerminal(Map<String, String> colors, String name) async => false;
  @override
  String? monospaceFont() => null;
  @override
  Future<bool> setMonospaceFont(String family) async => false;
  @override
  Future<bool> resetMonospaceFont() async => false;
  @override
  String? interfaceFont() => null;
  @override
  Future<bool> setInterfaceFont(String family) async => false;
  @override
  Future<bool> resetInterfaceFont() async => false;
  @override
  String? iconTheme() => null;
  @override
  Future<bool> setIconTheme(String name) async => false;
  @override
  Future<Map<String, dynamic>?> wm(List<String> args, {Duration timeout = const Duration(seconds: 20)}) async => wmNotAvailable(name);
  @override
  ShortcutBinder? shortcutBinder(Paths paths) => null;
  @override
  Stream<Map<String, dynamic>>? watch() => null;
  @override
  Future<Map<String, dynamic>> health(Paths paths, Map<String, String> environment) async => const {};
}
