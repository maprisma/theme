# Maprisma Theme on more than one desktop

Goal: the same app on COSMIC and KDE Plasma, and open for a third desktop later, without a second
app. One Flutter UI, one Dart core; only a **desktop backend** differs. A new desktop costs one backend
class (plus a color template), and every feature it cannot do is hidden, not broken.

Status 2026-11-08: COSMIC only (`CosmicDesktop` is hard-wired in `core.dart`). The user now runs
KDE Plasma 6.8 on CachyOS (Wayland). Nothing may regress on COSMIC.

## What is already desktop-neutral

- Themes (Omarchy `colors.toml`), catalogs, imports, editor, Ask AI, wallpaper files, backups.
- App colors: `apps.dart` `AppSpec` + `templates/*.tpl` (alacritty, kitty, foot, ghostty, helix,
  neovim, vscode, btop) — written whatever the desktop is.
- The helper's JSON for workspaces and windows (`docs/cosmic-interface.md`): 1-based workspace index,
  window `{id, app_id, title, workspace, output, active}`, `move/close/activate/set-tiling`. Nothing
  in it is COSMIC-specific, so it becomes the **window-manager contract** every backend answers.

## Where COSMIC leaks today

| Place | Leak | Goes to |
| --- | --- | --- |
| `core.dart:16` | `CosmicDesktop` hard-wired | `selectDesktop(paths, env)` |
| `desktop.dart` `helperJson` | raw helper argv | `wm(args)`: same JSON, answered by the backend |
| `shortcuts.dart` | COSMIC shortcuts file format | `ShortcutStore` interface, COSMIC impl = today's code |
| `backup.dart` 299–345 health | COSMIC helper, applet id, CosmicPanel files | `desktop.health()` |
| `apply.dart` / `custom.dart` `cosmicNative` | RON themes need COSMIC to apply | RON → colors via `ronColors`, applied as colors elsewhere |
| `cosmic/applet` | automation (workspace events, tick, tiling limits, autostart) lives in the COSMIC panel applet | `maprisma-theme-core daemon` (step 3) |
| Texts | "COSMIC" in errors/UI | backend `name` |

## Design

### Backend interface (`desktop.dart`)

`Desktop` keeps its methods (minimal churn at call sites) and gains:

- `String get id` (`cosmic`, `kde`, `generic`, `fake`) and `String get name` ("COSMIC", "KDE Plasma").
- `Set<Cap> get caps` — what this backend can do:
  `appearance` (applyColors/current), `ron` (applyRon natively), `wallpaper`, `terminal` (the desktop's
  own terminal scheme), `fonts`, `icons`, `workspaces` (list + events), `tiling`, `windows`
  (list/move/close/activate), `shortcuts`, `panel` (native panel applet installed).
- `Future<Map<String, dynamic>?> wm(List<String> args, {Duration timeout})` replaces `helperJson`.
  Same commands and JSON as the COSMIC helper. A backend without `workspaces`/`windows` answers
  `{"error": "not_available"}`.
- `ShortcutStore? get shortcuts` (null without `shortcuts`).
- `Future<List<Map<String, dynamic>>> health()` — the backend's lines for the health check.

Calls a backend cannot do return false/null as today; callers that need a cap check `caps` first and
throw `RouteError('not_available', '<feature> is not available on <name>')`.

### Selection (`desktops.dart`)

`selectDesktop(paths, env)`: `MAPRISMA_THEME_DESKTOP` override (`cosmic|kde|generic`), else
`XDG_CURRENT_DESKTOP` (colon list, case-insensitive): contains `COSMIC` → CosmicDesktop, `KDE` →
KdeDesktop (step 2), otherwise GenericDesktop. GenericDesktop: no caps, `current()` from the applied
theme; app templates still work. New route `desktop.info` → `{id, name, caps}`.

### UI

The app reads `desktop.info` once (AppScope) and hides what the backend lacks: Presets/workspace pages
without `workspaces`, tiling controls without `tiling`, shortcut page without `shortcuts`, font/icon
rows, "COSMIC Terminal" row → backend terminal name. Info page names the backend. No per-desktop pages.

### KDE backend (step 2/4)

