import Foundation
import CoreServices
import Observation

struct VaultFile {
    let url: URL
    let date: Date
    var text: String
    var blocks: [Block]

    init(url: URL, date: Date, text: String) {
        self.url = url
        self.date = date
        self.text = text
        self.blocks = BlockTree.parse(text)
    }
}

struct JournalDay: Identifiable {
    let date: Date
    var files: [VaultFile]
    /// Cached at parse/refresh time — the calendar reads this for every
    /// visible cell, and walking every block of every file per access was
    /// O(total blocks) per SwiftUI evaluation.
    private(set) var hasOpenTodos = false
    /// Cached open (TODO/DOING/LATER/NOW) task count — feeds the
    /// open-task bubbles above the stream without a re-walk per render.
    private(set) var openTodoCount = 0

    var id: Date { date }

    mutating func refreshOpenTodos() {
        var found = false
        var openCount = 0
        func walk(_ nodes: [Block]) {
            for n in nodes {
                if n.todoState == .open {
                    found = true
                    openCount += 1
                }
                walk(n.children)
            }
        }
        files.forEach { walk($0.blocks) }
        hasOpenTodos = found
        openTodoCount = openCount
    }

    /// The file editing and saving target: prefers a content-bearing file so an
    /// empty sibling in a newer filename format never shadows the real note.
    var editFile: VaultFile? {
        files.first(where: { !$0.text.isEmpty }) ?? files.first
    }

    /// Files to render; empty siblings are hidden when a sibling has content.
    var displayFiles: [VaultFile] {
        let nonEmpty = files.filter { !$0.text.isEmpty }
        return nonEmpty.isEmpty ? Array(files.prefix(1)) : nonEmpty
    }
}

enum VaultLayout {
    case root                       // selected folder is the vault root (has journals/)
    case journalsDirectory          // selected folder *is* the journals dir
}

@Observable
final class VaultStore {
    let vaultURL: URL
    let layout: VaultLayout
    let journalsURL: URL
    let pagesURL: URL
    private(set) var days: [JournalDay] = []          // newest first
    private(set) var pageCount: Int = 0
    /// Open tasks across every journal day, cached alongside `days` so the
    /// stream's counter bubble never re-walks the vault per render.
    private(set) var openTaskCountTotal = 0
    /// Open tasks in today's note (0 when today has no note yet).
    var openTaskCountToday: Int {
        let today = JournalDate.startOfDay(Date())
        return days.first(where: { $0.date == today })?.openTodoCount ?? 0
    }

    var onExternalChange: (() -> Void)?

    /// Last vault I/O failure (failed save/delete), surfaced once by the UI
    /// and cleared there. Set on the main thread only.
    private(set) var storageErrorMessage: String?

    func clearStorageError() {
        storageErrorMessage = nil
    }

    private func reportError(_ message: String) {
        storageErrorMessage = message
    }

