// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class PatchCharacterNavigationTests:XCTestCase {
    func testLogicalDirectionsIgnoreBidirectionalVisualOrder() {
        let text="aאבb"
        for caret in 0...4 {
            XCTAssertEqual(PatchCharacterNavigation.position(text:text,caret:caret,backwards:true),max(0,caret-1))
            XCTAssertEqual(PatchCharacterNavigation.position(text:text,caret:caret,backwards:false),min(4,caret+1))
        }
    }
    func testComposedSurrogateAndEmojiSequencesStayWhole() {
        let text="e\u{301}🐢👩‍💻x"
        let endpoints=[0,2,4,9,10]
        for pair in zip(endpoints,endpoints.dropFirst()) {
            XCTAssertEqual(PatchCharacterNavigation.position(text:text,caret:pair.0,backwards:false),pair.1)
            XCTAssertEqual(PatchCharacterNavigation.position(text:text,caret:pair.1,backwards:true),pair.0)
        }
        for caret in [1,3,5,6,7,8] {
            XCTAssertNil(PatchCharacterNavigation.position(text:text,caret:caret,backwards:true))
            XCTAssertNil(PatchCharacterNavigation.position(text:text,caret:caret,backwards:false))
        }
    }
    func testCRLFIsOneStepWhileMixedLineEndingsRetainTheirOwnSteps() {
        let text="a\r\nb\rc\nd\n\re"
        let endpoints=[0,1,3,4,5,6,7,8,9,10,11]
        for pair in zip(endpoints,endpoints.dropFirst()) {
            XCTAssertEqual(PatchCharacterNavigation.position(text:text,caret:pair.0,backwards:false),pair.1)
            XCTAssertEqual(PatchCharacterNavigation.position(text:text,caret:pair.1,backwards:true),pair.0)
        }
        XCTAssertNil(PatchCharacterNavigation.position(text:text,caret:2,backwards:false))
        XCTAssertNil(PatchCharacterNavigation.position(text:text,caret:2,backwards:true))
    }
    func testDocumentEdgesAndInvalidOffsets() {
        for backwards in [false,true] {
            XCTAssertEqual(PatchCharacterNavigation.position(text:"",caret:0,backwards:backwards),0)
            XCTAssertNil(PatchCharacterNavigation.position(text:"x",caret:-1,backwards:backwards))
            XCTAssertNil(PatchCharacterNavigation.position(text:"x",caret:2,backwards:backwards))
        }
        XCTAssertEqual(PatchCharacterNavigation.position(text:"x",caret:0,backwards:true),0)
        XCTAssertEqual(PatchCharacterNavigation.position(text:"x",caret:1,backwards:false),1)
    }
    func testOpaqueLegacyDocumentNavigationPreservesExactSnapshot()throws {
        let bytes=Data([0xff,0,32,0xe9,13,10,0xfe])
        let buffer=UnifiedDiffEditBuffer(document:UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:.windows1252))
        var caret=0,endpoints=[0]
        while caret<buffer.text.utf16.count {
            caret=try XCTUnwrap(PatchCharacterNavigation.position(text:buffer.text,caret:caret,backwards:false));endpoints.append(caret)
        }
        XCTAssertEqual(endpoints,[0,1,2,3,4,6,7])
        for expected in endpoints.dropLast().reversed() {
            caret=try XCTUnwrap(PatchCharacterNavigation.position(text:buffer.text,caret:caret,backwards:true))
            XCTAssertEqual(caret,expected)
        }
        XCTAssertEqual(try buffer.snapshot().bytes,bytes)
    }
}
