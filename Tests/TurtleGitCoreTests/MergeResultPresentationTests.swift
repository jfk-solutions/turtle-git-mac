import XCTest
@testable import TurtleGitCore
final class MergeResultPresentationTests: XCTestCase {
    func testDisjointEditsRetainUnchangedMiddleAndResolvedProvenance() throws {
        let text="first\nmiddle\nlast\n",original=MergeResultPresentation(text:text,states:[.normal,.filtered,.added])
        let first=try XCTUnwrap(original.replacing(NSRange(location:0,length:5),with:"changed",state:.resolved))
        let last=(first.text as NSString).range(of:"last"),second=try XCTUnwrap(first.replacing(last,with:"edited"))
        XCTAssertEqual(second.text,"changed\nmiddle\nedited\n");XCTAssertEqual(second.states(conflicts:[]),[.resolved,.filtered,.edited])
        XCTAssertEqual(first.states(conflicts:[]),[.resolved,.filtered,.added]);XCTAssertEqual(original.states(conflicts:[]),[.normal,.filtered,.added])
    }
    func testUnresolvedConflictOverridesEditedAndResolvedSpans() throws {
        let text="head\n<<<<<<< Mine\na\n=======\nb\n>>>>>>> Theirs\ntail\n",original=MergeResultPresentation(text:text,states:[])
        let value=try XCTUnwrap(original.replacing((text as NSString).range(of:"a\n"),with:"edit\n",state:.resolved))
        let conflicts=MergeText.conflicts(in:value.text).map(\.range),states=value.states(conflicts:conflicts)
        XCTAssertEqual(states.first,.normal);XCTAssertEqual(states.last,.normal);XCTAssertTrue(states.dropFirst().dropLast().allSatisfy{$0 == .conflicted})
        let block=try XCTUnwrap(conflicts.first),resolved=try XCTUnwrap(value.replacing(block,with:"picked\n",state:.resolved))
        XCTAssertEqual(resolved.states(conflicts:[]),[.normal,.resolved,.normal])
    }
    func testUTF16ReconciliationKeepsAuthoritativeEmojiAndCRLFBytes() {
        let original=MergeResultPresentation(text:"🐢 same\r\nplain\r\n",states:[.normal,.normal]),changed=original.reconciling("🐈 same\r\nplain\r\n")
        XCTAssertEqual(Array(changed.text.utf8),Array("🐈 same\r\nplain\r\n".utf8));XCTAssertEqual(changed.states(conflicts:[]),[.edited,.normal])
        let ending=changed.reconciling("🐈 same\nplain\r\n");XCTAssertEqual(ending.states(conflicts:[]),[.edited,.normal])
    }
    func testDeletingAndInsertingLinesUpdatesOnlyAffectedProvenance() throws {
        let original=MergeResultPresentation(text:"one\ntwo\nthree\n",states:[.normal,.resolved,.filtered])
        let deleted=try XCTUnwrap(original.replacing(NSRange(location:0,length:4),with:""));XCTAssertEqual(deleted.states(conflicts:[]),[.edited,.filtered])
        let inserted=try XCTUnwrap(original.replacing(NSRange(location:4,length:0),with:"new\n",state:.resolved));XCTAssertEqual(inserted.states(conflicts:[]),[.normal,.resolved,.resolved,.filtered])
        XCTAssertNil(original.replacing(NSRange(location:Int.max,length:1),with:"x"))
    }
    func testModifiedOnlyFindUsesResolvedAndEditedRowsWithoutUnchangedMiddle() {
        let value=MergeResultPresentation(text:"needle\nneedle\nneedle\n",states:[.resolved,.normal,.edited])
        let matches=MergeFind.matches("needle",in:MergeFindLine.document(value.text,states:value.states(conflicts:[])),options:MergeFindOptions(modifiedOnly:true))
        XCTAssertEqual(matches.map(\.location),[0,14])
    }
}
