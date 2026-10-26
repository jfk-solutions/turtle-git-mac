// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class PatchLineIndexTests: XCTestCase {
    func testUTF16MixedTerminatorsPreserveEmojiAndFinalEmptyLine() {
        let text = "😀a\r\nb\rc\n"
        let original = Data(text.utf8), index = PatchLineIndex(text: text)
        XCTAssertEqual(index.utf16Length, 9)
        XCTAssertEqual(index.lineStarts, [0, 5, 7, 9])
        XCTAssertEqual(index.lineRanges, [NSRange(location: 0, length: 5), NSRange(location: 5, length: 2), NSRange(location: 7, length: 2), NSRange(location: 9, length: 0)])
        let source = text as NSString
        XCTAssertEqual(index.lineRanges.map { source.substring(with: $0) }.joined(), text)
        XCTAssertEqual(Data(text.utf8), original)
        XCTAssertEqual(index.lineIndex(atUTF16Offset: 1), 0)
        XCTAssertEqual(index.lineIndex(atUTF16Offset: 3), 0)
        XCTAssertEqual(index.lineIndex(atUTF16Offset: 4), 0)
        XCTAssertEqual(index.lineIndex(atUTF16Offset: 5), 1)
        XCTAssertEqual(index.lineIndex(atUTF16Offset: 9), 3)
    }
    func testEmptyUnterminatedAndLFCRUseScintillaBoundaries() {
        XCTAssertEqual(PatchLineIndex(text: "").lineRanges, [NSRange(location: 0, length: 0)])
        XCTAssertEqual(PatchLineIndex(text: "one").lineRanges, [NSRange(location: 0, length: 3)])
        XCTAssertEqual(PatchLineIndex(text: "\r\n").lineStarts, [0, 2])
        XCTAssertEqual(PatchLineIndex(text: "\n\r").lineStarts, [0, 1, 2])
        XCTAssertEqual(PatchLineIndex(text: "\r\r\n").lineStarts, [0, 1, 3])
        XCTAssertEqual(PatchLineIndex(text: "\n\n").lineStarts, [0, 1, 2])
        let unicodeSeparators = "A\u{2028}B\u{0085}C\u{000b}D\u{000c}E"
        XCTAssertEqual(PatchLineIndex(text: unicodeSeparators).lineRanges, [NSRange(location: 0, length: 9)])
        let complex = PatchLineIndex(text: "e\u{301}\r\n👩‍💻")
        XCTAssertEqual(complex.lineStarts, [0, 4])
        XCTAssertEqual(complex.lineRanges, [NSRange(location: 0, length: 4), NSRange(location: 4, length: 5)])
    }
    func testDigitWidthThresholdsWithoutDocumentAllocation() {
        for (count, columns) in [(1, 3), (9, 3), (10, 4), (99, 4), (100, 5), (999, 5), (1000, 6)] {
            XCTAssertEqual(PatchLineIndex.marginColumns(forLineCount: count), columns)
        }
        XCTAssertEqual(PatchLineIndex(text: "").marginColumns, 3)
        XCTAssertEqual(PatchLineIndex(text: String(repeating: "\n", count: 9)).marginColumns, 4)
        XCTAssertEqual(PatchLineIndex.marginColumns(forLineCount: 0), 3)
        XCTAssertEqual(PatchLineIndex.marginColumns(forLineCount: Int.min), 3)
        XCTAssertEqual(PatchLineIndex.marginColumns(forLineCount: Int.max), String(Int.max).count + 2)
    }
    func testWholeLineSelectionIncludesEndingsAndPreservesDirection() throws {
        let index = PatchLineIndex(text: "A\nBB\nCCC")
        let down = try XCTUnwrap(index.selection(anchorLine: 1, currentLine: 2))
        XCTAssertEqual(down.anchorOffset, 2); XCTAssertEqual(down.caretOffset, 8)
        XCTAssertEqual(down.range, NSRange(location: 2, length: 6)); XCTAssertFalse(down.isReversed)
        let up = try XCTUnwrap(index.selection(anchorLine: 2, currentLine: 0))
        XCTAssertEqual(up.anchorOffset, 8); XCTAssertEqual(up.caretOffset, 0)
        XCTAssertEqual(up.range, NSRange(location: 0, length: 8)); XCTAssertTrue(up.isReversed)
        let same = try XCTUnwrap(index.selection(anchorLine: 1, currentLine: 1))
        XCTAssertEqual(same.range, NSRange(location: 2, length: 3))
        let emptyFinal = try XCTUnwrap(PatchLineIndex(text: "x\n").selection(anchorLine: 1, currentLine: 1))
        XCTAssertEqual(emptyFinal.range, NSRange(location: 2, length: 0))
        let empty = try XCTUnwrap(PatchLineIndex(text: "").selection(anchorLine: 0, currentLine: 0))
        XCTAssertEqual(empty.range, NSRange(location: 0, length: 0))
    }
    func testShiftExclusiveAnchorAndDragReversalKeepLogicalAnchor() throws {
        let index = PatchLineIndex(text: "A\nBB\nCCC")
        XCTAssertEqual(index.anchorLine(selectionAnchor: 5, selectionCaret: 2), 1)
        XCTAssertEqual(index.anchorLine(selectionAnchor: 2, selectionCaret: 8), 1)
        XCTAssertEqual(index.anchorLine(selectionAnchor: 5, selectionCaret: 5), 2)
        XCTAssertEqual(index.anchorLine(selectionAnchor: 0, selectionCaret: 0), 0)
        let anchor = try XCTUnwrap(index.anchorLine(selectionAnchor: 5, selectionCaret: 0))
        XCTAssertEqual(anchor, 1)
        XCTAssertEqual(index.selection(anchorLine: anchor, currentLine: 2)?.range, NSRange(location: 2, length: 6))
        let reversed = try XCTUnwrap(index.selection(anchorLine: anchor, currentLine: 0))
        XCTAssertEqual(reversed.anchorOffset, 5); XCTAssertEqual(reversed.caretOffset, 0)
        XCTAssertEqual(index.selection(anchorLine: anchor, currentLine: 1)?.range, NSRange(location: 2, length: 3))
        XCTAssertEqual(index.selection(anchorLine: anchor, currentLine: 2)?.anchorOffset, 2)
    }
    func testInvalidOffsetsAndLinesCannotProduceOutOfBoundsSelection() {
        let index = PatchLineIndex(text: "a\nb")
        XCTAssertNil(index.lineIndex(atUTF16Offset: -1))
        XCTAssertNil(index.lineIndex(atUTF16Offset: 4))
        XCTAssertNil(index.lineIndex(atUTF16Offset: Int.max))
        XCTAssertNil(index.range(forLine: -1)); XCTAssertNil(index.range(forLine: 2))
        XCTAssertNil(index.selection(anchorLine: -1, currentLine: 0))
        XCTAssertNil(index.selection(anchorLine: 0, currentLine: 2))
        XCTAssertNil(index.anchorLine(selectionAnchor: 4, selectionCaret: 0))
        XCTAssertNil(index.anchorLine(selectionAnchor: 0, selectionCaret: -1))
        for offset in 0...index.utf16Length { XCTAssertNotNil(index.lineIndex(atUTF16Offset: offset)) }
    }
}
