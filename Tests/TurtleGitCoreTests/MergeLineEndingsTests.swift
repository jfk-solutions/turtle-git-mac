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

extension MergeLineEndingsTests {
    func testOverwriteKeepsComposedCharactersAndNeverConsumesEndings() {
        let text = "A🦎e\u{301}Z\r\nEOF"
        for (offset,length) in [(1,2),(3,2),(5,1)] {
            XCTAssertEqual(MergeTyping.overwriteRange(in:text,range:NSRange(location:offset,length:0),inserted:"雪"),NSRange(location:offset,length:length))
        }
        for offset in [2,4,6,7,text.utf16.count,999] {
            let range = NSRange(location:offset,length:0)
            XCTAssertEqual(MergeTyping.overwriteRange(in:text,range:range,inserted:"雪"),range)
        }
        for inserted in ["", "paste", "\t", "\n", "\r\n", "\u{2028}"] {
            XCTAssertEqual(MergeTyping.overwriteRange(in:text,range:NSRange(location:1,length:0),inserted:inserted),NSRange(location:1,length:0))
        }
        XCTAssertEqual(MergeTyping.overwriteRange(in:text,range:NSRange(location:1,length:4),inserted:"x"),NSRange(location:1,length:4))
        XCTAssertEqual(MergeTyping.overwriteRange(in:"👨‍👩‍👧‍👦x",range:NSRange(location:0,length:0),inserted:"e\u{301}"),NSRange(location:0,length:"👨‍👩‍👧‍👦".utf16.count))
    }
    func testSingleLineCycleAndDisplayRowsDoNotInventFinalEnding() {
        var line = "🦎e\u{301}\r\n"
        for expected in ["🦎e\u{301}\r","🦎e\u{301}\n","🦎e\u{301}\r\n"] {
            line = MergeTyping.cycledLine(line)!
            XCTAssertEqual(Data(line.utf8),Data(expected.utf8))
        }
        XCTAssertNil(MergeTyping.cycledLine("last"));XCTAssertNil(MergeTyping.cycledLine(""))
        for ending in MergeLineEnding.allCases where ![.crlf,.cr,.lf].contains(ending) {
            XCTAssertEqual(MergeTyping.cycledLine("x"+ending.rawValue),"x\r\n")
        }
        XCTAssertEqual(MergeTyping.displayRow(in:"🦎\nlast\n",offset:3),1)
        XCTAssertNil(MergeTyping.displayRow(in:"",offset:0))
        XCTAssertNil(MergeTyping.displayRow(in:"x\n",offset:99))
    }
}
