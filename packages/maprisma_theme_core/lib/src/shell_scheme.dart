/// Maprisma Shell's colour scheme (scheme.json, Hyprland's scheme/current.lua)
/// from a theme's colours object, in plain code: the theme's own surfaces,
/// text and terminal colours, and the Material-style roles (onPrimary,
/// containers, fixed tones, …) mixed from them with a readable contrast.
library;

import 'colors.dart';

/// The terminal colour keys of a colours object, in ANSI order (term0..term15).
const shellTermKeys = [
  'black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white',
  'bright_black', 'bright_red', 'bright_green', 'bright_yellow',
  'bright_blue', 'bright_magenta', 'bright_cyan', 'bright_white',
];

/// For a theme without some terminal colour (term1..term6).
const _ansiDefaults = {
  'red': '#e06c75', 'green': '#98c379', 'yellow': '#e5c07b',
  'blue': '#61afef', 'magenta': '#c678dd', 'cyan': '#56b6c2',
};

const _black = '#000000', _white = '#ffffff';

String? _hex(String? v) {
  if (v == null) return null;
  var s = v.trim().toLowerCase();
  if (!s.startsWith('#')) s = '#$s';
  if (s.length == 4) s = '#${s[1]}${s[1]}${s[2]}${s[2]}${s[3]}${s[3]}';
  return isHex(s) ? s : null;
}

/// A colour of [hue] that reads on [on] (WCAG 4.5:1): [hue] mixed toward
/// black on light colours, toward white on dark ones, from [start] on.
String _readable(String on, String hue, double start) {
  final extreme = luminance(on) > 0.18 ? _black : _white;
  for (var w = start; w < 1.0; w += 0.05) {
    final c = mixColor(hue, extreme, w);
    if (contrast(c, on) >= 4.5) return c;
  }
  return extreme;
}

/// [c] with [amount] of its colour taken out (toward its own grey).
String _desaturate(String c, double amount) {
  final (r, g, b) = rgbOf(c);
  final grey = (0.299 * r + 0.587 * g + 0.114 * b).round();
  return mixColor(c, hexOf(grey, grey, grey), amount);
}

