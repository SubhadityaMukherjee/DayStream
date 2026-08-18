import XCTest
@testable import DayStream

final class TaskSyncTests: XCTestCase {
    func testSyncedTextFlipsMatchingTasksOnly() {
        let text = """
        - TODO eval the model
        - DONE unrelated done task
        - TODO eval the model
        - TODO something else
        """
        let synced = BlockTree.syncedText(text, key: BlockTree.normalize("Eval the model."), to: .done)
        XCTAssertNotNil(synced)
        let lines = synced!.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "- DONE eval the model")
        XCTAssertEqual(lines[2], "- DONE eval the model")
        XCTAssertEqual(lines[1], "- DONE unrelated done task", "already-done task untouched")
        XCTAssertEqual(lines[3], "- TODO something else")
    }

    func testSyncedTextReturnsNilWhenNothingMatches() {
        let text = "- TODO other\n"
        XCTAssertNil(BlockTree.syncedText(text, key: "eval", to: .done))
    }

    func testSyncedTextHandlesStatusPropertyStyle() {
        let text = "- Deal with email\n  Status:: Todo\n"
        let synced = BlockTree.syncedText(text, key: BlockTree.normalize("deal with email"), to: .done)
        XCTAssertEqual(synced?.components(separatedBy: "\n")[1].contains("Status:: Done"), true)
    }
}

final class WikiLinkScanTests: XCTestCase {
    func testReferencesDetection() {
        XCTAssertTrue(WikiName.references("some [[eval]] mention", page: "eval"))
        XCTAssertTrue(WikiName.references("- [[ Eval ]] task", page: "eval"), "whitespace + case insensitive")
        XCTAssertFalse(WikiName.references("[[evaluation]]", page: "eval"), "prefix must not match")
        XCTAssertFalse(WikiName.references("no links here", page: "eval"))
    }

    func testWikilinkTargets() {
        let targets = WikiName.wikilinkTargets(in: "- [[a]] and [[b c]] but [[not closed")
        XCTAssertEqual(targets, ["a", "b c"])
    }
}

final class VaultFeatureTests: XCTestCase {
    private var tmp: URL!
    private var journals: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("daystream-features-\(UUID().uuidString)", isDirectory: true)
        journals = tmp.appendingPathComponent("journals", isDirectory: true)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("pages", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, name: String) throws {
        try text.write(to: journals.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func utcDate(_ s: String) -> Date {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)!
    }

    private func makeStore() -> VaultStore {
        let store = VaultStore(vaultURL: tmp, watchEnabled: false)
        store.reload()
        return store
    }

    /// Finds the loaded day that contains the named journal file (days group by
    /// local-time start-of-day, so match on the file, not the date).
    private func dayContaining(_ store: VaultStore, fileName: String) -> JournalDay {
        store.days.first { day in day.files.contains { $0.url.lastPathComponent == fileName } }!
    }

    func testToggleTodoPropagatesAcrossNotes() throws {
        try write("- TODO eval the model\n", name: "2026-08-17.md")
        try write("- notes\n- TODO eval the model\n- TODO keep me\n", name: "2026-08-18.md")

        let store = makeStore()
        let day = dayContaining(store, fileName: "2026-08-18.md")
        let file = day.files.first { $0.url.lastPathComponent == "2026-08-18.md" }!
        let block = file.blocks[1]

        store.toggleTodo(in: file, block: block, syncAcrossNotes: true)

        // Cross-note sync runs on a background queue; wait for the write.
        let olderURL = journals.appendingPathComponent("2026-08-17.md")
        let synced = waitForFile(olderURL, containing: "- DONE eval the model")
        XCTAssertTrue(synced, "matching task in older note synced")
        let newer = try String(contentsOf: journals.appendingPathComponent("2026-08-18.md"), encoding: .utf8)
        XCTAssertTrue(newer.contains("- DONE eval the model"))
        XCTAssertTrue(newer.contains("- TODO keep me"))
    }

    /// Polls a file until it exists with the expected content (background sync).
    private func waitForFile(_ url: URL, containing needle: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(needle) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return (try? String(contentsOf: url, encoding: .utf8))?.contains(needle) ?? false
    }

    func testToggleTodoWithoutSyncLeavesOtherNotesAlone() throws {
        try write("- TODO eval the model\n", name: "2026-08-17.md")
        try write("- TODO eval the model\n", name: "2026-08-18.md")

        let store = makeStore()
        let day = dayContaining(store, fileName: "2026-08-18.md")
        let file = day.files.first { $0.url.lastPathComponent == "2026-08-18.md" }!
        store.toggleTodo(in: file, block: file.blocks[0], syncAcrossNotes: false)

        let older = try String(contentsOf: journals.appendingPathComponent("2026-08-17.md"), encoding: .utf8)
        XCTAssertEqual(older, "- TODO eval the model\n")
    }

    func testMentionsFindsReferencesAcrossJournalsAndPages() throws {
        try write("- [[eval]] went well\n", name: "2026-08-17.md")
        try write("notes without links\n", name: "2026-08-16.md")
        try "- see [[Eval]] again\n".write(
            to: tmp.appendingPathComponent("pages").appendingPathComponent("notes.md"),
            atomically: true, encoding: .utf8)

        let store = makeStore()
        let mentions = store.mentions(of: "eval")
        XCTAssertEqual(mentions.count, 2)
        XCTAssertTrue(mentions.contains { $0.date != nil && $0.lineText.contains("[[eval]]") })
        XCTAssertTrue(mentions.contains { $0.date == nil && $0.lineText.contains("[[Eval]]") })
    }

    func testDeleteEmptyNotesRemovesOnlyEmptyFiles() throws {
        try write("", name: "2026-08-15.md")
        try write("   \n\n", name: "2026-08-16.md")
        try write("- real content\n", name: "2026-08-17.md")
        try "".write(
            to: tmp.appendingPathComponent("pages").appendingPathComponent("empty page.md"),
            atomically: true, encoding: .utf8)

        let store = makeStore()
        let result = store.deleteEmptyNotes()

        XCTAssertEqual(result.deletedJournals, 2)
        XCTAssertEqual(result.deletedPages, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journals.appendingPathComponent("2026-08-15.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journals.appendingPathComponent("2026-08-16.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journals.appendingPathComponent("2026-08-17.md").path),
                      "content-bearing note must survive")
    }

    func testEnsureDayFileCreatesArbitraryDate() throws {
        let store = makeStore()
        let date = utcDate("2026-08-10")
        let (url, _) = store.ensureDayFile(for: date)
        XCTAssertEqual(url.lastPathComponent, "2026-08-10.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testImportImageWritesToAssets() throws {
        let store = makeStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let embed = store.importImage(png, originalName: "chart.png")
        XCTAssertNotNil(embed)
        XCTAssertTrue(embed!.hasPrefix("![](assets/"))
        XCTAssertTrue(embed!.hasSuffix("_chart.png)"))
        let fileName = String(embed!.dropFirst("![](assets/".count).dropLast())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.assetsURL.appendingPathComponent(fileName).path))
    }