    private func writeToFile(_ text: String, url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Disk writes happen on writeQueue; hop to main for the
            // observable property.
            DispatchQueue.main.async { [weak self] in
                self?.reportError("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Deletes a file, reporting failures (permissions, read-only vault)
    /// instead of silently leaving the file on disk. Returns an error
    /// message on failure, nil on success.
    @discardableResult
    func removeFile(at url: URL) -> String? {
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            let message = "Couldn't delete \(url.lastPathComponent): \(error.localizedDescription)"
            reportError(message)
            return message
        }
    }

    private var fsStream: FSEventStreamRef?

    private var reloadWorkItem: DispatchWorkItem?
    /// Skip watcher reloads briefly after our own writes (they'd be redundant).
    private var lastSelfWrite: Date?
    /// Bumped by every write. Snapshots and async applies capture the value
    /// they started from and are discarded when it moved, so a stale
    /// snapshot can never roll `days` (or the file) back mid-editing.
    private var writeGeneration = 0
    /// Serializes file writes so an async typing save can never land on disk
    /// after a newer synchronous write to the same file.
    private let writeQueue = DispatchQueue(label: "daystream.write", qos: .userInitiated)
    /// Serial queue for cross-note todo syncing, so checkbox clicks stay snappy.
    private let syncQueue = DispatchQueue(label: "daystream.todocync", qos: .userInitiated)
    /// Vault parsing for watcher-triggered reloads runs here, off the main thread.
    private let reloadQueue = DispatchQueue(label: "daystream.reload", qos: .utility)
    let watchEnabled: Bool

    init(vaultURL: URL, watchEnabled: Bool = true) {
        self.vaultURL = vaultURL
        self.watchEnabled = watchEnabled

        let fm = FileManager.default
        let journalsSub = vaultURL.appendingPathComponent("journals", isDirectory: true)
        if fm.fileExists(atPath: journalsSub.path) {
            layout = .root
            journalsURL = journalsSub
        } else {
            layout = .journalsDirectory
            journalsURL = vaultURL
        }
        let pagesCandidate: URL
        switch layout {
        case .root:
            pagesCandidate = vaultURL.appendingPathComponent("pages", isDirectory: true)
        case .journalsDirectory:
            pagesCandidate = vaultURL.deletingLastPathComponent().appendingPathComponent("pages", isDirectory: true)
        }
        pagesURL = pagesCandidate
        try? fm.createDirectory(at: pagesURL, withIntermediateDirectories: true)
    }

    // MARK: - Loading

    /// Pure load: reads every journal file, parses blocks, counts pages.
    /// No state mutation, so it is safe to run off the main thread.
    private func computeSnapshot() -> (days: [JournalDay], pageCount: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: journalsURL.path) else {
            return ([], 0)
        }
        var byDay: [Date: [VaultFile]] = [:]
        for name in names.sorted() {
            guard JournalDate.isJournalFilename(name) else { continue }
            guard let date = JournalDate.date(fromFilename: name) else { continue }
            let url = journalsURL.appendingPathComponent(name)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let day = JournalDate.startOfDay(date)
            byDay[day, default: []].append(VaultFile(url: url, date: day, text: text))
        }
        var newDays = byDay.map { day, files in
            // Same date in multiple filename formats: newest convention first.
            let f = files.sorted {
                let ar = $0.url.journalFormatRank
                let br = $1.url.journalFormatRank
                return ar == br ? $0.url.lastPathComponent < $1.url.lastPathComponent : ar < br
            }
            var d = JournalDay(date: day, files: f)
            d.refreshOpenTodos()
            return d
        }
        .sorted { $0.date > $1.date }

        let newPageCount = ((try? fm.contentsOfDirectory(atPath: pagesURL.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
            .count
        return (newDays, newPageCount)
    }

    /// Publishes a computed snapshot. Must run on the main thread (`days` is
    /// observable state the UI reads).
    private func applySnapshot(days newDays: [JournalDay], pageCount newPageCount: Int) {
        days = newDays
        pageCount = newPageCount
        openTaskCountTotal = newDays.reduce(0) { $0 + $1.openTodoCount }
        pageNamesCache = nil
    }

    func reload() {
        let snap = computeSnapshot()
        applySnapshot(days: snap.days, pageCount: snap.pageCount)

        if watchEnabled {
            installWatchers()
        }
    }

    /// Watcher-triggered reload: the same work as `reload()` with the file
    /// I/O and parsing on a background queue, so external edits to a large
    /// vault can never stall the main thread. Results land on the main thread.
    private func reloadAsync() {
        let generation = writeGeneration
        reloadQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.computeSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Discard a snapshot that raced one of our own writes — those
                // already refreshed the store with newer content, and
                // applying the snapshot would revert it under the editor.
                // But our writes don't cover *other* files' external
                // changes, so re-enqueue instead of dropping the reload.
                guard self.writeGeneration == generation else {
                    self.scheduleReload()
                    return
                }
                self.applySnapshot(days: snap.days, pageCount: snap.pageCount)
                self.onExternalChange?()
            }
        }
    }

    // MARK: - Today

    var todayURL: URL {
        journalsURL.appendingPathComponent(JournalDate.filename(for: Date()))
    }

    /// Today's canonical file: an existing content-bearing journal file (any
    /// filename format, newest convention preferred), else any existing today
    /// file, else a freshly created ISO-format file. Never creates a duplicate
    /// file next to an existing one.
    @discardableResult
    func ensureTodayFile() -> (url: URL, text: String) {
        ensureDayFile(for: Date())
    }

    /// The canonical journal file for an arbitrary date, creating it if needed.
    @discardableResult
    func ensureDayFile(for date: Date) -> (url: URL, text: String) {
        let fm = FileManager.default
        var existing: [(url: URL, text: String)] = []
        for name in JournalDate.allFilenames(for: date) {
            let url = journalsURL.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            existing.append((url, text))
        }
        if let best = existing.first(where: { !$0.text.isEmpty }) ?? existing.first {
            return best
        }
        let url = journalsURL.appendingPathComponent(JournalDate.filename(for: date))
        try? "".write(to: url, atomically: true, encoding: .utf8)
        return (url, "")
    }

    // MARK: - Writing

    func write(text: String, to url: URL) {
        writeGeneration += 1
        lastSelfWrite = Date()
        // The write itself runs inside the queue: an async typing save
        // enqueued after this call can never overtake it on disk (the old
        // drain-then-write-on-caller had that ordering hole), and the disk
        // I/O stays off the caller's thread.
        writeQueue.sync {
            writeToFile(text, url: url)
        }
        refresh(fileURL: url, newText: text)
    }

    /// Debounced typing saves: file I/O and block parsing off the main
    /// thread; the parsed file is applied to `days` on the main thread in
    /// write order, and only if no newer write superseded it.
    func writeAsync(text: String, to url: URL) {
        writeGeneration += 1
        let generation = writeGeneration
        lastSelfWrite = Date()
        writeQueue.async { [weak self] in
            self?.writeToFile(text, url: url)
            let day = JournalDate.startOfDay(url.dateFromJournalName ?? Date())
            let file = VaultFile(url: url, date: day, text: text)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.writeGeneration == generation else {
                    // Superseded by a newer write to this file: disk already
                    // holds the newer text, but `days` never saw ours —
                    // adopt via a reload instead of dropping it.
                    self?.scheduleReload()
                    return
                }
                self.applyRefresh(file)
            }
        }
    }

    /// Serial off-main batch write (cross-note todo echo): one generation
    /// bump, disk writes on the write queue, then an in-place refresh per
    /// file on the main thread — N files cost one main-thread hop, not N
    /// blocking writes.
    private func writeBatch(_ updates: [(url: URL, text: String)]) {
        writeGeneration += 1
        let generation = writeGeneration
        lastSelfWrite = Date()
        writeQueue.async { [weak self] in
            for update in updates {
                self?.writeToFile(update.text, url: update.url)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.writeGeneration == generation else {
                    self.scheduleReload()
                    return
                }
                for update in updates {
                    self.refresh(fileURL: update.url, newText: update.text)
                }
            }
        }
    }

    /// Re-parse a single file in place (keeps scroll position; avoids full reload).
    func refresh(fileURL: URL, newText: String) {
        let day = JournalDate.startOfDay(fileURL.dateFromJournalName ?? Date())
        applyRefresh(VaultFile(url: fileURL, date: day, text: newText))
    }

    private func applyRefresh(_ file: VaultFile) {
        // Page (and any non-journal) writes must not trigger a full vault
        // reload — that re-read and re-parsed everything on every debounced
        // page save. Pages aren't part of `days`; only derived page state
        // needs invalidating. (Path comparison, not URL equality: trailing-
        // slash conventions differ between the two URL constructions.)
        let parent = file.url.deletingLastPathComponent().standardizedFileURL.path
        let journals = journalsURL.standardizedFileURL.path
        guard parent == journals || parent == journals + "/" else {
            pageNamesCache = nil
            return
        }
        if let dayIndex = days.firstIndex(where: { $0.date == file.date }) {
            if let fileIndex = days[dayIndex].files.firstIndex(where: { $0.url == file.url }) {
                let oldOpenCount = days[dayIndex].openTodoCount
                days[dayIndex].files[fileIndex] = file
                days[dayIndex].refreshOpenTodos()
                openTaskCountTotal += days[dayIndex].openTodoCount - oldOpenCount
            } else {
                reload()
            }
        } else {
            reload()
        }
    }

    func toggleTodo(in file: VaultFile, block: Block, syncAcrossNotes: Bool = true) {
        var newText = BlockTree.toggledFileText(file.text, blockLineIndex: block.lineIndex)
        guard newText != file.text else { return }
        let key = BlockTree.normalize(block.content)
        let target: TodoState = block.todoState == .done ? .open : .done
        if target == .done {
            newText = NoteFormatter.withCompletionStamp(newText, blockLineIndex: block.lineIndex, at: Date())
        }
        write(text: newText, to: file.url)
        guard syncAcrossNotes, block.todoState != .none, !key.isEmpty else { return }
        syncTodoState(taskContent: block.content, to: target, excluding: file.url)
    }

    /// Rewrites matching tasks in every other note to `target` — used after
    /// an editor-side toggle (⌘⏎), where the toggled note's text is already
    /// in the editor and only the cross-note echo is the store's job.
    func syncTodoState(taskContent: String, to target: TodoState, excluding editedURL: URL) {
        let key = BlockTree.normalize(taskContent)
        guard !key.isEmpty else { return }
        // Snapshot journal text (value copies) and page URLs on the main
        // thread; page files are read inside the sync queue so the main
        // thread never blocks on disk, and the echo writes land as one
        // off-main batch.
        var journalPairs: [(url: URL, text: String)] = []
        for day in days {
            for f in day.files where f.url != editedURL {
                journalPairs.append((f.url, f.text))
            }
        }
        let pages = pageFileURLs().filter { $0 != editedURL }
        syncQueue.async { [weak self] in
            var candidates = journalPairs
            for url in pages {
                candidates.append((url, (try? String(contentsOf: url, encoding: .utf8)) ?? ""))
            }
            var updates: [(url: URL, text: String)] = []
            for candidate in candidates {
                if let synced = BlockTree.syncedText(candidate.text, key: key, to: target) {
                    updates.append((candidate.url, synced))
                }
            }
            guard !updates.isEmpty else { return }
            DispatchQueue.main.async {
                self?.writeBatch(updates)
            }
        }
    }

    // MARK: - Task insertion (quick add, scheduled, recurring)

    /// Writes `- TODO <title>` (with an `added::` timestamp) into the day's
    /// canonical file, creating the file if needed. Duplicate-checked against
    /// the note's existing content, so re-adding or re-applying is a no-op.
    /// Returns false when the task was already present (or empty).
    @discardableResult
    func addTask(_ title: String, to date: Date, atTop: Bool) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
        let (url, existing) = ensureDayFile(for: date)
        let existingKeys = BlockTree.allContentKeys(BlockTree.parse(existing))
        guard !existingKeys.contains(BlockTree.normalize(trimmedTitle)) else { return false }

        let entry = ["- TODO " + trimmedTitle, "\tadded:: " + NoteFormatter.timestamp(Date())]
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText: String
        if trimmed.isEmpty {
            newText = entry.joined(separator: "\n") + "\n"
        } else if atTop {
            newText = entry.joined(separator: "\n") + "\n\n" + trimmed + "\n"
        } else {
            newText = trimmed + "\n" + entry.joined(separator: "\n") + "\n"
        }
        write(text: newText, to: url)
        if !days.contains(where: { $0.date == JournalDate.startOfDay(date) }) {
            reload()
        }
        return true
    }

