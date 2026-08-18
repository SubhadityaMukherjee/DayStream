import XCTest
@testable import DayStream

final class MultiFileDayTests: XCTestCase {
    private var tmp: URL!
    private var journals: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("daystream-tests-\(UUID().uuidString)", isDirectory: true)
        journals = tmp.appendingPathComponent("journals", isDirectory: true)
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String, name: String) throws {
        try text.write(to: journals.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func makeStore() -> VaultStore {
        let store = VaultStore(vaultURL: tmp, watchEnabled: false)
        store.reload()
        return store
    }

    func testEditFilePrefersContentBearingSibling() throws {
        let names = JournalDate.allFilenames(for: Date())
        try "".write(to: journals.appendingPathComponent(names[0]), atomically: true, encoding: .utf8) // ISO, empty
        try "- TODO real task\n".write(to: journals.appendingPathComponent(names[1]), atomically: true, encoding: .utf8) // yyyy_MM_dd, content

        let store = makeStore()
        let today = JournalDate.startOfDay(Date())
        let day = store.days.first { $0.date == today }
        XCTAssertNotNil(day)

        XCTAssertEqual(day?.editFile?.url.lastPathComponent, names[1],
                       "editor must target the file with content, not the empty ISO sibling")
        XCTAssertEqual(day?.displayFiles.map(\.url.lastPathComponent), [names[1]],
                       "empty sibling must be hidden from display")
    }

    func testDisplayFilesShowsSoleFileWhenAllEmpty() throws {
        let names = JournalDate.allFilenames(for: Date())
        try "".write(to: journals.appendingPathComponent(names[0]), atomically: true, encoding: .utf8)
        let store = makeStore()
        let today = JournalDate.startOfDay(Date())
        let day = store.days.first { $0.date == today }
        XCTAssertEqual(day?.displayFiles.count, 1)
    }

    func testEnsureTodayFileReturnsContentBearingFileWithoutCreatingDuplicates() throws {
        let names = JournalDate.allFilenames(for: Date())
        try "".write(to: journals.appendingPathComponent(names[0]), atomically: true, encoding: .utf8) // empty ISO exists
        try "- existing note\n".write(to: journals.appendingPathComponent(names[2]), atomically: true, encoding: .utf8) // dd-MM-yyyy content

        let store = makeStore()
        let (url, text) = store.ensureTodayFile()
        XCTAssertEqual(url.lastPathComponent, names[2])
        XCTAssertTrue(text.contains("existing note"))
    }

    func testCarryForwardLandsInContentBearingTodayFile() throws {
        let todayNames = JournalDate.allFilenames(for: Date())
        try "- existing note\n".write(to: journals.appendingPathComponent(todayNames[1]), atomically: true, encoding: .utf8)
        let yesterday = Date(timeIntervalSinceNow: -3 * 86400)
        let yesterdayNames = JournalDate.allFilenames(for: yesterday)
        try "- [[Project]]\n\t- TODO from yesterday\n".write(to: journals.appendingPathComponent(yesterdayNames[1]), atomically: true, encoding: .utf8)

        let store = makeStore()
        let result = store.carryForward()

        XCTAssertEqual(result.carriedCount, 1)
        let carried = try String(contentsOf: journals.appendingPathComponent(todayNames[1]), encoding: .utf8)
        XCTAssertTrue(carried.contains("from yesterday"), "carried tasks must land in the content-bearing today file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journals.appendingPathComponent(todayNames[0]).path),
                       "no duplicate ISO file should be created when a today file already exists")
    }

    func testEnsureTodayFileCreatesISOWhenNothingExists() throws {
        let store = makeStore()
        let (url, _) = store.ensureTodayFile()
        XCTAssertEqual(url.lastPathComponent, JournalDate.filename(for: Date()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
