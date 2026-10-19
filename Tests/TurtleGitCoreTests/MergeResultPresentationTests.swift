import XCTest
@testable import TurtleGitCore
final class MergeResultPresentationTests: XCTestCase {
    func testIgnoredConflictRemapsOutsideEditsAndChoicesResolveEvenUnchangedBytes() throws {
        let text = "head 🦎\nxy\nfooter\n", range = (text as NSString).range(of:"xy\n")
        let value = MergeResultPresentation(text:text,states:[.normal,.conflictedIgnored,.normal],ignoredConflicts:[.init(range:range,mine:"xy\n",base:"x y\n",theirs:"x  y\n")])
        let shifted = try XCTUnwrap(value.replacing(NSRange(location:0,length:4),with:"long header"))
        XCTAssertEqual(shifted.ignoredConflicts.first?.range.location,range.location + 7)
        XCTAssertTrue(shifted.conflicts().first?.isIgnored == true)
        let chosen = try XCTUnwrap(value.replacing(range,with:"xy\n",state:.resolved))
        XCTAssertEqual(chosen.text,value.text); XCTAssertTrue(chosen.ignoredConflicts.isEmpty); XCTAssertEqual(chosen.states(conflicts:[]),[.normal,.resolved,.normal]); XCTAssertNotEqual(chosen,value)
        let typed = try XCTUnwrap(value.replacing(NSRange(location:range.location + 1,length:0),with:"edited"))
        XCTAssertTrue(typed.conflicts().isEmpty); XCTAssertEqual(typed.states(conflicts:[]),[.normal,.edited,.normal])
        XCTAssertEqual(value.states(conflicts:[]),[.normal,.conflictedIgnored,.normal])
    }
    func testAdjacentIgnoredLinesGroupAndNoEndingChoicesKeepSeparators() throws {
        let value = MergeResultPresentation(text:"one\nlast",states:[],ignoredConflicts:[.init(range:NSRange(location:0,length:4),mine:"one\n",base:"base1\n",theirs:"their1\n"),.init(range:NSRange(location:4,length:4),mine:"last",base:"base2",theirs:"their2")])
        let block = try XCTUnwrap(value.conflicts().first)
        XCTAssertEqual(value.conflicts().count,1); XCTAssertEqual(block.replacement(.mine),"one\nlast")
        XCTAssertEqual(block.replacement(.mineThenTheirs),"one\nlast\ntheir1\ntheir2")
        XCTAssertEqual(block.replacement(.theirsThenMine),"their1\ntheir2\none\nlast")
        let edited = try XCTUnwrap(value.replacing(NSRange(location:8,length:0),with:"!"))
        XCTAssertEqual(edited.ignoredConflicts.count,1); XCTAssertEqual(edited.ignoredConflicts[0].range.location,0)
    }
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

extension MergeResultPresentationTests {
    func testEqualResultStatesKeepIndependentVisibilityRunsAndUntouchedFlags() throws {
        let original = MergeResultPresentation(text: "first 🐢\r\nshown\r\nlast", states: [.normal, .normal, .normal], hiddenByComparison: [true, false, true])
        XCTAssertEqual(original.runs.count, 3, "Equal state must not merge different source hide flags")
        XCTAssertEqual(original.hiddenByComparison(), [true, false, true])
        let changed = try XCTUnwrap(original.replacing((original.text as NSString).range(of: "shown"), with: "manual"))
        XCTAssertEqual(changed.states(conflicts: []), [.normal, .edited, .normal])
        XCTAssertEqual(changed.hiddenByComparison(), [true, false, true])
        let resolved = try XCTUnwrap(original.replacing((original.text as NSString).range(of: "first 🐢"), with: "picked 🐢", state: .resolved))
        XCTAssertEqual(resolved.states(conflicts: []), [.resolved, .normal, .normal])
        XCTAssertEqual(resolved.hiddenByComparison(), [false, false, true])
        XCTAssertEqual(original.hiddenByComparison(), [true, false, true])
        XCTAssertEqual(original.text, "first 🐢\r\nshown\r\nlast")
    }
}


extension MergeResultPresentationTests {
    func testRecordedAndInferredHideMetadataCannotShareAProjectionCacheIdentity() throws {
        let cell = MergeSourceCell(text: "x\n", lineNumber: 1, state: .normal, hiddenByComparison: false)
        let map = MergeNavigationMap(entries: [.init(sourceRows: 0..<1, resultRange: NSRange(location: 0, length: 2))])
        let source = MergeSourceComparison(rows: [.init(mine: cell, theirs: cell)], navigationMap: map, alignedResultRows: [cell])
        let inferred = MergeResultPresentation(text: "x\n", states: [.normal], navigationMap: map)
        let recorded = MergeResultPresentation(text: "x\n", states: [.normal], hiddenByComparison: [true], navigationMap: map)
        XCTAssertNotEqual(inferred, recorded, "The same state can have different checked hide provenance")
        XCTAssertFalse(try XCTUnwrap(MergeAlignedResultProjection(comparison: source, presentation: inferred)).cells[0].hiddenByComparison)
        XCTAssertTrue(try XCTUnwrap(MergeAlignedResultProjection(comparison: source, presentation: recorded)).cells[0].hiddenByComparison)
    }
}
