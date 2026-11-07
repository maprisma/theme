# UI parity with the Omarchy plugin (user's request, 2026-11-08)

The user's F12 note on the first version: "looks total different from the omarchy plugin version, all features, defined
there, are missing". Every page must now look and work like the plugin's GTK popup:
- Plugin view code (the spec for look and behaviour): /mnt/Data/Projects/omarchy-theme-manager/theme_popup.py (main list,
  header, wallpaper page, web search, import page, settings, info, menus, keyboard), workspaces_page.py (Presets),
  ask_page.py (Ask AI), theme_custom.py + theme_popup.py editor parts, more_plugins.py (Information).
- Plugin README (feature list) and preview.png (/mnt/Data/Projects/omarchy-theme-manager/preview.png: the main list, Ask AI and
  Presets as they look).
- Keep the colours from the COSMIC theme (theme.dart), but structure, sizes, density, texts, badges, hints, header buttons
  and their order, menus, empty states, notes ("19 hidden themes not shown. The eye button in the header shows them."),
  keyboard behaviour and tooltips follow the plugin. Product name in the UI: "Maprisma Theme".
- The ONE allowed difference (user decision): Hyprland-only window placement cannot work on COSMIC, so on the Presets page the
  layout choices are COSMIC's real ones only — Tiled, Floating, Native (= leave COSMIC's setting) — no Master Left/Right,
  Columns, 2×2, no drag-to-swap or split sizes. Everything else of the Presets page (groups Workspaces 1–5 / 6–10 with All
  Workspaces in both, the large preview of the chosen workspace on the right in a wide window with its wallpaper and theme
  colours, magnifier preview in a narrow window, window-limit buttons 1–4, + / − for one window more/less, App Presets and
  Save/Load tabs, notes, Undo) as in the plugin.
- Omarchy-only items with no COSMIC meaning stay out (Omarchy picker sync), as decided before.

Check your work visually: render pages offscreen with a widget test (`flutter test` with `matchesGoldenFile` or
`tester.binding.takeScreenshot`-style RepaintBoundary.toImage → PNG into the scratchpad) at 700 px and 1300 px wide with real
core data from TestEnv-like temp HOMEs, and Read the PNGs; compare with preview.png. Do not open real windows on the user's
desktop.
