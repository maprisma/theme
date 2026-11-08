Found four issues. Paths below are under `packages/maprisma_theme_core/lib/src/`.

- **P2 — Changed COSMIC error precedence:** [shortcuts.dart:386](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/shortcuts.dart:386) resolves commands before the binder reads the custom file. With an existing shortcut, malformed COSMIC `custom`, and missing `maprisma-theme-core`, `health.repair` now throws `not_installed`; HEAD throws `not_available` with “COSMIC's custom shortcuts file cannot be read: …”. This violates the exact error requirement.

- **P2 — Generic current theme is missing:** [desktops.dart:55](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/desktops.dart:55) always returns null. With a valid applied theme recorded in `current.json`, an injected GenericDesktop makes `desktop.look` return empty colors and default darkness instead of the applied theme’s values required by the plan.

- **P2 — Missed protocol caller:** [apply.dart:57](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/apply.dart:57) still emits `done: ['cosmic']`. An injected backend with another ID that successfully applies colors reports that ID in `core.hello` and `desktop.look`, but reports COSMIC in the apply result. Step 1 explicitly requires protocol values from `desktop.id`.

- **P3 — Empty override silently falls back:** [desktops.dart:19](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/desktops.dart:19) treats an explicitly set empty/whitespace `MAPRISMA_THEME_DESKTOP` as absent. For example, `MAPRISMA_THEME_DESKTOP=''` with `XDG_CURRENT_DESKTOP=COSMIC` selects COSMIC instead of rejecting the invalid override.

Otherwise, inspection against HEAD found helper argv/timeouts, COSMIC health values, shortcut bytes, shadow handling, write order, and rollback order preserved. Rename/delete and backup restore/rollback/repair reach the binder through `ThemeShortcuts`. Production still constructs CosmicDesktop. Import cycles are legal Dart; no affected Flutter caller depends on the moved CosmicDesktop export.

No files modified; tests/analyzer not run.