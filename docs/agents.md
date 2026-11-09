# Working on Maprisma Theme (for every agent)

Read first: `docs/plan.md`, `docs/cosmic-interface.md`, and the plugin's README
(`/mnt/Data/Projects/omarchy-theme-manager/README.md`) — that README is the feature spec. Port the
plugin's Python faithfully (its files are listed at the end of its README), adapted to COSMIC as
docs/plan.md says. English only: no i18n, no `_()`; use the plugin's English texts. No manual.

## Layout and conventions

- Core (pure Dart, no Flutter): `packages/maprisma_theme_core/lib/src/`. Shared pieces you use, don't
  rewrite: `paths.dart` (Paths), `store.dart` (readSmall, readJson, writeJson atomic 0600, chmodPath),
  `colors.dart` (Omarchy colors.toml parse/resolve/templates, mixColor, contrast), `themes.dart`
  (ThemeInfo, discoverThemes, listBackgrounds, Lists: hidden/favorites/recent, Current), `apply.dart`
  (applyTheme, setBackground, startWallpaper, themeColors), `desktop.dart` (Desktop interface:
  COSMIC + maprisma-theme-helper; FakeDesktop for tests), `context.dart` (Ctx, Handler, RouteError,
  str/optStr/intParam/boolParam), `bounded.dart` (readBoundedText/runBounded: argv, caps, deadlines),
  `posix.dart` (which(), readRegular, writeNewPrivate, withFlock), `settings.dart` (Settings keys).
- Each module owns `lib/src/<module>_routes.dart` (already registered in routes.dart; fill in the map)
  plus any new `lib/src/*.dart` files. Export new public files from `lib/maprisma_theme_core.dart` only
  if the Flutter app needs them (add one line; keep others' lines).
- A route is `'area.verb': (params) async => {...}`; refusals `throw RouteError('code', 'message')`.
- GUI: `flutter_app/lib/pages/<page>.dart` (stubs exist: keep the class names and constructor
  parameters, others already call them). Use `AppScope.of(context)` / `AppScope.read(context)`:
  `.call(method, params)`, `.run(method, params)` (null on failure, shows the error), `.notify(text,
  undo:)` (snackbar with Undo, Ctrl+Z), `.changed()` (other pages reload, window restyles), `.settings`.
  Helpers in `widgets.dart`: `item()` menu rows, `Tag`, `ColorPreview`, `confirm()`, `pickWorkspaces()`,
  `SubPage`. Native window: `window.dart` (AppWindow: hide, drops of files/images, dragging).
  Esc/Backspace on a sub page go back (Navigator.maybePop) unless a text field has focus.
- Security as in the plugin: argv only (one exception: launching an app goes through a fixed `/bin/sh -c` script in `launchers.dart` whose variable parts are passed as quoted arguments, never pasted into it), every subprocess/network read size- and time-bounded,
  HTTPS only with exact URL shapes, images header-checked before decoding (16384 px/side, 64 MP),
  untrusted text shown as plain text.
- Tests: core tests in `packages/maprisma_theme_core/test/<module>_test.dart` using `test/support.dart`
  (TestEnv: temp HOME, FakeDesktop; never touch the real ~/.config). Widget tests optional in
  `flutter_app/test/`. Never write to the real COSMIC config, never call the network in tests.
- Run: `export PATH=/mnt/Data/flutter/bin:$PATH`; `dart analyze` + `dart test test/<yours>` in the core
  package, `flutter analyze` in flutter_app. Do NOT run `flutter build` (others work in parallel), do
  NOT commit (Claude commits), do NOT edit other modules' files; if you need something from another
  module that is not there yet, code against the contract below and say so in your report.

## Modules and cross-module contracts

| Module | Owner files | Provides to others |
| --- | --- | --- |
| wallpaper (A) | wallpaper_routes.dart, wallpapers.dart, images.dart, trash.dart, wallhaven.dart; pages/wallpapers_page.dart, pages/wallhaven_page.dart | routes `wallpapers.list {slug}`, `wallpapers.add_files {slug, paths}`, `wallpapers.add_bytes {slug, data(base64), type}`, `wallpapers.add_clipboard {slug}`, `wallpapers.hide {slug, name, hidden}`, `wallpapers.delete {slug, name}` → `{receipt}`, `wallpapers.undo_delete {receipt}`, `wallpapers.set {slug?, path}`, `wallpapers.preview {path}` / `wallpapers.preview_end`, `themes.delete {slug}` → `{receipt}`, `themes.undo_delete {receipt}`, `wallhaven.search/add`; Dart: `images.dart` `imageSizeProblem(path)`, `pngMetadataProblem` |
| custom (B) | custom_routes.dart, custom.dart, preview_draw.dart, extract.dart; pages/editor_page.dart | routes `custom.editor {base?, edit?, wallpaper?}` → editor data, `custom.save {...}` → `{slug}`, `custom.from_wallpaper {path}` → colors, `fonts.list`; Dart `createThemeFolder(...)` (used by import for cosmic-themes.org themes), `drawPreview(colors, wallpaper?) -> png bytes` |
| auto (C) | auto_routes.dart, auto.dart, shortcut_routes.dart, shortcuts*.dart, apps.dart, backup_routes.dart, backup.dart, health; pages/settings_page.dart, pages/shortcut_page.dart, screenshots.dart | routes in docs/protocol.md "auto" (`auto.step_background {direction}`, `auto.step_theme`, `auto.workspace {workspace}`, `auto.tick`, `auto.menu`, `auto.schedule`/`auto.schedule_set {day?, night?, enabled?, day_at?, night_at?}`, `auto.workspace_themes` → `{themes: {ws: slug}}`, `auto.set_workspace_themes {slug, workspaces}`, `auto.use_everywhere` → `{saved}`, `auto.undo_use_everywhere {saved}`, `auto.workspace_wallpapers {slug}` → `{map: {ws: name}}`, `auto.set_workspace_wallpaper {slug, name, workspaces}`), `shortcuts.labels` → `{labels: {target: [label]}}` with targets `apply:<slug>`, `open`, `bg:next`, `bg:prev`, `theme:next`; Dart `renameThemeState(ctx, old, new)`, `forgetThemeState(ctx, slug)`, `writeAutomation(ctx)` (sets ctx.onAutomationChange) |
| import (D) | import_routes.dart, catalog_omarchy.dart, catalog_cosmic.dart, plugin_catalog.dart; pages/import_page.dart, pages/info_page.dart | routes `import.omarchy_list`, `import.omarchy_install {name, apply?}`, `import.cosmic_list {search?, sort?, page?}`, `import.cosmic_install {id, apply?}`, `info.plugins` |
| presets (E) | preset_routes.dart, presets.dart, workspace_state.dart, launchers.dart; pages/presets_page.dart | routes `presets.*`, `workspaces.*`, `apppresets.*`, `presets.autostart` (CLI `autostart`) |
| ask (F) | ask_routes.dart, ask_ai.dart, theme_ai.dart; pages/ask_page.dart | routes `ask.helpers`, `ask.run {helper, request, refine?}`, `ask.cancel`, `ask.signin`; opens `EditorPage(base:, initial:)` or the import page's install for omarchy.org themes |

Rust parts (`cosmic/`) are Codex's. The helper's commands are in docs/cosmic-interface.md; call them
through `ctx.desktop.helperJson([...])`.
