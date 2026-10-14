import XCTest
@testable import TurtleGitCore

final class MergePaneSaveAsTests: XCTestCase {
    func testLeftRetainsRemovedRowsAndRightOmitsThem() {
        let removed = MergeSourceCell(text: "old\r\n", lineNumber: nil, state: .removed)
        let gap = MergeSourceCell(text: "", lineNumber: nil, state: .empty)
        let rows = [MergeSourceRow(mine: removed, theirs: removed), MergeSourceRow(mine: .init(text: "mine\r\n", lineNumber: 1, state: .added), theirs: gap)]
        XCTAssertEqual(MergePaneSaveAs.sourceText(rows: rows, mine: false, keepRemoved: true), "old\r\n")
        XCTAssertEqual(MergePaneSaveAs.sourceText(rows: rows, mine: true, keepRemoved: false), "mine\r\n")
    }
    func testPinnedConflictMarkerSerializationAndSelectedPaneGroups() {
        let rows = [MergeSourceRow(mine: .init(text: "mine\n", lineNumber: 1, state: .conflicted), theirs: .init(text: "theirs\r\n", lineNumber: 1, state: .conflicted))]
        XCTAssertEqual(MergePaneSaveAs.sourceText(rows: rows, mine: true, keepRemoved: false), "<<<<<<< .minemine\n=======theirs\r\n>>>>>>> .theirs")
    }
    func testOriginalUnicodeEndingsAndEncoding() throws {
        for ending in ["\r\n", "\n", "\r", "\n\r", "\u{b}", "\u{c}", "\u{85}", "\u{2028}", "\u{2029}"] {
            let text = "🐢 snow 雪" + ending + "last"
            let cell = MergeSourceCell(text: text, lineNumber: 1, state: .normal)
            let rows = [MergeSourceRow(mine: cell, theirs: cell)]
            XCTAssertEqual(try MergePaneSaveAs.sourceBytes(rows: rows, mine: true, encoding: .utf16LEBOM), try ComparisonTextEncoding.utf16LEBOM.encode(text))
        }
        XCTAssertEqual(MergePaneSaveAs.sourceText(rows: [], mine: false, keepRemoved: true), "")
    }
}
