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

## Shared Ask AI rules and provenance

Theme implements the shared contract in
`../maprisma-settings/docs/ask-ai-rules.md`. Manual requests omit `proposal` and
remain unrestricted. `ask.run` returns a random session-only `proposal` on every
candidate; `ask.wallpapers` returns one for its theme's wallpaper workflow. The
core keeps its action ids, theme target and catalog source in memory. Unknown
ids, mismatched actions/targets/sources and disallowed steps fail with
`ask_ai_blocked`, message `Switched off in Maprisma Settings › AI`.
Editor proposals retain their identity when the user edits their target.

These execution routes accept optional `proposal`:

| Routes | Required action ids |
| --- | --- |
| `themes.apply`, `wallpapers.set` | `theme.apply` |
| `import.omarchy_install`, `import.cosmic_install`, `import.kde_install` | `theme.install`; also `theme.apply` with `apply: true` |
| `custom.save` | `theme.edit`; also `theme.apply` with `apply: true` or when editing the current theme |
| `create.make`, `create.setup` | `theme.generate` |
| `wallhaven.add`, `webimg.add`, `create.add` | `theme.wallpapers`; also `theme.apply` with `set: true` |

`themes.apply` and `custom.save` also accept `with_wallpaper: true` for the
Ask card's following wallpaper step: both `theme.wallpapers` and `theme.apply`
are checked before the first change. The wallpaper step keeps the same proposal
and checks again. The GUI carries provenance through cards, the editor, search
phrase buttons, generated pictures, previews' result items and already-added
wallpaper paths. Manual searches clear their search provenance.

`ask.rules {}` returns `{level, actions, sources, folders, broken}` read afresh
from the shared settings. The GUI uses this when showing Ask actions and
refreshes visible results every two seconds. A disabled action shows the shared
message and a Settings link. `ask.open_settings {}` starts
`maprisma-settings --page ai` detached with argv, without a shell. Answers,
searches and previews remain available.

The core checks at entry and after preparation before publishing changes.
Request-local Dart zones carry the check into asynchronous preparation without
mixing concurrent manual requests. Every attempted Ask execution records its
proposal as `op`, app `theme`, action id(s), target and `done`, `failed`,
`cancelled` or `blocked`. Background generator setup reports its eventual
outcome, rather than treating setup launch as completion. Logging is best effort.

Rules live in `$XDG_CONFIG_HOME/maprisma-ai/settings.json` (fallback
`~/.config`). Missing rules allow actions; unreadable/oversized/non-object files
and malformed values are restrictive. Explicit JSON null is malformed; absent
keys retain defaults. Only Settings writes rules. Theme's helper writer takes
libc `flock(LOCK_EX)` on persistent `settings.lock`, rereads under the lock,
refuses an existing broken file, creates an O_EXCL 0600 temporary file, writes
and fsyncs it, then renames it over the settings, preserving other keys.

The shared log is `$XDG_STATE_HOME/maprisma-ai/actions.jsonl` (fallback
`~/.local/state`). Writers lock persistent `actions.lock` with libc flock,
then open the log O_APPEND|O_CREAT|O_NOFOLLOW, checking the open descriptor is a
regular file owned by the user. Writes loop to completion. Folder mode is 0700,
file and lock modes 0600. Above 1000 lines or 1 MiB, rotation keeps the newest
500 complete lines using an O_EXCL, fsynced temporary file and rename under the
same lock. A symlink/unowned log folder or unsafe log/lock file is refused.
