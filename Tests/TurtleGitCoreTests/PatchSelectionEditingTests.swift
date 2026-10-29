// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class PatchSelectionEditingTests:XCTestCase {
    private func plan(_ text:String,_ anchor:Int,_ caret:Int,_ command:PatchSelectionEditCommand)throws->PatchLineEditPlan {
        try XCTUnwrap(PatchSelectionEditing.plan(text:text,selections:[.init(id:7,anchor:anchor,caret:caret)],primarySelectionID:7,rectangular:false,command:command))
    }
    func testPinnedCaseMappingExpansionsLiteralDecompositionAndDirection()throws {
        let text="Straße İ Σς ﬃ e\u{301}"
        let upper=try plan(text,text.utf16.count,0,.upperCase)
        XCTAssertEqual(upper.resultText,"STRASSE İ ΣΣ FFI E\u{301}")
        XCTAssertEqual(upper.selectionAnchor,upper.resultText.utf16.count);XCTAssertEqual(upper.selectionCaret,0)
        let lower=try plan(text,0,text.utf16.count,.lowerCase)
        XCTAssertEqual(lower.resultText,"straße i\u{307} σς ﬃ e\u{301}","Source maps scalars without locale, normalization or contextual final-sigma substitution")
        XCTAssertEqual(lower.selectionRange,NSRange(location:0,length:lower.resultText.utf16.count))
        let empty=try plan("word",2,2,.upperCase)
        XCTAssertFalse(empty.hasReplacement);XCTAssertEqual(empty.selectionCaret,2)
    }
    func testCaseConvertsEverySelectedRowAndRetainsUnselectedPackets()throws {
        let text="one ß\nKEEP\ntwo İ"
        let last=(text as NSString).range(of:"two İ").location
        let rows=[PatchLineEditSelection(id:1,anchor:0,caret:5),.init(id:9,anchor:text.utf16.count,caret:last)]
        let changed=try XCTUnwrap(PatchSelectionEditing.plan(text:text,selections:rows,primarySelectionID:9,rectangular:true,command:.upperCase,rectangleAnchor:0,rectangleCaret:text.utf16.count))
        XCTAssertEqual(changed.resultText,"ONE SS\nKEEP\nTWO İ")
        XCTAssertEqual(changed.selections.map(\.id),[1,9]);XCTAssertTrue(changed.selections[1].isReversed)
        XCTAssertEqual(changed.selections.map{$0.range.length},[6,5],"Expanded rows retain distinct source ranges rather than reflowing a uniform rectangle")
        XCTAssertEqual(changed.primarySelectionID,9);XCTAssertTrue(changed.rectangular);XCTAssertTrue(changed.rectangleRowsExplicit)
        XCTAssertTrue(changed.segments.contains{if case let .source(r)=$0{return (text as NSString).substring(with:r).contains("KEEP")};return false},"Unselected source must not be re-encoded")
    }
    func testDeletionUsesPrimaryCaretWithAsymmetricAnchorAndDropsAdditionalRows()throws {
        let text="alpha beta gamma"
        let left=try plan(text,0,10,.deleteWordLeft)
        XCTAssertEqual(left.resultText,"alpha  gamma");XCTAssertEqual(left.selectionAnchor,0);XCTAssertEqual(left.selectionCaret,6)
        let right=try plan(text,0,6,.deleteWordRight)
        XCTAssertEqual(right.resultText,"alpha gamma");XCTAssertEqual(right.selectionAnchor,6);XCTAssertEqual(right.selectionCaret,6)
        let rows=[PatchLineEditSelection(id:1,anchor:0,caret:3),.init(id:8,anchor:6,caret:10)]
        let deleted=try XCTUnwrap(PatchSelectionEditing.plan(text:text,selections:rows,primarySelectionID:8,rectangular:true,command:.deleteWordLeft,rectangleAnchor:0,rectangleCaret:10))
        XCTAssertEqual(deleted.resultText,"alpha  gamma");XCTAssertEqual(deleted.selections.count,1);XCTAssertEqual(deleted.selections[0].id,8)
        XCTAssertEqual(deleted.selections[0].anchor,6);XCTAssertEqual(deleted.selections[0].caret,6)
        XCTAssertTrue(deleted.rectangular);XCTAssertTrue(deleted.rectangleRowsExplicit)
        let caseAfter=try XCTUnwrap(PatchSelectionEditing.plan(text:deleted.resultText,selections:deleted.selections,primarySelectionID:8,rectangular:true,command:.upperCase,rectangleAnchor:deleted.rectangleAnchor,rectangleCaret:deleted.rectangleCaret,rectangleRowsExplicit:true))
        XCTAssertTrue(caseAfter.rectangleRowsExplicit);XCTAssertEqual(caseAfter.selections.count,1)
    }
    func testWordClassesSeparatePunctuationUnderscoreWhitespaceUnicodeAndNewline()throws {
        XCTAssertEqual(try plan("a... __word42 !",1,1,.deleteWordRight).resultText,"a__word42 !")
        XCTAssertEqual(try plan("a... __word42 !",5,5,.deleteWordLeft).resultText,"a__word42 !")
        XCTAssertEqual(try plan("é雪_42! next",0,0,.deleteWordRight).resultText,"! next")
        XCTAssertEqual(try plan("é雪_42! next",6,6,.deleteWordRight).resultText,"é雪_42!next")
        let unicodeSpace="a\u{00a0}\u{200b}b"
        XCTAssertEqual(try plan(unicodeSpace,0,0,.deleteWordRight).resultText,"b")
        XCTAssertEqual(try plan("a\r\nb",1,1,.deleteWordRight).resultText,"ab","Word deletion can consume the newline class as a unit")
        XCTAssertEqual(try plan("a\r\nb",3,3,.deleteWordLeft).resultText,"ab")
        XCTAssertEqual(try plan("a\u{2028}b",1,1,.deleteWordRight).resultText,"ab","Source Unicode line separators form their own class")
    }
    func testLineDeletionKeepsMixedEndingsAndNeverJoinsAtLineBoundary()throws {
        let text="abc\r\ndef\rghi\njkl"
        XCTAssertEqual(try plan(text,1,1,.deleteLineRight).resultText,"a\r\ndef\rghi\njkl")
        XCTAssertEqual(try plan(text,3,3,.deleteLineRight).resultText,text)
        XCTAssertEqual(try plan(text,5,5,.deleteLineLeft).resultText,text)
        XCTAssertEqual(try plan(text,7,7,.deleteLineLeft).resultText,"abc\r\nf\rghi\njkl")
        XCTAssertEqual(try plan(text,text.utf16.count,text.utf16.count,.deleteLineRight).resultText,text)
        XCTAssertFalse(try plan("",0,0,.deleteLineLeft).hasReplacement)
    }
    func testBytePlansPreserveOpaqueAndUnchangedLegacyFragmentsAcrossUndoSnapshots()throws {
        let bytes=Data([0xff,0,32,0x61,0xdf,32,0xfe,10])
        let document=UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:.windows1252)
        var buffer=UnifiedDiffEditBuffer(document:document)
        let original=buffer
        let at=(buffer.text as NSString).range(of:"aß").location
        let changed=try plan(buffer.text,at,at+2,.upperCase)
        XCTAssertTrue(try buffer.apply(changed))
        XCTAssertEqual(try buffer.snapshot().bytes,Data([0xff,0,32,65,83,83,32,0xfe,10]))
        let edited=buffer
        buffer=original;XCTAssertEqual(try buffer.snapshot().bytes,bytes)
        buffer=edited;XCTAssertEqual(try buffer.snapshot().bytes,Data([0xff,0,32,65,83,83,32,0xfe,10]))
        let deletion=try plan(buffer.text,at,at,.deleteWordRight)
        XCTAssertTrue(try buffer.apply(deletion));XCTAssertEqual(try buffer.snapshot().bytes,Data([0xff,0,32,0xfe,10]))
    }
    func testDecomposedUTF8CasePlanAppliesToExactRetainedBufferBytes()throws {
        let text="Straße e\u{301}\r\nOTHER\n",bytes=Data(text.utf8)
        var buffer=UnifiedDiffEditBuffer(document:UnifiedDiffDocument(bytes:bytes))
        XCTAssertTrue(buffer.text.utf8.elementsEqual(text.utf8),"Input display must retain the literal decomposed UTF-8")
        let changed=try plan(buffer.text,0,9,.upperCase)
        let expected="STRASSE E\u{301}\r\nOTHER\n"
        XCTAssertTrue(changed.resultText.utf8.elementsEqual(expected.utf8),"Plan must preserve the combining scalar, not merely canonical String equality")
        let diagnostic="segments=\(changed.segments), sourceUTF8=\(Array(buffer.text.utf8)), resultUTF8=\(Array(changed.resultText.utf8)), selection=\(changed.selectionRange)"
        do {XCTAssertTrue(try buffer.apply(changed),diagnostic)}
        catch {XCTFail("Actual byte-plan application failed: \(error); \(diagnostic)");throw error}
        XCTAssertEqual(try buffer.snapshot().bytes,Data(expected.utf8),diagnostic)
        XCTAssertEqual(changed.selectionAnchor,0);XCTAssertEqual(changed.selectionCaret,10)
    }
    func testLargeCaseConversionKeepsLiteralPacketsAndEveryDirectionalRow()throws {
        let prefix="opaque:\0\u{fffd} ",block=String(repeating:"aß",count:5000),suffix="\r\nKEEP 雪\n"
        let text=prefix+block+suffix,start=prefix.utf16.count,end=start+block.utf16.count
        let changed=try plan(text,end,start,.upperCase)
        XCTAssertEqual(changed.resultText,prefix+String(repeating:"ASS",count:5000)+suffix)
        XCTAssertEqual(changed.selectionAnchor,start+15000);XCTAssertEqual(changed.selectionCaret,start)
        let sourcePackets=changed.segments.compactMap {segment->String? in if case let .source(r)=segment {return (text as NSString).substring(with:r)};return nil}
        XCTAssertEqual(sourcePackets.joined(),prefix+suffix,"Both untouched packets retain source provenance")
        var rows:[PatchLineEditSelection]=[]
        let many=String(repeating:"ß\n",count:2000)
        for row in 0..<2000 {rows.append(.init(id:row,anchor:row*2+1,caret:row*2))}
        let rectangle=try XCTUnwrap(PatchSelectionEditing.plan(text:many,selections:rows,primarySelectionID:1999,rectangular:true,command:.upperCase))
        XCTAssertEqual(rectangle.resultText,String(repeating:"SS\n",count:2000))
        XCTAssertEqual(rectangle.selections.count,2000);XCTAssertTrue(rectangle.rectangleRowsExplicit)
        for (row,selection) in rectangle.selections.enumerated() {
            XCTAssertEqual(selection.id,row);XCTAssertEqual(selection.anchor,row*3+2);XCTAssertEqual(selection.caret,row*3)
        }
    }
    func testInvalidSelectionAndNativeComposedBoundariesRefuseWholePlan()throws {
        let text="e\u{301}🐢\r\nx"
        for caret in [-1,1,3,5,text.utf16.count+1] {
            XCTAssertNil(PatchSelectionEditing.plan(text:text,selections:[.init(id:0,anchor:0,caret:caret)],primarySelectionID:0,rectangular:false,command:.deleteWordRight))
        }
        XCTAssertNil(PatchSelectionEditing.plan(text:"abc",selections:[.init(id:0,anchor:0,caret:2),.init(id:1,anchor:1,caret:3)],primarySelectionID:0,rectangular:false,command:.upperCase))
        XCTAssertNil(PatchSelectionEditing.plan(text:"abc",selections:[.init(id:0,anchor:0,caret:1)],primarySelectionID:7,rectangular:false,command:.lowerCase))
    }
}