- Colors: new `templates/kde.colors.tpl` (Plasma color scheme from Omarchy colors), written to
  `~/.local/share/color-schemes/Maprisma.colors` (alternating name to force a reload), then
  `plasma-apply-colorscheme`. `current()` from kdeglobals.
- Wallpaper: `plasma-apply-wallpaperimage <path>`; snapshot/restore from the applet config.
- Terminal: Konsole `.colorscheme` (`~/.local/share/konsole/Maprisma.colorscheme`) + default profile.
- Fonts: `kwriteconfig6 kdeglobals General fixed`; icons: `plasma-changeicons`.
- Workspaces/windows: KWin D-Bus (`/VirtualDesktopManager`) + a small KWin script loaded on demand
  (`org.kde.KWin /Scripting loadScript`) that lists/moves/closes windows and reports events. Answers
  the same `wm` JSON. Tiling: available when Maprisma Tiling is installed; workspaces are excluded by 1-based index.
- Shortcuts: kglobalaccel D-Bus (`setForeignShortcutKeys`), component `maprisma-theme`.
- Panel: StatusNotifierItem tray icon (step 3); a Plasma widget is optional later.

### Automation daemon (step 3)

`maprisma-theme-core daemon`: subscribes to `wm watch` of the active backend; does what the COSMIC
applet does now (workspace events, minute tick, tiling limits, autostart once per session) and shows a
StatusNotifierItem tray icon (click: toggle window, scroll: wallpaper, menu: favorites). On COSMIC the
applet keeps its icon but leaves automation to the daemon (one owner, `flock` in XDG_RUNTIME_DIR).
Started by an XDG autostart entry.

## Codex plan review (2026-11-08), verified and folded in

- More leaks: protocol values `'cosmic'` (`core.dart` hello, `settings_routes.dart` desktop.look,
  `apply.dart` `done: ['cosmic']`); shortcut lifecycle outside shortcuts.dart (`auto.dart` rename/delete,
  `backup.dart` restore/rollback/repair) → all go through `ThemeShortcuts`, which delegates to the
  backend's `ShortcutBinder`; preset semantics (ten workspaces, Tiled/Floating/Native, per-workspace
  tiling) and their UI texts/drawing describe COSMIC's tiling; persistent state shared across desktops
  (`own_font`, workspace/base-theme state) → namespace per desktop when a second backend goes live.
- Health keeps its response shape (`helper/core/applet/shortcuts`); the backend fills `helper`/`applet`,
  the binder fills `shortcuts`.
- `wm watch` is a stream, not a call: only the Rust applet uses it today; the daemon (step 3) gets a
  separate subscription API (snapshot, reconnect, cancel). Keep the applet's guarantees (queue bound 64,
  startup marker, 15 s tiling reconciliation, manual-move cancellation, reconnect).
- Caps finer where the UI needs it; gate **operations**, not whole pages (appearance presets work
  without a WM). Preflight before an apply changes anything. Keep `not_available`, `not_found` and
  transport failures distinct.
- Selection: exact colon tokens, invalid override = error, an injected desktop wins, never inferred from
  installed binaries.
