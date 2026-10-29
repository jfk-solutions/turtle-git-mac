// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class PatchBoundaryNavigationTests:XCTestCase {
    private func target(_ text:String,_ caret:Int,_ boundary:PatchBoundary)throws->Int {
        try XCTUnwrap(PatchBoundaryNavigation.position(text:text,caret:caret,boundary:boundary))
    }
    func testSmartHomeTogglesOnlyASCIISpaceAndTabIndentation()throws {
        let text=" \t  word\r\n\t  \n\u{00a0} word"
        XCTAssertEqual(try target(text,7,.smartLineStart),4)
        XCTAssertEqual(try target(text,4,.smartLineStart),0)
        XCTAssertEqual(try target(text,0,.smartLineStart),4)
        let blank=(text as NSString).range(of:"\t  \n").location
        XCTAssertEqual(try target(text,blank,.smartLineStart),blank+3)
        XCTAssertEqual(try target(text,blank+3,.smartLineStart),blank)
        let nonASCII=(text as NSString).range(of:"\u{00a0}").location
        XCTAssertEqual(try target(text,text.utf16.count,.smartLineStart),nonASCII)
    }
    func testLogicalEndpointsKeepMixedEndingsAndUnicodeSeparatorsAsText()throws {
        let text="one\r\ntwo\rthree\nfour\n\rnext\u{2028}tail\n"
        let source=text as NSString
        for word in ["one","two","three","four","next\u{2028}tail"] {
            let range=source.range(of:word)
            XCTAssertEqual(try target(text,range.location,.lineEnd),NSMaxRange(range))
            XCTAssertEqual(try target(text,NSMaxRange(range),.smartLineStart),range.location)
        }
        let lfcr=source.range(of:"\n\r").location
        XCTAssertEqual(try target(text,lfcr+1,.lineEnd),lfcr+1,"LFCR contains an empty logical line")
        XCTAssertEqual(try target(text,source.length,.lineEnd),source.length)
        XCTAssertEqual(try target(text,source.length,.smartLineStart),source.length)
        XCTAssertEqual(try target(text,7,.documentStart),0)
        XCTAssertEqual(try target(text,7,.documentEnd),source.length)
        for boundary in PatchBoundary.allCases {XCTAssertEqual(try target("",0,boundary),0)}
    }
    func testPinnedWordClassesWithPunctuationControlsAndUnicode()throws {
        let text="é雪_42... \u{00a0}\u{200b}next\r\n\u{2028}🐢 end"
        let source=text as NSString
        let punctuation=source.range(of:"...").location
        let next=source.range(of:"next").location
        let newline=source.range(of:"\r\n").location
        let turtle=source.range(of:"🐢").location
        XCTAssertEqual(try target(text,0,.nextWord),punctuation)
        XCTAssertEqual(try target(text,punctuation,.nextWord),next)
        XCTAssertEqual(try target(text,next,.previousWord),punctuation)
        XCTAssertEqual(try target(text,next,.nextWord),newline)
        XCTAssertEqual(try target(text,newline,.nextWord),turtle,"Consecutive source newline classes include LS")
        XCTAssertEqual(try target(text,turtle,.previousWord),newline)
        XCTAssertEqual(try target(text,turtle,.nextWord),source.range(of:"end").location)
        XCTAssertEqual(try target("a\0\tb",0,.nextWord),3,"ASCII controls and tab use exact source space class")
        XCTAssertEqual(try target("a\0\tb",3,.previousWord),0)
    }
    func testNativeBoundariesRejectSplitCharactersAndNeverReturnSplitClusters()throws {
        let text="e\u{301} 🐢\r\nx"
        for boundary in PatchBoundary.allCases {
            for invalid in [-1,1,4,6,text.utf16.count+1] {
                XCTAssertNil(PatchBoundaryNavigation.position(text:text,caret:invalid,boundary:boundary))
            }
        }
        XCTAssertEqual(try target(text,0,.nextWord),3)
        XCTAssertEqual(try target(text,3,.nextWord),5)
        XCTAssertEqual(try target(text,7,.previousWord),5)
        // Source class transitions inside a grapheme are rounded outward rather
        // than leaving the caret between a base punctuation and its mark.
        XCTAssertEqual(try target("!\u{301} x",0,.nextWord),2)
        XCTAssertEqual(try target("!\u{301} x",2,.previousWord),0)
        XCTAssertEqual(try target(" \u{301}word",0,.smartLineStart),2)
        XCTAssertEqual(try target(" \u{301}word",2,.smartLineStart),0,"Rounded native indentation endpoint must still toggle")
    }
    func testSharedDeletionUsesTheSameTargetsAndPreservesOpaqueSourceBytes()throws {
        let bytes=Data([0xff,0,32,0x61,0xdf,32,0xfe,13,10])
        let document=UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:.windows1252)
        var buffer=UnifiedDiffEditBuffer(document:document)
        let caret=(buffer.text as NSString).range(of:"aß").location
        let end=try target(buffer.text,caret,.nextWord)
        XCTAssertEqual(try buffer.snapshot().bytes,bytes,"Navigation must not rewrite opaque or legacy packets")
        let plan=try XCTUnwrap(PatchSelectionEditing.plan(text:buffer.text,selections:[.init(id:1,anchor:caret,caret:caret)],primarySelectionID:1,rectangular:false,command:.deleteWordRight))
        XCTAssertEqual(plan.selectionCaret,caret)
        XCTAssertEqual(end,caret+3)
        XCTAssertTrue(try buffer.apply(plan))
        XCTAssertEqual(try buffer.snapshot().bytes,Data([0xff,0,32,0xfe,13,10]))
    }
    func testLongDocumentNavigationUsesLocalContextAtBothEnds()throws {
        let prefix=String(repeating:"unchanged payload\n",count:10000)
        let text=prefix+"alpha... \tβeta tail\n"+prefix
        let start=prefix.utf16.count
        XCTAssertEqual(try target(text,start,.nextWord),start+5)
        XCTAssertEqual(try target(text,start+5,.nextWord),start+10)
        XCTAssertEqual(try target(text,start+10,.previousWord),start+5)
        XCTAssertEqual(try target(text,start+14,.nextWord),start+15)
        XCTAssertEqual(try target(text,0,.previousWord),0)
        XCTAssertEqual(try target(text,text.utf16.count,.nextWord),text.utf16.count)
    }
}
