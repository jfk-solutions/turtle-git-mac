// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class PresentationPackageTests: XCTestCase {
    private let slide = Data(#"<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld name="Slide"/></p:sld>"#.utf8)
    // Raw DEFLATE produced independently with Python zlib, not our ZIP writer.
    private let deflated = Data(base64Encoded: "HY1BCoQwDAC/svQBG/HgodR+whcEjVpo0tDk4PMtHoeBmaTR6vF7uIpFXcPtrhHA9psY7d+UZLizdUYf2C/QTkbi6KUJV5inaQHGIiEnjfs2YoJMa9hqOShATvAt8gs=")!
    private func little(_ value: Int, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private func fields(_ values: [Int], _ widths: [Int]) -> Data { zip(values,widths).reduce(Data()) { $0 + little($1.0,$1.1) } }
    private func fixture(name: String = "ppt/slides/slide1.xml", payload: Data? = nil, method: Int = 8, size: Int = 106, crc: Int = 0xd09c1ef0, descriptor: Bool = false) -> Data {
        let path = Data(name.utf8), body = payload ?? deflated, flags = 0x800 | (descriptor ? 8 : 0)
        var bytes = fields([0x04034b50,20,flags,method,0,0,descriptor ? 0:crc,descriptor ? 0:body.count,descriptor ? 0:size,path.count,0],[4,2,2,2,2,2,4,4,4,2,2])
        bytes += path; bytes += body
        if descriptor { bytes += fields([0x08074b50,crc,body.count,size],[4,4,4,4]) }
        let offset = bytes.count
        let directory = fields([0x02014b50,20,20,flags,method,0,0,crc,body.count,size,path.count,0,0,0,0,0,0],[4,2,2,2,2,2,2,4,4,4,2,2,2,2,2,4,4]) + path
        bytes += directory
        bytes += fields([0x06054b50,0,0,1,1,directory.count,offset,0],[4,2,2,2,2,4,4,2])
        return bytes
    }
    private func put(_ value: Int, at: Int, count: Int, in bytes: inout Data) { bytes.replaceSubrange(at..<at+count,with:little(value,count)) }
    private func rejects(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PresentationPackage(data:bytes,cancellation:.init()),file:file,line:line)
    }
    func testGenuineDeflateAndStreamingDescriptor() throws {
        for streaming in [false,true] {
            let value = try PresentationPackage(data:fixture(descriptor:streaming),cancellation:.init())
            XCTAssertEqual(value.entries,["ppt/slides/slide1.xml":slide])
        }
    }
    func testDeterministicStoredRoundTripPreservesOpaquePartsAndEmptyMembers() throws {
        let opaque = Data([0,255,17,42,0,12])
        let entries:[String:Data] = ["[Content_Types].xml":Data("<Types/>".utf8),"ppt/slides/slide1.xml":slide,"ppt/embeddings/private.bin":opaque,"ppt/empty/":Data(),"ppt/empty/value":Data()]
        let package = try PresentationPackage(entries:entries), bytes = try package.encoded(cancellation:.init())
        XCTAssertEqual(bytes,try package.encoded(cancellation:.init()))
        XCTAssertEqual(try PresentationPackage(data:bytes,cancellation:.init()).entries,entries)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to:root); defer {try? FileManager.default.removeItem(at:root)}
        XCTAssertEqual(try PresentationPackage.read(from:root,cancellation:.init()).entries,entries)
        XCTAssertEqual(try PresentationPackage(data:try PresentationPackage(entries:[:]).encoded(cancellation:.init()),cancellation:.init()).entries,[:])
    }
    func testChecksumCompressedTruncationSizeMismatchAndTrailingStream() {
        var corrupt = fixture(); corrupt[30 + "ppt/slides/slide1.xml".utf8.count] ^= 1; rejects(corrupt)
        rejects(fixture(payload:deflated.dropLast()))
        rejects(fixture(size:107)); rejects(fixture(size:105))
        rejects(fixture(payload:deflated + Data([0])))
        rejects(fixture(crc:0))
        rejects(fixture(method:0)); rejects(fixture(method:12))
        for length in [0,1,21,40,fixture().count-1] { rejects(Data(fixture().prefix(length))) }
    }
    func testUnsafePathsAliasesAndMutableEntriesAreRejected() throws {
        for name in ["../escape","a/../escape","/absolute","a\\b","a//b","a/./b","a\u{0}b","a\nb","C:drive","a/%2e%2e/b","a%2fb","a%5cb","a%00b","bad%"] { rejects(fixture(name:name)) }
        for entries in [["A":Data(),"a":Data()],["a":Data(),"a/":Data()],["a b":Data(),"a%20b":Data()]] {
            XCTAssertThrowsError(try PresentationPackage(entries:entries))
        }
        var value = try PresentationPackage(entries:["good":Data()]); value.entries["../bad"] = Data()
        XCTAssertThrowsError(try value.encoded(cancellation:.init()))
        XCTAssertThrowsError(try PresentationPackage(entries:["folder/":Data([1])]))
    }
    func testLocalCentralHeaderAgreementAndUnsupportedFlags() {
        let original=fixture(), central=30 + "ppt/slides/slide1.xml".utf8.count + deflated.count
        for (at,size,value) in [(6,2,0x801),(8,2,0),(14,4,0),(18,4,1),(22,4,1),(30,1,Int(UInt8(ascii:"x")))] {
            var bytes=original;put(value,at:at,count:size,in:&bytes);rejects(bytes)
        }
        for (at,size,value) in [(central+8,2,0x801),(central+10,2,99),(central+34,2,1),(central+24,4,0xffffffff),(central+42,4,0xffffffff),(central+38,4,0xa000 << 16)] {
            var bytes=original;put(value,at:at,count:size,in:&bytes);rejects(bytes)
        }
        var multipart=original; put(1,at:multipart.count-18,count:2,in:&multipart); rejects(multipart)
        var zip64=original; put(0xffff,at:zip64.count-12,count:2,in:&zip64);rejects(zip64)
    }
    func testDuplicatePhysicalNamesOverlapsAndHiddenBytes() throws {
        var bytes=try PresentationPackage(entries:["a":Data([1]),"b":Data([2])]).encoded(cancellation:.init())
        let directory=64 // two local records, each 30-byte header + name + byte
        bytes[directory+47+46] = UInt8(ascii:"a") // second central filename
        rejects(bytes)
        var overlap=try PresentationPackage(entries:["a":Data([1]),"b":Data([2])]).encoded(cancellation:.init())
        put(0,at:directory+47+42,count:4,in:&overlap);rejects(overlap)
        var hidden=fixture(); hidden.insert(0,at:0); rejects(hidden)
    }
    func testBoundsAndCancellationAtReadAndWrite() throws {
        rejects(fixture(size:PresentationPackage.maximumEntryBytes+1))
        let entries=Dictionary(uniqueKeysWithValues:(0...PresentationPackage.maximumEntries).map{("part\($0)",Data())})
        XCTAssertThrowsError(try PresentationPackage(entries:entries))
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try PresentationPackage(data:fixture(),cancellation:token)) { XCTAssertTrue($0 is OperationCancellationFailure) }
        XCTAssertThrowsError(try PresentationPackage(entries:["a":Data()]).encoded(cancellation:token)) { XCTAssertTrue($0 is OperationCancellationFailure) }
    }
}

