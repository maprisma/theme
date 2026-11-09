# Maprisma Theme

A theme manager for the **COSMIC** and **KDE Plasma** desktops on Linux: every theme in one place, your own
themes made in a few clicks, wallpapers, fonts and blur per theme, workspace presets, and an optional AI
helper that suggests themes. It is the desktop app version of the
[Theme Manager](https://plugins.omarchy.org/plugin.html?id=ubruckhaus.theme-manager) plugin for Omarchy,
and uses the same theme format (Omarchy's `colors.toml`), so themes move freely between them.

## Features

- **All themes in one list**: apply, favorite, hide or delete (with Undo), type to filter, keyboard first.
  The desktop, its terminal and the usual apps (editors, btop, …) follow the theme's colors.
- **Your own themes**: start from any theme or from a picture, pick colors (with a sample desktop that shows
  the result as you go), a font and blur, rename and edit them later.
- **Font & effects per theme**: a monospace font, an interface font and blur for any theme, also the ones you
  did not make. Applying the theme uses them; a theme without them gives you your own back.
- **Wallpapers**: per theme, added by drag and drop, paste or a Wallhaven search; one wallpaper per workspace,
  a slideshow, day and night themes.
- **Imports**: themes from [omarchy.org](https://omarchy.org/themes), cosmic-themes.org and the KDE Store.
- **Presets**: workspace layouts and window limits, App Presets (apps that start on their workspace),
  and saved combinations of theme, wallpaper and workspaces.
- **Keyboard shortcuts** for themes and actions, a panel applet (COSMIC) or tray daemon (KDE).
- **Ask AI** (off by default): describe what you want and get up to three themes to look at, from Claude Code,
  Codex, pi or Hermes, or a local model. It runs only when you click Ask, without tools (Codex read-only in a jail), and gets only your
  words, the installed themes' names and colors, the names of up to 300 omarchy.org catalog themes and your
  font names.
- **Backup and restore** of all settings.

## Build and install

Needs Flutter (Linux desktop), Dart, Rust (cargo) and, for COSMIC, the COSMIC development libraries.

```bash
tools/install-local          # build everything and install it for this user (~/.local, no root)
tools/install-local --no-build
```

`FLUTTER` may point to Flutter's `bin` folder if `flutter` is not on `PATH`. The app starts from the app
launcher as **Maprisma Theme**; `maprisma-theme --toggle` shows or hides it.

Coming from Omarchy? `tools/import-omarchy <folder>` copies your Omarchy themes, wallpapers and Theme Manager
settings over once.

## Repository

| Folder | What |
| --- | --- |
| `flutter_app/` | The Flutter app (`com.maprisma.Theme`) |
| `packages/maprisma_theme_core/` | The Dart core: themes, wallpapers, imports, Ask AI, automation, desktop backends; a JSON protocol for the app and a CLI |
| `cosmic/` | Rust: the COSMIC helper (applies themes, talks to the compositor) and the panel applet |
| `themes/`, `templates/` | Omarchy's system themes (colors and app configs) and app templates |
| `packaging/`, `tools/` | Desktop entries, icon, install and import scripts |
| `docs/` | Design notes: `plan.md`, `multi-desktop.md`, `theme-looks.md`, `protocol.md`, … |

Tests: `dart test` in `packages/maprisma_theme_core`, `flutter test` in `flutter_app`.

## Bundled themes and artwork

`themes/` holds the colors and app configs of Omarchy's system themes (MIT, see `themes/LICENSE.omarchy`).
Their **wallpapers, preview and unlock pictures are not included**: the rights to that artwork belong to its
artists. The app draws each theme's preview from its colors; add wallpapers per theme in the app, or import
them from your Omarchy install with `tools/import-omarchy`.

## License

MIT, see `LICENSE`. Omarchy's theme files: MIT, see `themes/LICENSE.omarchy`.
