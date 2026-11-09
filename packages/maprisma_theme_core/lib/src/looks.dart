/// Theme looks (docs/theme-looks.md): the user's own fonts and blur for any
/// theme, kept in looks.json beside the settings; theme files never change.
library;

import 'dart:convert';

import 'auto.dart' show autoLocked, validSlug;
import 'context.dart';
import 'custom.dart' show fontRe;
import 'desktop.dart';
import 'settings.dart';
import 'store.dart';
import 'themes.dart';

/// `own_*` when the desktop's default was in use.
const defaultFontMark = '(default)';

/// The font fields of a look, with the desktop methods and the cap behind each.
enum FontRole {
  mono('mono_font', 'font', Cap.fonts),
  ui('ui_font', 'ui_font', Cap.uiFont);

  const FontRole(this.lookKey, this.themeKey, this.cap);

  /// The key in looks.json.
  final String lookKey;

  /// The key in a custom theme's theme-manager.json.
  final String themeKey;
  final Cap cap;

  String? current(Desktop d) => this == mono ? d.monospaceFont() : d.interfaceFont();
  Future<bool> set(Desktop d, String family) => this == mono ? d.setMonospaceFont(family) : d.setInterfaceFont(family);
  Future<bool> reset(Desktop d) => this == mono ? d.resetMonospaceFont() : d.resetInterfaceFont();
  Future<List<String>> choices(Desktop d) => this == mono ? d.monospaceFonts() : d.interfaceFonts();

  /// The setting that keeps the user's own font: one per desktop, as each has
  /// its own fonts (COSMIC keeps the unsuffixed names).
  String ownKey(Desktop d) => '${this == mono ? 'own_font' : 'own_ui_font'}${d.id == 'kde' ? '_kde' : ''}';
}

/// The setting key that keeps the user's own monospace font.
String ownFontKey(Desktop d) => FontRole.mono.ownKey(d);

const lookKeys = {'mono_font', 'ui_font', 'blur'};
const blurStrengths = (min: 1, max: 15);

/// A look as stored, or null when it does not fit (unknown keys, a bad
/// font name, a blur that is not {on: bool, strength: 1..15}).
Map<String, dynamic>? checkLook(Object? v) {
  if (v is! Map) return null;
  final out = <String, dynamic>{};
  for (final e in v.entries) {
    switch (e.key) {
      case 'mono_font' || 'ui_font':
        if (e.value == null) continue;
        if (e.value is! String || !fontRe.hasMatch(e.value as String)) return null;
        out[e.key as String] = e.value;
      case 'blur':
        if (e.value == null) continue;
        final b = e.value;
        if (b is! Map || b.keys.any((k) => k != 'on' && k != 'strength') || b['on'] is! bool) return null;
        final s = b['strength'];
        if (s is! int || s < blurStrengths.min || s > blurStrengths.max) return null;
        out['blur'] = {'on': b['on'], 'strength': s};
      default:
        return null;
    }
  }
  return out;
}

/// looks.json: {slug: look}.
final class Looks {
  Looks(this.ctx);
  final Ctx ctx;

  String get file => ctx.paths.file('looks.json');

  Map<String, Map<String, dynamic>> all() => {
    for (final e in readJsonMap(file).entries)
      if (checkLook(e.value) case final Map<String, dynamic> look when validSlug(e.key) && look.isNotEmpty) e.key: look,
  };

  Map<String, dynamic> of(String slug) => all()[slug] ?? {};

  /// Replaces a theme's look (an empty one removes the entry); returns the old one.
  Map<String, dynamic> set(String slug, Map<String, dynamic> look) {
    final m = all();
    final old = m[slug] ?? {};
    if (look.isEmpty) {
      m.remove(slug);
    } else {
      m[slug] = look;
    }
    writeJson(file, m);
    return old;
  }

  void rename(String old, String renamed) {
    final m = all();
    final look = m.remove(old);
    if (look == null) return;
    m[renamed] = look;
    writeJson(file, m);
  }

  void forget(String slug) {
    final m = all();
    if (m.remove(slug) != null) writeJson(file, m);
  }
}

/// The font a theme brings for [role]: its look, else its own; null = none.
String? themeFont(Ctx ctx, ThemeInfo theme, FontRole role, {Map<String, dynamic>? look}) {
  final mine = (look ?? Looks(ctx).of(theme.slug))[role.lookKey];
  if (mine is String) return mine;
  final own = theme.meta[role.themeKey];
  return own is String && fontRe.hasMatch(own) ? own : null;
}

