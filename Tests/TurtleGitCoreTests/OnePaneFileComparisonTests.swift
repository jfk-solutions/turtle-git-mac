import XCTest
@testable import TurtleGitCore

final class OnePaneFileComparisonTests: XCTestCase {
    func testRemovedRegionPrecedesAllAdditionsAndReconstructsMine() {
        let old = "same\r\nold one\r\nold two\r\nlast", new = "same\r\nnew one\r\nnew two\r\nlast"
        let alignment = FileComparisonAlignment(base: old, destination: new), projection = OnePaneFileComparison(alignment: alignment)
        XCTAssertEqual(projection.cells.map(\.displayText), ["same", "old one", "old two", "new one", "new two", "last"])
        XCTAssertEqual(projection.rows.filter { !$0.base }.map { $0.cell.text }.joined(), new)
        XCTAssertEqual(projection.differences, [1..<5]); XCTAssertEqual(projection.rows.map(\.alignmentRow), [0,1,2,1,2,3])
    }
    func testEditRemovedPayloadIncludesEditedLineButLeavesOtherRemovalsOut() throws {
        let projection = OnePaneFileComparison(alignment: FileComparisonAlignment(base: "same\r\nold 🦎 words\r\nremove me\r\nlast", destination: "same\r\nnew words\r\nlast"))
        let display = projection.cells.map(\.displayText).joined(separator: "\n") + "\n"
        let edit = try projection.applying("changed", ranges: [(display as NSString).range(of: "old")])
        XCTAssertEqual(edit.text, "same\r\nchanged 🦎 words\r\nnew words\r\nlast")
        XCTAssertFalse(edit.text.contains("remove me"))
        let copy = try MergeSourceComparison.clipboardText(NSRange(location: 5, length: "old 🦎 words".utf16.count), cells: projection.cells)
        XCTAssertEqual(copy, "old 🦎 words")
    }
    func testReplaceMultipleMatchesRetainsOriginalCRLFAndNoFinalTerminator() throws {
        let projection = OnePaneFileComparison(alignment: FileComparisonAlignment(base: "needle old\r\nlast", destination: "needle new\r\nlast"))
        let matches = MergeFind.matches("needle", in: MergeFindLine.displayCells(projection.cells), options: .init())
        XCTAssertEqual(matches.count, 2)
        let edit = try projection.applying("雪", ranges: matches)
        XCTAssertEqual(edit.text, "雪 old\r\n雪 new\r\nlast")
        XCTAssertFalse(MergeLineEndings.hasFinalEnding(edit.text))
        XCTAssertThrowsError(try projection.applying("x", ranges: [NSRange(location: Int.max, length: 1)]))
        XCTAssertThrowsError(try projection.applying("x", ranges: [NSRange(location: Int.max, length: 1), NSRange(location: 0, length: 1)]))
    }
    func testFilteredCasePairsAndWhitespaceCollapse() {
        let old = "same\nUPPER\nlast", new = "same\nlower\nlast"
        let alignment = FileComparisonAlignment(base: old, destination: new, baseKeys: ["same", "key", "last"], destinationKeys: ["same", "key", "last"])
        XCTAssertEqual(OnePaneFileComparison(alignment: alignment).cells.map(\.displayText), ["same", "UPPER", "lower", "last"])
        let spaces = FileComparisonAlignment(base: "a  b\n", destination: "a b\n", baseKeys: ["key"], destinationKeys: ["key"])
        XCTAssertEqual(OnePaneFileComparison(alignment: spaces, options: .init(whitespace: .ignoreChanges)).cells.map(\.displayText), ["a b"])
    }
}
