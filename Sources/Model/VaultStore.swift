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
        let fm = FileManager.default
        var existing: [(url: URL, text: String)] = []
        for name in JournalDate.allFilenames(for: Date()) {
            let url = journalsURL.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            existing.append((url, text))
        }
        if let best = existing.first(where: { !$0.text.isEmpty }) ?? existing.first {
            return best
        }
        let url = todayURL
        try? "".write(to: url, atomically: true, encoding: .utf8)
        return (url, "")
    }

    // MARK: - Writing

    func write(text: String, to url: URL) {
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

    func toggleTodo(in file: VaultFile, block: Block) {
        let newText = BlockTree.toggledFileText(file.text, blockLineIndex: block.lineIndex)
        write(text: newText, to: file.url)
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
        return url
    }

    func pageText(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