/// A theme's fonts, and the user's own fonts back for any field the theme
/// leaves alone. Returns the roles that changed.
Future<List<FontRole>> applyLookFonts(Ctx ctx, ThemeInfo theme) async {
  final look = Looks(ctx).of(theme.slug);
  final changed = <FontRole>[];
  for (final role in FontRole.values) {
    if (!ctx.desktop.caps.contains(role.cap)) continue;
    if (await _applyFont(ctx, role, themeFont(ctx, theme, role, look: look))) changed.add(role);
  }
  return changed;
}

/// The look's fields a theme apply touches: fonts and blur. Returns the
/// look keys that changed.
Future<List<String>> applyLook(Ctx ctx, ThemeInfo theme) async => [
  for (final r in await applyLookFonts(ctx, theme)) r.lookKey,
  if (await applyLookBlur(ctx, theme)) 'blur',
];

/// The blur a theme brings: its look's, else its own (theme-manager.json
/// `blur`, or a native COSMIC theme's frosted settings in its cosmic.ron).
Map<String, dynamic>? themeBlur(Ctx ctx, ThemeInfo theme, {Map<String, dynamic>? look}) {
  final mine = (look ?? Looks(ctx).of(theme.slug))['blur'];
  if (mine is Map<String, dynamic>) return mine;
  final own = checkLook({'blur': theme.meta['blur']})?['blur'] as Map<String, dynamic>?;
  if (own != null || !theme.cosmicNative) return own;
  final ron = readSmall('${theme.dir}/cosmic.ron', limit: 1024 * 1024);
  return ron == null ? null : ronBlur(ron);
}

/// COSMIC's BlurStrength names in order (0..13).
const cosmicBlurSteps = [
  'ExtremelyLow', 'ExtremelyLow2', 'VeryLow', 'VeryLow2', 'Low', 'Low2', 'Medium', 'Medium2',
  'High', 'High2', 'VeryHigh', 'VeryHigh2', 'ExtremelyHigh', 'ExtremelyHigh2',
];

/// A ThemeBuilder RON's blur as a look ({on, strength 1..15}), or null when
/// the file has no frosted settings (older COSMIC exports).
Map<String, dynamic>? ronBlur(String text) {
  bool? flag(String key) => switch (RegExp('\\b$key\\s*:\\s*(true|false)\\b').firstMatch(text)?.group(1)) {
    'true' => true,
    'false' => false,
    _ => null,
  };
  final flags = [for (final k in ['frosted_windows', 'frosted_system_interface', 'frosted_panel', 'frosted_applets']) flag(k)];
  if (flags.every((f) => f == null)) return null;
  final name = RegExp(r'\bfrosted\s*:\s*([A-Za-z0-9]+)').firstMatch(text)?.group(1);
  final step = cosmicBlurSteps.indexOf(name ?? 'Medium');
  return {'on': flags.contains(true), 'strength': ((step < 0 ? 6 : step) * 14 / 13).round() + 1};
}

String ownBlurKey(Desktop d) => d.id == 'kde' ? 'own_blur_kde' : 'own_blur';

/// A theme's blur, and the user's own blur back (the desktop's whole state
/// as it was) for a theme without one.
Future<bool> applyLookBlur(Ctx ctx, ThemeInfo theme) async {
  final d = ctx.desktop;
  if (!d.caps.contains(Cap.blur)) return false;
  final key = ownBlurKey(d);
  final own = ctx.settings.get(key);
  final themed = themeBlur(ctx, theme);
  if (themed != null) {
    final now = await d.blurState();
    if (now == null) return false;
    final target = d.blurTarget(now, on: themed['on'] as bool, strength: themed['strength'] as int);
    if (jsonEncode(target) == jsonEncode(now)) return false;
    // kept before the change: a write that fails halfway can't lose it
    if (own == null) ctx.settings.set(key, now);
    return d.restoreBlur(target);
  }
  if (own is Map) {
    final ok = await d.restoreBlur(Map<String, dynamic>.from(own));
    if (ok) ctx.settings.set(key, null);
    return ok;
  }
  return false;
}

Future<bool> _applyFont(Ctx ctx, FontRole role, String? themed) async {
  final d = ctx.desktop;
  final key = role.ownKey(d);
  final own = ctx.settings.get(key) as String?;
  if (themed != null) {
    final now = role.current(d);
    if (now == themed) return false;
    if (!await role.set(d, themed)) return false;
    // The font to go back to; the desktop's default when none was set.
    if (own == null) ctx.settings.set(key, now ?? defaultFontMark);
    return true;
  }
  if (own != null) {
    final ok = own == defaultFontMark ? await role.reset(d) : await role.set(d, own);
    if (ok) ctx.settings.set(key, null); // kept until the user's font is really back
    return ok;
  }
  return false;
}

