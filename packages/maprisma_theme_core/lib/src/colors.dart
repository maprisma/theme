import 'dart:math' as math;

/// Omarchy's colors.toml: parsing and the alias/derivation cascade of
/// omarchy-theme-color (Omarchy, MIT), so every consumer (COSMIC, the
/// terminal templates, previews) resolves the same palette.

final _hex = RegExp(r'^#[0-9A-Fa-f]{6}$');
final _keyRe = RegExp(r'^[A-Za-z0-9_-]+$');
final _valueRe = RegExp(r'^[A-Za-z0-9#(),._+/% -]*$');

bool isHex(String? v) => v != null && _hex.hasMatch(v);

/// The key/value pairs a colors.toml defines (comments, sections and values
/// with odd characters skipped, as omarchy-theme-color does).
Map<String, String> parseColorsToml(String text) {
  final out = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('[')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq).replaceAll(RegExp('["\' ]'), '');
    var value = line.substring(eq + 1).trim();
    final q = value.indexOf(RegExp('["\']'));
    if (q >= 0) {
      final rest = value.substring(q + 1);
      final end = rest.indexOf(RegExp('["\']'));
      value = end >= 0 ? rest.substring(0, end) : rest;
    } else {
      final hash = value.indexOf(' #');
      if (hash >= 0) value = value.substring(0, hash).trim();
    }
    if (!_keyRe.hasMatch(key) || !_valueRe.hasMatch(value)) continue;
    out[key] = value;
  }
  return out;
}

/// A colors.toml text from [colors] (only #rrggbb values and `mode`).
String writeColorsToml(Map<String, String> colors, {Map<String, String> keep = const {}}) {
  final b = StringBuffer();
  final mode = colors['mode'];
  if (mode == 'dark' || mode == 'light') b.writeln('mode = "$mode"\n');
  const order = [
    'accent', 'selection', 'muted', '',
    'background', 'dark_background', 'darker_background', 'lighter_background', '',
    'foreground', 'dark_foreground', 'light_foreground', 'bright_foreground', '',
    'cursor', 'selection_background', 'selection_foreground', '',
    'red', 'yellow', 'orange', 'green', 'cyan', 'blue', 'magenta', 'brown', '',
    'bright_red', 'bright_yellow', 'bright_green', 'bright_cyan', 'bright_blue', 'bright_magenta',
  ];
  final written = <String>{'mode'};
  var blank = false;
  for (final key in order) {
    if (key.isEmpty) {
      blank = true;
      continue;
    }
    final v = colors[key];
    if (!isHex(v)) continue;
    if (blank && b.isNotEmpty) b.writeln();
    blank = false;
    b.writeln('$key = "${v!.toLowerCase()}"');
    written.add(key);
  }
  final extra = <String>[];
  for (final e in {...keep, ...colors}.entries) {
    if (written.contains(e.key) || !_keyRe.hasMatch(e.key) || !_valueRe.hasMatch(e.value)) continue;
    if (colors.containsKey(e.key) && !isHex(e.value)) continue;
    extra.add('${e.key} = "${e.value}"');
  }
  if (extra.isNotEmpty) {
    b.writeln();
    extra.forEach(b.writeln);
  }
  return b.toString();
}

(int, int, int) rgbOf(String hex) {
  final v = int.parse(hex.substring(1), radix: 16);
  return ((v >> 16) & 255, (v >> 8) & 255, v & 255);
}

String hexOf(int r, int g, int b) =>
    '#${[r, g, b].map((c) => c.clamp(0, 255).toRadixString(16).padLeft(2, '0')).join()}';

/// omarchy-theme-color's mix_color: [amount] 0..1 of [end] into [start].
String mixColor(String start, String end, double amount) {
  amount = amount.clamp(0.0, 1.0);
  final (r1, g1, b1) = rgbOf(start);
  final (r2, g2, b2) = rgbOf(end);
  int m(int a, int b) => (a * (1 - amount) + b * amount + 0.5).floor();
  return hexOf(m(r1, r2), m(g1, g2), m(b1, b2));
}

