// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class PatchMultipleLineEditingTests:XCTestCase {
    private let rows:[PatchLineEditSelection]=[.init(id:10,anchor:1,caret:2),.init(id:20,anchor:5,caret:6)]
    private func plan(_ command:PatchLineEditCommand,text:String="abc\nxyz",rows:[PatchLineEditSelection]?=nil,rectangle:Bool=true)throws->PatchLineEditPlan {
        try XCTUnwrap(PatchLineEditing.plan(text:text,selections:rows ?? self.rows,primarySelectionID:20,rectangular:rectangle,command:command))
    }
    func testRectangleClipboardSortsRowsAddsFinalLFAndRetainsEmptyRows() throws {
        let selected:[PatchLineEditSelection]=[.init(id:20,anchor:6,caret:7),.init(id:30,anchor:4,caret:4),.init(id:10,anchor:2,caret:1)]
        let clipboard=try XCTUnwrap(PatchLineEditing.selectionClipboard(text:"abc\n\nxyz",selections:selected,primarySelectionID:20,rectangular:true))
        XCTAssertEqual(clipboard.text,"b\n\ny\n");XCTAssertTrue(clipboard.rectangular)
        XCTAssertNil(PatchLineEditing.selectionClipboard(text:"abc",selections:[.init(id:0,anchor:1,caret:1)],primarySelectionID:0,rectangular:true))
    }
    func testLineCopyUsesPrimaryWhereRectangleLineCutCutsEveryRow() throws {
        let copy=try plan(.copyLines)
        XCTAssertEqual(copy.clipboardText,"xyz");XCTAssertFalse(copy.clipboardRectangular)
        XCTAssertEqual(copy.selections,rows);XCTAssertEqual(copy.primarySelectionID,20)
        let cut=try plan(.cutLines)
        XCTAssertEqual(cut.resultText,"ac\nxz");XCTAssertEqual(cut.clipboardText,"b\ny\n")
        XCTAssertTrue(cut.clipboardRectangular);XCTAssertTrue(cut.rectangular)
        XCTAssertEqual(cut.selections,[.init(id:10,anchor:1,caret:1),.init(id:20,anchor:4,caret:4)])
    }
    func testNonrectangleLineCutFiltersToPrimaryAndDeleteKeepsOtherEndpoints() throws {
        let cut=try plan(.cutLines,rectangle:false)
        XCTAssertEqual(cut.resultText,"abc\n");XCTAssertEqual(cut.clipboardText,"xyz")
        XCTAssertEqual(cut.selections,[.init(id:20,anchor:4,caret:4)])
        let deletion=try plan(.deleteLine)
        XCTAssertEqual(deletion.resultText,"abc\n")
        XCTAssertEqual(deletion.selections,[.init(id:10,anchor:1,caret:2),.init(id:20,anchor:4,caret:4)])
        XCTAssertNil(deletion.clipboardText)
    }
    func testPerRangeDuplicatePreservesPrimaryIdentityAndDirections() throws {
        let duplicate=try plan(.duplicate)
        XCTAssertEqual(duplicate.resultText,"abbc\nxyyz")
        XCTAssertEqual(duplicate.selections,[.init(id:10,anchor:1,caret:2),.init(id:20,anchor:6,caret:7)])
        XCTAssertEqual(duplicate.primarySelectionID,20)
        let reversed=[PatchLineEditSelection(id:10,anchor:2,caret:1),.init(id:20,anchor:6,caret:5)]
        let reverse=try plan(.duplicate,rows:reversed,rectangle:false)
        XCTAssertEqual(reverse.selections,[.init(id:10,anchor:2,caret:1),.init(id:20,anchor:7,caret:6)])
        let mixed=[PatchLineEditSelection(id:10,anchor:1,caret:2),.init(id:20,anchor:5,caret:5)]
        let mixedPlan=try plan(.duplicate,rows:mixed)
        XCTAssertEqual(mixedPlan.resultText,"abbc\nxyz")
        XCTAssertEqual(mixedPlan.selections.last?.caret,6)
    }
    func testThinRectangleDuplicateUsesLineModeAndIndentFinishesThin() throws {
        let thin=[PatchLineEditSelection(id:10,anchor:0,caret:0),.init(id:20,anchor:2,caret:2)]
        XCTAssertEqual(try plan(.duplicate,text:"a\nb",rows:thin).resultText,"a\na\nb\nb")
        let tab=try plan(.tab)
        XCTAssertEqual(tab.resultText,"a\tc\nx\tz")
        XCTAssertTrue(tab.selections.allSatisfy {$0.range.length==0})
        XCTAssertTrue(tab.rectangular)
        let indentation=try plan(.indent)
        XCTAssertEqual(indentation.resultText,"\tabc\n\txyz")
        XCTAssertTrue(indentation.selections.allSatisfy {$0.range.length==0})
    }
    func testDuplicateRectangleCornerReceiptsMatchForwardReverseAndThinLineModes() throws {
        let forward=try plan(.duplicate)
        XCTAssertEqual(forward.rectangleAnchor,1);XCTAssertEqual(forward.rectangleCaret,7)
        let reverseRows=[PatchLineEditSelection(id:20,anchor:5,caret:6),.init(id:10,anchor:1,caret:2)]
        let reverse=try XCTUnwrap(PatchLineEditing.plan(text:"abc\nxyz",selections:reverseRows,primarySelectionID:10,rectangular:true,command:.duplicate))
        XCTAssertEqual(reverse.resultText,"abbc\nxyyz")
        XCTAssertEqual(reverse.rectangleAnchor,7);XCTAssertEqual(reverse.rectangleCaret,3)
        let thin=[PatchLineEditSelection(id:10,anchor:0,caret:0),.init(id:20,anchor:2,caret:2)]
        let lines=try plan(.duplicate,text:"a\nb",rows:thin)
        XCTAssertEqual(lines.rectangleAnchor,0);XCTAssertEqual(lines.rectangleCaret,6)
        let tab=try plan(.tab)
        XCTAssertTrue(tab.rectangleIsThin)
        XCTAssertNotNil(tab.rectangleAnchor);XCTAssertNotNil(tab.rectangleCaret)
    }
    func testPrimaryTypingCollapsesAdditionalRangesWithoutReplicatingText() throws {
        let typing=try XCTUnwrap(PatchLineEditing.replacePrimarySelection(text:"abc\nxyz",selections:rows,primarySelectionID:20,replacement:"雪"))
        XCTAssertEqual(typing.resultText,"abc\nx雪z")
        XCTAssertEqual(typing.selections,[.init(id:20,anchor:6,caret:6)])
        XCTAssertFalse(typing.rectangular)
    }
    func testThinRectangleDeleteAndBackspaceDoNotCrossEOLAndHandleSurrogates() throws {
        let text="😀x\r\ny\n",thin=[PatchLineEditSelection(id:10,anchor:2,caret:2),.init(id:20,anchor:6,caret:6)]
        let back=try XCTUnwrap(PatchLineEditing.deleteSelections(text:text,selections:thin,primarySelectionID:20,rectangular:true,backwards:true))
        XCTAssertEqual(back.resultText,"x\r\n\n");XCTAssertNil(back.clipboardText)
        let starts=[PatchLineEditSelection(id:10,anchor:0,caret:0),.init(id:20,anchor:5,caret:5)]
        let noBack=try XCTUnwrap(PatchLineEditing.deleteSelections(text:text,selections:starts,primarySelectionID:20,rectangular:true,backwards:true))
        XCTAssertEqual(noBack.resultText,text)
        let ends=[PatchLineEditSelection(id:10,anchor:3,caret:3),.init(id:20,anchor:6,caret:6)]
        let noForward=try XCTUnwrap(PatchLineEditing.deleteSelections(text:text,selections:ends,primarySelectionID:20,rectangular:true,backwards:false))
        XCTAssertEqual(noForward.resultText,text)
    }
    func testRectangularPasteRowsAndMeasuredInsertionReceiptsPreserveExistingEndings() throws {
        XCTAssertEqual(PatchLineEditing.rectanglePasteRows("a\r\n\r\nb\rc\n\r\n"),["a","","b","c"])
        XCTAssertEqual(PatchLineEditing.rectanglePasteRows("\r\n"),[])
        let paste=try XCTUnwrap(PatchLineEditing.planRectanglePaste(text:"abc\r\nx\rtail",insertions:[
            .init(offset:2,text:"A"),.init(offset:6,prefix:" ",text:"B"),.init(offset:9,text:"C"),
            .init(offset:11,prefix:"\n  ",text:"D")],primarySelectionID:9,caret:2))
        XCTAssertEqual(paste.resultText,"abAc\r\nx B\rtaCil\n  D")
        XCTAssertEqual(paste.selections,[.init(id:9,anchor:2,caret:2)])
        XCTAssertFalse(paste.rectangular)
    }
    func testInvalidAmbiguousRangesIDsAndPasteReceiptsRejectAtomically() {
        XCTAssertNil(PatchLineEditing.plan(text:"abc",selections:[.init(id:0,anchor:0,caret:2),.init(id:1,anchor:1,caret:3)],primarySelectionID:1,rectangular:true,command:.duplicate))
        XCTAssertNil(PatchLineEditing.plan(text:"abc",selections:[.init(id:0,anchor:0,caret:1),.init(id:0,anchor:2,caret:3)],primarySelectionID:0,rectangular:true,command:.duplicate))
        XCTAssertNil(PatchLineEditing.plan(text:"😀",selections:[.init(id:0,anchor:1,caret:2)],primarySelectionID:0,rectangular:true,command:.duplicate))
        XCTAssertNil(PatchLineEditing.planRectanglePaste(text:"abc",insertions:[.init(offset:1,prefix:"payload",text:"x")],primarySelectionID:0,caret:1))
        XCTAssertNil(PatchLineEditing.planRectanglePaste(text:"abc",insertions:[.init(offset:1,text:"x\ny")],primarySelectionID:0,caret:1))
    }
    func testLargeRectangleDuplicateAppliesAsOneByteTransactionAndRestoresAllRowIDs() throws {
        let count=2000,text=String(repeating:"abc\r\n",count:count)
        let selected=(0..<count).map {PatchLineEditSelection(id:$0,anchor:$0*5+1,caret:$0*5+2)}
        let transaction=try XCTUnwrap(PatchLineEditing.plan(text:text,selections:selected,primarySelectionID:count-1,rectangular:true,command:.duplicate))
        XCTAssertEqual(transaction.resultText,String(repeating:"abbc\r\n",count:count))
        XCTAssertEqual(transaction.selections.first,.init(id:0,anchor:1,caret:2))
        XCTAssertEqual(transaction.selections.last,.init(id:count-1,anchor:(count-1)*6+1,caret:(count-1)*6+2))
        var buffer=UnifiedDiffEditBuffer(document:UnifiedDiffDocument(bytes:Data(text.utf8)))
        let before=buffer
        XCTAssertTrue(try buffer.apply(transaction))
        XCTAssertEqual(try buffer.snapshot().bytes,Data(transaction.resultText.utf8))
        let after=buffer
        buffer=before;XCTAssertEqual(try buffer.snapshot().bytes,Data(text.utf8))
        buffer=after;XCTAssertEqual(try buffer.snapshot().bytes,Data(transaction.resultText.utf8))
    }
    func testPrimaryReplacementKeepsRegionalDraftEditableUntilSave() throws {
        var buffer=UnifiedDiffEditBuffer(document:UnifiedDiffDocument(bytes:Data("a\nb".utf8),sourceEncoding:.windows1252))
        let selected=[PatchLineEditSelection(id:10,anchor:0,caret:1),.init(id:20,anchor:2,caret:3)]
        let typing=try XCTUnwrap(PatchLineEditing.replacePrimarySelection(text:buffer.text,selections:selected,primarySelectionID:20,replacement:"雪"))
        XCTAssertTrue(try buffer.apply(typing));XCTAssertEqual(buffer.text,"a\n雪")
        XCTAssertThrowsError(try buffer.snapshot())
        let draft=buffer
        let deletion=try XCTUnwrap(PatchLineEditing.deleteSelections(text:buffer.text,selections:typing.selections,primarySelectionID:20,rectangular:false,backwards:true))
        XCTAssertTrue(try buffer.apply(deletion));XCTAssertEqual(try buffer.snapshot().bytes,Data("a\n".utf8))
        buffer=draft;XCTAssertEqual(buffer.text,"a\n雪");XCTAssertThrowsError(try buffer.snapshot())
    }
    func testCompositeBytePacketsDuplicateCutPasteAndExactUndoValueSnapshots() throws {
        let bytes=Data([0xff,0x98,13,10,0xfe,0x97,13])
        // Use a real carrier projection, retaining opaque bytes as their scalars.
        let shown=String(String.UnicodeScalarView(bytes.map {UnicodeScalar($0)}))
        let document=UnifiedDiffDocument(bytes:bytes,legacy:.windows1252,encoding:.utf8,
            presentation:UnifiedDiffBytePresentation(prefix:Data(),pieces:[.init(text:shown,bytes:bytes,mapping:.carrier)]))
        var buffer=UnifiedDiffEditBuffer(document:document)
        let selected=[PatchLineEditSelection(id:10,anchor:0,caret:1),.init(id:20,anchor:5,caret:4)]
        let duplicate=try XCTUnwrap(PatchLineEditing.plan(text:shown,selections:selected,primarySelectionID:20,rectangular:true,command:.duplicate))
        let before=buffer
        XCTAssertTrue(try buffer.apply(duplicate))
        XCTAssertEqual(try buffer.snapshot().bytes,Data([0xff,0xff,0x98,13,10,0xfe,0xfe,0x97,13]))
        let after=buffer
        let cut=try XCTUnwrap(PatchLineEditing.cutSelections(text:buffer.text,selections:duplicate.selections,primarySelectionID:20,rectangular:true))
        XCTAssertTrue(try buffer.apply(cut));XCTAssertEqual(try buffer.snapshot().bytes,bytes)
        buffer=before;XCTAssertEqual(try buffer.snapshot().bytes,bytes)
        buffer=after;XCTAssertEqual(try buffer.snapshot().bytes,Data([0xff,0xff,0x98,13,10,0xfe,0xfe,0x97,13]))
    }
}
