import XCTest
@testable import TurtleGitCore

final class MergeLineEndingsTests: XCTestCase {
    func testPredominantStylesTieOrderAndFinalEndingRecognition() {
        for style in MergeLineEnding.allCases {
            let text = "雪" + style.rawValue + "🦎" + style.rawValue + "EOF"
            XCTAssertEqual(MergeLineEndings.predominantStyle(in: text), style)
            XCTAssertFalse(MergeLineEndings.hasFinalEnding(text))
            XCTAssertTrue(MergeLineEndings.hasFinalEnding(text + style.rawValue))
        }
        XCTAssertEqual(MergeLineEndings.predominantStyle(in: "a\r\nb\nc\nd"), .lf)
        XCTAssertEqual(MergeLineEndings.predominantStyle(in: "a\nb\r\nc"), .crlf)
        XCTAssertEqual(MergeLineEndings.predominantStyle(in: "a\rb\n\rc"), .cr)
        XCTAssertEqual(MergeLineEndings.predominantStyle(in: ""), .lf)
        XCTAssertEqual(MergeLineEndings.predominantStyle(in: "EOF", fallback: .crlf), .crlf)
        XCTAssertFalse(MergeLineEndings.hasFinalEnding(""))
        XCTAssertFalse(MergeLineEndings.hasFinalEnding("\u{2028}EOF"))
    }
    func testCaretLineNumbersUseUtf16AndEveryEndingIncludingPairs() {
        for ending in MergeLineEnding.allCases {
            let prefix = "🦎" + ending.rawValue, text = prefix + "tail" + ending.rawValue
            let boundary = (prefix as NSString).length
            XCTAssertEqual(MergeLineEndings.lineNumber(in: text, utf16Offset: boundary - 1), 1)
            XCTAssertEqual(MergeLineEndings.lineNumber(in: text, utf16Offset: boundary), 2)
            XCTAssertEqual(MergeLineEndings.lineNumber(in: text, utf16Offset: 1), 1)
            XCTAssertEqual(MergeLineEndings.lineNumber(in: text, utf16Offset: -1), 1)
            XCTAssertEqual(MergeLineEndings.lineNumber(in: text, utf16Offset: 1000), 3)
        }
    }
    func testEveryEndingConvertsWithoutChangingUnicodeBomOrFinalNewlinePresence() {
        for original in MergeLineEnding.allCases {
            for target in MergeLineEnding.allCases {
                for trailing in [false, true] {
                    let first = "\u{feff}🦎 雪 e\u{301}", last = "last é"
                    let text = first + original.rawValue + last + (trailing ? original.rawValue : "")
                    let expected = first + target.rawValue + last + (trailing ? target.rawValue : "")
                    XCTAssertEqual(Data(MergeLineEndings.converting(text, to: target).utf8), Data(expected.utf8))
                    XCTAssertEqual(MergeLineEndings.styles(in: text), [original])
                }
            }
        }
        for ending in MergeLineEnding.allCases {
            XCTAssertEqual(MergeLineEndings.converting("", to: ending), "")
            XCTAssertEqual(MergeLineEndings.converting("e\u{301}", to: ending).utf8.count, 3)
        }
    }
    func testMixedStylesAndLfBeforeCrLfPreserveBlankLines() {
        let text = "a\r\nb\nc\rd\n\re\u{b}f\u{c}g\u{85}h\u{2028}i\u{2029}last"
        XCTAssertEqual(MergeLineEndings.styles(in: text), Set(MergeLineEnding.allCases))
        XCTAssertEqual(MergeLineEndings.converting(text, to: .lf), "a\nb\nc\nd\ne\nf\ng\nh\ni\nlast")
        XCTAssertEqual(MergeLineEndings.converting("a\n\r\nb", to: .lf), "a\n\nb")
        XCTAssertEqual(MergeLineEndings.styles(in: "a\n\r\nb"), [.lf, .crlf])
    }
    func testPrefixedConflictAndIncompleteMarkersAreDetectedForEveryEnding() throws {
        for ending in MergeLineEnding.allCases {
            let eol = ending.rawValue
            let prefix = "intro 🦎 雪" + eol
            let block = ["<<<<<<< Mine", "Mine e\u{301}", "||||||| Base", "Base", "=======", "Theirs", ">>>>>>> Theirs"].joined(separator: eol) + eol
            let text = prefix + block
            XCTAssertTrue(MergeText.hasMarkers(text), ending.rawValue.debugDescription)
            let conflict = try XCTUnwrap(MergeText.conflicts(in: text).first)
            XCTAssertEqual(conflict.range, NSRange(location: (prefix as NSString).length, length: (block as NSString).length))
            XCTAssertEqual(conflict.mine, "Mine e\u{301}" + eol)
            XCTAssertEqual(try MergeText.applying(.theirs, block: 0, to: text), prefix + "Theirs" + eol)
            XCTAssertEqual(Data(try MergeText.applying(.mineThenTheirs, block: 0, to: text).utf8), Data((prefix + "Mine e\u{301}" + eol + "Theirs" + eol).utf8))
            XCTAssertEqual(Data(try MergeText.applying(.theirsThenMine, block: 0, to: text).utf8), Data((prefix + "Theirs" + eol + "Mine e\u{301}" + eol).utf8))
            XCTAssertTrue(MergeText.hasMarkers(prefix + "<<<<<<< Mine" + eol + "unfinished"))
            XCTAssertTrue(MergeText.conflicts(in: prefix + "<<<<<<< Mine" + eol + "unfinished").isEmpty)
            XCTAssertFalse(MergeText.hasMarkers(prefix + "=======" + eol))
            for other in MergeLineEnding.allCases {
                let mixed = "<<<<<<< Mine\nMine" + eol + "=======\nTheirs" + other.rawValue + ">>>>>>> Theirs\n"
                XCTAssertEqual(Data(try MergeText.applying(.mineThenTheirs, block: 0, to: mixed).utf8), Data(("Mine" + eol + "Theirs" + other.rawValue).utf8))
                XCTAssertEqual(Data(try MergeText.applying(.theirsThenMine, block: 0, to: mixed).utf8), Data(("Theirs" + other.rawValue + "Mine" + eol).utf8))
            }
        }
    }
}
