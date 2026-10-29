// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import CoreFoundation
@testable import TurtleGitCore

final class ComparisonPayloadCodecTests:XCTestCase {
    // Independent platform-codec oracle; do not expose production-private state.
    private func codec(_ format:ComparisonTextEncoding)->String.Encoding {
        if let page=format.legacyCodePage {return .init(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding(page)))}
        switch format {
        case .utf8,.utf8BOM:return .utf8
        case .utf16LE,.utf16LEBOM:return .utf16LittleEndian
        case .utf16BE,.utf16BEBOM:return .utf16BigEndian
        case .utf32LE:return .utf32LittleEndian
        case .utf32BE:return .utf32BigEndian
        default:preconditionFailure("Regional codec must provide a code page")
        }
    }

    func testUnicodePayloadSentinelPreservesLeadingCombiningMarksFEFFAndNUL()throws {
        let formats=ComparisonTextEncoding.allCases.filter{$0.legacyCodePage==nil}
        XCTAssertGreaterThanOrEqual(formats.count,8)
        let payloads=["","\u{301}","\u{301}e\u{301}","\u{feff}","\u{feff}\u{301}x","\u{301}\u{feff}","\0\u{301}text","\u{feff}\u{feff}雪🐢\r\n"]
        for format in formats {for payload in payloads {
            let expected=try XCTUnwrap(payload.data(using:codec(format),allowLossyConversion:false))
            XCTAssertEqual(try format.encodePatchPayload(payload),expected,"Payload must not add an encoding header")
            let recovered=try XCTUnwrap(format.decodePatchPayload(expected),"\(format) \(Array(payload.utf8))")
            XCTAssertTrue(recovered.utf8.elementsEqual(payload.utf8),"Exact scalar sequence must survive, not only canonical String equality")
            if !payload.utf8.contains(0) {
                let saved=try format.encode(payload)
                XCTAssertEqual(saved,format.patchBOM+expected)
                XCTAssertTrue(try XCTUnwrap(format.decode(saved)).utf8.elementsEqual(payload.utf8))
            } else {XCTAssertThrowsError(try format.encode(payload),"Compare/Merge retain their separate NUL refusal")}
        }}
    }
    func testAutomaticBOMDocumentLoadsLeadingScalarsAndRetainsExactBufferBytes()throws {
        let formats=ComparisonTextEncoding.allCases.filter{$0.hasBOM}
        XCTAssertEqual(formats.count,5)
        for format in formats {for text in ["\u{301}text","\u{feff}text","\u{301}\u{feff}e\u{301}","\u{feff}\u{feff}雪🐢\r\n","\0\u{301}text"] {
            let payload=try XCTUnwrap(text.data(using:codec(format),allowLossyConversion:false))
            let bytes=format.patchBOM+payload
            // No explicit sourceEncoding override: exercise actual BOM discovery.
            let document=UnifiedDiffDocument(bytes:bytes)
            if format == .utf16LEBOM,text.unicodeScalars.first?.value==0 {
                // FF FE + UTF16 NUL is indistinguishable from a UTF32LE BOM.
                // Autodetection correctly prefers the longest signature; an
                // explicit encoding is required to express the other intent.
                XCTAssertEqual(document.sourceEncoding,.utf32LE)
                XCTAssertEqual(try UnifiedDiffEditBuffer(document:document).snapshot().bytes,bytes)
                continue
            }
            XCTAssertEqual(document.sourceEncoding,format)
            XCTAssertTrue(document.displayText.utf8.elementsEqual(text.utf8),"Automatic BOM load must preserve literal scalars for \(format)")
            let buffer=UnifiedDiffEditBuffer(document:document)
            XCTAssertTrue(buffer.text.utf8.elementsEqual(text.utf8))
            XCTAssertEqual(try buffer.snapshot().bytes,bytes,"Viewing an initial combining character or FEFF cannot rewrite original BOM/payload bytes")
        }}
    }
    func testRepresentableRegionalPayloadsRemainLiteralAndUnrepresentableMarksRefuse()throws {
        let payloads=["","plain\r\n","é","\u{301}","\u{feff}","\u{301}x"]
        var checked=0
        for format in ComparisonTextEncoding.allCases where format.legacyCodePage != nil {
            for payload in payloads {
                // The platform codec itself provides bytes, independently of
                // the sentinel helper. Exact round-trip remains mandatory.
                guard let expected=payload.data(using:codec(format),allowLossyConversion:false),
                      let decoded=String(data:expected,encoding:codec(format)),decoded.utf8.elementsEqual(payload.utf8) else {
                    XCTAssertThrowsError(try format.encodePatchPayload(payload));continue
                }
                checked+=1
                XCTAssertEqual(try format.encodePatchPayload(payload),expected)
                XCTAssertTrue(try XCTUnwrap(format.decodePatchPayload(expected)).utf8.elementsEqual(payload.utf8))
            }
        }
        XCTAssertGreaterThan(checked,3,"Exercise actual installed regional codecs, including ordinary payloads")
    }
}
