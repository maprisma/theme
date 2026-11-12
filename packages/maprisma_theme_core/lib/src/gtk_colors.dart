import 'colors.dart';

/// GTK's colours for the Breeze GTK theme (`~/.config/gtk-3.0/colors.css` and gtk-4.0's,
/// imported by their gtk.css), made from a theme as KDE makes them from its colour scheme: the
/// window, view, button, header and title bar, selection, tooltip, borders, links and the
/// status colours, each also "insensitive" (mixed toward the window) and "backdrop" (the
/// window without focus). On KDE, Plasma writes this file itself; on Hyprland nothing does,
/// so GTK windows (their title bars, dialogs) kept the colours of the last KDE session.
///
/// [colors]: the theme's colours object (`#rrggbb`); [colours]: the shell scheme's Material
/// roles (`rrggbb`, shell_scheme.dart).
String gtkColorsCss(Map<String, String> colors, Map<String, String> colours) {
  String role(String key) => '#${colours[key]}';
  String own(String key, String fallback) => isHex(colors[key]) ? colors[key]!.toLowerCase() : fallback;
  String mix(String a, String b, double w) => mixColor(a, b, w);

  final base = role('surface');
  final bg = role('surfaceContainerLow');
  final raised = role('surfaceContainer');
  final tooltip = role('surfaceContainerHigh');
  final fg = role('onSurface');
  final accent = role('primary');
  final borders = role('outlineVariant');
  final hover = mix(bg, accent, 0.75);
  final selected = mix(base, accent, 0.4);
  final faint = mix(bg, fg, 0.35);
  final faintBg = mix(base, bg, 0.5);
  final error = own('red', role('error'));
  final warning = own('orange', own('yellow', role('error')));
  final success = own('green', role('success'));

  final v = <String, String>{
    'theme_base_color': base,
    'theme_bg_color': bg,
    'theme_fg_color': fg,
    'theme_text_color': fg,
    'content_view_bg': base,
    'theme_selected_bg_color': selected,
    'theme_selected_fg_color': fg,
    'theme_hovering_selected_bg_color': hover,
    'theme_view_active_decoration_color': hover,
    'theme_view_hover_decoration_color': hover,
    'borders': borders,
    'unfocused_borders': borders,
    'insensitive_borders': mix(bg, borders, 0.5),
    'unfocused_insensitive_borders': mix(bg, borders, 0.5),
    'insensitive_base_color': mix(base, bg, 0.3),
    'insensitive_base_fg_color': faint,
    'insensitive_bg_color': faintBg,
    'insensitive_fg_color': faint,
    'insensitive_selected_bg_color': faintBg,
    'insensitive_selected_fg_color': faint,
    'insensitive_unfocused_bg_color': faintBg,
    'insensitive_unfocused_fg_color': faint,
    'insensitive_unfocused_selected_bg_color': faintBg,
    'insensitive_unfocused_selected_fg_color': faint,
    'theme_unfocused_base_color': base,
    'theme_unfocused_bg_color': bg,
    'theme_unfocused_fg_color': fg,
    'theme_unfocused_text_color': fg,
    'theme_unfocused_selected_bg_color': mix(base, accent, 0.2),
    'theme_unfocused_selected_bg_color_alt': mix(base, accent, 0.2),
    'theme_unfocused_selected_fg_color': fg,
    'theme_unfocused_view_bg_color': role('surfaceContainerLowest'),
    'theme_unfocused_view_text_color': faint,
    // the title bar and the header bar: the window one step raised, as the Maprisma apps draw it
    for (final part in ['header', 'titlebar']) ...{
      'theme_${part}_background': raised,
      'theme_${part}_background_backdrop': bg,
      'theme_${part}_background_light': bg,
      'theme_${part}_foreground': fg,
      'theme_${part}_foreground_backdrop': fg,
      'theme_${part}_foreground_insensitive': fg,
      'theme_${part}_foreground_insensitive_backdrop': fg,
    },
    'theme_button_background_normal': raised,
    'theme_button_background_backdrop': raised,
    'theme_button_background_insensitive': mix(raised, bg, 0.5),
    'theme_button_background_backdrop_insensitive': mix(raised, bg, 0.5),
    'theme_button_foreground_normal': fg,
    'theme_button_foreground_backdrop': fg,
    'theme_button_foreground_active': fg,
    'theme_button_foreground_active_backdrop': fg,
    'theme_button_foreground_insensitive': faint,
    'theme_button_foreground_backdrop_insensitive': faint,
    'theme_button_foreground_active_insensitive': faint,
    'theme_button_foreground_active_backdrop_insensitive': faint,
    'theme_button_decoration_focus': accent,
    'theme_button_decoration_focus_backdrop': accent,
    'theme_button_decoration_focus_insensitive': mix(bg, accent, 0.35),
    'theme_button_decoration_focus_backdrop_insensitive': mix(bg, accent, 0.35),
    'theme_button_decoration_hover': hover,
    'theme_button_decoration_hover_backdrop': hover,
    'theme_button_decoration_hover_insensitive': mix(bg, hover, 0.35),
    'theme_button_decoration_hover_backdrop_insensitive': mix(bg, hover, 0.35),
    'tooltip_background': tooltip,
    'tooltip_text': fg,
    'tooltip_border': mix(tooltip, fg, 0.2),
    'link_color': own('blue', accent),
    'link_visited_color': own('magenta', role('tertiary')),
    for (final (name, c) in [('error', error), ('warning', warning), ('success', success)]) ...{
      '${name}_color': c,
      '${name}_color_backdrop': c,
      '${name}_color_insensitive': mix(bg, c, 0.35),
      '${name}_color_insensitive_backdrop': mix(bg, c, 0.35),
    },
  };
  final b = StringBuffer('/* Written by Maprisma Theme from the theme\'s colours (KDE writes this file itself on Plasma). */\n');
  for (final e in v.entries) {
    b.writeln('@define-color ${e.key}_breeze ${e.value};');
  }
  return b.toString();
}
