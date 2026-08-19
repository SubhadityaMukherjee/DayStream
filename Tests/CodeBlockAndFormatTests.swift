import XCTest
@testable import DayStream

final class CodeBlockTests: XCTestCase {
    // MARK: - BlockTree.bodySegments

    func testSegmentsExtractFencedCode() {
        let lines = ["some text", "```swift", "let x = 1", "  * not a bullet", "```", "after"]
        let segments = BlockTree.bodySegments(lines)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .line("some text"))
        if case .code(let lang, let code) = segments[1] {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, ["let x = 1", "  * not a bullet"])
        } else {
            XCTFail("expected code segment")
        }
        XCTAssertEqual(segments[2], .line("after"))
    }

    func testUnclosedFenceRunsToEnd() {
        let segments = BlockTree.bodySegments(["```", "a", "b"])
        if case .code(let lang, let code) = segments.first {
            XCTAssertNil(lang)
            XCTAssertEqual(code, ["a", "b"])
        } else {
            XCTFail("expected code segment")
        }
    }

    func testTildeFencesAndNoLanguage() {
        let segments = BlockTree.bodySegments(["~~~", "plain", "~~~"])
        if case .code(let lang, let code) = segments.first {
            XCTAssertNil(lang)
            XCTAssertEqual(code, ["plain"])
        } else {
            XCTFail("expected code segment")
        }
    }

    func testEmptyCodeBlock() {
        let segments = BlockTree.bodySegments(["```", "```", "text"])
        if case .code(_, let code) = segments.first {
            XCTAssertTrue(code.isEmpty)
        } else {
            XCTFail("expected code segment")
        }
    }

    // MARK: - Whitespace normalization

    func testWhitespaceNormalization() {
        // 2 spaces is under one indent unit (4 spaces = 1 tab): stays flat.
        let text = "    - indented with spaces\n* star bullet\n  *  spaced star  \n-  trailing spaces  \n"
        let out = NoteFormatter.normalizingWhitespace(text)
        XCTAssertEqual(
            out.components(separatedBy: "\n"),
            ["\t- indented with spaces", "- star bullet", "- spaced star", "- trailing spaces", ""])
    }

    func testHeadingAndPropertySpacing() {
        let text = "##  Spaced Heading  \ncollapsed::    value\n"
        let out = NoteFormatter.normalizingWhitespace(text)
        XCTAssertEqual(out.components(separatedBy: "\n"), ["## Spaced Heading", "collapsed:: value", ""])
    }

    func testFenceContentUntouchedByNormalization() {
        let text = "```yaml\n  key:   value\n*  bullet-ish\n   \n```\n    - normal bullet\n"
        let out = NoteFormatter.normalizingWhitespace(text)
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "```yaml")
        XCTAssertEqual(lines[1], "  key:   value", "code content byte-identical")
        XCTAssertEqual(lines[2], "*  bullet-ish", "star bullets inside code are content")
        XCTAssertEqual(lines[3], "   ", "blank-ish line inside code preserved verbatim")
        XCTAssertEqual(lines[4], "```")
        XCTAssertEqual(lines[5], "\t- normal bullet")
    }

    func testEmptyBulletsKeptInsideFences() {
        let text = "```\n-\n```\n-\n"
        let out = NoteFormatter.removingEmptyBullets(text)
        XCTAssertEqual(out.components(separatedBy: "\n"), ["```", "-", "```", ""])
    }

    func testBlankCollapseSkipsFences() {
        let text = "a\n\n\n\nb\n```\n\n\n\ncode\n```\n"
        let out = NoteFormatter.collapsingBlankLines(text)
        XCTAssertEqual(out, "a\n\nb\n```\n\n\n\ncode\n```\n")
    }

    // MARK: - Block boundary spacing

    func testBlankBetweenTextAndBullets() {
        let text = "intro paragraph\n- TODO first\n- TODO second\n"
        let out = NoteFormatter.spacingBlockBoundaries(text)
        XCTAssertEqual(out, "intro paragraph\n\n- TODO first\n- TODO second\n")
    }

    func testBulletGroupsStayTight() {
        let text = "- TODO a\n- TODO b\n"
        XCTAssertEqual(NoteFormatter.spacingBlockBoundaries(text), text)
    }

    func testStackedHeadingsStayTight() {
        let text = "# Title\n## Section\n"
        XCTAssertEqual(NoteFormatter.spacingBlockBoundaries(text), text)
    }

    func testBlankAroundHeadings() {
        let text = "- TODO a\n# Title\nbody text\n"
        let out = NoteFormatter.spacingBlockBoundaries(text)
        XCTAssertEqual(out, "- TODO a\n\n# Title\n\nbody text\n")
    }

    func testBlankAroundCodeFences() {
        let text = "- TODO a\n```swift\nlet x = 1\n```\n- TODO b\n"
        let out = NoteFormatter.spacingBlockBoundaries(text)
        XCTAssertEqual(out, "- TODO a\n\n```swift\nlet x = 1\n```\n\n- TODO b\n")
    }

    func testFenceInternalBlanksUntouched() {
        let text = "```\na\n\nb\n```\n"
        XCTAssertEqual(NoteFormatter.spacingBlockBoundaries(text), text)
    }

    func testExistingBlanksNotDoubled() {
        let text = "text\n\n- TODO a\n"
        XCTAssertEqual(NoteFormatter.spacingBlockBoundaries(text), text)
    }

    // MARK: - End-to-end save normalization

    func testNormalizedForSavePreservesCodeVerbatim() {
        let text = "* TODO fix parser\n   ```yaml\n   key:   value\n   *  not a bullet\n   ```\nplain tail\n"
        let out = NoteFormatter.normalizedForSave(text, isToday: false, now: Date())
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "- TODO fix parser")
        XCTAssertEqual(lines[1], "", "code block separates from the bullet above")
        XCTAssertEqual(lines[2], "```yaml", "fence markers de-indented to column 0")
        XCTAssertEqual(lines[3], "   key:   value")
        XCTAssertEqual(lines[4], "   *  not a bullet")
        XCTAssertEqual(lines[5], "```")
        XCTAssertEqual(lines[6], "", "code block separates from the text below")
        XCTAssertEqual(lines[7], "plain tail")
        XCTAssertTrue(out.hasSuffix("\n"))
    }

    func testNormalizedForSaveSpacesWikilinksListsAndCode() {
        let text = "notes for today\n- TODO write docs\n- [[Project]]\n\t- research\n```sh\nls -l\n```\n"
        let out = NoteFormatter.normalizedForSave(text, isToday: false, now: Date())
        let lines = out.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "notes for today")
        XCTAssertEqual(lines[1], "", "text separates from bullets")
        XCTAssertEqual(lines[2], "- TODO write docs")
        XCTAssertEqual(lines[3], "", "wikilink group separates")
        XCTAssertEqual(lines[4], "- [[Project]]")
        XCTAssertEqual(lines[5], "\t- research")
        XCTAssertEqual(lines[6], "", "code separates")
        XCTAssertEqual(lines[7], "```sh")
        XCTAssertEqual(lines[8], "ls -l")
        XCTAssertEqual(lines[9], "```")
    }
}
