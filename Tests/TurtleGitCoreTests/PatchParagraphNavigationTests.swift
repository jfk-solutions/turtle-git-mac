// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class PatchParagraphNavigationTests:XCTestCase {
    private func move(_ text:String,_ at:Int,_ backwards:Bool=false)throws->Int {
        try XCTUnwrap(PatchParagraphNavigation.position(text:text,caret:at,backwards:backwards))
    }
    private func offset(_ needle:String,_ text:String)->Int {(text as NSString).range(of:needle).location}
    func testLogicalBlocksAcrossLFCRAndCRLFUseCurrentCaretNotSelectionBoundary()throws {
        for ending in ["\n","\r","\r\n"] {
            let text=["one"," two"," \t","beta","","last"].joined(separator:ending)
            let beta=offset("beta",text),last=offset("last",text)
            XCTAssertEqual(try move(text,2,true),0)
            XCTAssertEqual(try move(text,2),beta)
            XCTAssertEqual(try move(text,beta,true),0,"Previous at block start enters the preceding block")
            XCTAssertEqual(try move(text,beta+2,true),beta,"Previous inside a block reaches its own start")
            XCTAssertEqual(try move(text,beta),last)
            XCTAssertEqual(try move(text,last,true),beta)
            XCTAssertEqual(try move(text,last),text.utf16.count)
            XCTAssertEqual(try move(text,text.utf16.count),text.utf16.count)
        }
    }
    func testOnlyASCIISpaceAndTabMakeASeparatorLine()throws {
        for content in ["\u{000b}","\u{000c}","\u{0085}","\u{00a0}","\u{2028}","\u{2029}","\0","雪"] {
            let text="first\n"+content+"\nsecond\n\nlast"
            XCTAssertEqual(try move(text,0),offset("last",text),"Non-space/tab source must stay in the same block")
            XCTAssertEqual(try move(text,offset("second",text)+1,true),0)
        }
        for separator in [""," ","\t"," \t\t "] {
            let text="first\n"+separator+"\nsecond"
            XCTAssertEqual(try move(text,0),offset("second",text))
            XCTAssertEqual(try move(text,offset("second",text),true),0)
        }
    }
    func testMixedEndingsLeadingAndTrailingBlankLinesAndEmptyDocument()throws {
        let text="\r\n\t \rone\n\rtwo\r\n \t\nlast\r"
        let one=offset("one",text),two=offset("two",text),last=offset("last",text)
        XCTAssertEqual(try move(text,0),one)
        XCTAssertEqual(try move(text,one,true),0)
        XCTAssertEqual(try move(text,one),two,"LFCR is two line endings with an empty intervening line")
        XCTAssertEqual(try move(text,two),last)
        XCTAssertEqual(try move(text,text.utf16.count,true),last)
        XCTAssertEqual(try move(text,text.utf16.count),text.utf16.count)
        for blank in [""," ","\t\r\n\r\n"] {
            XCTAssertEqual(try move(blank,0,true),0)
            XCTAssertEqual(try move(blank,0),blank.utf16.count)
        }
        XCTAssertEqual(try move("a\n\rb",0),3)
    }
    func testNativeCaretSafetyRejectsComposedAndCRLFInteriors()throws {
        let text="e\u{301}🐢\r\n\n雪"
        XCTAssertNil(PatchParagraphNavigation.position(text:text,caret:-1,backwards:false))
        XCTAssertNil(PatchParagraphNavigation.position(text:text,caret:text.utf16.count+1,backwards:true))
        for at in [1,3,5] {
            XCTAssertNil(PatchParagraphNavigation.position(text:text,caret:at,backwards:false))
            XCTAssertNil(PatchParagraphNavigation.position(text:text,caret:at,backwards:true))
        }
        XCTAssertEqual(try move(text,2),offset("雪",text))
        XCTAssertEqual(try move(text,4,true),0)
    }
    func testOpaqueBytesAndNULNavigateWithoutReencodingOrMutatingBuffer()throws {
        let bytes=Data([0xff,0,65,13,10,32,9,10,0xfe,90])
        let document=UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:.windows1252)
        let buffer=UnifiedDiffEditBuffer(document:document),initial=try buffer.snapshot().bytes
        let index=PatchLineIndex(text:buffer.text),last=try XCTUnwrap(index.lineStarts.last)
        XCTAssertEqual(try move(buffer.text,0),last)
        XCTAssertEqual(try move(buffer.text,last,true),0)
        XCTAssertEqual(try buffer.snapshot().bytes,initial)
        XCTAssertEqual(initial,bytes)
        XCTAssertEqual(buffer.text,document.displayText)
    }
}
