// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class PatchCaretEditingTests:XCTestCase {
    private func next(_ text:String,_ at:Int,_ backwards:Bool=false)throws->Int {
        try XCTUnwrap(PatchCaretEditing.wordPart(text:text,caret:at,backwards:backwards))
    }
    private func overtype(_ text:String,_ anchor:Int,_ caret:Int,_ replacement:String)throws->PatchLineEditPlan {
        try XCTUnwrap(PatchCaretEditing.overtype(text:text,selections:[.init(id:7,anchor:anchor,caret:caret)],primarySelectionID:7,replacement:replacement))
    }
    func testPinnedASCIIWordPartsAcronymsDigitsAndSeparators()throws {
        let text="HTTPServer42__name.foo !!\t bar"
        var at=0,visited=[0]
        while at<text.utf16.count {at=try next(text,at);visited.append(at)}
        XCTAssertEqual(visited,[0,4,10,12,18,19,22,23,25,27,30])
        XCTAssertEqual(try next(text,18,true),14)
        XCTAssertEqual(try next(text,14,true),10) // separators attach to preceding part on left
        XCTAssertEqual(try next(text,10,true),4)
        XCTAssertEqual(try next(text,4,true),0)
        XCTAssertEqual(try next("__foo",0),5)
        XCTAssertEqual(try next("foo__",5,true),0)
        XCTAssertEqual(try next("a_B",1),3)
        XCTAssertEqual(try next("a_B",3,true),2)
    }
    func testLineEndWhitespacePunctuationAndDocumentBoundaries()throws {
        let text="a\r\n\t b!?__c"
        XCTAssertEqual(try next(text,1),5)
        XCTAssertEqual(try next(text,5,true),1)
        XCTAssertEqual(try next(text,6),10) // punctuation run, including underscores
        XCTAssertEqual(try next(text,10),11)
        XCTAssertEqual(try next("",0),0);XCTAssertEqual(try next("",0,true),0)
        XCTAssertEqual(try next(text,0,true),0)
        XCTAssertEqual(try next(text,text.utf16.count),text.utf16.count)
        XCTAssertNil(PatchCaretEditing.wordPart(text:text,caret:2,backwards:false)) // CRLF interior
        XCTAssertNil(PatchCaretEditing.wordPart(text:text,caret:2,backwards:true))
        XCTAssertNil(PatchCaretEditing.wordPart(text:text,caret:-1,backwards:true))
    }
    func testUnicodeIsLiteralAndNativeCaretsRespectComposedCharacters()throws {
        let text="e\u{301}HTTP雪🦎猫42"
        XCTAssertEqual(try next(text,0),2)
        XCTAssertEqual(try next(text,2,true),0)
        XCTAssertEqual(try next(text,6),10)
        XCTAssertEqual(try next(text,10,true),6)
        XCTAssertNil(PatchCaretEditing.wordPart(text:text,caret:1,backwards:false))
        XCTAssertNil(PatchCaretEditing.wordPart(text:text,caret:8,backwards:true))
        XCTAssertEqual(try next("éÉ😀",0),4)
        XCTAssertEqual(try next("éÉ😀",4,true),0)
    }
    func testOvertypeReplacesOneComposedCharacterAndSelectionExactly()throws {
        let text="a👩‍💻e\u{301}z\r\ntail"
        let emoji=try overtype(text,1,1,"Q")
        XCTAssertEqual(emoji.resultText,"aQe\u{301}z\r\ntail")
        XCTAssertEqual(emoji.selectionCaret,2)
        let combining=try overtype("e\u{301}x",0,0,"雪")
        XCTAssertEqual(combining.resultText,"雪x")
        XCTAssertEqual(try overtype("abcdef",4,1,"XY").resultText,"aXYef")
        XCTAssertEqual(try overtype("abc",1,1,"XY").resultText,"aXYc") // one source character, not one per input scalar
    }
    func testOvertypeNeverConsumesExistingLineEndAndNewlineInserts()throws {
        for ending in ["\r\n","\r","\n"] {
            XCTAssertEqual(try overtype("a"+ending+"b",1,1,"X").resultText,"aX"+ending+"b")
        }
        XCTAssertEqual(try overtype("ab",1,1,"\n").resultText,"a\nb")
        XCTAssertEqual(try overtype("ab",2,2,"X").resultText,"abX")
        XCTAssertEqual(try overtype("",0,0,"X").resultText,"X")
        XCTAssertNil(PatchCaretEditing.overtype(text:"😀",selections:[.init(id:0,anchor:1,caret:1)],primarySelectionID:0,replacement:"X"))
        for (anchor,caret) in [(2,2),(0,2),(2,4),(4,2)] {
            XCTAssertNil(PatchCaretEditing.overtype(text:"a\r\nb",selections:[.init(id:0,anchor:anchor,caret:caret)],primarySelectionID:0,replacement:"X"),"CRLF interior endpoint must not be admitted")
        }
    }
    func testOvertypeFiltersAdditionalSelectionsAndPreservesOpaqueByteFragments()throws {
        let bytes=Data([0xff,0,65,13,10,0xfe,90])
        let document=UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:.windows1252)
        var buffer=UnifiedDiffEditBuffer(document:document)
        let original=buffer
        let index=PatchLineIndex(text:buffer.text)
        let last=try XCTUnwrap(index.lineStarts.last)
        let plan=try XCTUnwrap(PatchCaretEditing.overtype(text:buffer.text,selections:[.init(id:0,anchor:2,caret:2),.init(id:1,anchor:last,caret:last)],primarySelectionID:0,replacement:"B"))
        XCTAssertEqual(plan.selections.count,1);XCTAssertEqual(plan.primarySelectionID,0)
        XCTAssertTrue(try buffer.apply(plan))
        XCTAssertEqual(try buffer.snapshot().bytes,Data([0xff,0,66,13,10,0xfe,90]))
        let changed=buffer
        buffer=original;XCTAssertEqual(try buffer.snapshot().bytes,bytes)
        buffer=changed;XCTAssertEqual(try buffer.snapshot().bytes,Data([0xff,0,66,13,10,0xfe,90]))
    }
}
