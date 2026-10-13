import XCTest
@testable import TurtleGitCore

final class MergeClipboardTests: XCTestCase {
    func testBlockCopyIncludesRemovedRowsAndConflictGapsSkipsEmptyAndHasNoSyntheticFinalBreak() throws {
        for ending in MergeLineEnding.allCases {
            let cells = [
                MergeSourceCell(text: "context" + ending.rawValue, lineNumber: 1, state: .normal),
                MergeSourceCell(text: "removed 🦎" + ending.rawValue, lineNumber: nil, state: .removed),
                MergeSourceCell(text: "", lineNumber: nil, state: .empty),
                MergeSourceCell(text: "", lineNumber: nil, state: .conflicted),
                MergeSourceCell(text: "added 雪" + ending.rawValue, lineNumber: 2, state: .added),
                MergeSourceCell(text: "tail", lineNumber: 3, state: .normal)]
            XCTAssertEqual(try MergeClipboard.sourceText(selection: NSRange(location: 8, length: 0), cells: cells, blockRows: 1..<5), "removed 🦎\n\nadded 雪")
            XCTAssertEqual(MergeClipboard.changedBlock(selection: NSRange(location: 8, length: 0), cells: cells), 1..<5)
            XCTAssertNil(MergeClipboard.changedBlock(selection: NSRange(location: 0, length: 0), cells: cells))
            XCTAssertEqual(try MergeClipboard.sourceText(selection: NSRange(location: 0, length: 3), cells: cells, blockRows: 1..<5), "con")
            XCTAssertEqual(try MergeClipboard.sourceText(selection: NSRange(location: 0, length: 0), cells: cells), "")
            XCTAssertThrowsError(try MergeClipboard.sourceText(selection: NSRange(location: 0, length: 0), cells: cells, blockRows: 0..<7))
        }
    }
    func testDocumentSelectionBlockFallbackAndPasteEndingPolicy() throws {
        for ending in MergeLineEnding.allCases {
            let text = "head" + ending.rawValue + "雪 🦎" + ending.rawValue
            let source = text as NSString, start = (("head" + ending.rawValue) as NSString).length
            XCTAssertEqual(try MergeClipboard.documentText(selection: NSRange(location: 0, length: 0), document: text, block: NSRange(location: start, length: source.length-start)), "雪 🦎")
            XCTAssertEqual(try MergeClipboard.documentText(selection: NSRange(location: 0, length: source.length), document: text), "head\n雪 🦎\n")
            XCTAssertEqual(MergeClipboard.pastedText("new\r\ntext\n", document: text), "new" + ending.rawValue + "text" + ending.rawValue)
        }
        XCTAssertThrowsError(try MergeClipboard.documentText(selection: NSRange(location: 100, length: 0), document: "short"))
        XCTAssertEqual(try MergeClipboard.sourceText(selection: NSRange(location: 0, length: 0), cells: [.init(text: "", lineNumber: nil, state: .empty)], blockRows: 0..<1), "")
    }
}
