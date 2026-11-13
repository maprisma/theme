# Interface between the Dart side and the Rust side

All programs print JSON on stdout (one object, or JSON lines for `watch`), errors as
`{"error": "<code>", "message": "..."}` with exit status 1. Paths are absolute. Nothing runs through a
shell. Workspace numbers are 1-based in the order COSMIC shows them on the output the user works on
(the focused output; with "workspaces span displays" all outputs share them).

## `maprisma-theme-helper` (Rust, `cosmic/helper`, Codex)

Built against libcosmic rev `95236a944bfd51c63a2fc65fe50a592c47168d40` (as the other applets in
/mnt/Data/Projects/cosmic-*), crates `cosmic-theme`, `cosmic-config`, `cosmic-client-toolkit` /
`cosmic-protocols`.

| Command | Does | Prints |
| --- | --- | --- |
| `apply --colors <file.json>` | Builds a COSMIC `ThemeBuilder` from Omarchy-style colors (below), writes it to the Dark or Light builder config, builds the `Theme` and writes that too, sets `com.system76.CosmicTheme.Mode` `is_dark` to match. Gaps, the active hint and blur stay as the mode in use has them. Exactly what COSMIC Settings does on "import", so every running COSMIC app restyles at once | `{"applied": true, "mode": "dark"}` |
| `apply --ron <file.ron> [--mode dark\|light]` | Same with a ThemeBuilder RON file (cosmic-themes.org download, COSMIC Settings export). Mode from the file's palette (`Dark(..)`/`Light(..)`) unless given. Files over 1 MiB or unparsable: `bad_theme` | as above |
| `blur` | Blur ("frosted") per mode: strength 0..13 (BlurStrength) and where it is used; a mode never written is null | `{"mode": "dark", "dark": {"strength": 6, "windows": false, "system": false, "panel": false, "applets": false, "maximized": false}, "light": null}` |
| `set-blur <json>` | `{dark, light}` (each mode as given) or one change for both modes, written to the Theme Builder and built into each Theme; rolled back when a write fails (docs/theme-looks.md) | as `blur` |
| `ron-colors <file.ron>` | Reads a ThemeBuilder RON and prints the Omarchy-style colors derived from it (for the terminals and previews) | the colors object |
| `current` | The colors of the COSMIC theme in use now, and `is_dark`, `corner_radius` (px of the window corners, `radius_s`… as COSMIC uses for windows) | `{"colors": {...}, "is_dark": true, "corner_radius": 8}` |
| `terminal --colors <file.json> --name <name>` | Writes a COSMIC Terminal color scheme called `<name>` (replacing an earlier scheme of Maprisma Theme, recognisable by a fixed name prefix `Maprisma: `) and selects it for the matching mode. Must follow cosmic-term 1.11's real config format (`com.system76.CosmicTerm/v1`) | `{"written": true}` |
| `workspaces` | The workspaces | `{"workspaces": [{"index": 1, "name": "1", "active": true, "tiling": true, "output": "DP-1"}], "can_tile": true}` |
| `set-tiling <index> on\|off` | `set_tiling_state` on that workspace | `{"done": true}` / `not_available` |
| `windows` | The toplevels | `{"windows": [{"id": "<stable id for this session>", "app_id": "...", "title": "...", "workspace": 2, "output": "DP-1", "active": false}]}` |
| `move <id> <index>` / `close <id>` / `activate <id>` | toplevel management | `{"done": true}` / `not_found` |
| `watch` | Runs until stdin closes; JSON lines `{"event":"workspace","index":3}` (active workspace changed), `{"event":"window_new","id":..,"app_id":..,"workspace":..}`, `{"event":"window_closed","id":..}`, `{"event":"window_moved","id":..,"workspace":..}` | lines |

KDE-only wm commands (`tile-style`, `set-tile-style`, `animations`, `set-animations`) are answered by
`KdeDesktop.wm` in Dart, not by this helper; see docs/multi-desktop.md.

### The colors object (Omarchy `colors.toml`, as JSON)

```json
{"mode": "dark", "background": "#2e3440", "foreground": "#d8dee9", "accent": "#81a1c1",
 "selection": "#434c5e", "muted": "#4c566a", "cursor": "#d8dee9",
 "black": "#…", "red": "#…", "green": "#…", "yellow": "#…", "blue": "#…", "magenta": "#…",
 "cyan": "#…", "white": "#…", "bright_black": "#…", … "bright_white": "#…",
 "orange": "#…", "corner": null}
```

