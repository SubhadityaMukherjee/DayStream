import XCTest
@testable import DayStream

final class DaySummaryTests: XCTestCase {
    private func date(_ s: String) -> Date {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)!
    }

    func testMergesSectionsDedupesTasksAndStripsMetadata() {
        let day1 = """
        ## [[ADMIN]]
        - TODO Standup
        \tadded:: 2026-08-20T08:00:00Z
        - DONE Morning reset
        \tadded:: 2026-08-20T07:00:00Z
        \tcompleted:: 2026-08-20T07:30:00Z
        """
        let day2 = """
        ## [[admin]]
        - TODO Standup
        - TODO Write report
        """
        let day3 = """
        ## [[ADMIN]]
        - DONE Write report
        Some free text
        """

        let result = DaySummary.make(
            entries: [(date("2026-08-20"), day1), (date("2026-08-21"), day2), (date("2026-08-22"), day3)],
            endDate: date("2026-08-22"))

        XCTAssertEqual(result.dayCount, 3)
        XCTAssertEqual(result.sections.count, 1, "headings merge case-insensitively")

        let standupLines = result.markdown.components(separatedBy: "\n").filter { $0.contains("Standup") }
        XCTAssertEqual(standupLines.count, 1, "duplicate task appears once")
        XCTAssertTrue(result.markdown.contains("- TODO Standup\n"), "first occurrence keeps its state")
        XCTAssertTrue(result.markdown.contains("- DONE Write report"), "DONE anywhere wins the merge")
        XCTAssertTrue(result.markdown.contains("- DONE Morning reset"))
        XCTAssertTrue(result.markdown.contains("Some free text"))
        XCTAssertFalse(result.markdown.contains("added::"))
        XCTAssertFalse(result.markdown.contains("completed::"))
        XCTAssertTrue(result.markdown.hasPrefix("# Summary: "))
    }

    func testPreambleContentBeforeAnyHeading() {
        let day = """
        An intro line
        ## [[ADMIN]]
        - TODO Task
        """
        let result = DaySummary.make(entries: [(date("2026-09-01"), day)], endDate: date("2026-09-01"))
        XCTAssertEqual(result.sections.count, 2)
        XCTAssertNil(result.sections[0].heading, "content before headings is its own section")
        XCTAssertEqual(result.sections[0].nodes.first?.content, "An intro line")
        XCTAssertEqual(result.sections[1].heading, "## [[ADMIN]]")
    }

    func testDistinctHeadingsStaySeparate() {
        let day = """
        ## [[WORK]]
        - TODO Ship release
        ## [[HOME]]
        - TODO Water plants
        ## [[work]]
        - TODO Review PR
        """
        let result = DaySummary.make(entries: [(date("2026-09-02"), day)], endDate: date("2026-09-02"))
        XCTAssertEqual(result.sections.count, 2)
        XCTAssertEqual(result.sections.filter { $0.heading == "## [[WORK]]" }.count, 1)
        XCTAssertTrue(result.markdown.contains("- TODO Review PR"))
        XCTAssertTrue(result.markdown.contains("- TODO Water plants"))
    }
}
