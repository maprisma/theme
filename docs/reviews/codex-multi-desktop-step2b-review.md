Found six concrete issues:

- **[P2] Filtered-empty pages hide subsequent results.** [catalog_kde.dart:129](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/catalog_kde.dart:129), [import_page.dart:232](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/import_page.dart:232)  
  If API page 0 contains only archives or rejected entries, `themes` is empty while `next_page` is valid. The gallery’s empty-list branch omits the footer, hiding “Load more”; there is also nothing to scroll. Valid schemes on subsequent pages become inaccessible.

- **[P2] Missing palette groups produce themes that cannot render app templates.** [catalog_kde.dart:199](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/catalog_kde.dart:199)  
  A file containing only valid Window background/foreground passes validation. Conversion supplies no red/green/yellow/blue/magenta/cyan, and `resolveColors` cannot derive these without source colors. Terminal/editor templates needing those values consequently fail rendering, although installation succeeds. Supply usable defaults or reject schemes that cannot support the promised conversion.

- **[P2] Conversion discards the selection foreground.** [catalog_kde.dart:238](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/catalog_kde.dart:238)  
  For a light scheme with black Window text and a dark selection background with white `Colors:Selection/ForegroundNormal`, conversion retains the selection background but drops its white text. Resolution substitutes the normal black foreground, making selected text difficult or impossible to read in generated terminal/editor themes. Preserve `selection_foreground` explicitly.

- **[P2] `_seen` retains expired download URLs indefinitely.** [catalog_kde.dart:139](/mnt/Data/Projects/maprisma-theme/packages/maprisma_theme_core/lib/src/catalog_kde.dart:139)  
  List a scheme, let its tokenized download URL expire or the author replace its file, then install it without fetching a list containing that ID again. `kdeEntry` always returns the old entry; download failure never invalidates it or retries the detail endpoint. Repeated installations keep failing until a fresh list overwrites that ID or the process restarts.

- **[P2] Pagination can mix results from different searches during debounce.** [import_page.dart:849](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/import_page.dart:849)  
  Load query A with another page available, type query B, then scroll or click “Load more” within 400 ms. `more()` uses B’s live search text with A’s next-page number and generation. If it finishes before the debounce fires, it appends B’s later-page results to A’s list. Capture the loaded query for pagination and invalidate requests when search changes.

- **[P2] A transient preview failure suppresses retries for the tab’s lifetime.** [import_page.dart:875](/mnt/Data/Projects/maprisma-theme/flutter_app/lib/pages/import_page.dart:875)  
  The ID is inserted into `previews` before requesting it. If the request throws or returns a null path, that empty entry remains, and every later `wantPreview` returns immediately. Restoring connectivity, changing sort, or searching back to the same scheme never retries its preview. Clear failed entries or provide a bounded retry mechanism.

No additional concrete defect found in the host checks, single redirect boundary, byte caps, folder collision handling, duplicate detection, native KDE application/alternation, or KDE-versus-RON capability precedence.

Files unchanged. Review was static; Dart and Flutter were unavailable on `PATH`.