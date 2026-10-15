import XCTest
@testable import TurtleGitCore

final class MergeSourceBlockEditTests: XCTestCase {
    private func fixture() -> (MergeSourceComparison, MergeResultPresentation) {
        func cell(_ text: String, _ state: MergeSourceState = .normal) -> MergeSourceCell { .init(text:text,lineNumber:1,state:state) }
        let rows: [MergeSourceRow] = [
            .init(mine:cell("head 🐢\r\n"),theirs:cell("head 🐢\r\n")),
            .init(mine:cell("old\n",.yoursRemoved),theirs:cell("old\n")),
            .init(mine:cell("new1\n",.identicalAdded),theirs:cell("",.empty)),
            .init(mine:cell("new2\n",.identicalAdded),theirs:cell("",.empty)),
            .init(mine:cell("tail\r\n"),theirs:cell("tail\r\n"))]
        let text = "head 🐢\r\nnew1\r\nnew2\r\ntail\r\n", start = "head 🐢\r\n".utf16.count
        let map = MergeNavigationMap(entries:[.init(sourceRows:0..<1,resultRange:NSRange(location:0,length:start)),.init(sourceRows:1..<2,resultRange:NSRange(location:start,length:0)),.init(sourceRows:2..<3,resultRange:NSRange(location:start,length:6)),.init(sourceRows:3..<4,resultRange:NSRange(location:start + 6,length:6)),.init(sourceRows:4..<5,resultRange:NSRange(location:start + 12,length:6))])
        return (.init(rows:rows,navigationMap:map), .init(text:text,states:[],navigationMap:map))
    }
    func testSelectedAddedRowDoesNotReplaceNeighboringRows() throws {
        let (source,presentation) = fixture()
        let edit = try XCTUnwrap(MergeSourceBlockEdit(comparison:source,presentation:presentation,rows:2..<3,choice:.theirs))
        let next = try XCTUnwrap(presentation.applyingSourceBlock(edit))
        XCTAssertEqual(edit.replacement, "")
        XCTAssertEqual(next.text,"head 🐢\r\nnew2\r\ntail\r\n")
        XCTAssertEqual(next.navigationMap.exactResultRange(sourceRows:2..<3),NSRange(location:"head 🐢\r\n".utf16.count,length:0))
        XCTAssertEqual(next.navigationMap.exactResultRange(sourceRows:3..<4)?.length,6)
        XCTAssertTrue(next.states(conflicts:[]).allSatisfy { $0 == .normal })
    }
    func testRemovedRowRestoresOtherSideAtZeroByteAnchor() throws {
        let (source,presentation) = fixture()
        let edit = try XCTUnwrap(MergeSourceBlockEdit(comparison:source,presentation:presentation,rows:1..<2,choice:.theirs))
        let next = try XCTUnwrap(presentation.applyingSourceBlock(edit))
        XCTAssertEqual(next.text,"head 🐢\r\nold\r\nnew1\r\nnew2\r\ntail\r\n")
        XCTAssertEqual(next.navigationMap.exactResultRange(sourceRows:2..<3)?.location,"head 🐢\r\nold\r\n".utf16.count)
        XCTAssertNotNil(next.navigationMap.exactResultRange(sourceRows:0..<5))
    }
    func testBothOrdersRetainSecondSourceEndings() throws {
        func cell(_ text:String)->MergeSourceCell { .init(text:text,lineNumber:1,state:.filtered) }
        let source = MergeSourceComparison(rows:[.init(mine:cell("mine\n"),theirs:cell("theirs\r"))])
        let map = MergeNavigationMap(entries:[.init(sourceRows:0..<1,resultRange:NSRange(location:0,length:6))])
        let presentation = MergeResultPresentation(text:"mine\r\n",states:[],navigationMap:map)
        XCTAssertEqual(MergeSourceBlockEdit(comparison:source,presentation:presentation,rows:0..<1,choice:.mineThenTheirs)?.replacement,"mine\r\ntheirs\r")
        XCTAssertEqual(MergeSourceBlockEdit(comparison:source,presentation:presentation,rows:0..<1,choice:.theirsThenMine)?.replacement,"theirs\r\nmine\n")
    }
    func testPartialEngineGroupAndMissingMappingsAreRefused() {
        let map = MergeNavigationMap(entries:[.init(sourceRows:0..<2,resultRange:NSRange(location:0,length:4)),.init(sourceRows:3..<4,resultRange:NSRange(location:4,length:2))])
        XCTAssertNil(map.exactResultRange(sourceRows:0..<1))
        XCTAssertNil(map.exactResultRange(sourceRows:0..<4))
        XCTAssertEqual(map.exactResultRange(sourceRows:0..<2),NSRange(location:0,length:4))
    }
    func testStaleTextAndChangedMapCannotApplyCapturedEdit() throws {
        let (source,presentation) = fixture()
        let edit = try XCTUnwrap(MergeSourceBlockEdit(comparison:source,presentation:presentation,rows:2..<3,choice:.mine))
        XCTAssertNil(presentation.reconciling("different").applyingSourceBlock(edit))
        XCTAssertNil(MergeResultPresentation(text:presentation.text,states:[]).applyingSourceBlock(edit))
        XCTAssertEqual(presentation.text,"head 🐢\r\nnew1\r\nnew2\r\ntail\r\n")
    }
    func testFinalNoEndingIsRetainedAndConflictEmptyDoesNotCreateLine() throws {
        let source = MergeSourceComparison(rows:[.init(mine:.init(text:"final 🐢",lineNumber:1,state:.conflictAdded),theirs:.init(text:"",lineNumber:nil,state:.conflictEmpty))])
        let presentation = MergeResultPresentation(text:"old",states:[],navigationMap:.init(entries:[.init(sourceRows:0..<1,resultRange:NSRange(location:0,length:3))]))
        XCTAssertEqual(MergeSourceBlockEdit(comparison:source,presentation:presentation,rows:0..<1,choice:.mine)?.replacement,"final 🐢")
        XCTAssertEqual(MergeSourceBlockEdit(comparison:source,presentation:presentation,rows:0..<1,choice:.theirs)?.replacement,"")
    }
    func testSameTextChoiceRetainsSourceColorsAndUndoableRevision() throws {
        let cell = MergeSourceCell(text:"same\n",lineNumber:1,state:.normal)
        let source = MergeSourceComparison(rows:[.init(mine:cell,theirs:cell)])
        let before = MergeResultPresentation(text:"same\n",states:[.normal],navigationMap:.init(entries:[.init(sourceRows:0..<1,resultRange:NSRange(location:0,length:5))]))
        let edit = try XCTUnwrap(MergeSourceBlockEdit(comparison:source,presentation:before,rows:0..<1,choice:.mine))
        let next = try XCTUnwrap(before.applyingSourceBlock(edit))
        XCTAssertEqual(next.text,before.text); XCTAssertEqual(next.runs,before.runs)
        XCTAssertEqual(next.sourceChoiceRevision,1); XCTAssertNotEqual(next,before)
        XCTAssertEqual(next.reconciling("typed\n").sourceChoiceRevision,1)
    }
}