/// The scheme's colours (hex without '#') and its mode for a colours object
/// (docs/cosmic-interface.md); null without background, foreground and an
/// accent (or blue).
({Map<String, String> colours, String mode})? shellScheme(Map<String, String> colors) {
  final bg = _hex(colors['background']), fg = _hex(colors['foreground']);
  final accent = _hex(colors['accent']) ?? _hex(colors['blue']);
  if (bg == null || fg == null || accent == null) return null;
  final given = colors['mode'];
  final mode = given == 'dark' || given == 'light' ? given! : (luminance(bg) < 0.18 ? 'dark' : 'light');
  final light = mode == 'light';
  String? get(String key) => _hex(colors[key]);
  String mix(String a, String b, double w) => mixColor(a, b, w);
  String container(String hue) => mix(bg, hue, light ? 0.25 : 0.35);

  // Terminal colours exactly as the theme has them (a bright one falls back to its base).
  final term = <String>[];
  for (final key in shellTermKeys) {
    final base = key.startsWith('bright_') ? key.substring(7) : key;
    term.add(get(key) ?? get(base) ?? switch (base) {
      'black' => bg,
      'white' => fg,
      _ => _ansiDefaults[base]!,
    });
  }
  final red = term[1], green = term[2], yellow = term[3], blue = term[4], magenta = term[5], cyan = term[6];
  final orange = get('orange') ?? yellow;
  final muted = get('muted');
  final sel = get('selection_background') ?? get('selection');
  final cursor = get('cursor');

  final c = <String, String>{};
  // The theme's own surfaces and text.
  for (final k in ['background', 'surface', 'surfaceDim']) {
    c[k] = bg;
  }
  c['onBackground'] = fg;
  const steps = {
    'surfaceBright': 0.16, 'surfaceContainerLowest': -0.03, 'surfaceContainerLow': 0.03,
    'surfaceContainer': 0.06, 'surfaceContainerHigh': 0.09, 'surfaceContainerHighest': 0.12,
  };
  final edge = light ? _white : _black;
  String step(double w) => w < 0 ? mix(bg, edge, -w) : mix(bg, fg, w);
  steps.forEach((k, w) => c[k] = step(w));
  c['onSurface'] = fg;
  c['surfaceVariant'] = step(0.12);
  c['onSurfaceVariant'] = mix(fg, bg, 0.25);
  c['outline'] = muted ?? mix(fg, bg, 0.5);
  c['outlineVariant'] = mix(bg, fg, 0.22);
  c['inverseSurface'] = fg;
  c['inverseOnSurface'] = mix(bg, fg, 0.3);
  c['shadow'] = _black;
  c['scrim'] = _black;

  // The accent roles; secondary is the selection (else the cursor, else a
  // muted accent), as terminals and Hyprland used it under Caelestia.
  final secondary = sel ?? cursor ?? _desaturate(accent, 0.55);
  final tertiary = [magenta, cyan, green].firstWhere((h) => h != accent, orElse: () => _desaturate(accent, 0.3));
  final error = get('red') ?? (light ? '#ba1a1a' : '#ffb4ab');
  void role(String name, String hue, {String? containerColour}) {
    final box = containerColour ?? container(hue);
    final on = name[0].toUpperCase() + name.substring(1);
    c[name] = hue;
    c['${name}Dim'] = mix(hue, bg, 0.15);
    c['on$on'] = _readable(hue, hue, 0.7);
    c['${name}Container'] = box;
    c['on${on}Container'] = _readable(box, hue, 0.5);
    if (name != 'error') {
      c['${name}Fixed'] = mix(hue, _white, 0.6);
      c['${name}FixedDim'] = mix(hue, _white, 0.35);
      c['on${on}Fixed'] = mix(hue, _black, 0.8);
      c['on${on}FixedVariant'] = mix(hue, _black, 0.6);
    }
  }

  c['surfaceTint'] = accent;
  role('primary', accent);
  c['inversePrimary'] = light ? mix(accent, _white, 0.4) : mix(accent, _black, 0.4);
  role('secondary', secondary, containerColour: sel);
  role('tertiary', tertiary);
  role('error', error);
  final keys = {
    'primary': accent, 'secondary': secondary, 'tertiary': tertiary,
    'neutral': mix(bg, fg, 0.5), 'neutralVariant': c['outline']!, 'error': error,
  };
  keys.forEach((k, v) => c['${k}PaletteKeyColor'] = v);
  for (final k in ['primary', 'secondary', 'tertiary', 'neutral']) {
    c['${k}_paletteKeyColor'] = keys[k]!;
  }
  c['neutral_variant_paletteKeyColor'] = keys['neutralVariant']!;

  for (var i = 0; i < term.length; i++) {
    c['term$i'] = term[i];
  }
  // The catppuccin-style names.
  c.addAll({
    'rosewater': mix(red, fg, 0.7), 'flamingo': mix(red, fg, 0.5), 'pink': magenta, 'mauve': magenta,
    'red': red, 'maroon': red, 'peach': orange, 'yellow': yellow, 'green': green, 'teal': cyan,
    'sky': cyan, 'sapphire': blue, 'blue': blue, 'lavender': mix(blue, fg, 0.4),
  });
  // KDE-style link/state colours.
  final k = {'klink': blue, 'kvisited': magenta, 'knegative': red, 'kneutral': orange, 'kpositive': green};
  k.forEach((name, v) {
    c[name] = v;
    c['${name}Selection'] = v;
  });
  c.addAll({
    'text': fg, 'subtext1': c['onSurfaceVariant']!, 'subtext0': c['outline']!,
    'overlay2': step(0.86), 'overlay1': step(0.71), 'overlay0': step(0.57),
    'surface2': step(0.43), 'surface1': step(0.29), 'surface0': step(0.14),
    'base': bg, 'mantle': step(-0.03), 'crust': step(-0.05),
  });
  c['success'] = green;
  c['onSuccess'] = _readable(green, green, 0.7);
  c['successContainer'] = container(green);
  c['onSuccessContainer'] = _readable(c['successContainer']!, green, 0.5);
  return (colours: {for (final e in c.entries) e.key: e.value.substring(1)}, mode: mode);
}
