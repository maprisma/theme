# The core protocol

The Flutter app talks to the Dart core (`packages/maprisma_theme_core`) with one JSON object per request
and one per answer (`lib/src/protocol.dart`, `lib/src/core.dart`).

## Frames

Request (at most 64 KiB):

```json
{"protocol": 1, "id": 7, "method": "themes.apply", "params": {"slug": "nord"}}
```

`id` is a non-negative integer chosen by the caller; `params` is an object (optional).

Answer (at most 4 MiB; a larger result becomes the error `response_too_large`):

```json
{"id": 7, "result": {"applied": "nord", "done": ["cosmic", "wallpaper", "terminal"]}}
{"id": 7, "error": {"code": "not_found", "message": "no theme nord"}}
```

Error codes are short snake_case words (`bad_request`, `bad_params`, `not_found`, `exists`, `bad_url`,
`too_large`, `clone_failed`, `internal`, …); `message` is plain text for the user.

## Methods

Each module owns its routes in `lib/src/<module>_routes.dart`; `lib/src/routes.dart` lists them all.
The name before the dot is the module:

| Prefix | File | What |
| --- | --- | --- |
| `core.hello` | `core.dart` | version, protocol and desktop |
| `themes.*` | `theme_routes.dart` | theme list, apply, hide, favorite, delete with Undo |
| `settings.*`, `desktop.*` | `settings_routes.dart` | settings page values, the desktop's look |
| `wallpapers.*`, `wallhaven.*` | `wallpaper_routes.dart` | per-theme wallpapers, Wallhaven search and download |
| `custom.*`, `fonts.*`, `looks.*` | `custom_routes.dart` | theme editor, fonts, Font & effects (`docs/theme-looks.md`) |
| `auto.*`, `apps.*` | `auto_routes.dart` | workspace themes and wallpapers, slideshow, day/night, app colors |
| `shortcuts.*` | `shortcut_routes.dart` | keyboard shortcuts |
| `import.*`, `info.*` | `import_routes.dart` | omarchy.org, cosmic-themes.org and KDE Store imports; Information page |
| `presets.*`, `workspaces.*`, `apppresets.*`, `tiling.*`, `animations.*` | `preset_routes.dart` | workspace presets, App Presets, tiling, animations, saved presets |
| `ask.*` | `ask_routes.dart` | Ask AI helpers and requests |
| `backup.*`, `health.*` | `backup_routes.dart` | backup export and restore, integration health |

The parameters of each method are documented next to its route.

## Command line

`maprisma-theme-core` runs one request and prints its answer as JSON, for the panel applet, the tray daemon
and keyboard shortcuts (`lib/src/cli.dart`):

```
maprisma-theme-core apply <slug> | bg next|prev | theme next|prev | workspace <n> | tick | menu | autostart | status
maprisma-theme-core daemon
```