/// `looks.get`: the look, what the theme itself brings, the user's own
/// values and the choices, for the Font & effects dialog.
Future<Map<String, dynamic>> lookData(Ctx ctx, String slug) async {
  final theme = ctx.theme(slug);
  final d = ctx.desktop;
  final roles = [for (final r in FontRole.values) if (d.caps.contains(r.cap)) r];
  final blur = d.caps.contains(Cap.blur) ? await d.blurState() : null;
  return {
    'slug': slug,
    'name': theme.name,
    'look': Looks(ctx).of(slug),
    'theme': {
      for (final r in roles) r.lookKey: themeFont(ctx, theme, r, look: const {}),
    },
    'current': {for (final r in roles) r.lookKey: r.current(d)},
    // the user's own fonts: kept while a theme's font is in use, else the one in use
    'own': {
      for (final r in roles)
        r.lookKey: switch (ctx.settings.get(r.ownKey(d))) {
          defaultFontMark => null,
          final String f => f,
          _ => r.current(d),
        },
    },
    'fonts': {
      for (final r in roles) r.lookKey: (await r.choices(d)).where(fontRe.hasMatch).take(400).toList(),
    },
    'caps': [for (final r in roles) r.lookKey, if (blur != null) 'blur'],
    if (blur != null) ...{
      'blur': {
        'current': d.blurAsLook(blur),
        'own': d.blurAsLook(switch (ctx.settings.get(ownBlurKey(d))) {
          final Map m => Map<String, dynamic>.from(m),
          _ => blur,
        }),
        'theme': themeBlur(ctx, theme, look: const {}),
      },
    },
    'in_use': ctx.current.slug == slug,
  };
}

/// `looks.set {slug, look}`: replaces the look; the theme in use gets it at once.
Future<Map<String, dynamic>> setLook(Ctx ctx, String slug, Object? raw) async {
  final theme = ctx.theme(slug);
  final look = checkLook(raw);
  if (look == null) throw RouteError('bad_args', 'not a look');
  for (final r in FontRole.values) {
    final f = look[r.lookKey];
    if (f is String && !(await r.choices(ctx.desktop)).contains(f)) {
      throw RouteError('bad_args', '$f is not installed');
    }
  }
  // one change at a time with theme applies (the daemon's workspace themes too)
  return autoLocked(ctx, () async {
    final previous = Looks(ctx).set(slug, look);
    final done = ctx.current.slug == slug ? await applyLook(ctx, theme) : <String>[];
    return {'done': true, 'previous': previous, 'look': look, 'applied': done};
  });
}

/// A font from outside a theme (a preset), set through the same chain, so
/// the user's own font is kept to come back later.
Future<bool> applyFontOverride(Ctx ctx, FontRole role, String family) => _applyFont(ctx, role, family);

/// Every font, blur and the user's own values as they are, for an undo to put back exactly.
Future<Map<String, dynamic>> captureLook(Ctx ctx) async {
  final d = ctx.desktop;
  return {
    for (final r in FontRole.values) r.lookKey: r.current(d),
    if (d.caps.contains(Cap.blur)) 'blur': await d.blurState(),
    'own': {
      for (final r in FontRole.values) r.ownKey(d): ctx.settings.get(r.ownKey(d)),
      ownBlurKey(d): ctx.settings.get(ownBlurKey(d)),
    },
  };
}

Future<void> restoreLook(Ctx ctx, Map<String, dynamic> state) async {
  final d = ctx.desktop;
  final blur = state['blur'];
  if (blur is Map && d.caps.contains(Cap.blur)) {
    final now = await d.blurState();
    if (jsonEncode(now) != jsonEncode(blur)) await d.restoreBlur(Map<String, dynamic>.from(blur));
  }
  for (final r in FontRole.values) {
    if (!d.caps.contains(r.cap)) continue;
    final f = state[r.lookKey];
    if (f == r.current(d)) continue;
    f is String ? await r.set(d, f) : await r.reset(d);
  }
  final own = state['own'];
  if (own is Map) {
    for (final e in own.entries) {
      if (Settings.check(e.key as String, e.value)) ctx.settings.set(e.key as String, e.value);
    }
  }
}
