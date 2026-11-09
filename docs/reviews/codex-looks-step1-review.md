Found five correctness issues worth fixing before building the dialog.

1. **High — Valid Plasma QFonts are treated as desktop defaults, losing the user’s font.**  
   [desktop_kde.dart:587](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/desktop_kde.dart:587) uses `qfontFamily()`, whose parser at [kde_formats.dart:126](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/kde_formats.dart:126) requires every field after the family to be numeric. Qt serializes a textual style name, including `Regular`; KDE explicitly sets that style in its defaults. Consequently, reading a valid font returns null, setting it replaces its size/style with fallback values, and the own-value chain records `(default)` instead of the real family. Followers also fail to match.  
   **Fix:** Support actual Qt 6 serialization, preserving the suffix when replacing the family; distinguish an absent key from an invalid/unreadable value. Add fixtures with `Regular`, an empty style name, and nondefault size/weight. See [Qt serialization](https://raw.githubusercontent.com/qt/qtbase/dev/src/gui/text/qfont.cpp) and [KDE font defaults](https://raw.githubusercontent.com/KDE/plasma-workspace/master/kcms/fonts/fontssettings.kcfg).

2. **High — `looks.set` bypasses the lock protecting theme application.**  
   [looks.dart:184](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/looks.dart:184) saves and applies fonts without `autoLocked`, unlike `themes.apply`. A daemon/workspace apply can interleave during font enumeration or writes. Both calls can read an empty own setting, then one records the other theme’s font as the user’s own; alternatively, a look can finish applying after a different theme becomes current.  
   **Fix:** Put look replacement, the current-theme check, and font application inside the same `autoLocked` transaction. Test overlapping GUI `looks.set` and daemon/workspace application with delayed backend setters.

3. **Medium — Presets override looks and can contaminate the own-font chain.**  
   The new application chain at [apply.dart:82](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/apply.dart:82) is immediately overridden by [presets.dart:308](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/presets.dart:308). A preset captured before a look was added silently replaces that look’s font. For a fontless preset theme, the direct setter also leaves `own_font` empty: the next font-bearing theme captures the preset font as “own,” losing the original user font. Preset undo similarly writes fonts directly and does not capture interface-font or own-setting state.  
   **Fix:** Define preset-font precedence explicitly and pass preset overrides through the shared font-state mechanism. Capture/restore both font roles and their own settings for appearance undo. Test stale presets, fontless preset themes, default fonts, and undo.

4. **Medium — KDE restoration can change a follower that originally had an independent family.**  
   [desktop_kde.dart:599](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/desktop_kde.dart:599) recomputes follower membership on every change. Example: general font is A, toolbar independently uses B; applying a look with B correctly leaves the toolbar alone. Restoring A now sees both families as B and changes the toolbar to A. Reset at line 618 can likewise delete an independently configured font, including its size/weight.  
   **Fix:** Remember which follower keys were changed, together with their original values/presence, and restore only those keys. Test an independent follower whose family equals the incoming look.

5. **Medium — Partial KDE writes can replace the real font without saving a restoration value.**  
   [desktop_kde.dart:604](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/desktop_kde.dart:604) writes the general font before its followers. If a later command fails, it returns false after already changing the general font. [looks.dart:138](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/looks.dart:138) then skips saving `own_ui_font`; a retry can capture the partially applied font as the user’s own.  
   **Fix:** Snapshot and roll back all affected keys on failure, or persist a recoverable restoration receipt before mutation. Test failure on the second write and subsequent retry/restoration.

Additional coverage and contract gaps:

- [looks.dart:157](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/looks.dart:157): `looks.get` omits the documented `own` values. `current` cannot substitute while another theme’s fonts are active. Return the saved own value, falling back to current only when no saved value exists.
- Existing KDE tests inspect command logs against numeric-only fixtures; they do not exercise a real configuration round trip or write failures.
- Add integration tests for actual rename/forget routes, delete → undo retaining looks, workspace A → B → base restoration, and Ask AI themes with a font plus a look override.

The COSMIC path and RON fields match [libcosmic’s configuration](https://raw.githubusercontent.com/pop-os/libcosmic/master/src/config/mod.rs). Backup inclusion/validation and retaining looks until `themes.forget` appear consistent with the design. Wallpaper previews only change the background, so they do not enter the font chain; Ask AI fonts stored in theme metadata do enter it.

No files modified. Tests were not run: `dart` is unavailable on PATH, and the workspace is read-only.