    func testPageCreationMakesFileImmediately() throws {
        let store = makeStore()
        let url = store.pageURL(named: "Eval Notes", createIfMissing: true)
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path), "page file must exist on disk at creation")
    }

    // MARK: - Legacy filename migration

    func testMigrateLegacyFilenamesRenamesAndBacksUp() throws {
        try write("- old underscore note\n", name: "2026_08_10.md")
        try write("- old dash note\n", name: "11-08-2026.md")
        try write("- already iso\n", name: "2026-08-12.md")

        let store = makeStore()
        let result = store.migrateLegacyFilenames()

        XCTAssertEqual(result.migrated, 2)
        XCTAssertEqual(result.conflicts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journals.appendingPathComponent("2026_08_10.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journals.appendingPathComponent("11-08-2026.md").path))
        XCTAssertEqual(try String(contentsOf: journals.appendingPathComponent("2026-08-10.md"), encoding: .utf8),
                       "- old underscore note\n")
        XCTAssertEqual(try String(contentsOf: journals.appendingPathComponent("2026-08-11.md"), encoding: .utf8),
                       "- old dash note\n")

        let backup = tmp.appendingPathComponent("backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("2026_08_10.md").path),
                      "originals backed up before rename")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("11-08-2026.md").path))
    }

    func testMigrateReplacesEmptyPlaceholderWithLegacyContent() throws {
        try write("- real content\n", name: "2026_08_10.md")
        try "".write(to: journals.appendingPathComponent("2026-08-10.md"), atomically: true, encoding: .utf8)

        let store = makeStore()
        let result = store.migrateLegacyFilenames()

        XCTAssertEqual(result.migrated, 1)
        XCTAssertEqual(result.conflicts, 0)
        XCTAssertEqual(try String(contentsOf: journals.appendingPathComponent("2026-08-10.md"), encoding: .utf8),
                       "- real content\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journals.appendingPathComponent("2026_08_10.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("backup/2026-08-10.md").path),
            "empty placeholder backed up too")
    }

    func testMigrateSkipsConflictingDuplicatesButDropsIdenticalOnes() throws {
        try write("- same content\n", name: "2026_08_10.md")
        try write("- same content\n", name: "2026-08-10.md")
        try write("- different content\n", name: "11-08-2026.md")
        try write("- iso version\n", name: "2026-08-11.md")

        let store = makeStore()
        let result = store.migrateLegacyFilenames()

        XCTAssertEqual(result.migrated, 1, "identical duplicate dropped")
        XCTAssertEqual(result.conflicts, 1, "differing duplicate skipped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journals.appendingPathComponent("2026_08_10.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journals.appendingPathComponent("11-08-2026.md").path),
                      "conflicting legacy file untouched")
        XCTAssertEqual(try String(contentsOf: journals.appendingPathComponent("2026-08-11.md"), encoding: .utf8),
                       "- iso version\n")
    }
}
