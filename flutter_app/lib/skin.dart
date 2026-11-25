import 'dart:math';

import 'package:flutter/material.dart';

import 'theme.dart';

const String skinKey = 'skin';

const List<String> appSkins = [
  'native',
  'synthwave',
  'cozy',
  'terminal',
  'disco',
  'zen',
];

class AppSkinStyle {
  const AppSkinStyle({
    required this.accent,
    required this.borderTint,
    required this.bgTint,
    required this.windowBg,
    required this.foreground,
    required this.borderWidth,
  });

  final Color accent;
  final Color borderTint;
  final Color bgTint;
  final Color windowBg;
  final Color foreground;
  final double borderWidth;

  Map<String, String> toDesktopColors() => {
    'background': _hex(windowBg),
    'foreground': _hex(foreground),
    'accent': _hex(accent),
    'muted': _hex(Color.lerp(windowBg, foreground, 0.55)!),
    'selection': _hex(Color.alphaBlend(accent.withValues(alpha: 0.28), windowBg)),
  };
}

class AppSkinExtension extends ThemeExtension<AppSkinExtension> {
  const AppSkinExtension({required this.skin, this.style});

  final String skin;
  final AppSkinStyle? style;

  @override
  AppSkinExtension copyWith({String? skin, AppSkinStyle? style}) =>
      AppSkinExtension(skin: skin ?? this.skin, style: style ?? this.style);

  @override
  AppSkinExtension lerp(AppSkinExtension? other, double t) => other ?? this;
}

AppSkinStyle? activeSkinStyle(BuildContext context) =>
    Theme.of(context).extension<AppSkinExtension>()?.style;

String normalizeSkin(String? raw) {
  final value = raw?.trim().toLowerCase();
  return value != null && appSkins.contains(value) ? value : 'native';
}

AppSkinStyle? skinStyle(String? skin) => switch (normalizeSkin(skin)) {
  'synthwave' => const AppSkinStyle(
    accent: Color(0xffff2e93),
    borderTint: Color(0xff00e5ff),
    bgTint: Color(0xff3a1259),
    windowBg: Color(0xff130924),
    foreground: Color(0xfff4eaff),
    borderWidth: 1.5,
  ),
  'cozy' => const AppSkinStyle(
    accent: Color(0xfff09a36),
    borderTint: Color(0xffe0822a),
    bgTint: Color(0xff593012),
    windowBg: Color(0xff21150e),
    foreground: Color(0xfff5e8d6),
    borderWidth: 1.25,
  ),
  'terminal' => const AppSkinStyle(
    accent: Color(0xff2ce868),
    borderTint: Color(0xff22c55e),
    bgTint: Color(0xff0d381a),
    windowBg: Color(0xff09130b),
    foreground: Color(0xffd2fce0),
    borderWidth: 1.25,
  ),
  'disco' => const AppSkinStyle(
    accent: Color(0xffd946ef),
    borderTint: Color(0xfffacc15),
    bgTint: Color(0xff4c1666),
    windowBg: Color(0xff1c0c2b),
    foreground: Color(0xfff8ecff),
    borderWidth: 1.5,
  ),
  'zen' => const AppSkinStyle(
    accent: Color(0xff52b798),
    borderTint: Color(0xff64c2a4),
    bgTint: Color(0xff1e3832),
    windowBg: Color(0xff141d1c),
    foreground: Color(0xffe2f0ec),
    borderWidth: 1.0,
  ),
  _ => null,
};

String skinLabel(String skin, String Function(String) tr) => switch (normalizeSkin(skin)) {
  'synthwave' => tr('Synthwave'),
  'cozy' => tr('Cozy'),
  'terminal' => tr('Terminal'),
  'disco' => tr('Disco'),
  'zen' => tr('Zen'),
  _ => tr('Native'),
};

double _lum(Color c) => .2126 * c.r + .7152 * c.g + .0722 * c.b;

Color _darker(Color c) {
  final hsv = HSVColor.fromColor(c);
  return hsv.withValue(hsv.value / 1.45).toColor();
}

