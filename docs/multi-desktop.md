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
  the same `wm` JSON. Tiling: on when Krohnkite is installed+enabled (per workspace not available in
  Krohnkite → `tiling` cap only global).
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
  long-lived script, request ids, timeouts); Krohnkite has no external control API → `tiling` off on KDE
  until shown to work.

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
3. **Daemon + tray icon**; coordinated automation handover from the COSMIC applet.
4. **KDE workspaces/windows/shortcuts** (KWin bridge script + kglobalaccel actions); presets live-tested.
5. Optional: Plasma panel widget.

## Who does what

Claude: Dart core + Flutter (steps 1–3), commits. Codex: plan review, KWin script and Konsole/Plasma
format checks (step 2/4), read-only crosscheck of every step. Findings are verified before fixing.
