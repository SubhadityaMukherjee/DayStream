import XCTest
@testable import DayStream

final class LiveMarkdownTests: XCTestCase {
    private struct R: Equatable {
        let location: Int
        let length: Int
        init(_ location: Int, _ length: Int) {
            self.location = location
            self.length = length
        }
    }

    private func hidden(_ line: String, offset: Int = 0) -> [R] {
        LiveMarkdown.hiddenRanges(line: line, offset: offset)
            .map { R($0.location, $0.length) }
            .sorted { $0.location < $1.location }
    }

    func testBoldDelimiters() {
        XCTAssertEqual(hidden("a **b** c"), [R(2, 2), R(5, 2)])
    }

    func testItalicDelimiters() {
        XCTAssertEqual(hidden("*hi* x"), [R(0, 1), R(3, 1)])
    }

    func testItalicInsideBoldIsSkipped() {
        XCTAssertEqual(hidden("**b**"), [R(0, 2), R(3, 2)])
    }

    func testWikilinkBrackets() {
        XCTAssertEqual(hidden("[[Page]] x"), [R(0, 2), R(6, 2)])
    }

    func testCodeSpanBackticks() {
        XCTAssertEqual(hidden("`c` x"), [R(0, 1), R(2, 1)])
    }

    func testLinkHidesBracketAndURL() {
        XCTAssertEqual(hidden("[l](u)"), [R(0, 1), R(2, 4)])
    }

    func testImageEmbedStaysVisible() {
        XCTAssertEqual(hidden("![a](u)"), [])
    }

    func testHeadingMarker() {
        XCTAssertEqual(hidden("## Title"), [R(0, 3)])
    }

    func testHashtagIsNotAHeading() {
        XCTAssertEqual(hidden("#daystream notes"), [])
        XCTAssertFalse(LiveMarkdown.isHeadingLine("#daystream"))
        XCTAssertTrue(LiveMarkdown.isHeadingLine("# Title"))
        XCTAssertTrue(LiveMarkdown.isHeadingLine("##  Double"))
        XCTAssertFalse(LiveMarkdown.isHeadingLine("##NoSpace"))
    }

    func testTaskBulletHidesPrefix() {
        XCTAssertEqual(hidden("- TODO ship it"), [R(0, 7)])
    }

    func testWikilinkInsideBullet() {
        XCTAssertEqual(hidden("- TODO ship the thing [[link]]"), [R(0, 7), R(22, 2), R(28, 2)])
    }

    func testOffsetIsApplied() {
        XCTAssertEqual(hidden("a *b*", offset: 10), [R(12, 1), R(14, 1)])
    }

    func testEmptyLine() {
        XCTAssertEqual(hidden(""), [])
    }

    func testBookkeepingPropertyLines() {
        XCTAssertTrue(LiveMarkdown.isBookkeepingPropertyLine("added:: [2026-08-20]"))
        XCTAssertTrue(LiveMarkdown.isBookkeepingPropertyLine("\tcompleted:: 10:32"))
        XCTAssertTrue(LiveMarkdown.isBookkeepingPropertyLine("id:: 66f0a1"))
        XCTAssertFalse(LiveMarkdown.isBookkeepingPropertyLine("status:: waiting"))
        XCTAssertFalse(LiveMarkdown.isBookkeepingPropertyLine("- TODO added"))
        XCTAssertFalse(LiveMarkdown.isBookkeepingPropertyLine("added up"))
    }

    func testTodoMarkerRange() {
        func marker(_ line: String) -> R? {
            LiveMarkdown.todoMarkerRange(inLine: line).map { R($0.location, $0.length) }
        }
        XCTAssertEqual(marker("- TODO ship it"), R(2, 4))
        XCTAssertEqual(marker("\t- DONE x"), R(3, 4))
        XCTAssertEqual(marker("- LATER"), R(2, 5))
        XCTAssertNil(marker("- plain bullet"))
        XCTAssertNil(marker("# TODO heading"))
        // Marker must be a whole word, not a prefix of the content.
        XCTAssertNil(marker("- TODOography"))
    }

    func testRenderableBulletPrefix() {
        func prefix(_ line: String) -> R? {
            LiveMarkdown.renderableBulletPrefix(inLine: line).map { R($0.location, $0.length) }
        }
        // Task lines hide bullet + marker + one space (never the newline).
        XCTAssertEqual(prefix("- TODO ship it"), R(0, 7))
        XCTAssertEqual(prefix("- DONE"), R(0, 6))
        XCTAssertEqual(prefix("* NOW urgent"), R(0, 6))
        // Indent stays visible.
        XCTAssertEqual(prefix("\t- TODO nested"), R(1, 7))
        // Plain bullets hide just the bullet + whitespace.
        XCTAssertEqual(prefix("- plain"), R(0, 2))
        XCTAssertEqual(prefix("-   spaced"), R(0, 4))
        XCTAssertNil(prefix("no bullet here"))
        XCTAssertNil(prefix("# heading"))
    }

    func testHiddenRangesHideBulletPrefix() {
        let hidden = LiveMarkdown.hiddenRanges(line: "- TODO task", offset: 5)
        XCTAssertTrue(hidden.contains { $0.location == 5 && $0.length == 7 })
        let plainHidden = LiveMarkdown.hiddenRanges(line: "- item", offset: 0)
        XCTAssertTrue(plainHidden.contains { $0.location == 0 && $0.length == 2 })
    }
}
