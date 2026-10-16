import XCTest
@testable import TurtleGitCore

final class MergeMarginPresentationTests: XCTestCase {
    func cell(_ value:String,_ state:MergeSourceState = .added)->MergeSourceCell { .init(text:value,lineNumber:1,state:state) }
    func testStateIconsAndPriorityWithoutPeer() {
        let states: [MergeSourceState] = [.normal,.filtered,.added,.theirsAdded,.yoursAdded,.identicalAdded,.conflictAdded,.removed,.theirsRemoved,.yoursRemoved,.identicalRemoved,.conflicted,.conflictedIgnored,.edited,.empty,.conflictEmpty,.resolved,.resolvedEmpty,.removedWhitespace,.addedWhitespace]
        let expected: [MergeMarginSymbol?] = [nil,nil,.added,.added,.added,.added,.added,.removed,.removed,.removed,.removed,.conflict,.ignoredConflict,.edited,nil,nil,nil,nil,nil,nil]
        let view = MergeMarginPresentation(cells:states.map {cell("x\n",$0)})
        XCTAssertEqual(view.symbols,expected)
        XCTAssertEqual(view.symbol(at:2,moved:true),.moved)
        XCTAssertEqual(view.symbol(at:2,moved:true,marked:true),.marked)
        XCTAssertNil(view.symbol(at:states.count,moved:true,marked:true))
    }
    func testPayloadEqualityAndLineEndingsFollowSourceEarlyReturns() {
        let cells = [cell("normal\r\n",.normal),cell("\n",.empty),cell("same\n"),cell("a b\n"),cell("typed \n",.edited)]
        let peers = [cell("normal\n"),cell("\r\n"),cell("same\r"),cell("ab\n"),cell("typed\n")]
        XCTAssertEqual(MergeMarginPresentation(cells:cells,peers:peers).symbols,[nil,nil,.equal,.whitespace,.edited])
    }
    func testWhitespaceFilterIsOnlySpaceTabCRLFAndLiteralUnicode() {
        XCTAssertEqual(MergeMarginPresentation(cells:[cell("a \t🐢\n")],peers:[cell("a🐢\r\n")]).symbols,[.whitespace])
        XCTAssertEqual(MergeMarginPresentation(cells:[cell("a\u{00a0}b\n")],peers:[cell("ab\n")]).symbols,[.added])
        XCTAssertEqual(MergeMarginPresentation(cells:[cell("é\n")],peers:[cell("e\u{301}\n")]).symbols,[.added])
    }
    func testStateBlockCanRecognizeReflowAcrossRowsAndCacheWholeBlock() {
        let mine = [cell("one two\n"),cell("three\n")],other = [cell("one\n",.removed),cell("two three\n",.removed)]
        XCTAssertEqual(MergeMarginPresentation(cells:mine,peers:other).symbols,[.whitespace,.whitespace])
        let exact = [cell("one two\n",.removed),cell("three\n",.removed)]
        XCTAssertEqual(MergeMarginPresentation(cells:mine,peers:exact).symbols,[.equal,.equal])
    }
    func testEmptyCanAdoptNeighborStateButNormalIsBoundary() {
        let mine = [cell("a\n"),cell("",.empty),cell("b c\n"),cell("sentinel\n",.normal)]
        let peer = [cell("ab\n",.removed),cell("c\n",.removed),cell("",.empty),cell("sentinel\n",.normal)]
        XCTAssertEqual(MergeMarginPresentation(cells:mine,peers:peer).symbols,[.whitespace,.whitespace,.whitespace,nil])
    }
    func testBlockAllocationBoundUsesUTF16PlusTwoPerRow() {
        let exactLimit = String(repeating:"🐢",count:511) // 1022 UTF-16 units
        let a = [cell(exactLimit+"\n"),cell(exactLimit+"\n")]
        let b = [cell(String(repeating:"🐢",count:510)+"\n",.removed),cell(String(repeating:"🐢",count:512)+"\n",.removed)]
        XCTAssertEqual(MergeMarginPresentation(cells:a,peers:b).symbols,[.whitespace,.whitespace])
        let long = [cell(exactLimit+"x\n"),cell(exactLimit+"\n")]
        let longPeer = [cell(String(repeating:"🐢",count:510)+"\n",.removed),cell(String(repeating:"🐢",count:512)+"x\n",.removed)]
        XCTAssertEqual(MergeMarginPresentation(cells:long,peers:longPeer).symbols,[.added,.added])
    }
    func testLongStateRunDoesNotLookBeyondEightRows() {
        var a = (0..<20).map {cell("record\($0)\n")}, b = (0..<20).map {cell("record\($0)\n",.removed)}
        a[0] = cell("prefix\n"); b[0] = cell("\n",.removed)
        a[19] = cell("\n"); b[19] = cell("prefix\n",.removed)
        let symbols = MergeMarginPresentation(cells:a,peers:b).symbols
        XCTAssertEqual(symbols[0],.added);XCTAssertEqual(symbols[19],.added)
    }
    func testAbsentAndShorterPeersAreSafeAndPreserveOriginalRecords() {
        let a = [cell("x\n"),cell("x \n")]
        XCTAssertEqual(MergeMarginPresentation(cells:a,peers:[]).symbols,[.added,.added])
        XCTAssertEqual(MergeMarginPresentation(cells:a,peers:[cell("x\n",.removed)]).symbols,[.equal,.whitespace])
        XCTAssertEqual(a.map(\.text),["x\n","x \n"])
    }
}
