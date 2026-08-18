# Decision Log

Short record of *why* things are the way they are, so agents don't undo them.

## Editor: AppKit `NSTextView` in SwiftUI (not TextEditor)

SwiftUI's `TextEditor` scrolls internally, can't do per-line syntax highlighting cheaply, and intercepts key events unpredictably. The custom `NSTextView` inside a content-fitting `NSScrollView` gives outliner key bindings (Enter/Tab/⇧Tab), live highlighting, drag & drop, and a non-scrolling editor that grows with content inside the outer stream `ScrollView`.

## Space bar: local NSEvent monitor

SwiftUI's outer `ScrollView` claims unmodified Space during the key-equivalent phase for page-scrolling; `performKeyEquivalent` in the text view does not reliably win. A **local keyDown monitor** (installed per-editor, removed in `dismantleNSView`) checks that our text view is the window's first responder, inserts the space, and swallows the event. Anything else passes through untouched.

## Todo sync: snapshot → background queue → main-thread apply

Checkbox clicks used to parse every note in the vault on the main thread (O(files × matches) re-parses). Now: one snapshot of candidate texts on main, single parse + surgical line edits per file on `syncQueue` (QoS userInitiated), writes applied back on main. `BlockTree.syncedText` also prefilters with a cheap `contains(longest key word)` before parsing, and toggles all matching lines found in **one** parse instead of re-parsing after each edit (safe because toggles never change line counts).

## Block identity: `line-<index>`

SwiftUI diffs rows by `Block.id`. Using the bullet's line index keeps unchanged rows stable across a one-line todo rewrite, so only the toggled row re-renders. Consequence: **any text transform that changes line counts breaks identity** — keep toggles surgical.

## Same-date multi-file days

Real vaults contain the same date as `2026_08_18.md` and `18-08-2026.md`. Loading groups by parsed date; `editFile` prefers the content-bearing file (format rank order ISO → `yyyy_MM_dd` → legacy) so an empty newer-format sibling never shadows real content. Empty siblings are hidden from rendering (`displayFiles`).

## Filename migration

Canonical format is ISO `yyyy-MM-dd.md`. `VaultStore.migrateLegacyFilenames()` copies every original into `<vault>/backup/` before renaming; if the target exists with identical content the legacy copy is dropped, if it differs it's skipped (conflict). Mirrored by `scripts/migrate_filenames` (dry-run by default) for use outside the app.

## Branching

`develop` = active work, `main` = stable + `vX.Y.Z` tags. Tagged builds produce `DayStream-macOS.zip` GitHub Releases; `main` pushes deploy the GitHub Pages site from `docs/index.html`.

## Menu bar panel

`MenuBarExtra` with `.window` style — a real popover window with a TextField (menu style doesn't support text input). Quick-add appends `- TODO <text>` to today's canonical file via `ensureTodayFile()` so it never duplicates existing files.

## Task timestamps (`added::` / `completed::`)

Quick-add, recurring injection, and ⌘S on *today's* note stamp open tasks with `added:: yyyy-MM-dd HH:mm` (local) as a tab-indented property line right under the bullet. Toggling to DONE stamps/updates `completed::` in the file the click happened in only — cross-note sync (`syncedText`) never adds lines, it only flips markers, preserving the line-count invariant. Duration capsule in the stream renders only when both stamps parse.

## Recurring tasks

`RecurringTaskStore` (UserDefaults JSON) holds daily / weekly(weekday) / once(date) tasks. `VaultStore.applyRecurringTasks` prepends due tasks via `addTask`, which duplicate-checks against the note's content keys (same normalization as carry-forward), so re-running on every launch/reload/midnight-rollover is idempotent. Triggered from `AppModel`: vault setup, Today button, `createDayNote` (so calendar-clicked empty days get their tasks), and a 60s rollover timer.

## Wikilink routing

`MarkdownText` classifies each `[[target]]`: if `WikiDate.parse` matches (ISO, `Aug 18th, 2026`, `18 Aug 2026` variants) the link goes to `daystream://date?value=yyyy-MM-dd` → reveal/create that day in the stream; otherwise `daystream://page?name=…` → PageView. PageView renders front-page-style (BlockRowView + linked references) with a raw-editor toggle; ⎋/⌘S save and return to rendered. Double-click-to-edit uses `simultaneousGesture` so plain link clicks still work.

## Editor extras

`EditorTextView` handles ⌘S (`onSaveCommit`: `NoteFormatter.normalizedForSave` — drop empty bullets, blank line between top-level wikilink groups and what follows, stamp `added::` today-only — then quit editing). `[[` triggers a page-name suggestion popover (`WikiSuggestController`, self-drawing rows, transient NSPopover that refuses first responder so typing is uninterrupted; ↑/↓/⏎/⇥ navigate). `VaultStore.allPageNames()` (pages dir + every wikilink target, 5s TTL cache) feeds both the popover and search.

## Deadlines

`DeadlineStore` (UserDefaults JSON, like recurring tasks) holds `{title, date}` items. Sidebar section lists them soonest-first with relative labels (`Today`, `Tomorrow`, `Fri`, `Aug 30`, `Overdue 2d` — red). Clicking one goes through `createDayNote` (creates + seeds + reveals). On the due date the title is seeded into the day's note via `VaultStore.applyDeadlines` → `addTask(atTop:)`, same duplicate-checked path as recurring tasks, so completing or keeping the task never re-duplicates. Deadlines stay listed until manually removed — "persistent" per the feature request.

## Search

`VaultStore.search` walks every loaded journal file (newest day first) then every page file, case-insensitive substring per line, capped at a limit. `SearchBarView` (MainView) debounces 150ms, shows a content-sized dropdown (no inner scroll views — they're greedy and break panel sizing), journal hits → `reveal(day:)`, page hits → `PageRef` sheet.

## Docs site

`docs/index.html` is the entire GitHub Pages site (single file, no build step; dark mode via `prefers-color-scheme`). Badges must reference things that exist — the repo has no LICENSE file, so no license badge. `docs/icon.png` is a copy of the app icon.