/// Relative luminance 0..1 (WCAG).
double luminance(String hex) {
  final (r, g, b) = rgbOf(hex);
  double c(int v) {
    final s = v / 255;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b);
}

double contrast(String a, String b) {
  final la = luminance(a), lb = luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Every resolved key (omarchy-theme-color --all). [lightModeFile]: a
/// light.mode file lies beside the colors.toml.
Map<String, String> resolveColors(Map<String, String> raw, {bool lightModeFile = false}) {
  final c = Map<String, String>.of(raw);
  bool has(String k) => (c[k] ?? '').isNotEmpty;
  void alias(String key, String fallback) {
    if (!has(key) && has(fallback)) c[key] = c[fallback]!;
  }

  const legacyPalette = {
    'background': 'bg', 'dark_background': 'dark_bg', 'darker_background': 'darker_bg',
    'lighter_background': 'lighter_bg', 'foreground': 'fg', 'dark_foreground': 'dark_fg',
    'light_foreground': 'light_fg', 'bright_foreground': 'bright_fg',
  };
  legacyPalette.forEach(alias);
  if (!has('background') && has('color0')) c['background'] = c['color0']!;
  if (!has('foreground') && has('color7')) c['foreground'] = c['color7']!;
  if (has('background')) c['color0'] = c['background']!;
  if (has('foreground')) c['color7'] = c['foreground']!;
  const legacy = {
    'red': 'color1', 'green': 'color2', 'yellow': 'color3', 'blue': 'color4', 'magenta': 'color5',
    'cyan': 'color6', 'bright_red': 'color9', 'bright_green': 'color10', 'bright_yellow': 'color11',
    'bright_blue': 'color12', 'bright_magenta': 'color13', 'bright_cyan': 'color14',
  };
  legacy.forEach(alias);
  alias('magenta', 'purple');
  alias('bright_magenta', 'bright_purple');
  String? first(List<String> keys) {
    for (final k in keys) {
      if (has(k)) return c[k];
    }
    return null;
  }

  void orElse(String key, List<String> keys) {
    if (!has(key)) {
      final v = first(keys);
      if (v != null) c[key] = v;
    }
  }

  orElse('light_foreground', ['color7', 'foreground']);
  orElse('bright_foreground', ['color15', 'foreground']);
  if (has('bright_foreground')) c['cursor'] = c['bright_foreground']!;
  orElse('lighter_background', ['color0', 'background']);
  orElse('dark_foreground', ['color8', 'foreground']);
  orElse('muted', ['color8', 'dark_foreground']);
  orElse('selection', ['selection_background', 'color8', 'color0', 'background']);
  orElse('selection_background', ['selection']);
  orElse('selection_foreground', ['bright_foreground']);
  orElse('orange', ['yellow']);
  void derive(String key, String from, String to, double amount) {
    if (!has(key) && isHex(c[from])) c[key] = mixColor(c[from]!, to, amount);
  }

  derive('brown', 'orange', '#000000', 0.5);
  derive('dark_background', 'background', '#000000', 0.25);
  derive('darker_background', 'background', '#000000', 0.5);
  for (final k in ['red', 'yellow', 'green', 'cyan', 'blue', 'magenta']) {
    derive('bright_$k', k, '#ffffff', 0.2);
  }
  alias('purple', 'magenta');
  alias('bright_purple', 'bright_magenta');
  const ansi = {
    'color0': 'background', 'color1': 'red', 'color2': 'green', 'color3': 'yellow', 'color4': 'blue',
    'color5': 'magenta', 'color6': 'cyan', 'color7': 'foreground', 'color8': 'muted',
    'color9': 'bright_red', 'color10': 'bright_green', 'color11': 'bright_yellow',
    'color12': 'bright_blue', 'color13': 'bright_magenta', 'color14': 'bright_cyan',
    'color15': 'bright_foreground',
  };
  ansi.forEach(alias);
  legacyPalette.forEach((k, short) {
    if (has(k)) c[short] = c[k]!;
  });
  if (!has('mode')) {
    if (has('theme_type')) c['mode'] = c['theme_type']!;
  }
  if (!has('mode')) {
    if (lightModeFile) {
      c['mode'] = 'light';
    } else if (isHex(c['background'])) {
      final (r, g, b) = rgbOf(c['background']!);
      c['mode'] = r + g + b > 382 ? 'light' : 'dark';
    } else {
      c['mode'] = 'dark';
    }
  }
  c['theme_type'] = c['mode']!;
  return c;
}

/// The colors object of docs/cosmic-interface.md (for the helper and the GUI).
Map<String, String> colorsObject(Map<String, String> resolved) {
  final out = <String, String>{'mode': resolved['mode'] == 'light' ? 'light' : 'dark'};
  const keys = [
    'background', 'foreground', 'accent', 'selection', 'muted', 'cursor', 'red', 'green', 'yellow',
    'blue', 'magenta', 'cyan', 'orange', 'bright_red', 'bright_green', 'bright_yellow', 'bright_blue',
    'bright_magenta', 'bright_cyan', 'bright_foreground', 'selection_background', 'selection_foreground',
    'dark_background', 'darker_background', 'lighter_background', 'dark_foreground', 'light_foreground',
  ];
  for (final k in keys) {
    if (isHex(resolved[k])) out[k] = resolved[k]!.toLowerCase();
  }
  if (!out.containsKey('accent') && out.containsKey('blue')) out['accent'] = out['blue']!;
  out['black'] = out['background'] ?? '#000000';
  out['white'] = out['foreground'] ?? '#ffffff';
  out['bright_black'] = out['muted'] ?? out['black']!;
  out['bright_white'] = out['bright_foreground'] ?? out['white']!;
  return out;
}

final _token = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}');

