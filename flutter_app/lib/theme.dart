import 'dart:math';

import 'package:flutter/material.dart';

Color? hexColor(Map colors, String key) {
  final value = colors[key];
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return null;
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}

/// The corner radius in effect (Settings › Corners; the desktop's windows), in Maprisma
/// Playground's three sizes: the window, cards, dialogs, pop-ups and menus take [radius]; buttons,
/// choice boxes, fields, tooltips and key caps [control] (at most 8); check boxes, slider tracks,
/// progress bars, colour swatches and small marks [small] (at most 4). Square squares everything,
/// the slider knob stays small (see [KnobShape]).
class Corners extends ThemeExtension<Corners> {
  const Corners(this.radius);
  final double radius;
  double get control => min(radius, 8);
  double get small => min(radius, 4);
  @override
  Corners copyWith({double? radius}) => Corners(radius ?? this.radius);
  @override
  Corners lerp(Corners? other, double t) => other ?? this;
}

/// The marks' colours: running (green), update (orange), new (yellow),
/// from the desktop's palette.
class MarkColors extends ThemeExtension<MarkColors> {
  const MarkColors({required this.running, required this.update, required this.fresh});
  final Color running, update, fresh;
  @override
  MarkColors copyWith({Color? running, Color? update, Color? fresh}) =>
      MarkColors(running: running ?? this.running, update: update ?? this.update, fresh: fresh ?? this.fresh);
  @override
  MarkColors lerp(MarkColors? other, double t) => other ?? this;
}

MarkColors markColors(BuildContext context) =>
    Theme.of(context).extension<MarkColors>() ??
    const MarkColors(running: Color(0xff3a944a), update: Color(0xffed5b00), fresh: Color(0xffc88800));

/// The plugin's palette (theme_popup.py apply_theme_css): background, text,
/// accent, muted hints, the dimmer settings labels, the selection and the
/// text on it, red for destructive entries.
class Look extends ThemeExtension<Look> {
  const Look({
    required this.bg,
    required this.fg,
    required this.accent,
    required this.muted,
    required this.dim,
    required this.selection,
    required this.selectionFg,
    required this.red,
  });
  final Color bg, fg, accent, muted, dim, selection, selectionFg, red;
  @override
  Look copyWith() => this;
  @override
  Look lerp(Look? other, double t) => other ?? this;

  static Look of(BuildContext context) =>
      Theme.of(context).extension<Look>() ?? _fallback(Theme.of(context).colorScheme);

  static Look _fallback(ColorScheme s) => Look(
    bg: s.surface,
    fg: s.onSurface,
    accent: s.primary,
    muted: s.onSurfaceVariant,
    dim: s.onSurfaceVariant,
    selection: s.secondaryContainer,
    selectionFg: s.onSecondaryContainer,
    red: s.error,
  );
}

double _lum(Color c) => .2126 * c.r + .7152 * c.g + .0722 * c.b;

/// Qt.darker(foreground, 1.45): the HSV value divided by 1.45.
Color _darker(Color c) {
  final hsv = HSVColor.fromColor(c);
  return hsv.withValue(hsv.value / 1.45).toColor();
}

/// A text role's size and weight without its colour: the text keeps the colour around it (a
/// button's, a chip's, a selected row's).
TextStyle textRole(TextStyle? role) =>
    TextStyle(fontSize: role?.fontSize, fontWeight: role?.fontWeight, letterSpacing: role?.letterSpacing, height: role?.height);

double corners(BuildContext context) => Theme.of(context).extension<Corners>()?.radius ?? 12;

/// Settings › Corners in its three sizes (see [Corners]).
Corners cornerSizes(BuildContext context) => Theme.of(context).extension<Corners>() ?? const Corners(12);

/// "windows" follows the desktop's window corners, "slight" 6 (round controls beside square or
/// tiled windows), "rounded" 12, "square" 0.
const slightRadius = 6, roundedRadius = 12;
double cornerRadius(String setting, int? windowRounding) => switch (setting) {
  'slight' => 6,
  'rounded' => 12,
  'square' => 0,
  _ => (windowRounding ?? 12).toDouble(),
};

