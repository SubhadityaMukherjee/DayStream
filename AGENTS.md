# AGENTS.md — DayStream contributor/agent guide

Native macOS (SwiftUI + AppKit) daily-notes app over a plain markdown vault (Logseq-compatible).

## Commands

```sh
./scripts/build_and_install test     # generate project + build + run XCTest — the verification command
./scripts/build_and_install release  # Release build, install to ~/Applications, launch
xcodegen generate                    # regenerate DayStream.xcodeproj from project.yml (after adding files)
```

Always run `xcodegen generate` after creating/moving source files, and `./scripts/build_and_install test` before declaring work done. There is no linter configured; keep style consistent with surrounding code.

## Architecture

- `project.yml` is the source of truth for the Xcode project; the `.xcodeproj` is generated and committed.
- `Sources/Model/` — pure logic, no UI: `BlockTree` (outliner parser + todo toggling/syncing), `VaultStore` (vault I/O, watching, migration), `JournalDate` (filename formats), `CarryForward`, `WikiName`. Most logic is unit-tested in `Tests/`.
- `Sources/Views/` — SwiftUI: `DailyStreamView` (List of `DaySectionView`), `CalendarView`, `PageView` (wikilink pages + linked references), `SettingsView`. The editor *is* the view — `DaySectionView` and `PageView` render `MarkdownEditorView` directly with live markdown preview; there is no rendered/editing split and no edit mode to enter or leave.
- `Sources/Editor/MarkdownEditorView.swift` — AppKit `NSTextView` wrapper, content-fitting (full note height; the stream scrolls, the editor doesn't), with outliner key bindings. Space-bar handling uses a local keyDown monitor because SwiftUI's ScrollView eats unmodified space. `[[` autocomplete is a non-activating NSPanel (`WikiSuggestController`) that must never take key focus. The text view owns the text while editing: never re-introduce a per-keystroke `Binding`/`@State` round-trip through SwiftUI (it re-rendered the section's glass chrome every key press — laggy typing, jumpy caret). External text reaches the editor only via `pushedText`; callers keep live text in `EditorSession` (a class held by `@State`, so keystrokes don't invalidate views). Typing saves go through `VaultStore.writeAsync` (I/O + parse off-main, generation-guarded so stale snapshots can't roll back `days`). Live markdown preview (`Sources/Editor/LiveMarkdown.swift` + `EditorTextView`'s `NSLayoutManagerDelegate`): syntax on lines away from the caret is hidden by nulling glyphs — the raw characters never leave the text storage, so saves/undo/autocomplete/outliner all see plain markdown. Don't implement hiding by mutating the storage instead; and keep syntax styling and hiding on the same regexes (both live in `LiveMarkdown`). The editor draws gutter glyphs over hidden bullet prefixes (checkboxes for task lines, dashes for plain bullets — only on non-active lines; the horizontal `textContainerInset` is the gutter, text starts at a fixed column); clicking a drawn checkbox (or the marker word on the caret's line, or ⌘⏎) toggles the task. Hidden bookkeeping property lines collapse to zero height via `shouldSetLineFragmentRect` — don't leave blank stripes. `added::`/`completed::` drive the drawn duration badge (`drawDurationBadge`), and a toggle to DONE stamps `completed::` in-editor (`stampCompletion`) so badges work like the old rendered checkboxes. ⌘⏎ fires `onTodoToggled` → callers echo the state across notes via `VaultStore.syncTodoState` (the editor never does cross-note writes itself). Every day is an editor now, so focus is opt-in: never auto-`makeFirstResponder` at creation (scrolling materializes cells); focus only rides `caretAtEndRequest` (⌘N / add-todo).
- `Sources/App/` — `DayStreamApp` (Window + Settings), `AppModel` (selection/navigation state), `AppSettings` (UserDefaults-backed), `GlobalQuickAddController` (system-wide quick-add shortcut → opens app + new todo today).
- `@Observable` everywhere; `VaultStore` mutates `days` in place to avoid full-list SwiftUI rebuilds (block IDs are `line-<index>` so unchanged rows keep identity across edits).

## Conventions & gotchas

- Files are the database: all writes go through `VaultStore.write` (atomic + in-place refresh). Watcher-triggered reloads are suppressed for ~0.8s after our own writes.
- Todo syncing across notes must stay off the main thread (see `syncQueue` in `VaultStore`); the sync algorithm parses once and edits lines in place — never change line counts in `toggledFileText` output.
- Journal filename formats: `yyyy-MM-dd.md` (new), `yyyy_MM_dd.md`, `dd-MM-yyyy.md` (legacy). New files always use ISO format. `migrateLegacyFilenames()` backs up to `backup/` before renaming.
- macOS SwiftUI `ScrollView` + `LazyVStack` materializes rows lazily but never releases them — scrolling a large vault ballooned memory to ~1GB. The stream uses `List` (NSTableView-backed, recycles cells) instead; don't switch it back. Recycled cells mean `DaySectionView` must reset edit state when its `day` changes.
- Journal filenames render in the **local** timezone (`allFilenames`), but parsing stays UTC — `startOfDay` instants are local midnight, whose UTC day differs in UTC+/- zones. Don't "simplify" either side.
- UI strings are plain English; code comments explain *why*, not *what*. No comments unless necessary.
- macOS 15+ deployment target; Swift 5, minimal strict concurrency.

## Git / release flow

- `develop` is the **default branch** and where all work lands — feature branches merge into it.
- `main` is **release-only**: it is updated solely by merging `develop` for a release; no direct commits.
- Releases: merge `develop` → `main`, bump `MARKETING_VERSION` in `project.yml`, tag `vX.Y.Z` on `main`, push the tag.
- CI (`.github/workflows/build.yml`): build + test on pushes/PRs to `main`/`develop`, release zip on `v*` tags, deploy GitHub Pages on `main` pushes.
- Commit style: short imperative subject lines, like existing history.
