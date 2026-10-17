// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class UnifiedDiffEncodingTests:XCTestCase {
    func testRegionalPatchDisplayAndSelectionRetainOriginalBytes() throws {
        for (codec,sample) in LegacyComparisonEncodingTests().samples {
            let header="diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1,1 +1,1 @@\n"
            let bytes=Data(header.utf8)+(try codec.encode("-"+sample+"\n+"+sample+" changed\n"))
            let patch=GitPatch(bytes:bytes,displayLegacyEncoding:codec)
            XCTAssertEqual(patch.text,header+"-"+sample+"\n+"+sample+" changed\n",codec.rawValue)
            XCTAssertEqual(patch.bytes,bytes)
            let selected=try patch.selectedPatchData(lines:[patch.files[0].hunks[0].header],entireHunks:true,reverse:false)
            XCTAssertEqual(selected,bytes)
            let source=UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:codec)
            XCTAssertEqual(source.displayText,patch.text)
            XCTAssertEqual(try source.encodedEdits(source.displayText),bytes)
            let changed=source.displayText+" context\r\n"
            XCTAssertEqual(try source.encodedEdits(changed),try codec.encode(changed))
        }
    }
    func testMixedUTF8AndLegacyLinesKeepTheirDisplayAcrossUnchangedSave() throws {
        let bytes=Data("+日本語\n".utf8)+(try ComparisonTextEncoding.windows1251.encode("-исходный\n"))
        let source=UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:.windows1251)
        XCTAssertEqual(source.displayText,"+日本語\n-исходный\n")
        XCTAssertEqual(source.recording(bytes).displayText,source.displayText)
        XCTAssertEqual(try source.encodedEdits(source.displayText),bytes)
        XCTAssertEqual(try source.encodedEdits(source.displayText+"+edit\n"),bytes+Data("+edit\n".utf8))
    }
    func testSavedRegionalCodecSurvivesBytesThatAlsoFormValidUTF8() throws {
        let source=UnifiedDiffDocument(bytes:try ComparisonTextEncoding.windows1251.encode("+старое\n"),displayLegacyEncoding:.windows1251)
        let edited="+Р°\n",bytes=try source.encodedEdits(edited)
        XCTAssertEqual(String(data:bytes,encoding:.utf8),"+а\n")
        let saved=source.recording(bytes)
        XCTAssertEqual(saved.sourceEncoding,.windows1251)
        XCTAssertEqual(saved.displayText,edited)
        XCTAssertEqual(try saved.encodedEdits(edited+"+ещё\n"),try ComparisonTextEncoding.windows1251.encode(edited+"+ещё\n"))
    }
    func testBOMEditsPreserveEncodingAndRealLeadingFEFF() throws {
        for codec in [ComparisonTextEncoding.utf8BOM,.utf16LEBOM,.utf16BEBOM,.utf32LE,.utf32BE] {
            let text="\u{feff}+café 雪\r\nlast",bytes=try codec.encode(text)
            let source=UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:.windows1251)
            XCTAssertEqual(Array(source.displayText.utf8),Array(text.utf8),codec.rawValue)
            XCTAssertEqual(try source.encodedEdits(text+" edited"),try codec.encode(text+" edited"))
        }
    }
    func testExactUnicodeChangesAndUnchangedOpaqueData() throws {
        let nfc="+café\n",nfd="+cafe\u{301}\n",source=UnifiedDiffDocument(bytes:Data(nfc.utf8))
        XCTAssertEqual(nfc,nfd) // Swift semantic equality must not define a save point.
        XCTAssertNotEqual(try source.encodedEdits(nfd),source.bytes)
        XCTAssertEqual(try source.encodedEdits(nfd),Data(nfd.utf8))
        for bytes in [Data([0xff,0xfe,65]),Data([0,255,10]),Data([0x81,0x8d])] {
            let opaque=UnifiedDiffDocument(bytes:bytes)
            XCTAssertEqual(try opaque.encodedEdits(opaque.displayText),bytes)
        }
        let regional=UnifiedDiffDocument(bytes:try ComparisonTextEncoding.windows1251.encode("+текст\n"),displayLegacyEncoding:.windows1251)
        XCTAssertThrowsError(try regional.encodedEdits("+日本語\n"))
    }
}
