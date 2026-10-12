import XCTest
@testable import TurtleGitCore

final class MergeWhitespaceTests: XCTestCase {
    func testTabInsertionUsesExpandedUtf16ColumnAndExplicitMode() {
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "ab", utf16Offset: 2), "\t")
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "ab", utf16Offset: 2, useSpaces: true), "  ")
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "\t🦎e\u{301}", utf16Offset: 5, useSpaces: true), "    ")
        for ending in MergeLineEnding.allCases {
            let text = "first" + ending.rawValue + "ab"
            XCTAssertEqual(MergeWhitespace.tabInsertion(in: text, utf16Offset: (text as NSString).length, useSpaces: true), "  ")
        }
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "", utf16Offset: -1, tabWidth: 8, useSpaces: true), "        ")
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "x\r\n", utf16Offset: 100, useSpaces: true), "    ")
    }
    func testSmartTabMatchesCurrentLineAndPairedNearbyEvidence() {
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "     x\t", utf16Offset: 0, useSpaces: true, smart: true), "\t")
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "     x", utf16Offset: 0, smart: true), "    ")
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "    x", utf16Offset: 0, useSpaces: true, smart: true), "\t")
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "     above\ncurrent\n     below", utf16Offset: 11, smart: true), "    ")
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "     above\ncurrent", utf16Offset: 11, useSpaces: true, smart: true), "\t")
        XCTAssertEqual(MergeWhitespace.tabInsertion(in: "\tabove\ncurrent\n     below", utf16Offset: 7, useSpaces: true, smart: true), "\t")
        for distance in [100, 101] {
            let before = "     above\n" + String(repeating: "x\n", count: distance - 1)
            let text = before + "current\n" + String(repeating: "x\n", count: distance - 1) + "     below"
            XCTAssertEqual(MergeWhitespace.tabInsertion(in: text, utf16Offset: (before as NSString).length, smart: true), distance == 100 ? "    " : "\t")
        }
    }
    func testSelectedLineIndentAndUnindentPreserveEndingsAndExcludeEndBoundary() throws {
        for ending in MergeLineEnding.allCases {
            let eol = ending.rawValue, text = "🦎one" + eol + "  " + eol + "two" + eol + "last"
            let end = ("🦎one" + eol + "  " + eol + "two" + eol as NSString).length
            let selection = NSRange(location: 2, length: end - 2)
            let edit = try XCTUnwrap(MergeWhitespace.indentSelection(in: text, selection: selection, useSpaces: true))
            XCTAssertEqual(edit.range, NSRange(location: 0, length: end))
            XCTAssertEqual(Data(edit.replacement.utf8), Data(("    🦎one" + eol + "  " + eol + "    two" + eol).utf8))
            let tabbed = " \t🦎one" + eol + "    two" + eol + "last"
            let removal = try XCTUnwrap(MergeWhitespace.indentSelection(in: tabbed, selection: NSRange(location: 0, length: (" \t🦎one" + eol + "    two" + eol as NSString).length), remove: true))
            XCTAssertEqual(Data(removal.replacement.utf8), Data(("🦎one" + eol + "two" + eol).utf8))
        }
        XCTAssertNil(MergeWhitespace.indentSelection(in: "abc", selection: NSRange(location: 0, length: 2)))
        XCTAssertNil(MergeWhitespace.indentSelection(in: "abc", selection: NSRange(location: 0, length: 20)))
        XCTAssertNil(MergeWhitespace.indentSelection(in: "abc", selection: NSRange(location: NSNotFound, length: 1)))
    }
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

final class MergeWhitespaceDisplayTests: XCTestCase {
    func testOriginalEndingsAndSyntheticGapsUseDisplayOffsets() {
        let cells: [MergeSourceCell] = [.init(text: "雪🦎 \t\r\n", lineNumber: 1, state: .normal), .init(text: "", lineNumber: nil, state: .empty), .init(text: "last", lineNumber: 2, state: .normal)]
        let other: [MergeSourceCell] = [.init(text: "other\n", lineNumber: 1, state: .normal), .init(text: "", lineNumber: nil, state: .empty), .init(text: "last", lineNumber: 2, state: .normal)]
        let display = cells.map(\.displayText).joined(separator: "\n") + "\n"
        let markers = MergeWhitespaceDisplay.markers(text: display, cells: cells, otherCells: other)
        XCTAssertEqual(markers.map(\.offset), [3, 4, 5])
        XCTAssertEqual(markers.map(\.kind), [.space, .tab, .ending(.crlf, changed: true)])
        XCTAssertEqual(cells.map(\.text), ["雪🦎 \t\r\n", "", "last"])
    }
    func testAllNineEndingsAndMissingEndingAreRetainedWithoutTextMutation() {
        for ending in MergeLineEnding.allCases {
            let text = "a\u{00a0} \t" + ending.rawValue + "tail"
            let markers = MergeWhitespaceDisplay.markers(text: text)
            XCTAssertEqual(markers.map(\.offset), [2, 3, 4])
            XCTAssertEqual(markers.map(\.kind), [.space, .tab, .ending(ending, changed: false)])
            XCTAssertEqual(MergeWhitespaceDisplay.markers(text: "unended"), [])
        }
        XCTAssertEqual(MergeWhitespaceDisplay.markers(text: "e\u{301} 🦎\t").map(\.offset), [2, 5])
    }
    func testWhitespaceSourceDefaultsAndIsolatedPersistence() {
        let suite = "TurtleGit.Whitespace." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MergeWhitespaceDisplayPreferences.load(from: defaults), .init(visible: true, endingIcons: false))
        let icons = MergeWhitespaceDisplayPreferences(visible: false, endingIcons: true)
        icons.save(to: defaults); XCTAssertEqual(MergeWhitespaceDisplayPreferences.load(from: defaults), icons)
    }
}

final class MergeGeneralPreferencesTests: XCTestCase {
    func testSourceDefaultsClampingAndPrivatePersistence() {
        let suite = "TurtleGit.MergeGeneral." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MergeGeneralPreferences.load(from: defaults), .init(fontName: "Consolas", fontSize: 10, maximumInlineLength: 3000, firstDifference: true, firstConflict: true))
        let value = MergeGeneralPreferences(fontName: "Menlo", fontSize: 16, maximumInlineLength: 10, firstDifference: false, firstConflict: false)
        value.save(to: defaults); XCTAssertEqual(MergeGeneralPreferences.load(from: defaults), value)
        XCTAssertEqual(MergeGeneralPreferences(fontSize: -2, maximumInlineLength: -3).fontSize, 6)
        XCTAssertEqual(MergeGeneralPreferences(fontSize: 500, maximumInlineLength: 200000).maximumInlineLength, 100000)
        XCTAssertFalse(value.inlineAllowed(baseLength: 11, mineLength: 1)); XCTAssertTrue(value.inlineAllowed(baseLength: 10, mineLength: 10))
    }
    func testConflictPriorityPreservesIndependentSourceFlags() {
        let difference = NSRange(location: 5, length: 2), conflict = NSRange(location: 90, length: 20)
        XCTAssertEqual(MergeGeneralPreferences().initialTarget(difference: difference, conflict: conflict), conflict)
        XCTAssertEqual(MergeGeneralPreferences(firstDifference: false).initialTarget(difference: difference, conflict: conflict), conflict)
        XCTAssertEqual(MergeGeneralPreferences(firstConflict: false).initialTarget(difference: difference, conflict: conflict), difference)
        XCTAssertNil(MergeGeneralPreferences(firstDifference: false, firstConflict: false).initialTarget(difference: difference, conflict: conflict))
    }
}
