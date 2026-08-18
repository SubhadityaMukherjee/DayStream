# Ideas

## Doable

- [x] Default font - system (SF Pro)
- [x] Clicking checkboxes is SUPER slow and lags a lot still (cross-note sync moved off the main thread + single-pass line edits)
- [x] Space bar still doesnt work. Maybe reconsider how the editor view works? (local keyDown monitor wins before SwiftUI's ScrollView)
- [x] App icon from /Users/smukherjee/Downloads/your-logo-our-leather-the-scholar-personalized-leather-journal-cover-custom-logo-and-corporate-gifting-4796254_2048x.jpg
- [x] Day headings : bigger font size
- [x] Outliner style lists (indent guide rails + depth-cycling bullets • ◦ ▪)
- [x] Github build workflow for main versions + move main branch -> develop and main for versions. Author - Subhaditya Mukherjee
- [x] Taskbar applet for today + quick add something (MenuBarExtra with quick add + today's open tasks)
- [x] Migrate old notes to current date format and store in the same vault (make a folder - backup/ and move all the older notes into it first before modifying) — Settings → Maintenance, plus scripts/migrate_filenames
- [x] Add documentation (github pages) — docs/ + Pages deployment from main
- [x] Create a .agents/ and add info to it for future use (.agents/AGENTS.md, .agents/decisions.md, AGENTS.md)
- [x] Use the icon from ~/Downloads/journal_app_icon.png instead
- [x] Add an menu in the settings to add recurring tasks - daily, weekly (on a particular day), on a certain date. On that date, this should appear for the day at the top with a TODO. Unsure how this would work with the current implementation of duplicate checking, so consider that. (Settings → Recurring; injected at the top of the day's note, duplicate-checked against existing content keys)
- [x] Allow setting scheduled tasks with a date picker (menu-bar quick-add calendar toggle; "Once" recurring for date-scheduled tasks)
- [x] For new tasks, store the date/time when it was added and then when it's marked done show how long it took nxt to it in a small button (like the status done button) (`added::` / `completed::` properties; duration capsule next to done tasks)
- [x] Allow typing Cmd+S in editor view to save and quit the editor
  - [x] Remove empty - lines
  - [x] Make sure there is a line space between [[]] and subsequent sub -'s and the next [[]]
- [x] Make the checkboxes (larger hit area, styled markers)
- [x] Remove the new page button, its not needed.
- [x] When typing titles - show suggestions using existing ones that I can hit enter to select (typing `[[` shows page-name popover; ↑/↓ select, ⏎/⇥ complete)
- [x] When I click a title that opens a view eg : [[eval]], this should show something like current front page view for the notes - embedded view. At the moment clicking the links is useless, so it should take me to that dates note in the front page. (pages open a rendered front-page-style view with linked references; date-like links like [[Aug 18th, 2026]] jump to that day's note)
- [x] Add some more spacing between the sidebar
- [x] Clicking the today button should take me todays note and/or create it if not exists
- [x] Make sure you are creating a note for a new day if it doesnt exist (launch, Today button, calendar clicks, menu-bar quick add; midnight rollover timer)
- [x] Also add a search bar that lets me search across all the files at once (search bar above the stream; journals + pages)
- [x] Also make the bullet point better in the preview mode lol (accent-tinted depth-0 bullets, aligned markers)
- [x] Also create a DEADLINE button which gives me a datepicker and a deadline. these deadlines should show persistently in the sidebar in a new section (sidebar "Deadline…" button + persistent Deadlines section with countdowns/overdue states; the task seeds into the due day's note)
- [x] Update the documentation properly. The current one is very barebones and the github pages doesnt have any documentation. it also has distorted buttons for buildp passing and such (full docs site: features, getting started, usage guide, shortcuts, vault format, FAQ, build instructions; badges fixed + icon)
- [x] Update the information in .agents/ with whatever you know about hte code to make it easier for you later (key map for all model/view files, tricky spots incl. autocomplete/PageView/scheduling, decisions for deadlines/search/docs)

## Moonshot

- Sync todos with dates to google calendar? Not sure if this is even possible. Can add a sign in/api thingie
