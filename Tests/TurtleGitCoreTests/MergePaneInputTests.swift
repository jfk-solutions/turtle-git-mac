import XCTest
@testable import TurtleGitCore

final class MergePaneInputTests:XCTestCase {
    private func cell(_ text:String,_ state:MergeSourceState = .normal)->MergeSourceCell {
        .init(text:text,lineNumber:state.isViewEmpty ? nil : 1,state:state)
    }
    private var gap:MergeSourceCell { cell("",.empty) }
    private func display(_ cells:[MergeSourceCell])->String { cells.map { $0.displayText + "\n" }.joined() }
    private func deletion(_ cells:[MergeSourceCell],_ location:Int,_ backward:Bool)throws->NSRange {
        try XCTUnwrap(MergePaneInput.deletionRange(in:display(cells),cells:cells,selection:NSRange(location:location,length:0),backward:backward))
    }
    func testBothDeleteDirectionsJoinRealLinesAcrossConsecutiveAlignmentGaps()throws {
        let cells = [cell("A\r\n"),gap,cell("",.conflictEmpty),cell("B\r\n")]
        let backward = try deletion(cells,4,true), forward = try deletion(cells,1,false)
        XCTAssertEqual(backward,NSRange(location:1,length:3)); XCTAssertEqual(forward,backward)
        let peers = ["left A\n","left middle\n","left other\n","left B\n"].map { cell($0) }
        let alignment = FileComparisonAlignment(rows:cells.indices.map { .init(base:peers[$0],destination:cells[$0]) },differences:[])
        let edit = try FileComparisonInPlaceEdit(alignment:alignment,base:false,range:backward,replacement:"")
        XCTAssertEqual(edit.text,"AB\r\n"); XCTAssertEqual(edit.displayCaret,1)
        XCTAssertEqual(edit.alignment.rows.map { $0.base.text },peers.map(\.text))
        XCTAssertEqual(edit.alignment.rows.count,4)
        XCTAssertEqual(edit.alignment.rows.first?.destination.state,.edited)
        XCTAssertEqual(alignment.rows.map { $0.destination.text },cells.map(\.text),"Original snapshot remains usable for Undo")
    }
    func testLeadingTrailingAndAllGapBoundariesDoNotDeleteUnrelatedCharacters()throws {
        let cells = [gap,gap,cell("B"),gap,gap]
        XCTAssertNil(MergePaneInput.deletionRange(in:display(cells),cells:cells,selection:.init(location:2,length:0),backward:true))
        XCTAssertNil(MergePaneInput.deletionRange(in:display(cells),cells:cells,selection:.init(location:5,length:0),backward:false))
        XCTAssertEqual(try deletion(cells,2,false),NSRange(location:2,length:1))
        XCTAssertNil(MergePaneInput.deletionRange(in:display([gap,gap]),cells:[gap,gap],selection:.init(location:1,length:0),backward:true))
        XCTAssertNil(MergePaneInput.deletionRange(in:display([gap,gap]),cells:[gap,gap],selection:.init(location:0,length:0),backward:false))
        XCTAssertNil(MergePaneInput.deletionRange(in:"last\n",cells:[cell("last")],selection:.init(location:4,length:0),backward:false))
        XCTAssertNil(MergePaneInput.deletionRange(in:"last",cells:[cell("last")],selection:.init(location:4,length:0),backward:false))
    }
    func testRealBlankEditedResolvedEmptyAndRemovedRowsRemainViewRecords()throws {
        for state:MergeSourceState in [.normal,.edited,.resolvedEmpty,.removed,.removedWhitespace] {
            let cells = [cell("A\n"),cell("\n",state),cell("B")]
            XCTAssertEqual(try deletion(cells,1,false),NSRange(location:1,length:1),"\(state) is not an alignment gap")
            XCTAssertEqual(try deletion(cells,3,true),NSRange(location:2,length:1))
        }
        let cells = [cell("A\n"),cell("\n"),cell("B")]
        let alignment = FileComparisonAlignment(rows:cells.map { .init(base:$0,destination:$0) },differences:[])
        let edit = try FileComparisonInPlaceEdit(alignment:alignment,base:false,range:deletion(cells,1,false),replacement:"")
        XCTAssertEqual(edit.text,"A\nB","Only the first newline is removed; the real blank row is the join endpoint")
    }
    func testGraphemeDeletionAndCRLFSourceEndingsRemainAtomic()throws {
        let value = "e\u{301}👩🏽‍💻🇩🇪", cells = [cell(value + "\r\n"),cell("tail")]
        let first = "e\u{301}".utf16.count, second = "👩🏽‍💻".utf16.count
        XCTAssertEqual(try deletion(cells,0,false),NSRange(location:0,length:first))
        XCTAssertEqual(try deletion(cells,first + second,true),NSRange(location:first,length:second))
        let alignment = FileComparisonAlignment(rows:cells.map { .init(base:$0,destination:$0) },differences:[])
        let edit = try FileComparisonInPlaceEdit(alignment:alignment,base:false,range:deletion(cells,first,false),replacement:"")
        XCTAssertEqual(edit.text,"e\u{301}🇩🇪\r\ntail")
        XCTAssertEqual(try deletion(cells,value.utf16.count + 1,true),NSRange(location:value.utf16.count,length:1),"One display newline represents the complete source CRLF")
    }
    func testSelectedReplacementEndpointsAdvanceOffOnlyAlignmentGaps()throws {
        let cells = [cell("A\n"),gap,gap,cell("B\n"),cell("C")]
        XCTAssertEqual(MergePaneInput.normalizedReplacementRange(in:display(cells),cells:cells,selection:.init(location:1,length:1)),NSRange(location:1,length:3))
        XCTAssertEqual(MergePaneInput.normalizedReplacementRange(in:display(cells),cells:cells,selection:.init(location:2,length:3)),NSRange(location:4,length:1))
        XCTAssertEqual(MergePaneInput.normalizedReplacementRange(in:display(cells),cells:cells,selection:.init(location:2,length:0)),NSRange(location:2,length:0),"Collapsed typing intentionally targets the selected record")
        let alignment = FileComparisonAlignment(rows:cells.map { .init(base:cell("peer\n"),destination:$0) },differences:[])
        let replacement = try FileComparisonInPlaceEdit(alignment:alignment,base:false,range:.init(location:2,length:3),replacement:"X")
        XCTAssertEqual(replacement.text,"A\nX\nC")
        let noOp = try FileComparisonInPlaceEdit(alignment:alignment,base:false,range:.init(location:2,length:1),replacement:"")
        XCTAssertEqual(noOp.text,"A\nB\nC"); XCTAssertEqual(noOp.alignment.rows.map { $0.destination.state },cells.map(\.state))
        XCTAssertTrue(noOp.replacedRows.isEmpty); XCTAssertEqual(noOp.displayCaret,4)
    }
    func testAlignedMergeJoinPreservesBothSourcePanesAndNavigationCoordinates()throws {
        let mine = [cell("A\r\n"),cell("removed\r\n",.identicalRemoved),cell("B\r\n")]
        let theirs = [cell("A\r\n"),cell("removed\r\n",.identicalRemoved),cell("B\r\n")]
        let map = MergeNavigationMap(entries:[.init(sourceRows:0..<1,resultRange:.init(location:0,length:3)),.init(sourceRows:1..<2,resultRange:.init(location:3,length:0)),.init(sourceRows:2..<3,resultRange:.init(location:3,length:3))])
        let comparison = MergeSourceComparison(rows:mine.indices.map { .init(mine:mine[$0],theirs:theirs[$0]) },navigationMap:map,alignedResultRows:[cell("A\r\n"),gap,cell("B\r\n")])
        let initial = MergeResultPresentation(text:"A\r\nB\r\n",states:[.normal,.normal],navigationMap:map)
        let projection = try XCTUnwrap(MergeAlignedResultProjection(comparison:comparison,presentation:initial))
        XCTAssertTrue(projection.cells[1].state.isViewEmpty)
        let range = try deletion(projection.cells,projection.displayRanges[2].location,true)
        let edit = try MergeAlignedResultEdit(comparison:comparison,presentation:initial,range:range,replacement:"")
        XCTAssertEqual(edit.presentation.text,"AB\r\n"); XCTAssertEqual(edit.displayCaret,1)
        XCTAssertEqual(edit.comparison.rows.map { $0.mine.text },mine.map(\.text))
        XCTAssertEqual(edit.comparison.rows.map { $0.theirs.text },theirs.map(\.text))
        XCTAssertNotNil(edit.presentation.navigationMap.exactResultRange(sourceRows:0..<3))
        XCTAssertEqual(initial.text,"A\r\nB\r\n")
    }
    func testInvalidRangesAndMismatchedPaneGeometryAreRefused() {
        let cells = [cell("A")]
        for range in [NSRange(location:NSNotFound,length:0),NSRange(location:0,length:Int.max),NSRange(location:4,length:0)] {
            XCTAssertNil(MergePaneInput.deletionRange(in:display(cells),cells:cells,selection:range,backward:true))
            XCTAssertNil(MergePaneInput.normalizedReplacementRange(in:display(cells),cells:cells,selection:range))
        }
        XCTAssertNil(MergePaneInput.deletionRange(in:"other\n",cells:cells,selection:.init(location:1,length:0),backward:true))
    }
}
