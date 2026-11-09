Found five issues:

1. **P2 — Esc stops cancelling when a font field has focus.** [look_dialog.dart:71](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/look_dialog.dart:71)  
   Flutter’s `DropdownMenu` installs a `DismissMenuAction` that consumes Esc even when its menu is closed. After selecting a font, Esc therefore leaves the dialog open. Add explicit Escape handling around the font controls: close an open dropdown first, then cancel the dialog when no dropdown is open. Test this through Menu-key entry, font selection, and Esc; assert that cancellation never calls `looks.set`.

2. **P2 — An unavailable saved font is displayed as “Theme default”, but still submitted.** [look_dialog.dart:76](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/look_dialog.dart:76), [look_dialog.dart:168](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/look_dialog.dart:168)  
   `initialSelection` falls back to null, while `mono`/`ui` retain the saved family. Changing only blur then submits that hidden family, and the backend rejects the entire save as “not installed”. This also affects retained fields whose controls are hidden on the current desktop. Undo similarly cannot restore an unavailable family through the current `looks.set` validation. Display the saved family explicitly, marked unavailable, and allow unchanged stored families to survive replacement and Undo through an appropriate backend validation/restore contract. Add tests for both visible and capability-hidden saved values.

3. **P2 — A failed save discards the dialog’s edits.** [look_dialog.dart:18](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/look_dialog.dart:18), [look_dialog.dart:167](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/look_dialog.dart:167)  
   Save pops the dialog before awaiting `looks.set`. Any validation, transport, or filesystem failure leaves only a snackbar; reopening requires re-entering every change. Submit while the dialog remains mounted, disable duplicate submissions, retain its state on failure, and close only on success. Test failure followed by a successful retry.

4. **P2 — Form controls lack accessible field names.** [look_dialog.dart:69](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/look_dialog.dart:69), [look_dialog.dart:143](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/look_dialog.dart:143)  
   The row labels are separate `Text` widgets, with no semantic association to the dropdowns or slider. A screen reader focusing either font field gets its value/default description without identifying which font it controls; the slider likewise lacks “Blur strength”. Supply control labels through `DropdownMenu.label` or explicit semantics, label the slider, and identify the blur group. Verify the focused controls’ semantic labels in tests.

5. **P3 — The theme-details entry required by step 4 is missing.** [themes_page.dart:244](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/themes_page.dart:244)  
   The action exists only in the theme-card menu. The theme’s details/wallpapers page has no corresponding action. Add a capability-gated “Font & effects…” action there, reusing this dialog and restoring focus afterward.

Capability naming is correct: the menu checks desktop `fonts`/`uiFont`/`blur`, while the dialog checks the translated `looks.get` keys. Ordinary Undo correctly restores the previous stored look, applying it immediately only if that theme is currently in use. `looks.get` failures are reported through `app.run`.

The new tests cover a successful inactive-theme save and restricted capabilities, but omit active-theme editing, Undo, keyboard entry/cancellation, unavailable fonts, and failures. The presets helper’s eight rounds add fixed waiting—about 808 ms per default call—without establishing completion; a bounded wait for the expected state would be more reliable.

Review was read-only. Tests were not run because they write temporary files, build outputs, and screenshots.