/// The desktop's palette (desktop.look colors) as a Material theme; an
/// empty palette (generic desktops) follows the platform's light or dark.
ThemeData appTheme(Brightness platform, Map colors, double radius) {
  final background = hexColor(colors, 'background');
  final brightness = background == null
      ? platform
      : (background.computeLuminance() < .5 ? Brightness.dark : Brightness.light);
  var scheme = ColorScheme.fromSeed(
    seedColor: hexColor(colors, 'accent') ?? const Color(0xff3584e4),
    brightness: brightness,
  );
  if (background != null) {
    final foreground = hexColor(colors, 'foreground') ?? scheme.onSurface;
    Color step(double amount) => Color.lerp(background, foreground, amount)!;
    final accent = hexColor(colors, 'accent');
    scheme = scheme.copyWith(
      primary: accent ?? scheme.primary,
      // Text on the accent: black on a light one, else white.
      onPrimary: accent == null ? null : (accent.computeLuminance() > .4 ? Colors.black : Colors.white),
      surface: background,
      onSurface: foreground,
      onSurfaceVariant: hexColor(colors, 'muted') == null
          ? step(.6)
          : Color.lerp(hexColor(colors, 'muted'), foreground, .35),
      surfaceContainerLowest: step(.02),
      surfaceContainerLow: step(.05),
      surfaceContainer: step(.08),
      surfaceContainerHigh: step(.11),
      surfaceContainerHighest: step(.14),
      outlineVariant: step(.18),
      secondaryContainer: hexColor(colors, 'selection') ?? step(.2),
      error: hexColor(colors, 'red') ?? scheme.error,
      onError: hexColor(colors, 'red') == null ? null : (hexColor(colors, 'red')!.computeLuminance() > .4 ? Colors.black : Colors.white),
    );
  }
  final bg = scheme.surface, fg = scheme.onSurface, accent = scheme.primary;
  final sel = hexColor(colors, 'selection') ?? Color.lerp(bg, fg, .2)!;
  final look = Look(
    bg: bg,
    fg: fg,
    accent: accent,
    muted: hexColor(colors, 'muted') ?? Color.lerp(bg, fg, .55)!,
    dim: _darker(fg),
    selection: sel,
    selectionFg: (_lum(sel) - _lum(fg)).abs() < .25 ? (_lum(sel) <= .45 ? Colors.white : bg) : fg,
    red: hexColor(colors, 'red') ?? scheme.error,
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radius),
    side: BorderSide(color: accent),
  );
  final sizes = Corners(radius);
  final control = sizes.control, small = sizes.small;
  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(control));
  // The text roles' sizes (Material 3), for the theme's own styles.
  final type = Typography.material2021().englishLike;
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
    hoverColor: fg.withValues(alpha: .06),
    focusColor: sel.withValues(alpha: .5),
    tooltipTheme: TooltipThemeData(
      textStyle: TextStyle(color: fg, fontSize: type.bodySmall!.fontSize),
      decoration: BoxDecoration(
        color: Color.lerp(bg, fg, .1),
        border: Border.all(color: fg.withValues(alpha: .2)),
        borderRadius: BorderRadius.circular(control),
      ),
      waitDuration: const Duration(milliseconds: 500),
    ),
    extensions: [
      look,
      sizes,
      MarkColors(
        running: hexColor(colors, 'green') ?? const Color(0xff3a944a),
        update: hexColor(colors, 'orange') ?? const Color(0xffed5b00),
        fresh: hexColor(colors, 'yellow') ?? const Color(0xffc88800),
      ),
    ],
    // .tm-tile / .tm-group-card: a faint mat and hairline.
    cardTheme: CardThemeData(
      color: fg.withValues(alpha: .03),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: fg.withValues(alpha: .16)),
      ),
    ),
    // Confirmations as the plugin's in-card dialog: background, accent border.
    dialogTheme: DialogThemeData(shape: shape, backgroundColor: bg, elevation: 8),
    // popover.tm-popover: background, accent border, the card's corners.
    popupMenuTheme: PopupMenuThemeData(
      color: bg,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black54,
      menuPadding: const EdgeInsets.all(4),
      textStyle: TextStyle(fontSize: type.bodyMedium!.fontSize, fontWeight: FontWeight.w500, color: fg),
      shape: shape,
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(backgroundColor: WidgetStatePropertyAll(bg), shape: WidgetStatePropertyAll(shape)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(backgroundColor: WidgetStatePropertyAll(bg), shape: WidgetStatePropertyAll(shape)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      hintStyle: TextStyle(color: look.muted, fontSize: type.bodyMedium!.fontSize),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(control),
        borderSide: BorderSide(color: fg.withValues(alpha: .25)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(control),
        borderSide: BorderSide(color: fg.withValues(alpha: .25)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(control),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(control),
        borderSide: BorderSide(color: look.red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(control),
        borderSide: BorderSide(color: look.red, width: 1.5),
      ),
    ),
    // .tm-undo: the selection colour, accent border, floating over the bottom.
    snackBarTheme: SnackBarThemeData(
      backgroundColor: sel,
      contentTextStyle: TextStyle(color: look.selectionFg, fontSize: type.bodyMedium!.fontSize),
      actionTextColor: look.selectionFg,
      behavior: SnackBarBehavior.floating,
      insetPadding: const EdgeInsets.all(16),
      shape: shape,
    ),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(small))),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      borderRadius: BorderRadius.circular(small),
      linearTrackColor: fg.withValues(alpha: .10),
    ),
    // Square squares the slider too, but keeps its knob small (no block).
    sliderTheme: SliderThemeData(
      trackShape: radius <= 0 ? const RectangularSliderTrackShape() : const RoundedRectSliderTrackShape(),
      thumbShape: KnobShape(square: radius <= 0),
    ),
    chipTheme: ChipThemeData(shape: controlShape),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(controlShape)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: controlShape)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: controlShape)),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : fg.withValues(alpha: .15)),
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? bg : fg.withValues(alpha: .7)),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: fg,
        iconColor: accent,
        side: BorderSide(color: fg.withValues(alpha: .25)),
        shape: controlShape,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: const Size(0, 32),
        textStyle: Typography.material2021().black.labelLarge!.copyWith(fontSize: type.labelLarge!.fontSize, fontWeight: FontWeight.w500),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        shape: controlShape,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        padding: const EdgeInsets.all(4),
        minimumSize: const Size(28, 28),
        iconSize: 18,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: controlShape,
      ),
    ),
    dividerTheme: DividerThemeData(color: fg.withValues(alpha: .12), space: 1, thickness: 1),
  );
}

/// The slider's knob: 14 px, round, or square with Square corners (not a big block).
class KnobShape extends SliderComponentShape {
  const KnobShape({this.square = false});
  final bool square;
  static const _side = 14.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size.square(_side);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final paint = Paint()..color = sliderTheme.thumbColor ?? Colors.grey;
    final box = Rect.fromCenter(center: center, width: _side, height: _side);
    square ? context.canvas.drawRect(box, paint) : context.canvas.drawOval(box, paint);
  }
}