    /// Line index of the note's recurring-task section header, if present:
    /// an outliner bullet (`- [[ADMIN]]`), a markdown heading (`## [[ADMIN]]`)
    /// or a standalone `[[ADMIN]]` line — case-insensitive so hand-typed
    /// headers match. Whitespace-only or empty `header` falls back to ADMIN.
    static func recurringHeaderLineIndex(header: String = "ADMIN", in text: String) -> Int? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "ADMIN" : trimmed
        let pattern = "^([-*]\\s*)?(#{1,6}\\s*)?\\[\\[\\s*"
            + NSRegularExpression.escapedPattern(for: name)
            + "\\s*\\]\\]\\s*$"
        let lines = text.components(separatedBy: "\n")
        return lines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces).range(
                of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Writes `- TODO <title>` (with an `added::` timestamp) under the day's
    /// recurring-task section header (`[[ADMIN]]` unless `header` says
    /// otherwise), creating the header at the top of the note when missing.
    /// Duplicate-checked against the note's existing content, so
    /// re-applying is a no-op. Returns false when the task was already
    /// present (or empty).
    @discardableResult
    func addRecurringTask(_ title: String, to date: Date, header: String = "ADMIN") -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
        let (url, existing) = ensureDayFile(for: date)
        let existingKeys = BlockTree.allContentKeys(BlockTree.parse(existing))
        guard !existingKeys.contains(BlockTree.normalize(trimmedTitle)) else { return false }

        let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedHeader.isEmpty ? "ADMIN" : trimmedHeader
        let entry = ["- TODO " + trimmedTitle, "\tadded:: " + NoteFormatter.timestamp(Date())]
        var newText: String
        if let index = Self.recurringHeaderLineIndex(header: header, in: existing) {
            var lines = existing.components(separatedBy: "\n")
            // Bullet-form headers (`- [[ADMIN]]`) keep their tasks as
            // indented children; heading/bare forms take top-level bullets.
            let headerLine = lines[index].trimmingCharacters(in: .whitespaces)
            let isBullet = headerLine.hasPrefix("- ") || headerLine.hasPrefix("* ")
            lines.insert(contentsOf: entry.map { (isBullet ? "\t" : "") + $0 }, at: index + 1)
            newText = lines.joined(separator: "\n")
        } else {
            let section = ["- [[" + name + "]]"] + entry.map { "\t" + $0 }
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                newText = section.joined(separator: "\n") + "\n"
            } else {
                newText = section.joined(separator: "\n") + "\n\n" + trimmed + "\n"
            }
        }
        if !newText.hasSuffix("\n") { newText += "\n" }
        write(text: newText, to: url)
        if !days.contains(where: { $0.date == JournalDate.startOfDay(date) }) {
            reload()
        }
        return true
    }

    /// Seeds every task due on `date` into that day's note, grouped under
    /// each task's own header (falling back to the passed default, ADMIN).
    /// Duplicate-checked per task, so this is safe to run on every launch,
    /// reload and rollover.
    @discardableResult
    func applyRecurringTasks(_ tasks: [RecurringTask], to date: Date = Date(),
                             header: String = "ADMIN") -> Int {
        var added = 0
        for task in tasks where task.isDue(on: date) {
            let own = task.header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if addRecurringTask(task.title, to: date, header: own.isEmpty ? header : own) {
                added += 1
            }
        }
        return added
    }

    /// Seeds deadlines due on `date` into that day's note (duplicate-checked,
    /// like recurring tasks).
    @discardableResult
    func applyDeadlines(_ deadlines: [Deadline], to date: Date = Date()) -> Int {
        var added = 0
        for deadline in deadlines where deadline.isDue(on: date) {
            if addTask(deadline.title, to: date, atTop: true) {
                added += 1
            }
        }
        return added
    }

    // MARK: - Page name index (wikilink autocomplete)

    private var pageNamesCache: (names: [String], at: Date)?
    private var pageNamesRefreshInFlight = false

    /// Every page name that exists or is referenced anywhere in the vault:
    /// files in pages/ plus all `[[wikilink]]` targets in journals and pages.
    /// Stale-while-revalidate: a warm cache serves instantly (the `[[`
    /// autocomplete runs per keystroke) and expiry refreshes in the
    /// background instead of re-reading every page from disk on main.
    func allPageNames() -> [String] {
        if let cache = pageNamesCache {
            if Date().timeIntervalSince(cache.at) >= 5 {
                refreshPageNamesInBackground()
            }
            return cache.names
        }
        let names = Self.computePageNames(journals: journalSnapshots(), pages: pageSnapshots())
        pageNamesCache = (names, Date())
        return names
    }

    private func refreshPageNamesInBackground() {
        guard !pageNamesRefreshInFlight else { return }
        pageNamesRefreshInFlight = true
        let journals = journalSnapshots()
        let pageURLs = pageFileURLs()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pages = pageURLs.map { url in
                (url: url, title: WikiName.pageName(for: url.lastPathComponent),
                 text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
            let names = Self.computePageNames(journals: journals, pages: pages)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pageNamesRefreshInFlight = false
                self.pageNamesCache = (names, Date())
            }
        }
    }

    private static func computePageNames(
        journals: [(url: URL, date: Date, title: String, text: String)],
        pages: [(url: URL, title: String, text: String)]
    ) -> [String] {
        var names = Set<String>()
        for p in pages {
            names.insert(p.title)
            for target in WikiName.wikilinkTargets(in: p.text) {
                names.insert(target)
            }
        }
        for j in journals {
            for target in WikiName.wikilinkTargets(in: j.text) {
                names.insert(target)
            }
        }
        return names
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Snapshot helpers (main thread)

    /// Value-copied journal content + precomputed titles: everything the
    /// vault-wide scans (search, mentions, page names) need, snapshotted
    /// on the main thread so the scans themselves can run anywhere.
    private func journalSnapshots() -> [(url: URL, date: Date, title: String, text: String)] {
        days.flatMap { day in
            day.files.map { file in
                (url: file.url, date: day.date,
                 title: JournalDate.filename(for: day.date), text: file.text)
            }
        }
    }

    private func pageSnapshots() -> [(url: URL, title: String, text: String)] {
        pageFileURLs().map { url in
            (url: url, title: WikiName.pageName(for: url.lastPathComponent), text: pageText(at: url))
        }
    }

    // MARK: - Vault-wide search

    struct SearchHit: Identifiable {
        let url: URL
        /// Journal day (start-of-day) for journals; nil for pages.
        let date: Date?
        let title: String
        let lineText: String
        /// Page-name match: the title itself matched, no preview line.
        var isTitleMatch = false
        /// 1-based line number in the file — keeps ids unique when the same
        /// line text appears twice (two identical `- TODO` bullets).
        var lineNumber = 0
        var id: String { url.absoluteString + ":" + String(lineNumber) }
        var isPage: Bool { date == nil }
    }

    /// Pure scan over snapshotted content; runs on any thread. Case-
    /// insensitive `range(of:)` — no lowercased copy of every line.
    private static func scanForHits(
        query: String,
        journals: [(url: URL, date: Date, title: String, text: String)],
        pages: [(url: URL, title: String, text: String)],
        limit: Int
    ) -> [SearchHit] {
        var out: [SearchHit] = []
        for journal in journals {
            var lineNo = 0
            for line in journal.text.components(separatedBy: "\n") {
                lineNo += 1
                if line.range(of: query, options: .caseInsensitive) != nil {
                    out.append(SearchHit(
                        url: journal.url,
                        date: journal.date,
                        title: journal.title,
                        lineText: line.trimmingCharacters(in: .whitespaces),
                        lineNumber: lineNo
                    ))
                    if out.count >= limit { return out }
                }
            }
        }
        for page in pages {
            if page.title.range(of: query, options: .caseInsensitive) != nil {
                out.append(SearchHit(
                    url: page.url, date: nil, title: page.title,
                    lineText: page.title, isTitleMatch: true
                ))
                if out.count >= limit { return out }
            }
            var lineNo = 0
            for line in page.text.components(separatedBy: "\n") {
                lineNo += 1
                if line.range(of: query, options: .caseInsensitive) != nil {
                    out.append(SearchHit(
                        url: page.url, date: nil, title: page.title,
                        lineText: line.trimmingCharacters(in: .whitespaces),
                        lineNumber: lineNo
                    ))
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    /// Case-insensitive substring search across every journal and page line.
    /// Journals newest-first, then pages; a page whose *name* matches is
    /// offered first among page hits.
    func search(_ rawQuery: String, limit: Int = 100) -> [SearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return Self.scanForHits(query: query, journals: journalSnapshots(),
                                pages: pageSnapshots(), limit: limit)
    }

    /// Background variant for the interactive search field: snapshot on the
    /// caller's (main) thread, scan + page file reads off-main.
    func searchAsync(_ rawQuery: String, limit: Int = 100) async -> [SearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let journals = journalSnapshots()
        let pageURLs = pageFileURLs()
        return await Task.detached(priority: .userInitiated) {
            let pages = pageURLs.map { url in
                (url: url, title: WikiName.pageName(for: url.lastPathComponent),
                 text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
            return Self.scanForHits(query: query, journals: journals, pages: pages, limit: limit)
        }.value
    }

    // MARK: - Carry forward

    @discardableResult
    func carryForward() -> CarryResult {
        carryForward(to: Date())
    }

    /// Copies unfinished tasks from before `target` into that date's note.
    /// Duplicate-checked against the target, so it is safe to re-run.
    /// `excludingContentKeys` (normalized task titles) are never carried —
    /// AppModel passes recurring-task titles so recurrence, not carry-over,
    /// owns when they reappear.
    @discardableResult
    func carryForward(to target: Date = Date(), excludingContentKeys: Set<String> = Set()) -> CarryResult {
        let day = JournalDate.startOfDay(target)
        let (targetURL, targetText) = ensureDayFile(for: day)
        let previous = days
            .filter { $0.date < day }
            .flatMap { d in d.files.map { (date: d.date, text: $0.text) } }
        let (newText, result) = CarryForwardService.carryForward(
            allFiles: previous, todayText: targetText,
            excludingContentKeys: excludingContentKeys)
        if result.carriedCount > 0 {
            write(text: newText, to: targetURL)
            if !days.contains(where: { $0.date == day }) {
                reload()
            }
        }
        return result
    }

    // MARK: - Pages

    /// Finds or creates the markdown file backing a `[[wikilink]]` target.
    func pageURL(named pageName: String, createIfMissing: Bool) -> URL? {
        let fm = FileManager.default
        let trimmed = pageName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for candidate in WikiName.candidateFileNames(for: trimmed) {
            let url = pagesURL.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) { return url }
        }
        // Case-insensitive fallback.
        let existing = ((try? fm.contentsOfDirectory(atPath: pagesURL.path)) ?? [])
        for name in existing {
            if name.lowercased() == WikiName.fileName(for: trimmed).lowercased() {
                return pagesURL.appendingPathComponent(name)
            }
        }
        guard createIfMissing else { return nil }
        let url = pagesURL.appendingPathComponent(WikiName.fileName(for: trimmed))
        try? "".write(to: url, atomically: true, encoding: .utf8)
        pageCount += 1
        return url
    }

    func pageText(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// All page files currently in the vault's pages directory.
    func pageFileURLs() -> [URL] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: pagesURL.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
            .sorted()
        return names.map { pagesURL.appendingPathComponent($0) }
    }

    // MARK: - Linked references (mentions)

    struct Mention: Identifiable {
        let url: URL
        let date: Date?
        let title: String
        /// The matching line, trimmed (usually the wikilink bullet).
        let lineText: String
        /// All lines of the matching block's subtree — the block's real text
        /// on that day, children included (capped).
        var blockLines: [String] = []
        /// 1-based line number of the block — keeps ids unique when the same
        /// wikilink bullet appears twice in one file.
        var lineNumber = 0
        var id: String { url.absoluteString + ":" + String(lineNumber) }
    }

    /// Pure collect over snapshotted content; runs on any thread.
    private static func collectMentions(
        of target: String,
        journals: [(url: URL, date: Date, title: String, text: String)],
        pages: [(url: URL, title: String, text: String)]
    ) -> [Mention] {
        var out: [Mention] = []
        func collect(_ url: URL, date: Date?, title: String, text: String) {
            for root in BlockTree.parse(text) {
                func walk(_ b: Block) {
                    if let line = b.rawLines.first(where: { WikiName.references($0, page: target) }) {
                        out.append(Mention(
                            url: url,
                            date: date,
                            title: title,
                            lineText: line.trimmingCharacters(in: .whitespaces),
                            blockLines: BlockTree.subtreeLines(b, maxLines: 8),
                            lineNumber: b.lineIndex + 1
                        ))
                    }
                    b.children.forEach(walk)
                }
                walk(root)
            }
        }
        for journal in journals {
            collect(journal.url, date: journal.date, title: journal.title, text: journal.text)
        }
        for page in pages {
            // Skip the page's own file: it isn't a reference to itself.
            let stem = page.url.deletingPathExtension().lastPathComponent
            if stem.lowercased() == WikiName.fileName(for: target).lowercased() { continue }
            collect(page.url, date: nil, title: page.title, text: page.text)
        }
        return out
    }

    /// Every block in the vault (journals + pages) that links to `[[pageName]]`.
    func mentions(of pageName: String) -> [Mention] {
        let target = pageName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return [] }
        return Self.collectMentions(of: target, journals: journalSnapshots(), pages: pageSnapshots())
    }

    /// Background variant for the page sheet: snapshot on main, parse every
    /// journal and page off-main.
    func mentionsAsync(of pageName: String) async -> [Mention] {
        let target = pageName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return [] }
        let journals = journalSnapshots()
        let pageURLs = pageFileURLs()
        return await Task.detached(priority: .userInitiated) {
            let pages = pageURLs.map { url in
                (url: url, title: WikiName.pageName(for: url.lastPathComponent),
                 text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
            return Self.collectMentions(of: target, journals: journals, pages: pages)
        }.value
    }

    // MARK: - Maintenance

    struct CleanupResult: Equatable {
        var deletedJournals = 0
        var deletedPages = 0
        var freedBytes: Int64 = 0
    }

    struct MigrationResult: Equatable {
        var backedUp = 0
        var migrated = 0
        var conflicts = 0

        var summary: String {
            var s = "Backed up \(backedUp) note\(backedUp == 1 ? "" : "s") to backup/, renamed \(migrated) to yyyy-MM-dd.md."
            if conflicts > 0 {
                s += " \(conflicts) skipped (a different note with the target name already exists)."
            }
            return s
        }
    }

    /// Renames legacy-format journal files (`yyyy_MM_dd.md`, `dd-MM-yyyy.md`)
    /// to the current `yyyy-MM-dd.md` convention. Every original is copied into
    /// `backup/` (in the vault root) before anything is touched; a rename is
    /// skipped when the target already exists with different content.
    @discardableResult
    func migrateLegacyFilenames() -> MigrationResult {
        let fm = FileManager.default
        var result = MigrationResult()
        let backupURL = backupDirectory()

        for day in days {
            for file in day.files {
                let name = file.url.lastPathComponent
                let stem = (name as NSString).deletingPathExtension
                // Already ISO? (Compare by format, not date: `file.date` is the
                // local start-of-day grouping key, which doesn't round-trip
                // through the UTC filename formatter in every timezone.)
                if stem =~~ "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" { continue }
                guard let nameDate = JournalDate.date(fromFilename: name) else { continue }
                let targetName = JournalDate.filename(for: nameDate)

                // Safety copy first.
                let backupCopy = backupURL.appendingPathComponent(name)
                if !fm.fileExists(atPath: backupCopy.path) {
                    if (try? fm.copyItem(at: file.url, to: backupCopy)) != nil {
                        result.backedUp += 1
                    }
                }

                let target = journalsURL.appendingPathComponent(targetName)
                if fm.fileExists(atPath: target.path) {
                    let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
                    if existing == file.text {
                        // Identical duplicate: drop the legacy copy.
                        try? fm.removeItem(at: file.url)
                        result.migrated += 1
                    } else if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              !file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Empty duplicate (e.g. an app-created placeholder) shadowing
                        // real content in the legacy file: replace it.
                        let targetBackup = backupURL.appendingPathComponent(target.lastPathComponent)
                        if !fm.fileExists(atPath: targetBackup.path) {
                            try? fm.copyItem(at: target, to: targetBackup)
                        }
                        try? fm.removeItem(at: target)
                        if (try? fm.moveItem(at: file.url, to: target)) != nil {
                            result.migrated += 1
                        } else {
                            result.conflicts += 1
                        }
                    } else {
                        result.conflicts += 1
                    }
                    continue
                }
                do {
                    try fm.moveItem(at: file.url, to: target)
                    result.migrated += 1
                } catch {
                    result.conflicts += 1
                }
            }
        }
        if result.migrated > 0 {
            reload()
        }
        return result
    }

    /// Vault-level backup directory (`<vault root>/backup`), created on demand.
    func backupDirectory() -> URL {
        let url = vaultRootURL.appendingPathComponent("backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The vault root regardless of which folder was selected as the vault.
    var vaultRootURL: URL {
        switch layout {
        case .root: return vaultURL
        case .journalsDirectory: return vaultURL.deletingLastPathComponent()
        }
    }

    /// Markdown mirror of the sidebar deadlines, in the vault root.
    var deadlinesFileURL: URL {
        vaultRootURL.appendingPathComponent("deadlines.md")
    }

    /// Deletes journal and page files that contain nothing but whitespace.
    /// Never touches any file with real content, however old.
    @discardableResult
    func deleteEmptyNotes(includeToday: Bool = false) -> CleanupResult {
        let fm = FileManager.default
        var result = CleanupResult()
        let today = JournalDate.startOfDay(Date())

        for day in days {
            if !includeToday, day.date == today { continue }
            for file in day.files {
                guard file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let size = ((try? fm.attributesOfItem(atPath: file.url.path))?[.size] as? Int64) ?? 0
                if fm.removeItemIfPossible(file.url) {
                    result.deletedJournals += 1
                    result.freedBytes += size
                }
            }
        }
        for url in pageFileURLs() {
            let text = pageText(at: url)
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
            if fm.removeItemIfPossible(url) {
                result.deletedPages += 1
                result.freedBytes += size
            }
        }
        if result.deletedJournals > 0 || result.deletedPages > 0 {
            reload()
        }
        return result
    }

    // MARK: - Assets

    /// Directory for dropped images/files, created on demand.
    var assetsURL: URL {
        let url: URL
        switch layout {
        case .root: url = vaultURL.appendingPathComponent("assets", isDirectory: true)
        case .journalsDirectory: url = vaultURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies a dropped image into `assets/` and returns the markdown embed
    /// (`![](assets/...)`) to insert at the drop point.
    @discardableResult
    func importImage(_ data: Data, originalName: String?) -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let sanitized = (originalName ?? "image")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>#[]"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nsName = sanitized as NSString
        let stem = nsName.deletingPathExtension.trimmingCharacters(in: .whitespaces)
        let ext = nsName.pathExtension.lowercased()
        let base = stem.isEmpty ? "image" : stem
        let extName = ext.isEmpty ? "png" : ext
        let name = "\(stamp)_\(base).\(extName)"
        let url = assetsURL.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return "![](assets/\(name))"
        } catch {
            return nil
        }
    }

    // MARK: - File watching

    /// One FSEvents stream with per-file events over the vault root: a
    /// plain directory-fd `.write` watch only signals directory-entry
    /// changes (create/delete/rename), so an external editor modifying an
    /// existing journal in place was invisible. File events cover every
    /// subdirectory (journals/, pages/, assets/) in one source.
    private func installWatchers() {
        guard fsStream == nil else { return }
        var context = FSEventStreamContext()
        context.version = 0
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, _, eventFlags, _ in
            guard let info else { return }
            let store = Unmanaged<VaultStore>.fromOpaque(info).takeUnretainedValue()
            let interesting: UInt32 = UInt32(kFSEventStreamEventFlagItemModified)
                | UInt32(kFSEventStreamEventFlagItemRenamed)
                | UInt32(kFSEventStreamEventFlagItemRemoved)
                | UInt32(kFSEventStreamEventFlagItemCreated)
                | UInt32(kFSEventStreamEventFlagRootChanged)
                | UInt32(kFSEventStreamEventFlagMustScanSubDirs)
            for i in 0..<count where eventFlags[i] & interesting != 0 {
                store.scheduleReload()
                return
            }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [vaultRootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        fsStream = stream
    }

    deinit {
        if let fsStream {
            FSEventStreamStop(fsStream)
            FSEventStreamInvalidate(fsStream)
            FSEventStreamRelease(fsStream)
        }
    }

    private func scheduleReload() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Our own writes already refreshed the store in place; a watcher
            // reload right after would only duplicate work (and flicker).
            // The event isn't dropped, though — it is delayed past the
            // suppression window, so an external change that landed under
            // the same window is still adopted.
            let suppressed = self.lastSelfWrite.map { Date().timeIntervalSince($0) < 0.8 } ?? false
            self.reloadWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.reloadAsync()
            }
            self.reloadWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + (suppressed ? 1.0 : 0.6), execute: item)
        }
    }
}

private extension FileManager {
    @discardableResult
    func removeItemIfPossible(_ url: URL) -> Bool {
        (try? removeItem(at: url)) != nil && !fileExists(atPath: url.path)
    }
}

private extension URL {
    var dateFromJournalName: Date? {
        JournalDate.date(fromFilename: lastPathComponent)
    }
    /// 0 = ISO (new convention), 1 = yyyy_MM_dd, 2 = dd-MM-yyyy (legacy, day-first).
    var journalFormatRank: Int {
        let stem = (lastPathComponent as NSString).deletingPathExtension
        if JournalDate.matchesShape(stem, format: "yyyy-MM-dd") { return 0 }
        if JournalDate.matchesShape(stem, format: "yyyy_MM_dd") { return 1 }
        return 2
    }
}
