import XCTest
@testable import DayStream

final class BlockTreeTests: XCTestCase {
    private let sample = """
    - [[Review 1]]
    \t- [Presentations](https://example.com)
    - Deal with email
      Status:: Done
    - TODO write tests
    \t- DONE docker image
    \t- plain child note
    - DOING experimenting
    - DONE already finished
    \t- TODO hidden under done
    """

    func testParsesMarkersAndIndent() {
        let blocks = BlockTree.parse(sample)
        XCTAssertEqual(blocks.count, 5)

        XCTAssertEqual(blocks[0].content, "[[Review 1]]")
        XCTAssertEqual(blocks[0].todoState, .none)
        XCTAssertEqual(blocks[0].children.count, 1)
        XCTAssertEqual(blocks[0].children[0].indent, 1)

        XCTAssertEqual(blocks[1].content, "Deal with email")
        XCTAssertEqual(blocks[1].todoState, .done, "Status:: Done should mark parent done")

        XCTAssertEqual(blocks[2].marker, "TODO")
        XCTAssertEqual(blocks[2].todoState, .open)
        XCTAssertEqual(blocks[2].children.count, 2)
        XCTAssertEqual(blocks[2].children[0].todoState, .done)
        XCTAssertEqual(blocks[2].children[1].todoState, .none)

        XCTAssertEqual(blocks[3].marker, "DOING")
        XCTAssertEqual(blocks[3].todoState, .open)

        XCTAssertEqual(blocks[4].todoState, .done)
    }

    func testToggleMarker() {
        let blocks = BlockTree.parse(sample)
        let toggled = BlockTree.toggledFileText(sample, blockLineIndex: blocks[2].lineIndex)
        XCTAssertFalse(toggled.components(separatedBy: "\n")[blocks[2].lineIndex].contains("TODO"))
        XCTAssertTrue(toggled.components(separatedBy: "\n")[blocks[2].lineIndex].contains("DONE"))
    }

    func testToggleStatusProperty() {
        let blocks = BlockTree.parse(sample)
        // "Deal with email" at line 2; its Status:: line is line 3.
        let toggled = BlockTree.toggledFileText(sample, blockLineIndex: blocks[1].lineIndex)
        let lines = toggled.components(separatedBy: "\n")
        XCTAssertTrue(lines[3].contains("Status:: Todo"))
    }

    func testToggleStatusPropertyPreservesSurroundings() {
        let text = "- task one\n  Status:: Done  \n- task two"
        let blocks = BlockTree.parse(text)
        let toggled = BlockTree.toggledFileText(text, blockLineIndex: blocks[0].lineIndex)
        let lines = toggled.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("  Status:: Todo"))
        XCTAssertEqual(lines[2], "- task two")
    }

    func testRenderedSubtreeSkipsDoneChildren() {
        let blocks = BlockTree.parse(sample)
        let lines = BlockTree.renderedSubtree(blocks[2]) // TODO write tests
        XCTAssertEqual(lines.joined(separator: "\n").contains("DONE docker image"), false)
        XCTAssertTrue(lines.joined(separator: "\n").contains("plain child note"))
    }

    func testCollectOpenTasksIncludesAncestors() {
        let text = """
        - [[ALFIE]]
        \t- TODO follow up
        - TODO standalone
        """
        let blocks = BlockTree.parse(text)
        var tasks: [(task: Block, path: [Block])] = []
        BlockTree.collectOpenTasks(blocks, ancestors: [], into: &tasks)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].path.map(\.content), ["[[ALFIE]]"])
        XCTAssertEqual(tasks[1].path.map(\.content), [])
    }
}

