// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class PatchLineEditingTests: XCTestCase {
    private func plan(_ text:String,_ a:Int,_ c:Int,_ command:PatchLineEditCommand,tab:Int=4,useTabs:Bool=true)throws->PatchLineEditPlan {
        try XCTUnwrap(PatchLineEditing.plan(text:text,anchor:a,caret:c,command:command,tabWidth:tab,useTabs:useTabs))
    }
    func testCopyCutIncludesExclusiveEndpointLineUnlikeIndent() throws {
        let text="one\r\ntwo\nthree"
        let copy=try plan(text,0,5,.copyLines)
        XCTAssertEqual(copy.clipboardText,"one\r\ntwo\n");XCTAssertFalse(copy.hasReplacement)
        let cut=try plan(text,5,0,.cutLines)
        XCTAssertEqual(cut.resultText,"three");XCTAssertEqual(cut.selectionRange,NSRange(location:0,length:0))
        let indent=try plan(text,0,5,.indent)
        XCTAssertEqual(indent.resultText,"\tone\r\ntwo\nthree")
        XCTAssertEqual(indent.selectionAnchor,0);XCTAssertEqual(indent.selectionCaret,6)
    }
    func testDeleteAdjustsEachEndpointAndOnlyDeletesCaretLine() throws {
        let deletion=try plan("aa\nbb\ncc",8,4,.deleteLine)
        XCTAssertEqual(deletion.resultText,"aa\ncc")
        XCTAssertEqual(deletion.selectionAnchor,5);XCTAssertEqual(deletion.selectionCaret,3)
        XCTAssertFalse(try plan("a\n",0,2,.deleteLine).hasReplacement)
    }
    func testDuplicateSelectionAndCurrentLinePreserveOriginalSelectionAndTerminators() throws {
        let duplicate=try plan("abc\r\ndef",1,2,.duplicate)
        XCTAssertEqual(duplicate.resultText,"abbc\r\ndef")
        XCTAssertEqual(duplicate.selectionRange,NSRange(location:1,length:1))
        let line=try plan("abc\r\ndef",1,1,.duplicate)
        XCTAssertEqual(line.resultText,"abc\nabc\r\ndef");XCTAssertEqual(line.selectionCaret,1)
        XCTAssertEqual(try plan("",0,0,.duplicate).resultText,"\n")
        XCTAssertEqual(try plan("abc",3,3,.duplicate).selectionCaret,3)
    }
    func testTransposeContentsPreservesMixedEndingSlotsAndFinalEmptyLine() throws {
        let swap=try plan("first\r\nsecond\nlast",10,10,.transpose)
        XCTAssertEqual(swap.resultText,"second\r\nfirst\nlast")
        XCTAssertEqual(swap.selectionCaret,8)
        XCTAssertEqual(try plan("last\r\n",6,6,.transpose).resultText,"\r\nlast")
        XCTAssertFalse(try plan("first",0,0,.transpose).hasReplacement)
    }
    func testMultilineIndentCanonicalizesColumnsSkipsOnlyEmptyContentAndPreservesDirection() throws {
        let text="  a\r\n\n \tb\rtail"
        let indented=try plan(text,text.utf16.count,0,.indent)
        XCTAssertEqual(indented.resultText,"\t  a\r\n\n\t\tb\r\ttail")
        XCTAssertGreaterThan(indented.selectionAnchor,indented.selectionCaret)
        let dedented=try plan(indented.resultText,indented.resultText.utf16.count,0,.dedent)
        XCTAssertEqual(dedented.resultText,"  a\r\n\n\tb\rtail")
        let spaces=try plan("\tx\n",0,2,.indent,tab:4,useTabs:false)
        XCTAssertEqual(spaces.resultText,"        x\n")
    }
    func testTabDeletesSelectionThenAlignsIndentAndBackTabCanOnlyMoveCaret() throws {
        let tab=try plan("   word",1,2,.tab)
        XCTAssertEqual(tab.resultText,"\tword");XCTAssertEqual(tab.selectionCaret,1)
        let insert=try plan("word",2,2,.tab)
        XCTAssertEqual(insert.resultText,"wo\trd");XCTAssertEqual(insert.selectionCaret,3)
        let back=try plan("word more",7,7,.backTab)
        XCTAssertEqual(back.resultText,"word more");XCTAssertEqual(back.selectionCaret,4)
        let dedent=try plan("\t  word",2,2,.backTab)
        XCTAssertEqual(dedent.resultText,"  word");XCTAssertEqual(dedent.selectionCaret,2)
    }
    func testExplicitMenuIndentAtLineStartAndLargeBlockOneTransaction() throws {
        let one=try plan("value",0,0,.indent)
        XCTAssertEqual(one.resultText,"\tvalue")
        XCTAssertEqual(try plan("value",0,0,.tab).resultText,"\tvalue")
        let wide=try plan("value",0,0,.tab,tab:1000,useTabs:false)
        XCTAssertEqual(wide.resultText,String(repeating:" ",count:1000)+"value")
        let text=String(repeating:" a\r\n\n",count:2000)
        let block=try plan(text,0,text.utf16.count,.indent)
        XCTAssertEqual(block.resultText,String(repeating:"\t a\r\n\n",count:2000))
        XCTAssertEqual(block.selectionCaret,block.resultText.utf16.count)
        var buffer=UnifiedDiffEditBuffer(document:UnifiedDiffDocument(bytes:Data(text.utf8)))
        let before=buffer
        XCTAssertTrue(try buffer.apply(block))
        XCTAssertEqual(try buffer.snapshot().bytes,Data(block.resultText.utf8))
        let after=buffer
        buffer=before;XCTAssertEqual(try buffer.snapshot().bytes,Data(text.utf8))
        buffer=after;XCTAssertEqual(try buffer.snapshot().bytes,Data(block.resultText.utf8))
    }
    func testInvalidUTF16OrPreferencesAreRejectedWithoutPartialPlan() {
        XCTAssertNil(PatchLineEditing.plan(text:"😀",anchor:1,caret:2,command:.duplicate))
        XCTAssertNil(PatchLineEditing.plan(text:"x",anchor:-1,caret:0,command:.cutLines))
        XCTAssertNil(PatchLineEditing.plan(text:"x",anchor:0,caret:2,command:.cutLines))
        XCTAssertNil(PatchLineEditing.plan(text:"x",anchor:0,caret:0,command:.tab,tabWidth:0))
        XCTAssertNil(PatchLineEditing.plan(text:"x",anchor:0,caret:0,command:.duplicate,lineEnding:"bad"))
    }
    func testMixedLegacyAndOpaqueSourcePacketsMoveWithoutEncoding() throws {
        let first=Data("+日本語\r\n".utf8),second=Data([45,0xe8,0xf1,0xf5,0xee,0xe4,0xed,0xfb,0xe9,10]),tail=Data([32,0x98,0,0xff,13])
        let document=UnifiedDiffDocument(bytes:first+second+tail,displayLegacyEncoding:.windows1251)
        var buffer=UnifiedDiffEditBuffer(document:document)
        let offset=PatchLineIndex(text:buffer.text).lineStarts[1]
        let transaction=try plan(buffer.text,offset,offset,.transpose)
        XCTAssertTrue(try buffer.apply(transaction))
        XCTAssertEqual(try buffer.snapshot().bytes,Data(second.dropLast())+Data([13,10])+Data(first.dropLast(2))+Data([10])+tail)
        let last=PatchLineIndex(text:buffer.text).lineStarts[2]
        let duplicate=try plan(buffer.text,last,last,.duplicate)
        XCTAssertTrue(try buffer.apply(duplicate))
        var expected:Data=Data(second.dropLast())
        expected.append(contentsOf:[13,10])
        expected.append(contentsOf:first.dropLast(2))
        expected.append(10)
        expected.append(contentsOf:tail.dropLast())
        expected.append(10)
        expected.append(tail)
        XCTAssertEqual(try buffer.snapshot().bytes,expected)
    }
    func testByteOnlyTransposeSurvivesTypingUndoAndValueSnapshotUndoRedo() throws {
        let text="�\n�\n",bytes=Data([0xff,10,0xfe,10])
        let presentation=UnifiedDiffBytePresentation(prefix:Data(),pieces:[.init(text:text,bytes:bytes,mapping:.lossyUTF8)])
        let document=UnifiedDiffDocument(bytes:bytes,legacy:.windows1252,encoding:.utf8,presentation:presentation)
        var buffer=UnifiedDiffEditBuffer(document:document)
        let before=buffer,transaction=try plan(text,2,2,.transpose)
        XCTAssertFalse(transaction.changesText)
        XCTAssertTrue(try buffer.apply(transaction));XCTAssertTrue(try buffer.isModified())
        let after=buffer
        XCTAssertEqual(buffer.text,text);XCTAssertEqual(try buffer.snapshot().bytes,Data([0xfe,10,0xff,10]))
        buffer.replaceText(text+"typed");buffer.replaceText(text)
        XCTAssertEqual(try buffer.snapshot().bytes,Data([0xfe,10,0xff,10]))
        buffer=before;XCTAssertFalse(try buffer.isModified());XCTAssertEqual(try buffer.snapshot().bytes,bytes)
        buffer=after;XCTAssertEqual(try buffer.snapshot().bytes,Data([0xfe,10,0xff,10]))
        buffer.markSaved(try buffer.snapshot());XCTAssertFalse(try buffer.isModified())
    }
    func testUnencodableRegionalDraftCanStillBeCutAndUndone() throws {
        let document=UnifiedDiffDocument(bytes:Data("safe\n".utf8),sourceEncoding:.windows1252)
        var buffer=UnifiedDiffEditBuffer(document:document)
        buffer.replaceText("safe\n雪")
        XCTAssertThrowsError(try buffer.snapshot())
        let draft=buffer
        XCTAssertTrue(try buffer.apply(plan(buffer.text,5,5,.deleteLine)))
        XCTAssertEqual(try buffer.snapshot().bytes,Data("safe\n".utf8))
        buffer=draft
        XCTAssertEqual(buffer.text,"safe\n雪");XCTAssertThrowsError(try buffer.snapshot())
    }
    func testUnsplittableOpaquePacketFailsAtomicallyButWholePacketCanDuplicate() throws {
        let bytes=Data([0x91,0x92]),text="opaque"
        let document=UnifiedDiffDocument(bytes:bytes,legacy:.windows1252,encoding:.utf8,
            presentation:UnifiedDiffBytePresentation(prefix:Data(),pieces:[.init(text:text,bytes:bytes,mapping:.unmapped)]))
        var buffer=UnifiedDiffEditBuffer(document:document)
        XCTAssertThrowsError(try buffer.apply(plan(text,1,3,.duplicate)))
        XCTAssertEqual(try buffer.snapshot().bytes,bytes);XCTAssertEqual(buffer.text,text)
        XCTAssertTrue(try buffer.apply(plan(text,0,text.utf16.count,.duplicate)))
        XCTAssertEqual(try buffer.snapshot().bytes,bytes+bytes)
    }
    func testBOMRetainedStalePlanRejectedAndUnchangedCommandNoMutation() throws {
        let bytes=Data([0xff,0xfe])+"a\r\nb".data(using:.utf16LittleEndian)!
        var buffer=UnifiedDiffEditBuffer(document:UnifiedDiffDocument(bytes:bytes))
        let stale=try plan(buffer.text,0,0,.duplicate)
        buffer.replaceText(buffer.text+"!")
        let before=try buffer.snapshot().bytes
        XCTAssertThrowsError(try buffer.apply(stale));XCTAssertEqual(try buffer.snapshot().bytes,before)
        let copy=try plan(buffer.text,0,0,.copyLines)
        XCTAssertFalse(try buffer.apply(copy))
        let duplicate=try plan(buffer.text,0,0,.duplicate)
        XCTAssertTrue(try buffer.apply(duplicate))
        XCTAssertEqual(try buffer.snapshot().bytes,Data([0xff,0xfe])+"a\na\r\nb!".data(using:.utf16LittleEndian)!)
    }
}
