# Maprisma Theme: plan

The COSMIC port of the Omarchy plugin **Theme Manager 2.0.0**
(`/mnt/Data/Projects/omarchy-theme-manager`, its README is the feature spec). Built-in interface
translations cover English, Deutsch, Français, Español, Italiano, Português, Nederlands and Polski;
the earlier English-only rule is lifted. No manual. Every feature of the plugin is kept; where COSMIC works differently the
feature is adapted as listed below.

## Parts

| Folder | What | Who |
| --- | --- | --- |
| `packages/maprisma_theme_core` | Dart core: themes, wallpapers, settings, imports, AI, automation. A JSON protocol (`docs/protocol.md`) for the GUI, and a CLI `maprisma-theme-core` (AOT compiled) for the applet and keyboard shortcuts | Claude |
| `flutter_app` | Flutter window `maprisma-theme` (app id `com.maprisma.Theme`), single instance, `--toggle` | Claude |
| `cosmic/helper` | Rust `maprisma-theme-helper`: applies a COSMIC theme with the `cosmic-theme` crate, and talks to the compositor (workspaces, windows) | Codex |
| `cosmic/applet` | Rust/libcosmic panel applet `io.github.ubruckhaus.CosmicMaprismaTheme`: the plugin's bar widget | Codex |
| `themes/` | The 23 Omarchy system themes' colors and app configs (from Omarchy, MIT: `themes/LICENSE.omarchy`), shipped read-only. Their wallpapers, preview and unlock pictures are **not** in the repository (the artists' rights); the app draws previews from the colors | Claude |
| `templates/` | Omarchy's app templates (`default/themed/*.tpl`, MIT) for the terminals and editors | Claude |
| `tools/` | `build-release.py`, `install-local`, `import-omarchy` (one-time copy of the user's Omarchy themes/state) | Claude |

The interface between the parts is in `docs/cosmic-interface.md`.

## Where things live (COSMIC)

| Plugin (Omarchy) | Maprisma Theme (COSMIC) |
| --- | --- |
| `~/.config/omarchy/themes/<slug>/` | `~/.config/maprisma-theme/themes/<slug>/` (same layout: `colors.toml`, `backgrounds/`, `preview.png`, `icons.theme`, optional `cosmic.ron`, `theme-manager.json`) |
| `/usr/share/omarchy/themes/` | `<install>/share/maprisma-theme/themes/` (bundled, read-only) |
| `~/.config/omarchy/backgrounds/<theme>/` | `~/.config/maprisma-theme/backgrounds/<theme>/` |
| `~/.config/omarchy/theme-manager/*.json` | `~/.config/maprisma-theme/*.json` (same file names and shapes) |
| `~/.cache/theme-manager/` | `~/.cache/maprisma-theme/` |
| current theme `~/.local/state/omarchy/current/theme` | `~/.local/state/maprisma-theme/current.json` (slug, wallpaper) |

## Feature mapping

| Feature | On COSMIC |
| --- | --- |
| Apply theme | `maprisma-theme-helper apply` writes the COSMIC theme builder + built theme (dark or light by the theme's `mode`, else by its background), sets `is_dark`; then the wallpaper (cosmic-bg config `all`), icon theme (CosmicTk `icon_theme`, only if installed), the theme's font, the COSMIC Terminal color scheme, and the app templates |
| App colors | COSMIC Terminal always; Alacritty, Kitty, Ghostty, foot, btop, Neovim, Helix, VS Code when installed: rendered from Omarchy's templates into an include file the app reads (same idea as Omarchy's `~/.config/omarchy/current/theme/*`); the user's own config gets one marked include line, with a backup, removable |
| Native COSMIC themes | A theme folder can carry `cosmic.ron` (a ThemeBuilder from cosmic-themes.org or COSMIC Settings export); it is applied as is, and `colors.toml` is derived from it for the terminals |
| Hide / favorites / recent / delete with undo / trash | unchanged (own lists, freedesktop trash) |
| Also hide in Omarchy's pickers, sync health | no Omarchy picker on COSMIC: dropped; the health card checks the helper, the applet and the shortcut file instead |
| New theme from theme / from wallpaper, edit, font per theme | unchanged; fonts from `fc-list :spacing=mono family`, set as CosmicTk `monospace_font` |
| Wallpapers per theme: add (drop, paste, chooser), hide, delete, HEIC, preview on desktop (Space hold, 5 s) | unchanged; preview writes cosmic-bg's config and restores it |
| Wallpaper / theme per workspace | the applet watches the active workspace (cosmic workspace protocol) and runs `maprisma-theme-core workspace <n>` |
| Slideshow, day and night | the applet runs `maprisma-theme-core tick` once a minute while either is on |
| Workspace Presets | adapted: per workspace tiling on/off (`set_tiling_state`), window limit 1–4 with overflow to the next workspace with room (the applet watches new windows), Floating = tiling off; the layouts Hyprland had (Master Left, Columns, …) are shown as COSMIC's tiling; sizes and split ratios are not offered |
| App Presets | adapted: save which apps are on which workspace, restore = start missing apps from their launcher and move windows to their workspace (no positions or sizes); others moved/closed/kept as chosen; autostart at login by the applet |
| Save/Load Presets | unchanged |
| Keyboard shortcuts (open, next/prev wallpaper, next favorite, per theme) | COSMIC custom shortcuts (`com.system76.CosmicSettings.Shortcuts/v1/custom`, `Spawn(...)`), code from Maprisma Launcher's `shortcuts.dart`; key colouring free/own/COSMIC default |
| Ask AI (Claude Code, Codex, pi, Hermes, local models) | unchanged, code from Maprisma Launcher's `ask_ai.dart` plus the plugin's theme prompt and checks |
| Import from omarchy.org | unchanged (git clone into the user themes) |
| Import from cosmic-themes.org | new tab: list, search, sort; download = POST with the page's CSRF token; stored as a theme folder with `cosmic.ron` and derived colors |
| Wallhaven search | unchanged |
| F12 screenshot + note | the Flutter window paints itself (RepaintBoundary), as Maprisma Launcher |
| Backup export/restore | unchanged |
| Information page | unchanged (marketplace catalog, author's entries) |
| Language | Settings → General → Language; system locale or a saved choice, applied immediately. Shared English-key catalogs for Flutter, the Dart core, tray and Rust helper/applet; theme names stay unchanged. |
| Corners | Like windows = the COSMIC theme's corner radius; Rounded; Square |
| Bar widget | the panel applet: click toggles the window, scroll = next/previous wallpaper, right-click = favorites/recent, next wallpaper, open |
| Popup: resizable, remembered size, double-click title maximise | a normal COSMIC window (positions cannot be set on Wayland); size remembered; Esc and the applet close it |

## Order

1. Core skeleton, theme scan (bundled + user), apply via helper, wallpaper, applet toggle. → usable
2. Theme list UI, wallpaper pages, hide/favorite/delete/undo, settings.
3. Editor, from-wallpaper, fonts, app templates.
4. Imports (omarchy.org, cosmic-themes.org), Wallhaven.
5. Workspace wallpapers/themes, day/night, slideshow, shortcuts.
6. Presets (workspaces, apps, save/load), backups, Ask AI, F12, Information.
7. Codex crosscheck of the whole, fixes, `tools/install-local`, panel placement.
