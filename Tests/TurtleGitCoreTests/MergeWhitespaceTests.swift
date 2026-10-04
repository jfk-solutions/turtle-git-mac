import XCTest
@testable import TurtleGitCore

final class MergeWhitespaceTests: XCTestCase {
    func testIndentationConversionsRetainEveryEndingAndUnicode() {
        for ending in MergeLineEnding.allCases {
            let eol = ending.rawValue
            let text = " \t  🦎e\u{301}\t雪" + eol + "     tail  \t" + eol + "\tEOF"
            let expanded = "      🦎e\u{301}\t雪" + eol + "     tail  \t" + eol + "    EOF"
            let tabbed = "\t  🦎e\u{301}\t雪" + eol + "\t tail  \t" + eol + "\tEOF"
            let trimmed = " \t  🦎e\u{301}\t雪" + eol + "     tail" + eol + "\tEOF"
            for (command, expected) in [(MergeWhitespaceCommand.tabsToSpaces, expanded), (.spacesToTabs, tabbed), (.trimRight, trimmed)] {
                XCTAssertEqual(Data(MergeWhitespace.applying(command, to: text).utf8), Data(expected.utf8))
                XCTAssertTrue(MergeWhitespace.canApply(command, to: text))
                XCTAssertEqual(MergeLineEndings.styles(in: MergeWhitespace.applying(command, to: text)), [ending])
            }
        }
    }
    func testTabStopsPartialRunsAndEnablement() {
        for width in [1, 2, 4, 8] {
            let spaces = String(repeating: " ", count: width)
            XCTAssertEqual(MergeWhitespace.applying(.tabsToSpaces, to: "\t🦎\ttext", tabWidth: width), spaces + "🦎\ttext")
            XCTAssertEqual(MergeWhitespace.applying(.spacesToTabs, to: spaces + "🦎\ttext", tabWidth: width), "\t🦎\ttext")
            XCTAssertEqual(MergeWhitespace.applying(.tabsToSpaces, to: " \ttext", tabWidth: width), String(repeating: " ", count: width == 1 ? 2 : width) + "text")
        }
        XCTAssertEqual(MergeWhitespace.applying(.tabsToSpaces, to: "  \t\tX", tabWidth: 3), "      X")
        XCTAssertEqual(MergeWhitespace.applying(.spacesToTabs, to: "  \t  X", tabWidth: 3), "\t  X")
        XCTAssertEqual(MergeWhitespace.applying(.spacesToTabs, to: "       X", tabWidth: 3), "\t\t X")
        for command in MergeWhitespaceCommand.allCases {
            XCTAssertFalse(MergeWhitespace.canApply(command, to: ""))
            XCTAssertFalse(MergeWhitespace.canApply(command, to: "🦎e\u{301}\t雪"))
        }
        XCTAssertFalse(MergeWhitespace.canApply(.spacesToTabs, to: "   X"))
        XCTAssertFalse(MergeWhitespace.canApply(.spacesToTabs, to: "\tX"))
        XCTAssertEqual(MergeWhitespace.applying(.tabsToSpaces, to: "\tX", tabWidth: 0), " X")
        XCTAssertEqual(MergeWhitespace.applying(.trimRight, to: "X\u{a0}"), "X\u{a0}")
    }
    func testMixedEndingsBlankLinesBomAndMissingFinalNewline() {
        let text = "\u{feff} \tX\r\n \t\n\tY\u{2028}  \t"
        XCTAssertEqual(Data(MergeWhitespace.applying(.tabsToSpaces, to: text).utf8), Data("\u{feff} \tX\r\n    \n    Y\u{2028}    ".utf8))
        XCTAssertEqual(Data(MergeWhitespace.applying(.trimRight, to: text).utf8), Data("\u{feff} \tX\r\n\n\tY\u{2028}".utf8))
        XCTAssertEqual(MergeWhitespace.applying(.spacesToTabs, to: " \t \t X"), "\t\t X")
    }
}
