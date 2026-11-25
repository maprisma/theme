import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_theme/app.dart';
import 'package:maprisma_theme/skin.dart';
import 'package:maprisma_theme/theme.dart';
import 'package:maprisma_theme/window_style.dart';
import 'package:maprisma_theme_core/maprisma_theme_core.dart';

void main() {
  group('skin definitions and normalization', () {
    test('appSkins has exact 6 skins in order', () {
      expect(appSkins, ['native', 'synthwave', 'cozy', 'terminal', 'disco', 'zen']);
    });

    test('normalizeSkin handles valid, case/whitespace, null and unknown values', () {
      for (final s in appSkins) {
        expect(normalizeSkin(s), s);
      }
      expect(normalizeSkin(' DISCO '), 'disco');
      expect(normalizeSkin(null), 'native');
      expect(normalizeSkin(''), 'native');
      expect(normalizeSkin('unknown'), 'native');
    });

    test('skinStyle returns exact palettes for all 6 skins', () {
      expect(skinStyle('native'), isNull);
      expect(skinStyle('unknown'), isNull);

      final synthwave = skinStyle('synthwave')!;
      expect(synthwave.accent, const Color(0xffff2e93));
      expect(synthwave.borderTint, const Color(0xff00e5ff));
      expect(synthwave.bgTint, const Color(0xff3a1259));
      expect(synthwave.windowBg, const Color(0xff130924));
      expect(synthwave.foreground, const Color(0xfff4eaff));
      expect(synthwave.borderWidth, 1.5);

      final cozy = skinStyle('cozy')!;
      expect(cozy.accent, const Color(0xfff09a36));
      expect(cozy.borderTint, const Color(0xffe0822a));
      expect(cozy.bgTint, const Color(0xff593012));
      expect(cozy.windowBg, const Color(0xff21150e));
      expect(cozy.foreground, const Color(0xfff5e8d6));
      expect(cozy.borderWidth, 1.25);

      final terminal = skinStyle('terminal')!;
      expect(terminal.accent, const Color(0xff2ce868));
      expect(terminal.borderTint, const Color(0xff22c55e));
      expect(terminal.bgTint, const Color(0xff0d381a));
      expect(terminal.windowBg, const Color(0xff09130b));
      expect(terminal.foreground, const Color(0xffd2fce0));
      expect(terminal.borderWidth, 1.25);

      final disco = skinStyle('disco')!;
      expect(disco.accent, const Color(0xffd946ef));
      expect(disco.borderTint, const Color(0xfffacc15));
      expect(disco.bgTint, const Color(0xff4c1666));
      expect(disco.windowBg, const Color(0xff1c0c2b));
      expect(disco.foreground, const Color(0xfff8ecff));
      expect(disco.borderWidth, 1.5);

      final zen = skinStyle('zen')!;
      expect(zen.accent, const Color(0xff52b798));
      expect(zen.borderTint, const Color(0xff64c2a4));
      expect(zen.bgTint, const Color(0xff1e3832));
      expect(zen.windowBg, const Color(0xff141d1c));
      expect(zen.foreground, const Color(0xffe2f0ec));
      expect(zen.borderWidth, 1.0);
    });

    test('toDesktopColors produces valid 6-digit hex strings', () {
      for (final skin in appSkins.where((s) => s != 'native')) {
        final colors = skinStyle(skin)!.toDesktopColors();
        for (final key in ['background', 'foreground', 'accent', 'muted', 'selection']) {
          expect(colors[key], matches(RegExp(r'^#[0-9a-f]{6}$')), reason: '$skin.$key');
        }
      }
    });
  });

  group('applySkinToTheme and withWindowAlpha composition', () {
    test('native returns base theme untouched', () {
      final base = appTheme(Brightness.light, {'background': '#eff1f5', 'foreground': '#4c4f69', 'accent': '#1e66f5'}, 12);
      final themed = applySkinToTheme(base, 'native');
      expect(identical(themed, base), isTrue);
      expect(themed.colorScheme.surface, const Color(0xffeff1f5));
      expect(themed.extension<AppSkinExtension>(), isNull);
    });

    test('non-native skin overrides palette, Look extension, card border, and composes with withWindowAlpha', () {
      final base = appTheme(Brightness.light, {'background': '#eff1f5', 'foreground': '#4c4f69', 'accent': '#1e66f5'}, 10);
      final terminal = skinStyle('terminal')!;
      final themed = applySkinToTheme(base, 'terminal', radius: 10);

      expect(themed.brightness, Brightness.dark);
      expect(themed.colorScheme.surface, terminal.windowBg);
      expect(themed.colorScheme.onSurface, terminal.foreground);
      expect(themed.colorScheme.primary, terminal.accent);
      expect(themed.colorScheme.outlineVariant, terminal.borderTint.withValues(alpha: 0.42));
      expect(themed.extension<Look>()?.bg, terminal.windowBg);
      expect(themed.extension<Look>()?.accent, terminal.accent);
      expect(themed.extension<AppSkinExtension>()?.skin, 'terminal');

      final shape = themed.cardTheme.shape! as RoundedRectangleBorder;
      expect(shape.side.color, terminal.borderTint.withValues(alpha: 0.48));
      expect(shape.side.width, terminal.borderWidth);
      expect(themed.cardTheme.color!.a, closeTo(1.0, 0.001));

      final glassy = withWindowAlpha(themed, glassyAlpha);
      expect(glassy.scaffoldBackgroundColor.a, closeTo(glassyAlpha, 0.001));
      expect(glassy.cardTheme.color!.a, closeTo((1 + glassyAlpha) / 2, 0.001));
      expect(glassy.colorScheme.surfaceContainer.a, closeTo((1 + glassyAlpha) / 2, 0.001));
      expect(glassy.colorScheme.primary, terminal.accent);
    });
  });

  group('Settings page App skin control', () {
    late Directory root;
    late CoreService core;
    setUp(() {
      root = Directory.systemTemp.createTempSync('maprisma-skin-');
      final env = {'HOME': '${root.path}/home', 'XDG_RUNTIME_DIR': '${root.path}/run', 'PATH': '/usr/bin'};
      final paths = Paths.fromEnvironment(env, share: '${root.path}/share');
      Directory(paths.systemThemes).createSync(recursive: true);
      Directory(paths.templates).createSync(recursive: true);
      core = CoreService(environment: env, paths: paths, desktop: FakeDesktop(id: 'hyprland', name: 'Hyprland', terminalName: null));
    });
    tearDown(() => root.deleteSync(recursive: true));

    testWidgets('selecting a skin updates theme live and persists via settings.set', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final look = <String, dynamic>{
        'desktop': 'hyprland',
        'colors': {'background': '#eff1f5', 'accent': '#1e66f5', 'foreground': '#4c4f69'},
        'is_dark': false,
        'corner_radius': 12,
      };
      Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async =>
          method == 'desktop.look' ? look : core.call(method, params);

      ThemeData currentTheme() => tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 50 && !done(); i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
        }
      }

      await tester.pumpWidget(MaprismaThemeApp(call: call));
      await until(() => find.byType(MaterialApp).evaluate().isNotEmpty && currentTheme().colorScheme.surface == const Color(0xffeff1f5));
      expect(currentTheme().colorScheme.surface, const Color(0xffeff1f5));

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await until(() => find.byKey(const ValueKey('settings-skin')).evaluate().isNotEmpty);

      await tester.tap(find.byKey(const ValueKey('settings-skin')));
      await tester.pumpAndSettle();
      for (final label in ['Native', 'Synthwave', 'Cozy', 'Terminal', 'Disco', 'Zen']) {
        expect(find.text(label), findsWidgets);
      }

      await tester.tap(find.text('Cozy').last);
      await tester.pumpAndSettle();
      await until(() => currentTheme().colorScheme.surface == const Color(0xff21150e));

      expect(currentTheme().colorScheme.surface, const Color(0xff21150e));
      expect(currentTheme().colorScheme.primary, const Color(0xfff09a36));
      expect((await core.call('settings.get'))['settings']['skin'], 'cozy');

      await tester.tap(find.byKey(const ValueKey('settings-skin')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Native').last);
      await tester.pumpAndSettle();
      await until(() => currentTheme().colorScheme.surface == const Color(0xffeff1f5));

      expect(currentTheme().colorScheme.surface, const Color(0xffeff1f5));
      expect((await core.call('settings.get'))['settings']['skin'], 'native');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