/// Renders an Omarchy template (default/themed/*.tpl): `{{ key }}`,
/// `{{ key_strip }}`, `{{ key_rgb }}`, `{{ mix a b 30% }}` (and _strip/_rgb).
/// Unknown tokens stay as they are; null when one stays (the file would break).
String? renderTemplate(String template, Map<String, String> resolved) {
  var unresolved = false;
  final text = template.replaceAllMapped(_token, (m) {
    final token = m[1]!.trim();
    final v = templateValue(token, resolved);
    if (v == null) {
      unresolved = true;
      return m[0]!;
    }
    return v;
  });
  return unresolved ? null : text;
}

String? templateValue(String token, Map<String, String> c) {
  final parts = token.split(RegExp(r'\s+'));
  String fmt(String hex, String suffix) => switch (suffix) {
    '_strip' => hex.substring(1),
    '_rgb' => () {
      final (r, g, b) = rgbOf(hex);
      return '$r,$g,$b';
    }(),
    _ => hex,
  };
  if (parts.length == 4 && RegExp(r'^mix(_strip|_rgb)?$').hasMatch(parts[0])) {
    final a = c[parts[1]] ?? parts[1], b = c[parts[2]] ?? parts[2];
    if (!isHex(a) || !isHex(b)) return null;
    var amount = double.tryParse(parts[3].replaceAll('%', ''));
    if (amount == null) return null;
    if (parts[3].endsWith('%') || amount > 1) amount /= 100;
    return fmt(mixColor(a, b, amount), parts[0].substring(3));
  }
  if (parts.length != 1) return null;
  final key = parts.single;
  if (c.containsKey(key)) return c[key];
  for (final suffix in ['_strip', '_rgb']) {
    if (key.endsWith(suffix)) {
      final base = c[key.substring(0, key.length - suffix.length)];
      if (isHex(base)) return fmt(base!, suffix);
    }
  }
  return null;
}
