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
