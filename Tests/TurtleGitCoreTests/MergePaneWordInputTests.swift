import XCTest
@testable import TurtleGitCore

/// Independent offsets follow BaseView::IsCaretAtWordBoundary's separator-run
/// transitions and line-edge rules, rather than AppKit's linguistic tokenizer.
final class MergePaneWordInputTests: XCTestCase {
    private func cell(_ text:String,_ state:MergeSourceState = .normal)->MergeSourceCell {
        .init(text:text,lineNumber:state.isViewEmpty ? nil:1,state:state)
    }
    private func display(_ cells:[MergeSourceCell])->String {cells.map {$0.displayText + "\n"}.joined()}
    private func document(_ text:String)throws->MergePaneInput.WordDocument {
        try XCTUnwrap(MergePaneInput.WordDocument(text:text))
    }
    private func document(_ cells:[MergeSourceCell])throws->MergePaneInput.WordDocument {
        try XCTUnwrap(MergePaneInput.WordDocument(text:display(cells),cells:cells))
    }

    func testDefaultSeparatorsStopAtBothSidesOfRunsInsteadOfSkippingPunctuation()throws {
        let value=try document("alpha_beta::  gamma")
        for (start,end) in [(0,10),(10,14),(14,19),(19,19)] {
            XCTAssertEqual(value.destination(from:start,forward:true),end)
        }
        for (start,end) in [(19,14),(14,10),(10,0),(0,0)] {
            XCTAssertEqual(value.destination(from:start,forward:false),end)
        }
        let punctuation=try document("a/b")
        XCTAssertEqual(punctuation.destination(from:0,forward:true),1)
        XCTAssertEqual(punctuation.destination(from:1,forward:true),2)
        XCTAssertEqual(punctuation.destination(from:2,forward:true),3)
    }

    func testCustomSeparatorsReplaceDefaultsButControlWhitespaceAlwaysSeparates()throws {
        let value=try document("alpha_beta")
        XCTAssertEqual(value.destination(from:0,forward:true,wordSeparators:"_"),5)
        XCTAssertEqual(value.destination(from:5,forward:true,wordSeparators:"_"),6)
        XCTAssertEqual(value.destination(from:10,forward:false,wordSeparators:"_"),6)
        XCTAssertEqual(value.destination(from:6,forward:false,wordSeparators:"_"),5)
        let path=try document("a/b")
        XCTAssertEqual(path.destination(from:0,forward:true,wordSeparators:""),3)
        let controls=try document("ab\t\u{0001} cd")
        XCTAssertEqual(controls.destination(from:0,forward:true,wordSeparators:""),2)
        XCTAssertEqual(controls.destination(from:2,forward:true,wordSeparators:""),5)
        XCTAssertEqual(controls.destination(from:7,forward:false,wordSeparators:""),5)
    }

    func testLineEdgesSkipBlankAndWhitespaceOnlyRowsUntilARealBoundary()throws {
        let value=try document("alpha \n\n \t\nbeta\n")
        XCTAssertEqual(value.destination(from:5,forward:true),11)
        XCTAssertEqual(value.destination(from:11,forward:false),5)
        XCTAssertEqual(value.destination(from:0,forward:true),5)
        XCTAssertEqual(value.destination(from:11,forward:true),15)
        let adjacent=try document("alpha\nbeta")
        XCTAssertEqual(adjacent.destination(from:5,forward:true),6)
        XCTAssertEqual(adjacent.destination(from:6,forward:false),5)
    }