final class CarryForwardTests: XCTestCase {
    private func utcDate(_ s: String) -> Date {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)!
    }

    func testCarriesOpenTasksWithStructureAndSkipsDone() {
        let yesterday = """
        - [[ALFIE]]
        \t- TODO write tests
        \t\t- DONE docker image
        \t\t- TODO fix flaky suite
        \t- DONE already done
        - TODO Clean email
        - plain note
        """
        let today = ""

        let (newText, result) = CarryForwardService.carryForward(
            allFiles: [(date: utcDate("2026-08-17"), text: yesterday)],
            todayText: today
        )

        XCTAssertEqual(result.carriedCount, 2, "parent task + standalone task; nested TODOs ride along in the parent subtree")
        XCTAssertEqual(result.sourceDays, 1)

        let lines = newText.components(separatedBy: "\n")
        XCTAssertTrue(newText.contains("- [[ALFIE]]"))
        XCTAssertTrue(newText.contains("\t- TODO write tests"))
        XCTAssertTrue(newText.contains("\t\t- TODO fix flaky suite"))
        XCTAssertTrue(newText.contains("- TODO Clean email"))
        XCTAssertFalse(newText.contains("DONE docker image"))
        XCTAssertFalse(newText.contains("already done"))
        XCTAssertFalse(newText.contains("plain note"))
        _ = lines
    }

    func testCarriesStatusStyleTodosWithTheirProperty() {
        let yesterday = """
        - Deal with email
          Status:: Todo
        - Filed taxes
          Status:: Done
        """
        let (_, result) = CarryForwardService.carryForward(
            allFiles: [(date: utcDate("2026-08-17"), text: yesterday)],
            todayText: ""
        )
        XCTAssertEqual(result.carriedCount, 1)
    }

    func testSkipsTasksAlreadyOnToday() {
        let yesterday = "- TODO Clean email\n- TODO other task\n"
        let today = "- TODO clean email\n"

        let (newText, result) = CarryForwardService.carryForward(
            allFiles: [(date: utcDate("2026-08-17"), text: yesterday)],
            todayText: today
        )

        XCTAssertEqual(result.carriedCount, 1)
        XCTAssertEqual(result.skippedAlreadyToday, 1)
        XCTAssertEqual(newText.components(separatedBy: "\n").filter { $0.lowercased().contains("clean email") }.count, 1,
                       "the only occurrence is the one already on today; no copy appended")
    }

    func testMostRecentOccurrenceWins() {
        let old = "- TODO Clean email\n- TODO ancient task\n"
        let recent = "- TODO Clean email\n- TODO fresh task\n"

        let (newText, result) = CarryForwardService.carryForward(
            allFiles: [
                (date: utcDate("2026-08-16"), text: old),
                (date: utcDate("2026-08-17"), text: recent),
            ],
            todayText: ""
        )

        XCTAssertEqual(result.carriedCount, 3)
        XCTAssertEqual(result.skippedDuplicates, 1)
        XCTAssertEqual(newText.components(separatedBy: "\n").filter { $0.contains("Clean email") }.count, 1)
    }

    func testIdempotentWhenEverythingAlreadyCarried() {
        let yesterday = "- TODO Clean email\n"
        let today = "- TODO Clean email\n"
        let (_, result) = CarryForwardService.carryForward(
            allFiles: [(date: utcDate("2026-08-17"), text: yesterday)],
            todayText: today
        )
        XCTAssertEqual(result.carriedCount, 0)
    }

    func testGroupsTasksSharingAncestorChain() {
        let yesterday = """
        - [[ALFIE]]
        \t- TODO task a
        \t- TODO task b
        - [[Other]]
        \t- TODO task c
        """
        let (newText, result) = CarryForwardService.carryForward(
            allFiles: [(date: utcDate("2026-08-17"), text: yesterday)],
            todayText: ""
        )
        XCTAssertEqual(result.carriedCount, 3)
        XCTAssertEqual(newText.components(separatedBy: "\n").filter { $0 == "- [[ALFIE]]" }.count, 1)
        XCTAssertEqual(newText.components(separatedBy: "\n").filter { $0 == "- [[Other]]" }.count, 1)
    }
}
