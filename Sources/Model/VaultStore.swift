import Foundation
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

    var id: Date { date }
    var hasOpenTodos: Bool {
        var found = false
        func walk(_ nodes: [Block]) {
            for n in nodes {
                if n.todoState == .open { found = true }
                walk(n.children)
            }
        }
        files.forEach { walk($0.blocks) }
        return found
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

    var onExternalChange: (() -> Void)?

    private var watchers: [DispatchSourceFileSystemObject] = []
    private var reloadWorkItem: DispatchWorkItem?
    /// Skip watcher reloads briefly after our own writes (they'd be redundant).
    private var lastSelfWrite: Date?
    /// Serial queue for cross-note todo syncing, so checkbox clicks stay snappy.
    private let syncQueue = DispatchQueue(label: "daystream.todocync", qos: .userInitiated)
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

    func reload() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: journalsURL.path) else {
            days = []
            return
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
        days = byDay.map { day, files in
            // Same date in multiple filename formats: newest convention first.
            let f = files.sorted {
                let ar = $0.url.journalFormatRank
                let br = $1.url.journalFormatRank
                return ar == br ? $0.url.lastPathComponent < $1.url.lastPathComponent : ar < br
            }
            return JournalDay(date: day, files: f)
        }
        .sorted { $0.date > $1.date }

        pageCount = ((try? fm.contentsOfDirectory(atPath: pagesURL.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
            .count
        pageNamesCache = nil

        if watchEnabled {
            installWatchers()
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
        lastSelfWrite = Date()
        try? text.write(to: url, atomically: true, encoding: .utf8)
        refresh(fileURL: url, newText: text)
    }

    /// Re-parse a single file in place (keeps scroll position; avoids full reload).
    func refresh(fileURL: URL, newText: String) {
        let day = JournalDate.startOfDay(fileURL.dateFromJournalName ?? Date())
        guard let dayIndex = days.firstIndex(where: { $0.date == day }) else {
            reload()
            return
        }
        if let fileIndex = days[dayIndex].files.firstIndex(where: { $0.url == fileURL }) {
            days[dayIndex].files[fileIndex] = VaultFile(url: fileURL, date: day, text: newText)
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
        // Snapshot candidates on the main thread, then match/rewrite off-main so
        // a click never stalls the UI on large vaults; results are applied back
        // on the main thread.
        var others: [(url: URL, text: String)] = []
        for day in days {
            for f in day.files where f.url != file.url {
                others.append((f.url, f.text))
            }
        }
        for url in pageFileURLs() {
            others.append((url, pageText(at: url)))
        }
        syncQueue.async { [weak self] in
            var updates: [(url: URL, text: String)] = []
            for other in others {
                if let synced = BlockTree.syncedText(other.text, key: key, to: target) {
                    updates.append((other.url, synced))
                }
            }
            guard !updates.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for update in updates {
                    self.write(text: update.text, to: update.url)
                }
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

    /// Prepends every task due on `date` to that day's note. Duplicate-checked
    /// per task, so this is safe to run on every launch, reload and rollover.
    @discardableResult
    func applyRecurringTasks(_ tasks: [RecurringTask], to date: Date = Date()) -> Int {
        var added = 0
        for task in tasks where task.isDue(on: date) {
            if addTask(task.title, to: date, atTop: true) {
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

    /// Every page name that exists or is referenced anywhere in the vault:
    /// files in pages/ plus all `[[wikilink]]` targets in journals and pages.
    /// Short-TTL cache; invalidated on reload.
    func allPageNames() -> [String] {
        if let cache = pageNamesCache, Date().timeIntervalSince(cache.at) < 5 {
            return cache.names
        }
        var names = Set<String>()
        for url in pageFileURLs() {
            names.insert(WikiName.pageName(for: url.lastPathComponent))
        }
        for day in days {
            for file in day.files {
                for target in WikiName.wikilinkTargets(in: file.text) {
                    names.insert(target)
                }
            }
        }
        for url in pageFileURLs() {
            for target in WikiName.wikilinkTargets(in: pageText(at: url)) {
                names.insert(target)
            }
        }
        let sorted = names
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        pageNamesCache = (sorted, Date())
        return sorted
    }

    // MARK: - Vault-wide search

    struct SearchHit: Identifiable {
        let url: URL
        /// Journal day (start-of-day) for journals; nil for pages.
        let date: Date?
        let title: String
        let lineText: String
        var id: String { url.absoluteString + ":" + lineText }
        var isPage: Bool { date == nil }
    }

    /// Case-insensitive substring search across every journal and page line.
    /// Journals newest-first, then pages; a page whose *name* matches is
    /// offered first among page hits.
    func search(_ rawQuery: String, limit: Int = 100) -> [SearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let lower = query.lowercased()
        var out: [SearchHit] = []

        for day in days {
            for file in day.files {
                for line in file.text.components(separatedBy: "\n") {
                    if line.lowercased().contains(lower) {
                        out.append(SearchHit(
                            url: file.url,
                            date: day.date,
                            title: JournalDate.filename(for: day.date),
                            lineText: line.trimmingCharacters(in: .whitespaces)
                        ))
                        if out.count >= limit { return out }
                    }
                }
            }
        }

        for url in pageFileURLs() {
            let name = WikiName.pageName(for: url.lastPathComponent)
            if name.lowercased().contains(lower) {
                out.append(SearchHit(
                    url: url, date: nil, title: name, lineText: "Page"
                ))
                if out.count >= limit { return out }
            }
            for line in pageText(at: url).components(separatedBy: "\n") {
                if line.lowercased().contains(lower) {
                    out.append(SearchHit(
                        url: url, date: nil, title: name,
                        lineText: line.trimmingCharacters(in: .whitespaces)
                    ))
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    // MARK: - Carry forward

    func carryForward() -> CarryResult {
        let (targetURL, todayText) = ensureTodayFile()
        let today = JournalDate.startOfDay(Date())
        let previous = days
            .filter { $0.date < today }
            .flatMap { day in day.files.map { (date: day.date, text: $0.text) } }
        let (newText, result) = CarryForwardService.carryForward(allFiles: previous, todayText: todayText)
        if result.carriedCount > 0 {
            write(text: newText, to: targetURL)
            if !days.contains(where: { $0.date == today }) {
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
        let lineText: String
        var id: String { url.absoluteString + ":" + lineText }
    }

    /// Every line in the vault (journals + pages) that links to `[[pageName]]`.
    func mentions(of pageName: String) -> [Mention] {
        let target = pageName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return [] }
        var out: [Mention] = []

        for day in days {
            for file in day.files {
                for line in file.text.components(separatedBy: "\n") {
                    if WikiName.references(line, page: target) {
                        out.append(Mention(
                            url: file.url,
                            date: day.date,
                            title: JournalDate.filename(for: day.date),
                            lineText: line.trimmingCharacters(in: .whitespaces)
                        ))
                    }
                }
            }
        }
        for url in pageFileURLs() {
            // Skip the page's own file: it isn't a reference to itself.
            let name = url.deletingPathExtension().lastPathComponent
            if name.lowercased() == WikiName.fileName(for: target).lowercased() { continue }
            for line in pageText(at: url).components(separatedBy: "\n") {
                if WikiName.references(line, page: target) {
                    out.append(Mention(
                        url: url,
                        date: nil,
                        title: WikiName.pageName(for: url.lastPathComponent),
                        lineText: line.trimmingCharacters(in: .whitespaces)
                    ))
                }
            }
        }
        return out
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
        let root: URL
        switch layout {
        case .root: root = vaultURL
        case .journalsDirectory: root = vaultURL.deletingLastPathComponent()
        }
        let url = root.appendingPathComponent("backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    private func installWatchers() {
        guard watchers.isEmpty else { return }
        for dir in [journalsURL, pagesURL, vaultURL] {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: DispatchQueue.global(qos: .utility)
            )
            let dirPath = dir.path
            source.setEventHandler { [weak self] in
                _ = dirPath
                self?.scheduleReload()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func scheduleReload() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Our own writes already refreshed the store in place; a watcher
            // reload right after would only duplicate work (and flicker).
            if let last = self.lastSelfWrite, Date().timeIntervalSince(last) < 0.8 {
                return
            }
            self.reloadWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.reload()
                self?.onExternalChange?()
            }
            self.reloadWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
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
        let n = (lastPathComponent as NSString).deletingPathExtension
        if n =~~ "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" { return 0 }
        if n =~~ "^[0-9]{4}_[0-9]{2}_[0-9]{2}$" { return 1 }
        return 2
    }
}
