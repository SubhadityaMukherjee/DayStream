# Ideas

## Doable

- [x] For deadlines in the sidebar, show how many days left (labels now always include the count: "Fri · 3d", "Sep 30 · 43d")
- [x] Does this app follow the liquid glass guidelines? if not, update the UI (GlassStyle.swift: glass search dropdown + .glassProminent for primary actions on macOS 26+, material fallbacks on 15)
- [x] Do a code review and see if you can find any issues/things that could be better. In the code review, no features should be removed (fixed: duplicate-property-key ForEach crash, emoji UTF-16 offsets in editor, DateFormatter caching in hot paths, duplicate watcher, dead code)
- [x] Keyboard shortcuts
  - Cmd +n for a new todo today
  - Cmd +f for find and cursor moves to the search bar directly
  - escape exits search if open
  - Show these in settings as a tab for keyboard shortcuts (these are not configurable)
- [x] Only single window, no tabs. So clicking open Daystream in the menu bar applet does not open a new window if already open
- [x] System wide shortcut for adding a new todo for the day (configurable in settings) - Option t? (opens the menu bar applet with cursor on new task)
- [x] Update readme/docs features = Git backup
- [x] Auto git backup interval : daily/weekly (default weekly) (not enabled by default)
- [x] Markdown auto format on save/quit editor view
  - Consistent spaces/tabs/linebreaks
  - linebreaks between [[]] and lists vs - and also between - that are not part of a group
- [x] Add a sample note in the readme/docs which shows features/wikilinks etc.
- [x] Code block support (fenced ``` blocks: stream cards, editor highlighting, fence-aware formatting)

## Moonshot

- Sync todos with dates to google calendar? Not sure if this is even possible. Can add a sign in/api thingie
- Explain philosophy of tasks here
