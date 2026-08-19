# Ideas

## Doable

- [x] For deadlines in the sidebar, show how many days left (labels now always include the count: "Fri · 3d", "Sep 30 · 43d")
- [x] Does this app follow the liquid glass guidelines? if not, update the UI (GlassStyle.swift: glass search dropdown + .glassProminent for primary actions on macOS 26+, material fallbacks on 15)
- [x] Do a code review and see if you can find any issues/things that could be better. In the code review, no features should be removed (fixed: duplicate-property-key ForEach crash, emoji UTF-16 offsets in editor, DateFormatter caching in hot paths, duplicate watcher, dead code)

## Moonshot

- Sync todos with dates to google calendar? Not sure if this is even possible. Can add a sign in/api thingie
