# DayStream

A fast, native macOS app that turns a plain markdown vault (Logseq-compatible) into one endless, scrollable stream of daily notes. No cloud, no lock-in — just `.md` files on disk.

Author: **Subhaditya Mukherjee**

## What it does

- **Daily-notes stream** — every dated note in `journals/`, newest first, with a month calendar sidebar for quick navigation. Notes for new days are created automatically (launch, Today button, calendar clicks, midnight rollover). One window, no tabs — re-opening just brings it back.
- **Outliner editing** — Enter continues bullets, Tab/Shift-Tab indent/outdent, `/todo `/`/doing `/`/later `/`/done ` slash commands, TODO-family markers with live syntax highlighting. Saving (⌘S or closing the editor) auto-formats: consistent tabs and `-` bullets, collapsed blank runs, and blank lines between different block kinds (text, lists, `[[wikilink]]` groups, code fences).
- **Markdown code blocks** — fenced ` ``` `/`~~~` blocks render as monospaced cards (with the language label from the info string), stay byte-identical through auto-formatting, and get their own highlighting in the editor.
- **Task timing** — captured tasks record `added::` timestamps; completing one stamps `completed::` and the stream shows how long it took next to the finished task.
- **Task syncing** — checking a task rewrites matching tasks in every other note (journals and pages alike).
- **Recurring tasks & deadlines** — daily / weekly / once tasks (Settings → Recurring) seed themselves at the top of the due day's note, duplicate-checked so they never double up. Deadlines pin in the sidebar with countdowns and jump to their day.
- **Carry forward** — one click copies all unfinished tasks from previous days into today's note, preserving structure.
- **[[Wikilinks]] & pages** — typing `[[` suggests existing page names; pages open as a rendered view with Logseq-style Linked References; date-shaped links (`[[Aug 18th, 2026]]`) jump to that day.
- **Search** — ⌘F opens the search bar with the caret ready; one bar across every journal and page, hits jump to their day or page, Esc closes.
- **Keyboard-first** — ⌘N appends a fresh todo to today and drops the caret in it; ⌘F finds; a system-wide shortcut (⌥T by default, recordable in Settings → Shortcuts) opens the menu bar applet from any app.
- **Menu bar applet** — quick-add a task for today or schedule it to any date, and toggle today's open tasks without leaving what you're doing.
- **Git backup** — commit and push the vault to its git remote in one click (Settings → Advanced), or automatically on a daily/weekly schedule (off by default, weekly suggested).
- **Image & file drops** — dropped images are copied into `assets/` and embedded with relative markdown links.
- **Live on disk** — external edits are picked up via file watching; the vault is safe to use from other tools at the same time.

## Requirements

- macOS 15+
- Xcode 16+ (to build)

## Building

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`:

```sh
./scripts/build_and_install            # Debug build → ~/Applications → launch
./scripts/build_and_install release    # Release build
./scripts/build_and_install test       # Build + run unit tests
```

The script installs XcodeGen via Homebrew on first run if needed.

## Vault layout

DayStream expects either:

- a **vault root** containing `journals/` (a Logseq vault works as-is), or
- the `journals/` directory itself.

Recognized journal filename formats: `yyyy-MM-dd.md` (current convention, used for new files), `yyyy_MM_dd.md`, and `dd-MM-yyyy.md` (legacy). Legacy formats can be migrated in one click: **Settings → General → Maintenance → Migrate legacy filenames** — originals are copied to `backup/` first. There is also a standalone script:

```sh
./scripts/migrate_filenames /path/to/vault           # dry run
./scripts/migrate_filenames /path/to/vault --apply   # backup + rename
```

## A sample note

```markdown
- TODO Ship the parser fix
	added:: 2026-08-19 09:12
	- [[Parser Notes]] has the failing cases
- DONE Reply to Alice about the review
	added:: 2026-08-19 08:40
	completed:: 2026-08-19 10:02

- [[Gym]] log — 45 min, easy pace

- Snippet from yesterday's debugging:
	```sh
	git log --oneline -5
	```
```

What the pieces do: `TODO`/`DONE` markers render with checkboxes; `added::` / `completed::` properties power the duration badge (`1h 22m`) next to finished tasks; `[[Parser Notes]]` opens a page with every mention of it (Linked References); code fences render as monospaced cards; blank lines between different block kinds are kept by auto-format.

## Documentation

- Full usage guide & FAQ (GitHub Pages): https://subhadityamukherjee.github.io/DayStream/
- This README renders on the repo home page.

## Branching & releases

- **develop** — active development. CI (GitHub Actions) builds and runs tests on every push/PR.
- **main** — stable. Version tags (`v1.0.0`, …) live here; each tag builds a `DayStream-macOS.zip` and publishes a GitHub Release automatically.

## Project structure

```
Sources/
  App/        App entry point, app model, settings, menu bar panel, setup
  Model/      Vault store, block tree parser, journal dates, carry-forward, wiki names
  Views/      Stream, day sections, block rows, calendar, pages, settings
  Editor/     AppKit-based markdown editor with outliner behaviors
Tests/        XCTest suites for parsing, carry-forward, wiki names, vault behavior
scripts/      build_and_install, migrate_filenames
docs/         GitHub Pages site source
```

See `.agents/` and `AGENTS.md` for contributor/agent instructions.
