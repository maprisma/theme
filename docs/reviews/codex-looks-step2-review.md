Found five issues worth fixing before merging. No files changed; this was a source review, without running tests in the read-only environment.

1. **P2 — Saving one mode cannot undo changes to both modes.**  
   [looks.dart:158](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/looks.dart:158) captures only the active mode, while [theme.rs:212](/mnt/Data/Projects/maprisma-theme/cosmic/helper/src/theme.rs:212) modifies both. If dark and light have different blur settings, applying a look destroys the inactive mode’s original settings; restoring `own_blur` then copies the active mode’s original settings into both. `maximized` is also copied between modes despite the promise to preserve it.  
   **Fix:** snapshot and restore both modes independently, and apply look fields as patches so each mode retains its own `maximized` value. Test distinct dark/light states through apply → mode switch → restore.

2. **P2 — A partially failed write can lose the user’s original blur.**  
   [looks.dart:162](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/looks.dart:162) saves `own_blur` only after the helper succeeds. The helper writes builders and themes sequentially at [theme.rs:248](/mnt/Data/Projects/maprisma-theme/cosmic/helper/src/theme.rs:248). If the active mode succeeds but the inactive mode fails, the desktop has changed without a saved original. A retry can save the already modified state as the user’s own blur.  
   **Fix:** persist the original snapshot before mutation and retain it on failure; preferably roll back partial helper writes too. Add failure injection after each write, followed by retry and restore.

3. **P2 — RON imports silently discard theme-owned appearance values.**  
   [main.rs:31](/mnt/Data/Projects/maprisma-theme/cosmic/helper/src/main.rs:31) unconditionally calls `keep_desktop_settings`, which replaces `window_hint` and every frosted field at [theme.rs:159](/mnt/Data/Projects/maprisma-theme/cosmic/helper/src/theme.rs:159). A RON theme’s explicit hint color and frosted appearance therefore never apply. Its blur is also absent from `themeBlur`, which only reads look metadata and `theme-manager.json`.  
   **Fix:** distinguish generated color themes from native RON themes. Preserve user layout settings deliberately, but let native appearance values participate in look → theme → user precedence. Test a RON fixture with a distinctive hint color and blur configuration against conflicting current settings.

4. **P2 — Preset appearance undo does not restore blur exactly.**  
   [presets.dart:350](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/presets.dart:350) captures fonts, but neither desktop blur nor `own_blur`. Undo at [presets.dart:416](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/presets.dart:416) merely reapplies the previous theme. For example, manually adjust blur while a blur look is active, apply another preset, then undo: reapplication restores the look’s configured blur rather than the state before the preset.  
   **Fix:** capture both desktop blur and its ownership snapshot in the receipt; restore them after reapplying the previous theme. Extend the existing exact-font-undo test to blur, including manual changes.

5. **P2 — Preset routes bypass the lock protecting the blur ownership chain.**  
   `looks.set` and normal theme application use `autoLocked`, but [preset_routes.dart:323](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/preset_routes.dart:323) and the undo route call appearance operations without it. Concurrent preset and look/theme applications can interleave blur reads, helper writes, and `own_blur` updates, capturing a themed value as the original. The daemon queue does not serialize another process.  
   **Fix:** use the same lock for preset capture plus appearance mutation, assignment application, and appearance undo. Keep internal apply functions unlocked to avoid recursive locking. Test overlapping operations with a paused fake blur read/write.

Other requested checks:

- **Rebuilding `Theme` is correct.** At the pinned libcosmic revision, `ThemeBuilder::build()` derives alpha and colors from frosted settings, so changing only flags in the built theme would be insufficient. Rebuilding each independently loaded mode is reasonable; the restoration model needs to match that scope.
- **System-default fallback works.** `cosmic_config::ConfigGet::get()` falls back to system defaults for missing local keys, including the palette guard. An untouched light mode with packaged defaults is therefore loaded and updated. However, if no palette exists anywhere, the guard discards valid partial settings too. Load entries over a mode-specific default builder instead of treating missing palette as proof that the whole builder is absent.
- **Strength mapping is sound:** endpoints map to 0 and 13; one duplicate is unavoidable when mapping 15 values onto 14.
- **Settings validation is too permissive:** [settings.dart:106](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/settings.dart:106) accepts arbitrary small maps. A malformed saved strength can throw in `blurAsLook`; invalid restoration data can remain stuck indefinitely. Validate known COSMIC fields and ranges on load.
- I could not obtain COSMIC Settings source locally or remotely. The rebuild assessment above follows the pinned local libcosmic source; exact parity with Settings’ toggle handler remains unverified.