Every value `#rrggbb`; `mode` may be missing (then: dark when the background's luminance < 0.5). For the
ThemeBuilder: `bg_color` = background, `accent` = accent, `text_tint` = foreground, palette
blue/red/green/yellow from the colors, `neutral_tint` from the background's hue, `corner_radii` from
`corner` (`round`, `slightly_round`, `square`, null = keep the current one). Missing keys keep COSMIC's
default palette values.

## Panel applet (Rust, `cosmic/applet`, Codex)

App id `io.github.ubruckhaus.CosmicMaprismaTheme`, icon: a paint brush (symbolic). Tooltip
"Maprisma Theme · scroll: wallpaper · right-click: favorites".

- **Left click**: `maprisma-theme --toggle` (shows or hides the window; starts it if not running).
- **Scroll** up/down: `maprisma-theme-core bg prev` / `bg next` (debounced, one at a time).
- **Right click**: a popup from `maprisma-theme-core menu` →
  `{"title": "Favorite themes", "themes": [{"slug", "name", "current"}], "empty_note": "...",
  "items": [{"id": "next_wallpaper", "label": "Next wallpaper"}, {"id": "open", "label": "Open Maprisma Theme"}]}`.
  A theme row runs `maprisma-theme-core apply <slug>`, `next_wallpaper` runs `bg next`, `open` runs `--toggle`.
- **Automation**: reads `~/.config/maprisma-theme/automation.json` (written by the core whenever a setting
  changes; re-read when it changes):
  ```json
  {"workspace_events": true, "tick": true,
   "tiling": {"active": false, "default_limit": 2, "limits": {"3": 1}, "floating": [5], "tiled": [1, 2]},
   "autostart": true}
  ```
  - `workspace_events`: on every change of the active workspace run `maprisma-theme-core workspace <index>`.
  - `tick`: once a minute `maprisma-theme-core tick`.
  - `tiling.active`: keep each workspace's tiling as listed (`floating` off, `tiled` on, others untouched),
    and when a new window makes a workspace exceed its limit (`limits[index]` or `default_limit`), move it to
    the next workspace with room (windows the user moves by hand stay where they are).
  - `autostart`: once per login session (a marker in `$XDG_RUNTIME_DIR/maprisma-theme/`) run
    `maprisma-theme-core autostart`.
- Core calls run one at a time with a 60 s limit; the applet never blocks its UI on them.
- Programs are found next to the applet's binary or on PATH (`~/.local/bin`).

## `maprisma-theme-core` CLI (Dart, Claude)

`apply <slug>`, `bg next|prev`, `theme next|prev` (favorites), `workspace <n>`, `tick`, `menu`,
`autostart`, `status`, `list`. JSON on stdout. `list` (route `themes.brief`) is for Maprisma
Manager's Appearance page: `{current, themes: [{slug, name, current, favorite, hidden, preview,
colors}]}` in the Themes page's order, without wallpapers or desktop queries.

## COSMIC 1.11 implementation notes

- The pinned `cosmic-theme` uses **v2** for both `CosmicTheme.{Dark,Light}.Builder`
  and built `CosmicTheme.{Dark,Light}` entries; mode remains v1. Import writes all
  three through the typed API. A null/missing JSON corner preserves the current
  mode's radii even when changing modes. Native RON retains its own radii.
- Terminal's schema was verified against `cosmic-term` **epoch-1.11.0**, `src/config.rs`
  and `src/main.rs`: `color_schemes_dark/light` is a map from transparent u64 IDs
  to schemes, hex colors are bare strings, and **`syntax_theme_dark/light` selects
  by scheme name**, not ID. One `Maprisma: ` scheme per mode is replaced; unrelated
  schemes remain. Explicit per-profile syntax theme overrides remain effective.
  See https://github.com/pop-os/cosmic-term/blob/epoch-1.11.0/src/config.rs .
- Workspace ordering is by protocol coordinates within the focused window's
  output group. If no window is focused, the output with the lexicographically
  first name is the deterministic fallback (there is no generic focused-output
  event in these protocols). Windows on other independent output groups have
  `workspace: null`; overflow automation leaves those windows alone. Spanned
  workspace groups share the same numbering. Indices can change as COSMIC adds
  or removes workspaces.
- Stable window IDs use `ext_foreign_toplevel_handle_v1.identifier`, never proxy
  IDs. COSMIC batches initial extended properties on a refresh timer; initialization
  waits up to 500 ms for that batch after roundtrips. `move` requires management
  v4 and its `move_to_ext_workspace` capability. Requests may still be ignored by
  the compositor; `done` means the supported request was sent and synchronized.
- `watch` emits an initial active-workspace event, but does not emit `window_new`
  for preexisting windows. It exits on stdin EOF, reconnects through the applet,
  and reports only windows that become mapped after the initial snapshot as new.
- Automation is reread once a second. Overflow searches existing workspaces
  forward then wraps once; if all are full the window stays. A new window moved
  by the user before its queued overflow check is left alone. Limits are clamped
  to 1–4. The applet serializes core/helper action calls and bounds the action
  queue; the long-lived read-only watch runs separately. Autostart is claimed
  atomically in the runtime directory with the login session ID.
- Every short subprocess has a 60-second deadline and at most 1 MiB stdout.
  Theme/automation/terminal-scheme file reads are bounded to 1 MiB. The GUI toggle
  starts a normal long-lived GUI process; it is reaped without killing it after
  60 seconds. No subprocess uses a shell.
