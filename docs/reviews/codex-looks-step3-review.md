Found three **P2 (medium)** issues.

1. **Missing `blurEnabled` incorrectly means “load blur.”**  
   [desktop_kde.dart:305](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/desktop_kde.dart:305), also line 290.

   KWin’s default is conditional: blur defaults off on software rendering and several GPU families. The installed metadata explicitly enables that default method. Hardcoding `{'blur': true}` therefore changes the user’s effective state during restoration. For example, starting with no key and blur unloaded, applying a blur-off look and then a plain theme loads blur; `looks.dart` then clears `own_blur_kde` because restoration reported success. Rollback has the same assumption. [KWin’s implementation](https://raw.githubusercontent.com/KDE/kwin/Plasma/6.8/src/plugins/blur/blur.cpp)

   **Fix:** preserve effective loaded state alongside the raw keys in the snapshot, and restore both. Alternatively, delegate missing-key default resolution to KWin. Update the documentation’s unconditional “missing = enabled” claim. Test missing keys with blur initially unloaded.

2. **A failed strength reconfigure reports success and bypasses rollback.**  
   [desktop_kde.dart:311](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/desktop_kde.dart:311)

   With blur already loaded, `_writeEffects` only verifies that it remains loaded. If `reconfigureEffect` fails or times out, `restoreBlur` still returns `true`, leaving the new strength on disk while the running effect retains its previous strength. On own-state restoration, [looks.dart:168](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/looks.dart:168) then discards the saved state despite incomplete restoration.

   **Fix:** include reconfiguration in the checked transaction. On failure, restore both raw keys and reconfigure the restored effect; return `false` so the own-state snapshot remains available. Add a fake failure specifically for `reconfigureEffect`, including the restore-own path.

   The **method itself is correct**: KWin reparses its configuration and calls the loaded effect’s `reconfigure`. [KWin’s handler](https://raw.githubusercontent.com/KDE/kwin/Plasma/6.8/src/effect/effecthandler.cpp)

3. **Unsupported blur is always advertised as available.**  
   [desktop_kde.dart:279](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/desktop_kde.dart:279)

   `blurState()` always returns a map, so `lookData()` always exposes blur controls. KWin requires OpenGL compositing for blur; installed metadata and the configuration module do not establish runtime support. An unsupported compositor repeatedly reaches writes, failed loading, and rollback on every themed apply. Currently `applyLookBlur` silently returns `false`, rather than emitting a route error, but availability remains incorrectly advertised. [KWin’s support check](https://raw.githubusercontent.com/KDE/kwin/Plasma/6.8/src/plugins/blur/blur.cpp)

   **Fix:** query `/Effects org.kde.kwin.Effects.isEffectSupported blur` before exposing or applying blur; return unavailable/null without writes when unsupported or unreachable. Keep `own_blur_kde` intact if restoration cannot currently run. Test unsupported separately from supported-but-refusing-to-load.

The **strength default of 15 and range 1–15 are correct**. I confirmed the installed configuration module’s default and slider bounds, consistent with KDE’s [schema](https://raw.githubusercontent.com/KDE/kwin/Plasma/6.5/src/plugins/blur/blur.kcfg) and [Plasma 6.8 UI](https://raw.githubusercontent.com/KDE/kwin/Plasma/6.8/src/plugins/blur/blur_config.ui).

The shared stateful `kwriteconfig6` fake looks suitable for these flat groups and preserves unrelated keys. Its main coverage gap is the D-Bus fake: reconfiguration always succeeds without modelling runtime strength. Existing rollback coverage checks persisted keys for one load refusal, but cannot catch finding 2.

No files modified. Tests were inspected, not executed under the read-only filesystem restrictions.