    func testNativeGraphemesStayWholeWhileWordClassificationRemainsSourceDefined()throws {
        let prefix="e\u{301}👩🏽‍💻🇩🇪",text=prefix+"/tail",edge=prefix.utf16.count
        let value=try document(text)
        XCTAssertEqual(value.destination(from:0,forward:true),edge)
        XCTAssertEqual(value.destination(from:edge,forward:false),0)
        XCTAssertEqual(value.destination(from:edge,forward:true),edge+1)
        let deletion=try XCTUnwrap(value.deletionRange(selection:.init(location:0,length:0),backward:false))
        XCTAssertEqual((text as NSString).substring(with:deletion),prefix)
        XCTAssertEqual((text as NSString).replacingCharacters(in:deletion,with:""),"/tail")
        XCTAssertEqual(value.deletionRange(selection:.init(location:edge,length:0),backward:true),deletion)
        // Combining marks do not permit a stop within their composed character.
        let combining=try document("e\u{301} x")
        XCTAssertEqual(combining.destination(from:0,forward:true),2)
    }

    func testRawCRLFUsesWholeLineBoundariesAndRetainsRealTrailingEnding()throws {
        let text="a\r\n\r\n  b\r\n",value=try document(text)
        XCTAssertEqual(value.destination(from:1,forward:true),7)
        XCTAssertEqual(value.destination(from:7,forward:false),1)
        let joined=try XCTUnwrap(value.deletionRange(selection:.init(location:1,length:0),backward:false))
        XCTAssertEqual(joined,NSRange(location:1,length:6))
        XCTAssertEqual((text as NSString).replacingCharacters(in:joined,with:""),"ab\r\n")
        XCTAssertEqual(value.destination(from:8,forward:true),10)
        XCTAssertEqual(value.destination(from:10,forward:false),8)
        XCTAssertEqual(value.deletionRange(selection:.init(location:8,length:0),backward:false),NSRange(location:8,length:2))
    }

    func testAlignmentGapsNormalizeDeletionEndpointsWithoutBecomingWords()throws {
        let cells=[cell("A\r\n"),cell("",.empty),cell("",.conflictEmpty),cell("B\r\n")]
        let value=try document(cells)
        XCTAssertEqual(value.destination(from:1,forward:true),4)
        XCTAssertEqual(value.destination(from:4,forward:false),1)
        XCTAssertEqual(value.deletionRange(selection:.init(location:1,length:0),backward:false),NSRange(location:1,length:3))
        XCTAssertEqual(value.deletionRange(selection:.init(location:4,length:0),backward:true),NSRange(location:1,length:3))
        XCTAssertNil(value.deletionRange(selection:.init(location:2,length:0),backward:false),"An Empty start is normalized to the same next real endpoint")
        XCTAssertEqual(value.deletionRange(selection:.init(location:2,length:3),backward:true),NSRange(location:4,length:1))
        XCTAssertNil(value.deletionRange(selection:.init(location:5,length:0),backward:false),"Synthetic final display LF is not payload")
    }

    func testRemovedAndRealBlankRowsAreNotNormalizedAsAlignmentGaps()throws {
        for state:MergeSourceState in [.removed,.removedWhitespace,.identicalRemoved] {
            let value=try document([cell("A"),cell("X",state),cell("B")])
            XCTAssertEqual(value.destination(from:1,forward:true),2,"\(state)")
            XCTAssertEqual(value.destination(from:4,forward:false),3,"\(state)")
            XCTAssertEqual(value.deletionRange(selection:.init(location:2,length:1),backward:false),NSRange(location:2,length:1))
        }
        for state:MergeSourceState in [.normal,.edited,.resolvedEmpty] {
            let value=try document([cell("A"),cell("",state),cell("B")])
            XCTAssertEqual(value.deletionRange(selection:.init(location:2,length:1),backward:true),NSRange(location:2,length:1),"Real blank \(state) retains its own display interval")
        }
    }

