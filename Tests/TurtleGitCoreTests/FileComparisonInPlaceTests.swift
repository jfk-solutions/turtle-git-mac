import XCTest
@testable import TurtleGitCore

final class FileComparisonInPlaceTests: XCTestCase {
    func testInsertThenDeleteRemovesOnlyAllEmptyAlignmentRecords() throws {
        let original = FileComparisonAlignment(base:"head\nkeep\ntail\n",destination:"head\nkeep\ntail\n")
        let inserted = try FileComparisonInPlaceEdit(alignment:original,base:false,range:NSRange(location:5,length:0),replacement:"one\ntwo\n")
        XCTAssertEqual(inserted.alignment.rows.count,5)
        let deleted = try FileComparisonInPlaceEdit(alignment:inserted.alignment,base:false,range:NSRange(location:5,length:8),replacement:"")
        XCTAssertEqual(deleted.text,"head\nkeep\ntail\n")
        XCTAssertEqual(deleted.alignment.rows.count,3)
        XCTAssertEqual(deleted.removedEmptyRows,[2,3])
        XCTAssertEqual(deleted.insertedRows,1..<2)
        XCTAssertEqual(deleted.displayCaret,5)
        XCTAssertEqual(deleted.alignment.rows.map { $0.base.text }.joined(),"head\nkeep\ntail\n")
    }
    func testBlankEditedRecordIsNeverTreatedAsAnAlignmentGap() throws {
        let original = FileComparisonAlignment(base:"line\n",destination:"line\n")
        let edit = try FileComparisonInPlaceEdit(alignment:original,base:false,range:NSRange(location:0,length:4),replacement:"")
        XCTAssertEqual(edit.text,"\n")
        XCTAssertEqual(edit.alignment.rows.count,1)
        XCTAssertEqual(edit.alignment.rows[0].destination.state,.edited)
        XCTAssertTrue(edit.removedEmptyRows.isEmpty)
    }
    func testSameByteHistoryHasDistinctSavepointAndBranchIdentities() throws {
        let content = ComparisonFileContent(path:"file",revision:.workingTree,bytes:Data("same\n".utf8),mode:"100644",permissions:0o644)
        var drafts = FileComparisonDrafts(.init(base:content,destination:content))
        let first = UUID(), second = UUID(), branch = UUID()
        drafts.setEditRevision(first,base:false); drafts.update(annotations:.init(edited:[0]),base:false)
        XCTAssertTrue(drafts.isDirty(base:false))
        try drafts.didSave(content,base:false); XCTAssertFalse(drafts.isDirty(base:false))
        drafts.setEditRevision(second,base:false); XCTAssertTrue(drafts.isDirty(base:false))
        drafts.setEditRevision(first,base:false); XCTAssertFalse(drafts.isDirty(base:false))
        drafts.setEditRevision(branch,base:false); XCTAssertTrue(drafts.isDirty(base:false))
        try drafts.didSave(content,base:false); drafts.setEditRevision(first,base:false)
        XCTAssertTrue(drafts.isDirty(base:false))
        drafts.setEditRevision(branch,base:false); XCTAssertFalse(drafts.isDirty(base:false))
        XCTAssertEqual(try drafts.exported(base:false),content.bytes)
        XCTAssertNil(drafts.editRevision(base:true)); XCTAssertFalse(drafts.isDirty(base:true))
    }
    func testReboundSavepointRecordsHistoryWithoutSerializingIt() throws {
        let original = ComparisonFileContent(path:"old",revision:.workingTree,bytes:Data("same\n".utf8),mode:"100644",permissions:0o644)
        let rebound = ComparisonFileContent(path:"new",revision:.workingTree,bytes:original.bytes,mode:"100644",permissions:0o644)
        var drafts = FileComparisonDrafts(.init(base:original,destination:original))
        let revision = UUID(); drafts.setEditRevision(revision,base:false)
        drafts.rebindSavedPane(rebound,base:false); XCTAssertFalse(drafts.isDirty(base:false))
        drafts.setEditRevision(nil,base:false); XCTAssertTrue(drafts.isDirty(base:false))
        drafts.setEditRevision(revision,base:false); XCTAssertFalse(drafts.isDirty(base:false))
        XCTAssertEqual(try drafts.exported(base:false),original.bytes)
    }
    func testTypingRetainsPeerAndRowsInsteadOfDiffRegrouping() throws {
        let original = FileComparisonAlignment(base:"old\nkeep\n",destination:"new\nkeep\n")
        let edit = try FileComparisonInPlaceEdit(alignment:original,base:false,range:NSRange(location:1,length:1),replacement:"🐢")
        XCTAssertEqual(edit.text,"n🐢w\nkeep\n")
        XCTAssertEqual(edit.alignment.rows.count,original.rows.count)
        XCTAssertEqual(edit.alignment.rows.map { $0.base.text },original.rows.map { $0.base.text })
        XCTAssertEqual(edit.alignment.rows[0].destination.state,.edited)
        XCTAssertEqual(edit.alignment.rows[1].destination.state,.normal)
        XCTAssertEqual(edit.caret,3); XCTAssertEqual(edit.displayCaret,3)
    }
    func testInsertedLinesPadOppositePaneWithoutChangingItsBytes() throws {
        let original = FileComparisonAlignment(base:"head\r\ntail",destination:"head\r\ntail")
        let edit = try FileComparisonInPlaceEdit(alignment:original,base:false,range:NSRange(location:2,length:0),replacement:"x\ny\n")
        XCTAssertEqual(edit.text,"hex\r\ny\r\nad\r\ntail")
        XCTAssertEqual(edit.alignment.rows.map { $0.base.text }.joined(),"head\r\ntail")
        XCTAssertEqual(edit.alignment.rows.filter { $0.base.state == .empty }.count,2)
        XCTAssertEqual(edit.alignment.rows.filter { $0.destination.state == .edited }.count,3)
        XCTAssertEqual(edit.caret,8); XCTAssertEqual(edit.displayCaret,6)
    }
    func testDeletingAcrossRowsKeepsPeerRecordsAndDropsOnlySelectedText() throws {
        let original = FileComparisonAlignment(base:"first\nsecond\nthird\n",destination:"first\nsecond\nthird\n")
        let edit = try FileComparisonInPlaceEdit(alignment:original,base:false,range:NSRange(location:2,length:8),replacement:"")
        XCTAssertEqual(edit.text,"find\nthird\n")
        XCTAssertEqual(edit.alignment.rows.count,3)
        XCTAssertEqual(edit.alignment.rows[1].destination.state,.empty)
        XCTAssertEqual(edit.alignment.rows.map { $0.base.text }.joined(),"first\nsecond\nthird\n")
    }
    func testCombinedEditedRemovalStaysInPlaceAndUntouchedRemovalStaysRemoved() throws {
        let alignment = FileComparisonAlignment(base:"old1\nold2\ntail\n",destination:"new1\nnew2\ntail\n")
        let combined = OnePaneFileComparison(alignment:alignment)
        XCTAssertEqual(combined.cells.map(\.displayText),["old1","old2","new1","new2","tail"])
        let edit = try FileComparisonInPlaceEdit(alignment:alignment,combined:combined,base:false,range:NSRange(location:1,length:1),replacement:"X")
        let next = try XCTUnwrap(edit.combined)
        XCTAssertEqual(next.cells.map(\.displayText),["oXd1","old2","new1","new2","tail"])
        XCTAssertEqual(next.cells[0].state,.edited); XCTAssertEqual(next.cells[1].state,.removed)
        XCTAssertEqual(edit.text,"oXd1\nnew1\nnew2\ntail\n")
        XCTAssertEqual(next.sourceSaveText,edit.text)
        XCTAssertEqual(edit.displayCaret,2)
    }
    func testCombinedFinalRemovedLineIsSeparatedFromFollowingAddition() throws {
        let alignment = FileComparisonAlignment(base:"old",destination:"new")
        let edit = try FileComparisonInPlaceEdit(alignment:alignment,combined:OnePaneFileComparison(alignment:alignment),base:false,range:NSRange(location:0,length:1),replacement:"O")
        XCTAssertEqual(edit.text,"Old\nnew")
    }
    func testGapAtEOFBecomesARealLineWithPreviousEndingRepaired() throws {
        let original = FileComparisonAlignment(base:"last",destination:"last\nextra")
        let gap = try XCTUnwrap(original.rows.firstIndex { $0.base.lineNumber == nil })
        let offset = original.rows.prefix(gap).reduce(0) { $0 + $1.base.displayText.utf16.count + 1 }
        let edit = try FileComparisonInPlaceEdit(alignment:original,base:true,range:NSRange(location:offset,length:0),replacement:"typed")
        XCTAssertEqual(edit.text,"last\ntyped")
        XCTAssertEqual(edit.alignment.rows[gap].base.state,.edited)
    }
    func testReturnAtUnendedEOFHasEditableBlankRowWithoutExtraSavedEnding() throws {
        let edit = try FileComparisonInPlaceEdit(alignment:.init(base:"last",destination:"last"),base:false,range:NSRange(location:4,length:0),replacement:"\n")
        XCTAssertEqual(edit.text,"last\n")
        XCTAssertEqual(edit.alignment.rows.map { $0.destination.displayText },["last",""])
        XCTAssertEqual(edit.displayCaret,5)
    }
    func testEmptyBufferAndInvalidRanges() throws {
        let empty = FileComparisonAlignment(base:"",destination:"")
        XCTAssertEqual(try FileComparisonInPlaceEdit(alignment:empty,base:false,range:NSRange(location:0,length:0),replacement:"hello").text,"hello")
        XCTAssertThrowsError(try FileComparisonInPlaceEdit(alignment:empty,base:false,range:NSRange(location:2,length:0),replacement:"x"))
    }
}
