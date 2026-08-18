import XCTest
@testable import DayStream

final class JournalDateTests: XCTestCase {
    func testParsesISOFormat() {
        let d = JournalDate.date(fromFilename: "2026-08-14.md")
        XCTAssertNotNil(d)
    }

    func testParsesLogseqDefaultFormat() {
        let d = JournalDate.date(fromFilename: "2026_08_14.md")
        XCTAssertNotNil(d)
    }

    func testParsesCustomFormat() {
        // Day-first European format (dd-MM-yyyy), matching the vault's config.
        XCTAssertNotNil(JournalDate.date(fromFilename: "14-08-2026.md"))
        XCTAssertNil(JournalDate.date(fromFilename: "08-14-2026.md"), "second field is the month; 14 is invalid")
    }

    func testRejectsNonJournalFiles() {
        for name in ["transcript.md", "Library.md", "contents.md", "26.md", "sep 18th, 2024 - preamble.md", "2026-13-45.md"] {
            XCTAssertNil(JournalDate.date(fromFilename: name), "should reject \(name)")
        }
    }

    func testFormatsAgreeOnSameDay() {
        let iso = JournalDate.date(fromFilename: "2026-08-14.md")!
        let us = JournalDate.date(fromFilename: "14-08-2026.md")!
        let us2 = JournalDate.date(fromFilename: "2026_08_14.md")!
        XCTAssertEqual(JournalDate.startOfDay(iso), JournalDate.startOfDay(us))
        XCTAssertEqual(JournalDate.startOfDay(iso), JournalDate.startOfDay(us2))
    }

    func testNewFilenameIsISO() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        let date = df.date(from: "2026-08-18")!
        XCTAssertEqual(JournalDate.filename(for: date), "2026-08-18.md")
    }
}

final class WikiNameTests: XCTestCase {
    func testSlashBecomesTripleUnderscore() {
        XCTAssertEqual(WikiName.fileName(for: "ALFIE/ArchitectureNotes"), "ALFIE___ArchitectureNotes.md")
    }

    func testRoundtrip() {
        let name = "ALFIE/ArchitectureNotes"
        XCTAssertEqual(WikiName.pageName(for: WikiName.fileName(for: name)), name)
    }

    func testPlainNamesStay() {
        XCTAssertEqual(WikiName.fileName(for: "Monthly_plan"), "Monthly_plan.md")
    }

    func testPercentEncodingRoundtrip() {
        let name = "Research: ideas?"
        let file = WikiName.fileName(for: name)
        XCTAssertEqual(WikiName.pageName(for: file), name)
        XCTAssertFalse(file.contains(":"))
        XCTAssertFalse(file.contains("?"))
    }
}
