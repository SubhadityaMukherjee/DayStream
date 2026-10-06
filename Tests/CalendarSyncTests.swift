import XCTest
@testable import DayStream

final class CalendarSyncTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    private func date(_ s: String) -> Date { iso.date(from: s)! }
    private func event(_ title: String, _ start: String, allDay: Bool = false) -> CalendarEventSnapshot {
        CalendarEventSnapshot(title: title, start: date(start),
                              end: date(start).addingTimeInterval(3600), isAllDay: allDay)
    }

    private func merge(_ text: String,
                       _ events: [CalendarEventSnapshot],
                       ids: [String]) -> CalendarSync.MergeResult? {
        CalendarSync.mergedText(todayText: text, events: events, ids: ids) { _ in "9:00 AM" }
    }

    func testCreatesTodaySectionAtTopOfEmptyNote() {
        let result = merge("", [event("Standup", "2026-10-06T09:00:00Z")], ids: ["E1"])
        XCTAssertEqual(result?.added, 1)
        let lines = result!.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "- [[TODAY]]")
        XCTAssertEqual(lines[1], "\t- Standup, 9:00 AM")
        XCTAssertEqual(lines[2], "\t\tevent:: E1#\(Int(date("2026-10-06T09:00:00Z").timeIntervalSince1970))")
    }

    func testCreatesTodaySectionAboveExistingContent() {
        let result = merge("- existing task\n",
                           [event("Standup", "2026-10-06T09:00:00Z")], ids: ["E1"])
        let lines = result!.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "- [[TODAY]]")
        XCTAssertEqual(lines[3], "", "blank line between section and prior content")
        XCTAssertEqual(lines[4], "- existing task")
    }

    func testAllDayEventHasNoTimeSuffix() {
        let result = merge("", [event("Conference", "2026-10-06T00:00:00Z", allDay: true)], ids: ["E2"])
        XCTAssertTrue(result!.text.contains("\t- Conference\n"))
        XCTAssertFalse(result!.text.contains("Conference, "))
    }

    func testEventsSortByStartTime() {
        let result = merge("", [
            event("Late sync", "2026-10-06T16:00:00Z"),
            event("Early standup", "2026-10-06T08:00:00Z"),
        ], ids: ["A", "B"])
        let text = result!.text
        let early = text.range(of: "Early standup")!.lowerBound
        let late = text.range(of: "Late sync")!.lowerBound
        XCTAssertTrue(early < late)
    }

    func testReMergeIsNoOp() {
        let events = [event("Standup", "2026-10-06T09:00:00Z")]
        let first = merge("", events, ids: ["E1"])
        XCTAssertNotNil(first)
        XCTAssertNil(merge(first!.text, events, ids: ["E1"]))
    }

    func testEmptyEventsAndNoSectionIsNoOp() {
        XCTAssertNil(merge("- just a note\n", [], ids: []))
    }

    func testEmptyTitlesAreSkipped() {
        let result = merge("", [event("  ", "2026-10-06T09:00:00Z")], ids: ["E1"])
        XCTAssertNil(result)
    }

    func testDuplicateEventsFromOverlappingCalendarsDedupe() {
        let result = merge("", [
            event("Standup", "2026-10-06T09:00:00Z"),
            event("Standup", "2026-10-06T09:00:00Z"),
        ], ids: ["E1", "E1"])
        XCTAssertEqual(result?.added, 1)
    }

    func testAppendsToExistingBulletSectionWithoutTouchingOtherContent() {
        let text = "- [[TODAY]]\n\t- Standup, 9:00 AM\n\t\tevent:: E1#100\n- TODO other task\n"
        let result = merge(text, [event("Review", "2026-10-06T14:00:00Z")], ids: ["E2"])
        XCTAssertEqual(result?.added, 1)
        let lines = result!.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "- [[TODAY]]")
        XCTAssertEqual(lines[1], "\t- Standup, 9:00 AM")
        XCTAssertEqual(lines[3], "\t- Review, 9:00 AM")
        XCTAssertEqual(lines[5], "- TODO other task", "new events insert before dedented content")
    }

    func testMovedEventUpdatesInPlaceInsteadOfDuplicating() {
        let text = "- [[TODAY]]\n\t- Standup, 9:00 AM\n\t\tevent:: E1#100\n"
        let result = merge(text, [event("Standup moved", "2026-10-06T11:00:00Z")], ids: ["E1"])
        XCTAssertEqual(result?.updated, 1)
        XCTAssertEqual(result?.added, 0)
        let lines = result!.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "\t- Standup moved, 9:00 AM")
        XCTAssertTrue(lines[2].hasSuffix("#\(Int(date("2026-10-06T11:00:00Z").timeIntervalSince1970))"))
        XCTAssertEqual(lines.count, 4, "input line count preserved, no duplicate bullet")
    }

    func testHeadingFormSectionTakesTopLevelBullets() {
        let text = "## [[TODAY]]\n- TODO unrelated\n"
        let result = merge(text, [event("Standup", "2026-10-06T09:00:00Z")], ids: ["E1"])
        XCTAssertEqual(result?.added, 1)
        let lines = result!.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "## [[TODAY]]")
        XCTAssertEqual(lines[1], "- TODO unrelated")
        XCTAssertEqual(lines[2], "- Standup, 9:00 AM", "top-level bullet under a heading-form section")
        XCTAssertTrue(lines[3].hasPrefix("\tevent:: E1#"))
    }

    func testInsertionStopsAtNextSectionHeader() {
        let text = "- [[TODAY]]\n\t- Standup, 9:00 AM\n\t\tevent:: E1#100\n## [[ADMIN]]\n- TODO admin task\n"
        let result = merge(text, [event("Review", "2026-10-06T14:00:00Z")], ids: ["E2"])
        let lines = result!.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[3], "\t- Review, 9:00 AM")
        XCTAssertEqual(lines[5], "## [[ADMIN]]", "nothing inserted into the next section")
    }

    func testEventsRemovedFromCalendarStayInNote() {
        let text = "- [[TODAY]]\n\t- Standup, 9:00 AM\n\t\tevent:: E1#100\n"
        XCTAssertNil(merge(text, [], ids: []))
    }
}
