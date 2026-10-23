import XCTest
@testable import TurtleGitCore

/// Authored source Search/StringFound cases; Count's different projection is
/// retained explicitly rather than used as the directional navigation oracle.
final class MergeFindNavigationTests:XCTestCase {
    private func navigate(_ text:String,_ query:String,_ selection:NSRange,up:Bool=false,replace:Bool=false,
                          options:MergeFindOptions = .init())->MergeFind.Match? {
        MergeFind.navigate(query,in:MergeFindLine.document(text),options:options,selection:selection,upwards:up,useSelectionStart:replace)
    }
    func testCaretInsideOverlapUsesBoundedForwardAndRightmostReverseMatch() {
        XCTAssertEqual(navigate("aaa","aa",NSRange(location:1,length:0))?.range,NSRange(location:1,length:2))
        XCTAssertEqual(navigate("aaa","aa",NSRange(location:1,length:0))?.wrapped,false)
        XCTAssertEqual(navigate("aaa","aa",NSRange(location:3,length:0),up:true)?.range,NSRange(location:1,length:2))
        XCTAssertEqual(navigate("ababab","abab",NSRange(location:2,length:0))?.range,NSRange(location:2,length:4))
        XCTAssertEqual(MergeFind.matches("aa",in:MergeFindLine.document("aaa"),options:.init()),[NSRange(location:0,length:2)])
        XCTAssertEqual(MergeFind.matches("abab",in:MergeFindLine.document("ababab"),options:.init()),[NSRange(location:0,length:4)])
    }
    func testReplaceUsesSelectedStartForwardButSearchUpSkipsCurrentSelection() {
        let current=NSRange(location:4,length:3)
        XCTAssertEqual(navigate("foo foo","foo",current,replace:true)?.range,current)
        let previous=navigate("foo foo","foo",current,up:true,replace:true)
        XCTAssertEqual(previous?.range,NSRange(location:0,length:3));XCTAssertEqual(previous?.wrapped,false)
        XCTAssertEqual(navigate("foo foo","foo",NSRange(location:0,length:3),up:true,replace:true)?.range,current)
        XCTAssertEqual(navigate("foo foo","foo",NSRange(location:0,length:3),up:true,replace:true)?.wrapped,true)
        XCTAssertEqual(navigate("foo foo","foo",NSRange(location:0,length:3))?.range,current)
    }
    func testWholeWordUsesInitialSubstringBoundariesWithoutChangingCount() {
        let words=MergeFindOptions(wholeWord:true)
        XCTAssertEqual(navigate("xcat","cat",NSRange(location:1,length:0),options:words)?.range,NSRange(location:1,length:3))
        XCTAssertEqual(navigate("catx","cat",NSRange(location:3,length:0),up:true,options:words)?.range,NSRange(location:0,length:3))
        XCTAssertTrue(MergeFind.matches("cat",in:MergeFindLine.document("xcat"),options:words).isEmpty)
        XCTAssertTrue(MergeFind.matches("cat",in:MergeFindLine.document("catx"),options:words).isEmpty)
        XCTAssertNil(navigate("xcat","cat",NSRange(location:0,length:0),options:words))
        XCTAssertNil(navigate("catx","cat",NSRange(location:4,length:0),up:true,options:words))
    }
    func testWrapRevisitsTheEntireInitialLineWithDirectionalMatching() {
        let backwards=navigate("aaa","aa",NSRange(location:0,length:0),up:true)
        XCTAssertEqual(backwards?.range,NSRange(location:1,length:2));XCTAssertEqual(backwards?.wrapped,true)
        let forwards=navigate("aaa","aa",NSRange(location:3,length:0))
        XCTAssertEqual(forwards?.range,NSRange(location:0,length:2));XCTAssertEqual(forwards?.wrapped,true)
        let next=navigate("hit\nother hit\nhit","hit",NSRange(location:0,length:3))
        XCTAssertEqual(next?.range,NSRange(location:10,length:3));XCTAssertEqual(next?.wrapped,false)
        let previous=navigate("hit\nother hit\nhit","hit",NSRange(location:0,length:0),up:true)
        XCTAssertEqual(previous?.range,NSRange(location:14,length:3));XCTAssertEqual(previous?.wrapped,true)
        XCTAssertNil(navigate("no match","hit",NSRange(location:3,length:0)))
    }
    func testMultilineSelectionRetainsSourceEndLineAndStartColumnPolicy() {
        let text="x foo\nfoo xx foo",selection=NSRange(location:2,length:10)
        // Normal reverse Search starts on selection End.y, but uses Start.x.
        let previous=navigate(text,"foo",selection,up:true)
        XCTAssertEqual(previous?.range,NSRange(location:2,length:3));XCTAssertEqual(previous?.wrapped,false)
        let replacing=navigate(text,"foo",selection,up:true,replace:true)
        XCTAssertEqual(replacing?.range,NSRange(location:13,length:3));XCTAssertEqual(replacing?.wrapped,true)
        XCTAssertEqual(navigate(text,"foo",selection)?.range,NSRange(location:13,length:3))
        XCTAssertEqual(navigate(text,"foo",selection,replace:true)?.range,NSRange(location:2,length:3))
    }
    func testModifiedOnlyAndSyntheticGapsParticipateInTraversalNotCountOffsets() {
        let lines:[MergeFindLine]=[
            .init(text:"hit",offset:0,state:.normal),.init(text:"hit",offset:4,state:.empty),
            .init(text:"hit",offset:8,state:.filtered),.init(text:"hit",offset:12,state:.removed),
            .init(text:"hit",offset:16,state:.resolvedEmpty)]
        let options=MergeFindOptions(modifiedOnly:true)
        let forward=MergeFind.navigate("hit",in:lines,options:options,selection:NSRange(location:0,length:0),upwards:false)
        XCTAssertEqual(forward?.range,NSRange(location:12,length:3));XCTAssertEqual(forward?.wrapped,false)
        let reverse=MergeFind.navigate("hit",in:lines,options:options,selection:NSRange(location:12,length:0),upwards:true)
        XCTAssertEqual(reverse?.range,NSRange(location:16,length:3));XCTAssertEqual(reverse?.wrapped,true)
        XCTAssertEqual(MergeFind.matches("hit",in:lines,options:options).map(\.location),[12,16])
        XCTAssertNil(MergeFind.navigate("hit",in:Array(lines.prefix(3)),options:options,selection:NSRange(location:0,length:0),upwards:false))
    }
    func testLiteralCaseUTF16AndMixedEndingCoordinatesRemainExact() {
        let text="🦎 aaa\r\n雪 AAA\rhit\nhit"
        XCTAssertEqual(navigate(text,"aa",NSRange(location:4,length:0))?.range,NSRange(location:4,length:2))
        XCTAssertEqual(navigate(text,"aa",NSRange(location:13,length:0),up:true)?.range,NSRange(location:11,length:2))
        let sensitive=MergeFindOptions(matchCase:true)
        XCTAssertEqual(navigate(text,"aa",NSRange(location:13,length:0),up:true,options:sensitive)?.range,NSRange(location:4,length:2))
        XCTAssertNil(navigate(text,"\r\n",NSRange(location:0,length:0)))
        XCTAssertNil(navigate("foo\nbar","foo\nbar",NSRange(location:0,length:0)))
    }
    func testReverseWholeWordRejectionRetainsSourceStrictBeforeDecrement() {
        // Rightmost aa at1 fails its following X boundary. StringFound then
        // decrements start and skips the adjacent candidate at0, even though
        // Count (forward) accepts it. This is a pinned-source search quirk.
        let options=MergeFindOptions(wholeWord:true,wordSeparators:"a")
        XCTAssertNil(navigate("aaaX","aa",NSRange(location:4,length:0),up:true,options:options))
        XCTAssertEqual(MergeFind.matches("aa",in:MergeFindLine.document("aaaX"),options:options),[NSRange(location:0,length:2)])
    }
    func testEmptyAndInvalidReceiptsDoNotNavigateOrOverflow() {
        XCTAssertNil(navigate("hit","",NSRange(location:0,length:0)))
        XCTAssertNil(navigate("","hit",NSRange(location:0,length:0)))
        XCTAssertNil(navigate("hit","hit",NSRange(location:NSNotFound,length:0)))
        XCTAssertNil(navigate("hit","hit",NSRange(location:Int.max-1,length:3)))
        XCTAssertNil(MergeFind.navigate("hit",in:[.init(text:"hit",offset:-1,state:.added)],options:.init(),selection:NSRange(location:0,length:0),upwards:false))
        XCTAssertNil(MergeFind.navigate("hit",in:[.init(text:"hit",offset:4,state:.added),.init(text:"hit",offset:1,state:.added)],options:.init(),selection:NSRange(location:0,length:0),upwards:false))
        // Native caret after a final terminator maps to the final content end.
        XCTAssertEqual(navigate("hit\r\n","hit",NSRange(location:5,length:0))?.wrapped,true)
    }
}
