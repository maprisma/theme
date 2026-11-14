import 'apply.dart';
import 'bounded.dart';
import 'colors.dart';
import 'context.dart';
import 'desktop.dart';
import 'desktops.dart';
import 'themes.dart';

Map<String, Handler> settingsRoutes(Ctx ctx) => {
  'settings.get': (p) async => {'settings': ctx.settings.load()},
  'settings.set': (p) async {
    final key = str(p, 'key');
    try {
      final s = ctx.settings.set(key, p['value']);
      ctx.automationChanged();
      return {'settings': s};
    } on ArgumentError {
      throw RouteError('bad_params', key);
    }
  },
  'settings.reset': (p) async {
    final s = ctx.settings.reset();
    ctx.automationChanged();
    return {'settings': s};
  },
  /// The desktop's look; where the desktop has none to tell (no backend),
  /// the applied theme's colors.
  'desktop.look': (p) async {
    var cur = await ctx.desktop.current();
    if (cur == null && ctx.current.slug.isNotEmpty) {
      final theme = findTheme(ctx.paths, ctx.current.slug);
      if (theme != null) {
        final c = colorsObject(await themeColors(ctx, theme));
        if (isHex(c['background']) && isHex(c['foreground'])) {
          cur = {
            'colors': {'background': c['background'], 'foreground': c['foreground'], 'accent': c['accent'] ?? c['foreground']},
            'is_dark': luminance(c['background']!) < 0.5,
          };
        }
      }
    }
    return {
      'desktop': ctx.desktop.id,
      'colors': cur?['colors'] ?? const {},
      'is_dark': cur?['is_dark'] ?? true,
      'corner_radius': cur?['corner_radius'] ?? await ctx.desktop.windowRounding(),
      'theme': ctx.current.slug,
      'fonts': await desktopFonts(ctx),
    };
  },
};

// --- fonts (the same in every Maprisma app; Font & effects sets them) ----------------------

/// The desktop's interface and monospace font families, `{ui, mono}`, each left out when it
/// can't be read: what the desktop's backend reads (COSMIC's CosmicTk interface_font /
/// monospace_font, KDE's kdeglobals font / fixed, Hyprland's gsettings font-name /
/// monospace-font-name, asked at most every 30 s), elsewhere GTK's gsettings, asked at most
/// every 30 s too.
Future<Map<String, String>> desktopFonts(Ctx ctx) async {
  String? clean(String? v) {
    final t = v?.trim();
    return t == null || t.isEmpty || t.length > 100 ? null : t;
  }

  final d = ctx.desktop;
  final (String? ui, String? mono) = d is GenericDesktop ? await _gtkFonts(ctx) : (d.interfaceFont(), d.monospaceFont());
  return {'ui': ?clean(ui), 'mono': ?clean(mono)};
}

/// A Pango font ("Noto Sans  10", "Hack, 10") without its size.
String pangoFamily(String font) => font.trim().replaceFirst(RegExp(r',?\s+\d+(\.\d+)?$'), '').trim();

final _gtkFontCache = Expando<({DateTime at, (String?, String?) value})>('gtkFonts');

Future<(String?, String?)> _gtkFonts(Ctx ctx) async {
  final now = ctx.clock();
  final cached = _gtkFontCache[ctx];
  if (cached != null && now.difference(cached.at).abs() < const Duration(seconds: 30)) return cached.value;
  final g = findProgram(ctx.paths, ctx.environment, 'gsettings');
  Future<String?> get(String key) async {
    if (g == null) return null;
    final (code, out) = await runBounded([g, 'get', 'org.gnome.desktop.interface', key],
        timeout: const Duration(seconds: 3), environment: ctx.environment);
    final t = code == 0 ? out.trim() : '';
    return t.length > 2 && t.startsWith("'") && t.endsWith("'") ? pangoFamily(t.substring(1, t.length - 1)) : null;
  }

  final value = (await get('font-name'), await get('monospace-font-name'));
  _gtkFontCache[ctx] = (at: now, value: value);
  return value;
}
