// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class UnifiedDiffEditBufferTests:XCTestCase {
    func testMixedRegionsRetainUntouchedUTF8RegionalAndOpaqueBytes() throws {
        let codec=ComparisonTextEncoding.windows1251,head=Data("+日本語\n".utf8),regional=try codec.encode("-исходный\r\n"),opaque=Data([0x98,0,0xff,10])
        let source=UnifiedDiffDocument(bytes:head+regional+opaque,displayLegacyEncoding:codec)
        var buffer=UnifiedDiffEditBuffer(document:source)
        buffer.replaceText(buffer.text.replacingOccurrences(of:"日本語",with:"日本語 🐢"))
        buffer.replaceText(buffer.text.replacingOccurrences(of:"исходный",with:"новый"))
        let saved=try buffer.snapshot()
        XCTAssertEqual(saved.bytes,Data("+日本語 🐢\n".utf8)+(try codec.encode("-новый\r\n"))+opaque)
        XCTAssertEqual(Array(saved.displayText.utf8),Array(buffer.text.utf8))
        buffer.markSaved(saved);buffer.replaceText(buffer.text+"append\n")
        XCTAssertEqual(try buffer.snapshot().bytes,saved.bytes+Data("append\n".utf8))
    }
    func testEveryRegionalCodecSupportsEditsBesideUTF8WithoutTranscodingIt() throws {
        for (codec,sample) in LegacyComparisonEncodingTests().samples {
            let utf8=Data("+日本語 🐢\n".utf8),original=utf8+(try codec.encode("-"+sample+"\r\n"))
            var buffer=UnifiedDiffEditBuffer(document:.init(bytes:original,displayLegacyEncoding:codec))
            buffer.replaceText("+日本語 🐢\n-"+sample+" edited\r\n")
            XCTAssertEqual(try buffer.snapshot().bytes,utf8+(try codec.encode("-"+sample+" edited\r\n")),codec.rawValue)
            buffer.replaceText("+日本語 🐢\n-"+sample+"\r\n")
            XCTAssertEqual(try buffer.snapshot().bytes,original)
        }
    }
    func testEmbeddedNULIsDataForPatchDocumentsAcrossCodecs() throws {
        var samples=LegacyComparisonEncodingTests().samples
        samples += [ComparisonTextEncoding.utf8,.utf8BOM,.utf16LE,.utf16LEBOM,.utf16BE,.utf16BEBOM,.utf32LE,.utf32BE].map {($0,"日本語 🐢")}
        for (codec,sample) in samples {
            let text=sample+"\0\r\nnext",bytes=codec.patchBOM+(try codec.encodePatchPayload(text))
            let source=UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:codec,sourceEncoding:codec)
            XCTAssertEqual(Array(source.displayText.utf8),Array(text.utf8),codec.rawValue)
            var buffer=UnifiedDiffEditBuffer(document:source);buffer.replaceText(text.replacingOccurrences(of:"next",with:"edited"))
            let saved=try buffer.snapshot()
            XCTAssertEqual(saved.bytes,codec.patchBOM+(try codec.encodePatchPayload(sample+"\0\r\nedited")),codec.rawValue)
            buffer.markSaved(saved);buffer.replaceText(text)
            XCTAssertEqual(try buffer.snapshot().bytes,bytes,codec.rawValue)
            XCTAssertThrowsError(try codec.encode(text),"Compare/merge must keep its existing NUL boundary")
        }
    }
    func testByteUndoAndRedoSurviveSaveAndCoalescedTyping() throws {
        let original=Data("head\n".utf8)+Data([0x98,10]),source=UnifiedDiffDocument(bytes:original,displayLegacyEncoding:.windows1251)
        var buffer=UnifiedDiffEditBuffer(document:source)
        let shown=buffer.text
        buffer.replaceText("head\n") // Remove the undefined-codepage byte and its LF.
        buffer.replaceText("head\na");buffer.replaceText("head\nab");buffer.replaceText("head\nabc")
        let saved=try buffer.snapshot();buffer.markSaved(saved)
        buffer.replaceText(shown) // Native Undo may coalesce several notifications.
        XCTAssertEqual(try buffer.snapshot().bytes,original)
        buffer.replaceText("head\nabc")
        XCTAssertEqual(try buffer.snapshot().bytes,saved.bytes)
        buffer.replaceText("head\na")
        XCTAssertEqual(try buffer.snapshot().bytes,Data("head\na".utf8))
        buffer.replaceText("head\na branch")
        XCTAssertEqual(try buffer.snapshot().bytes,Data("head\na branch".utf8))
    }
    func testUndoTapeDoesNotStopAtAnArbitrarySmallHistoryLimit() throws {
        let original=Data([0x98,10]),source=UnifiedDiffDocument(bytes:original,displayLegacyEncoding:.windows1251)
        var buffer=UnifiedDiffEditBuffer(document:source)
        let base=buffer.text
        for count in 1...256 {buffer.replaceText(base+String(repeating:"x",count:count))}
        let saved=try buffer.snapshot();buffer.markSaved(saved)
        buffer.replaceText(base);XCTAssertEqual(try buffer.snapshot().bytes,original)
        buffer.replaceText(base+String(repeating:"x",count:256));XCTAssertEqual(try buffer.snapshot().bytes,saved.bytes)
    }
    func testUnrepresentableInsertionRetainsByteHistoryAndCanBeUndone() throws {
        let codec=ComparisonTextEncoding.windows1251,raw=try codec.encode("текст\n")
        var buffer=UnifiedDiffEditBuffer(document:.init(bytes:raw,displayLegacyEncoding:codec))
        buffer.replaceText("日本語\n");XCTAssertThrowsError(try buffer.snapshot())
        buffer.replaceText("текст\n");XCTAssertEqual(try buffer.snapshot().bytes,raw)
        buffer.replaceText("текст\nmore");XCTAssertEqual(try buffer.snapshot().bytes,raw+Data("more".utf8))
    }
    func testExactUnicodeEditsSavepointAndImmutableSnapshots() throws {
        var buffer=UnifiedDiffEditBuffer(document:.init(bytes:Data("+café 🐢\n".utf8)))
        let first=try buffer.snapshot(),nfd="+cafe\u{301} 🐢\n"
        buffer.replaceText(nfd);let second=try buffer.snapshot();buffer.markSaved(second)
        XCTAssertEqual(second.bytes,Data(nfd.utf8));XCTAssertNotEqual(first.bytes,second.bytes)
        buffer.replaceText(first.displayText);XCTAssertEqual(try buffer.snapshot().bytes,first.bytes)
        buffer.replaceText(nfd);XCTAssertEqual(try buffer.snapshot().bytes,second.bytes)
        buffer.replaceText("+cafe\u{301} 🐢\nmore");XCTAssertEqual(first.bytes,Data("+café 🐢\n".utf8))
    }
    func testSavedAmbiguousRegionalBytesKeepTheirPresentationForFurtherEdits() throws {
        let codec=ComparisonTextEncoding.windows1251
        var buffer=UnifiedDiffEditBuffer(document:.init(bytes:try codec.encode("старое\n"),displayLegacyEncoding:codec))
        buffer.replaceText("Р°\n");let saved=try buffer.snapshot();buffer.markSaved(saved)
        XCTAssertEqual(String(data:saved.bytes,encoding:.utf8),"а\n");XCTAssertEqual(saved.displayText,"Р°\n")
        buffer.replaceText("Р°\nещё");XCTAssertEqual(try buffer.snapshot().bytes,try codec.encode("Р°\nещё"))
    }
    func testMalformedUTF8ProjectionEditsPreserveEveryUntouchedByte() throws {
        let segments=(0...255).map{Data([UInt8($0)])}+[Data([0xe0,0xa0]),Data([0xf0,0x90,0x80]),Data([0xed,0xa0,0x80]),Data([0xf4,0x90,0x80,0x80]),Data("🐢".utf8)]
        for segment in segments {
            var raw=Data([0xff,0xfe])+Data("|".utf8)+segment+Data("|tail".utf8)
            if raw.count % 2==0 {raw.append(95)} // Keep the malformed UTF16 BOM payload odd.
            let source=UnifiedDiffDocument(bytes:(Data([42])+raw).dropFirst()),shown=source.displayText,projected=String(decoding:segment,as:UTF8.self)
            let start=String(decoding:Data([0xff,0xfe])+Data("|".utf8),as:UTF8.self).utf16.count
            let range=NSRange(location:start,length:projected.utf16.count)
            let changed=(shown as NSString).replacingCharacters(in:range,with:"X")
            var buffer=UnifiedDiffEditBuffer(document:source);buffer.replaceText(changed)
            let expected=Data(raw.prefix(3))+Data("X".utf8)+Data(raw.dropFirst(3+segment.count))
            XCTAssertEqual(try buffer.snapshot().bytes,expected,"Opaque segment \(segment as NSData)")
            buffer.replaceText(shown);XCTAssertEqual(try buffer.snapshot().bytes,raw)
        }
    }
}