    func testHiddenAndMarkerRowsAreSkippedButTheirPayloadBelongsToDeletionSpan()throws {
        let cells=[cell("aa"),cell("hidden"),cell("marker"),cell("bb")],text="aa\nhidden\nmarker\nbb\n"
        let value=try document(cells),hidden:Set<Int>=[1,2]
        XCTAssertEqual(value.destination(from:2,forward:true,hiddenRows:hidden),17)
        XCTAssertEqual(value.destination(from:17,forward:false,hiddenRows:hidden),2)
        XCTAssertEqual(value.destination(from:3,forward:true,hiddenRows:hidden),17)
        XCTAssertEqual(value.destination(from:10,forward:false,hiddenRows:hidden),2)
        let range=try XCTUnwrap(value.deletionRange(selection:.init(location:2,length:0),backward:false,hiddenRows:hidden))
        XCTAssertEqual(range,NSRange(location:2,length:15))
        XCTAssertEqual((text as NSString).replacingCharacters(in:range,with:""),"aabb\n")
        XCTAssertEqual(cells.map(\.text),["aa","hidden","marker","bb"],"Read-only geometry never mutates the Undo source snapshot")
        XCTAssertNil(value.destination(from:0,forward:true,hiddenRows:[0,1,2,3]))
    }

    func testExistingSelectionWinsOverWordDirectionAndSeparatorConfiguration()throws {
        let value=try document("alpha.beta gamma"),range=NSRange(location:2,length:9)
        for backward in [false,true] {
            XCTAssertEqual(value.deletionRange(selection:range,backward:backward,wordSeparators:""),range)
            XCTAssertEqual(value.deletionRange(selection:range,backward:backward,wordSeparators:"._",hiddenRows:[0]),range)
        }
        let empty=try document("")
        XCTAssertEqual(empty.destination(from:0,forward:true),0)
        XCTAssertEqual(empty.destination(from:0,forward:false),0)
        XCTAssertNil(empty.deletionRange(selection:.init(location:0,length:0),backward:true))
        XCTAssertNil(empty.deletionRange(selection:.init(location:0,length:0),backward:false))
    }

    func testMalformedCaretsAndSelectedEndpointsCannotSplitGraphemesOrCRLF()throws {
        for (text,inside) in [("e\u{301} x",1),("👩🏽‍💻 x",2),("🇩🇪 x",1),("a\r\nb",2)] {
            let value=try document(text)
            XCTAssertNil(value.destination(from:inside,forward:true),"\(text.debugDescription)")
            XCTAssertNil(value.destination(from:inside,forward:false))
            XCTAssertNil(value.deletionRange(selection:.init(location:inside,length:0),backward:false))
            XCTAssertNil(value.deletionRange(selection:.init(location:inside,length:0),backward:true))
            XCTAssertNil(value.deletionRange(selection:.init(location:0,length:inside),backward:false))
            XCTAssertNil(value.deletionRange(selection:.init(location:inside,length:text.utf16.count-inside),backward:true))
        }
        let value=try document("alpha\nbeta")
        XCTAssertNil(value.deletionRange(selection:.init(location:0,length:2),backward:false,hiddenRows:[-1]))
        XCTAssertNil(value.deletionRange(selection:.init(location:0,length:2),backward:true,hiddenRows:[2]))
    }

    func testInvalidGeometryRangesAndHiddenRowIndicesAreRefused()throws {
        XCTAssertNil(MergePaneInput.WordDocument(text:"A\nX\n",cells:[cell("A"),cell("B")]))
        XCTAssertNil(MergePaneInput.WordDocument(text:"e\u{301}\n",cells:[cell("é")]),"Canonical equivalence cannot replace exact pane bytes")
        let value=try document("alpha\nbeta")
        for offset in [-1,11,Int.max] {XCTAssertNil(value.destination(from:offset,forward:true))}
        XCTAssertNil(value.destination(from:0,forward:true,hiddenRows:[-1]))
        XCTAssertNil(value.destination(from:0,forward:false,hiddenRows:[2]))
        for range in [NSRange(location:NSNotFound,length:0),NSRange(location:0,length:-1),NSRange(location:2,length:Int.max),NSRange(location:11,length:0)] {
            XCTAssertNil(value.deletionRange(selection:range,backward:false))
        }
        let noFinal=try XCTUnwrap(MergePaneInput.WordDocument(text:"last",cells:[cell("last")]))
        XCTAssertEqual(noFinal.destination(from:0,forward:true),4)
        XCTAssertNil(noFinal.deletionRange(selection:.init(location:4,length:0),backward:false))
    }
}