- KDE: alternate scheme **basenames** (the tool skips an already-selected scheme); wallpaper snapshot
  through Plasma's live scripting API, not by rewriting appletsrc; Konsole profile ≠ colorscheme
  (profile selects scheme, preserve the user's profile, live reload is separate); fonts are serialized
  QFonts + settings notification; kglobalaccel needs registered actions plus a listener (or desktop-entry
  actions), not just `setForeignShortcutKeys`; KWin needs an explicit script↔D-Bus bridge (one
  long-lived script, request ids, timeouts); Maprisma Tiling re-reads its settings on KWin reconfigure.

## Steps (one branch each, tests green, Codex crosscheck before merge)

1. **Backend seam, pure refactor** (`multi-desktop/1-backends`): `Cap`, `id/name/terminalName`, `wm`
   (was `helperJson`), `ShortcutBinder` (COSMIC binder = today's code verbatim; every lifecycle caller
   through `ThemeShortcuts`), backend `health()` with the same response shape, `DesktopBase`,
   `selectDesktop` + GenericDesktop written and unit-tested **but production still constructs
   CosmicDesktop**, `desktop.info` route added. Protocol values come from `desktop.id` (= `cosmic`).
   Characterization tests stay green unchanged.
2. **Go multi-desktop**: activate `selectDesktop`; Generic = template-only apply, `current()` from the applied theme (Codex step-1 finding) (explicit success
   without desktop appearance), RON → colors when the desktop cannot apply RON; UI gates operations by
   caps; per-desktop state namespacing; KdeDesktop appearance: colors, wallpaper, Konsole, fonts, icons.
2b. **KDE Store import** (user request 2026-11-08): a third Import tab next to omarchy.org and
   cosmic-themes.org, shown on every desktop. Source: the KDE Store's public OCS API
   (`https://api.kde-look.org/ocs/v1/content/data?categories=112&sortmode=high|new&search=&page=`,
   category 112 = Plasma color schemes, ~2200 items with `previewpic1`, `score`, `downloadlink1`/
   `downloadname1` = a `.colors` file; checked 2026-11-08). Install = download the `.colors` (HTTPS,
   exact host shapes `api.kde-look.org` / `files*.pling.com` / `images.pling.com`, size-capped, parsed
   as INI before it is kept), convert to Omarchy colors (`colors.toml`: Window → background/foreground,
   Selection → accent/selection, View/Complementary for the shades, Negative/Positive/Neutral/Link/
   Visited for red/green/yellow/blue/magenta) and keep the original as `kde.colors` in the theme folder
   (like `cosmic.ron`). On KDE such a theme is applied with its own file (`kdeNative`), elsewhere as
   its colors. Later maybe: Konsole Color Schemes (category 462) as terminal palettes.
3. **Daemon + tray icon**; coordinated automation handover from the COSMIC applet.
4. **KDE workspaces/windows/shortcuts** (KWin bridge script + kglobalaccel actions); presets live-tested.
5. Optional: Plasma panel widget.

### Steps 3 and 4 as built (2026-11-08)

- **KWin bridge** (`kwin_bridge.dart`, Codex): one short KWin script per request (state, move, close,
  activate), loaded/run/unloaded over `org.kde.KWin /Scripting`, answering through `callDBus` to the
  caller's unique bus name; one long-lived watcher script for `watch` events, reloaded when KWin
  restarts. `KdeDesktop.wm` answers the wm contract with it (`set-tiling` → not_available).
- **KDE keys** (`shortcuts_kde.dart`): each key is a hidden desktop file
  `~/.local/share/applications/maprisma-theme-key-<target>.desktop`; kglobalaccel runs it itself
  (a "service" component, as System Settings' Add Command). The files are the wanted state;
  `syncKdeShortcuts` makes kglobalaccel match (after each change, at daemon start, when shortcuts.json
  changes). A key another action had is taken and given back after (`kde-shadowed.json`).
- **Daemon** (`daemon.dart`, `maprisma-theme-core daemon`): KDE only (on COSMIC the applet keeps
  ownership, so no handover is needed); single instance by bus name `com.maprisma.Theme.Daemon`;
  StatusNotifierItem tray icon + com.canonical.dbusmenu menu (favorites, Next wallpaper, Open); the
  applet's automation ported (queue ≤ 64 with coalescing, minute tick, workspace themes, window limits
  with the applet's overflow rule, autostart once per session). Started by
  `~/.config/autostart/com.maprisma.Theme.Daemon.desktop` (`OnlyShowIn=KDE;`) and by the installer.
- All D-Bus use goes through the backend's own environment (`DBUS_SESSION_BUS_ADDRESS`); tests have
  none, so they never reach the real session.
- KDE caps: appearance, kdeScheme, wallpaper, terminal, fonts, icons, workspaces, windows, shortcuts.
  Per-workspace `tiling` uses Maprisma Tiling; `panel` remains unavailable. The script enforces window limits, so the daemon skips overflow moves.

## Who does what

Claude: Dart core + Flutter (steps 1–3), commits. Codex: plan review, KWin script and Konsole/Plasma
format checks (step 2/4), read-only crosscheck of every step. Findings are verified before fixing.
