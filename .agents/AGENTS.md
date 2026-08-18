# DayStream — Agent Context

Quick context for AI agents (and future humans) working in this repo.

## What this app is

DayStream is a native macOS (SwiftUI + AppKit) daily-notes app that reads/writes a plain markdown vault — the same layout Logseq uses (`journals/`, `pages/`, `assets/`). Files are the database; the app is a view + editor over them.

## Non-negotiables

1. **Never lose user notes.** All writes atomic (`String.write(atomically:)`). Destructive operations (migration, cleanup, delete) back up first or refuse to touch non-empty files.
2. **Never change line counts when toggling todos** (`BlockTree.toggledFileText`) — line indices are block identities; the sync algorithm and UI diffs depend on 1:1 line mapping.
3. **Cross-note todo sync runs off the main thread** (`VaultStore.syncQueue`) and applies results back on main. Checkbox clicks must feel instant.
4. **The `.xcodeproj` is generated.** `project.yml` is the source of truth. After adding/moving files: `xcodegen generate`.
5. **Verify with `./scripts/build_and_install test`** before declaring work done. That regenerates the project, builds, and runs XCTest.

## Key maps

| Area | Files |
|---|---|
| Outliner parse / todo toggle / sync | `Sources/Model/BlockTree.swift` |
| Vault I/O, watching, migration, cleanup, mentions | `Sources/Model/VaultStore.swift` |
| Journal filename formats | `Sources/Model/JournalDate.swift` (ISO `yyyy-MM-dd.md` is canonical) |
| Carry-forward algorithm | `Sources/Model/CarryForward.swift` |
| Wikilink ↔ filename mapping | `Sources/Model/WikiName.swift` |
| Stream UI | `Sources/Views/DailyStreamView.swift` → `DaySectionView` → `BlockRowView` |
| Editor (AppKit) | `Sources/Editor/MarkdownEditorView.swift` |
| App shell / menu bar / settings | `Sources/App/` |
| Tests | `Tests/*.swift` |

## Tricky spots

- **Space bar:** SwiftUI's ScrollView eats unmodified space before `keyDown`. The editor installs a local `NSEvent` monitor (see `Coordinator.installSpaceMonitor`) that inserts the space when its text view is first responder. Don't remove this.
- **Editing vs. external changes:** `DaySectionView` keeps `draft` + `base`; external text is adopted only when the user hasn't typed since the last sync, so a stale editor can never clobber disk.
- **Same date, multiple filename formats:** a day can exist as `2026_08_18.md` and `18-08-2026.md`. `JournalDay.editFile` picks the content-bearing one; `editFile`/`displayFiles` must be used instead of `files.first`.
- **Watcher debounce:** `VaultStore.lastSelfWrite` suppresses watcher reloads for ~0.8s after our own writes to avoid redundant reloads/flicker.

## Scripts

- `./scripts/build_and_install [test|release|build-only|clean]` — build pipeline (installs XcodeGen via brew if missing).
- `./scripts/migrate_filenames <vault> [--apply]` — standalone legacy-filename migration (dry run by default, backs up to `backup/`).

## Branches & CI

- `develop` — active development. `main` — stable; `vX.Y.Z` tags cut from it.
- `.github/workflows/build.yml`: build+test on push/PR; `v*` tags → GitHub Release with `DayStream-macOS.zip`; `main` pushes → deploy GitHub Pages site (`docs/index.html`).

## Author

Subhaditya Mukherjee