ThemeData applySkinToTheme(ThemeData base, String? skin, {double? radius}) {
  final normalized = normalizeSkin(skin);
  final st = skinStyle(normalized);
  if (st == null) return base;

  final r = radius ?? base.extension<Corners>()?.radius ?? 12.0;
  final control = base.extension<Corners>()?.control ?? min(r, 8.0);
  final surfaceLow = Color.alphaBlend(st.bgTint.withValues(alpha: 0.22), st.windowBg);
  final surfaceContainer = Color.alphaBlend(st.bgTint.withValues(alpha: 0.28), st.windowBg);
  final surfaceHigh = Color.alphaBlend(st.bgTint.withValues(alpha: 0.36), st.windowBg);
  final surfaceHighest = Color.lerp(surfaceHigh, st.foreground, 0.08)!;
  final outlineVariant = st.borderTint.withValues(alpha: 0.42);
  final selection = Color.alphaBlend(st.accent.withValues(alpha: 0.28), st.windowBg);

  final scheme = ColorScheme.fromSeed(
    seedColor: st.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: st.accent,
    onPrimary: st.accent.computeLuminance() > 0.4 ? Colors.black : Colors.white,
    surface: st.windowBg,
    onSurface: st.foreground,
    onSurfaceVariant: Color.lerp(st.windowBg, st.foreground, 0.65)!,
    surfaceContainerLowest: Color.lerp(st.windowBg, st.bgTint, 0.14)!,
    surfaceContainerLow: surfaceLow,
    surfaceContainer: surfaceContainer,
    surfaceContainerHigh: surfaceHigh,
    surfaceContainerHighest: surfaceHighest,
    outline: st.borderTint.withValues(alpha: 0.56),
    outlineVariant: outlineVariant,
    secondaryContainer: selection,
    onSecondaryContainer: st.foreground,
    error: base.colorScheme.error,
  );

  final existingLook = base.extension<Look>();
  final skinLook = Look(
    bg: st.windowBg,
    fg: st.foreground,
    accent: st.accent,
    muted: Color.lerp(st.windowBg, st.foreground, 0.55)!,
    dim: _darker(st.foreground),
    selection: selection,
    selectionFg: (_lum(selection) - _lum(st.foreground)).abs() < .25
        ? (_lum(selection) <= .45 ? Colors.white : st.windowBg)
        : st.foreground,
    red: existingLook?.red ?? scheme.error,
  );

  final cardColor = Color.alphaBlend(st.bgTint.withValues(alpha: 0.28), st.windowBg);
  final cardBorder = BorderSide(
    color: st.borderTint.withValues(alpha: 0.48),
    width: st.borderWidth,
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(r),
    side: BorderSide(color: st.borderTint.withValues(alpha: 0.48)),
  );
  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(control));
  final menuStyle = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
    shape: WidgetStatePropertyAll(shape),
  );
  final extensions = base.extensions.values
      .where((ext) => ext is! AppSkinExtension && ext is! Look)
      .followedBy([skinLook, AppSkinExtension(skin: normalized, style: st)]);

  return base.copyWith(
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    hoverColor: st.foreground.withValues(alpha: 0.06),
    focusColor: selection.withValues(alpha: 0.5),
    extensions: extensions,
    cardTheme: base.cardTheme.copyWith(
      color: cardColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(r),
        side: cardBorder,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Color.alphaBlend(st.accent.withValues(alpha: 0.18), st.windowBg),
      selectedColor: Color.alphaBlend(st.accent.withValues(alpha: 0.30), st.windowBg),
      side: BorderSide(color: st.borderTint.withValues(alpha: 0.48)),
      shape: controlShape,
      labelStyle: TextStyle(color: st.foreground),
    ),
    dividerTheme: base.dividerTheme.copyWith(
      color: outlineVariant,
      thickness: 1,
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: shape,
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      color: scheme.surfaceContainerHigh,
      shape: shape,
    ),
    menuTheme: MenuThemeData(style: menuStyle),
    dropdownMenuTheme: base.dropdownMenuTheme.copyWith(
      menuStyle: menuStyle,
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: selection,
      contentTextStyle: (base.snackBarTheme.contentTextStyle ?? const TextStyle()).copyWith(
        color: skinLook.selectionFg,
      ),
      actionTextColor: skinLook.selectionFg,
      shape: shape,
    ),
    tooltipTheme: base.tooltipTheme.copyWith(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(control),
        border: Border.all(color: scheme.outlineVariant),
      ),
      textStyle: (base.tooltipTheme.textStyle ?? const TextStyle(fontSize: 13)).copyWith(
        color: scheme.onSurface,
      ),
    ),
  );
}

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}';
