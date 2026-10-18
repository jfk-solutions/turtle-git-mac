// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import Darwin
@testable import TurtleGitCore

final class MetafileImageTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
    private func image(_ name: String) throws -> ComparisonImage { try XCTUnwrap(ComparisonImage(bytes: data(name)), "Could not render \(name)") }
    private func rgb(_ image: ComparisonImage, _ x: Int, _ y: Int) throws -> [CGFloat] {
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image.pixels).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent]
    }
    private func primary(_ image: ComparisonImage, _ channel: Int, _ x: Int, _ y: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try rgb(image,x,y)
        XCTAssertGreaterThan(color[channel],0.8,file:file,line:line)
        for i in 0..<3 where i != channel { XCTAssertLessThan(color[i],0.25,file:file,line:line) }
    }
    func testWMFAndEMFRenderCapturedVectorColorsAtIntrinsicSize() throws {
        for name in ["clip-vector.wmf","classic-vector.emf"] {
            let value = try image(name)
            XCTAssertEqual(value.size,CGSize(width:96,height:64))
            try primary(value,0,12,12)
            if name.hasSuffix("wmf") {
                let outside = try rgb(value,35,35)
                XCTAssertTrue(outside.allSatisfy { $0>0.9 },"WMF intersection clipping was ignored")
            } else { try primary(value,2,58,12) }
        }
    }
    func testFrameAndDeviceMetadataDetermineSizeAndDPI() throws {
        let physical = try image("physical-frame.emf")
        XCTAssertEqual(physical.size,CGSize(width:192,height:128))
        XCTAssertEqual(try XCTUnwrap(physical.dpiX),96,accuracy:0.1)
        XCTAssertEqual(try XCTUnwrap(physical.dpiY),96,accuracy:0.1)
        let wmf = try image("clip-144dpi.wmf")
        XCTAssertEqual(wmf.size,CGSize(width:96,height:64))
        XCTAssertEqual(try XCTUnwrap(wmf.dpiX),144,accuracy:0.1)
        XCTAssertEqual(try XCTUnwrap(wmf.dpiY),144,accuracy:0.1)
    }
    func testEMFPlusTransformsClipsAndIndexedRestoreRenderDifferentTargets() throws {
        let value = try image("plus-transform.emf")
        XCTAssertEqual(value.size,CGSize(width:96,height:64))
        try primary(value,0,20,12)
        try primary(value,2,58,12)
        let outside = try rgb(value,34,12)
        XCTAssertTrue(outside.allSatisfy { $0>0.9 },"EMF+ transformed clip did not constrain red rectangle")
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-transform.emf"))),as:UTF8.self)
        XCTAssertTrue(svg.contains("matrix(1 0 0 1 12 4)")); XCTAssertTrue(svg.contains("mask="))
    }
    func testGDIPlusAppendAndPrependUseDifferentNoncommutingOrder() throws {
        let value = try image("plus-matrix-order.emf")
        try primary(value,0,20,8)
        try primary(value,2,32,40)
        XCTAssertTrue(try rgb(value,35,8).allSatisfy { $0>0.9 })
    }
    func testDualPlaybackChoosesPlusAndPermitsOnlyGetDCClassicInterval() throws {
        let value = try image("plus-dual-getdc.emf")
        try primary(value,0,12,12)
        try primary(value,2,58,12)
    }
    func testClassicAndPlusBitmapsDecodeOriginalChannelOrderAndKeepTextFace() throws {
        for name in ["classic-bitmap.emf","plus-bitmap-text.emf"] {
            let value = try image(name)
            XCTAssertEqual(value.size,CGSize(width:96,height:64))
            // Sample the source-pixel centers after each captured destination
            // transform; shared coordinates would sample different interpolation.
            let first = name.hasPrefix("classic") ? 16 : 12
            let second = first + 16
            try primary(value,0,first,first)
            try primary(value,1,second,first)
            try primary(value,2,first,second)
        }
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-bitmap-text.emf"))),as:UTF8.self)
        XCTAssertTrue(svg.contains("Helvetica"));XCTAssertTrue(svg.contains("TurtleGit"));XCTAssertTrue(svg.contains("data:image/png;base64,"))
    }
    func testPlusPathContainerAndContinuedObjectKeepCapturedGeometry() throws {
        let path = try image("plus-path-container.emf")
        try primary(path,0,40,12)
        try primary(path,2,10,44)
        let bitmap = try image("plus-continued-bitmap.emf")
        try primary(bitmap,0,12,12)
        try primary(bitmap,1,30,12)
    }
    func testCompressedPlusBitmapUsesSignatureDimensionsAndSourceCrop() throws {
        let value = try image("plus-compressed-crop.emf")
        // Source green pixel center (1.5,0.5) through crop/destination
        // matrix (32,0,0,16,-24,8) lands exactly at (24,16).
        try primary(value,1,24,16)
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-compressed-crop.emf"))),as:UTF8.self)
        XCTAssertTrue(svg.contains("turtle-image-clip"));XCTAssertTrue(svg.contains("width=\"2\""))
    }
    func testMalformedAndUnsupportedPaintingFailInsteadOfSuccessfulBlank() throws {
        for name in ["unsupported-region.emf","unsupported-rop.emf"] {
            XCTAssertThrowsError(try MetafileImageDecoder.convert(data(name)))
            XCTAssertNil(ComparisonImage(bytes: try data(name)))
        }
        var truncated = try data("plus-transform.emf");truncated.removeLast()
        XCTAssertThrowsError(try MetafileImageDecoder.convert(truncated))
        var malformed = try data("classic-vector.emf");malformed.replaceSubrange(92..<96,with:[0xff,0xff,0xff,0x7f])
        XCTAssertThrowsError(try MetafileImageDecoder.convert(malformed))
        XCTAssertNil(try MetafileImageDecoder.convert(Data("ordinary text".utf8)))
    }
    func testOutputRejectsExternalResourcesScriptsEntitiesAndOversizedDimensions() throws {
        for text in [
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><image href=\"file:///etc/passwd\"/></svg>",
            "<!DOCTYPE svg [<!ENTITY x SYSTEM 'https://invalid.example/'>]><svg>&x;</svg>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect style=\"fill:url(https://invalid.example/)\"/></svg>"
        ] { XCTAssertThrowsError(try MetafileImageDecoder.validateSVG(Data(text.utf8))) }
        var huge = try data("classic-vector.emf")
        // Enormous physical frame while device DPI remains valid.
        huge.replaceSubrange(32..<36,with:[0xff,0xff,0xff,0x7f])
        XCTAssertThrowsError(try MetafileImageDecoder.convert(huge))
    }
    private func stalledHelper(_ directory: URL) throws -> (URL,URL) {
        let helper=directory.appendingPathComponent("owned-helper"),marker=directory.appendingPathComponent("pids")
        let script="#!/bin/sh\n/bin/sleep 60 &\nchild=$!\nprintf '%s %s' \"$$\" \"$child\" > '\(marker.path)'\ntrap 'kill \"$child\" 2>/dev/null; wait \"$child\" 2>/dev/null; exit 143' TERM INT\nwait \"$child\"\n"
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        return(helper,marker)
    }
    private func assertReaped(_ marker: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let pids=try String(contentsOf:marker).split(separator:" ").compactMap {Int32($0)}
        XCTAssertEqual(pids.count,2,file:file,line:line)
        for pid in pids {let status=kill(pid,0),code=errno;XCTAssertEqual(status,-1,"Owned metafile helper survived",file:file,line:line);XCTAssertEqual(code,ESRCH,file:file,line:line)}
    }
    func testOwnedHelperCancellationAndDeadlineReapBothProcessGroupMembers() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMetafileTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let bytes=try data("classic-vector.emf")
        let (helper,marker)=try stalledHelper(directory),token=OperationCancellation()
        let work=Task.detached {try MetafileImageDecoder.convert(bytes,executable:helper,cancellation:token)}
        for _ in 0..<500 where !FileManager.default.fileExists(atPath:marker.path) {try await Task.sleep(nanoseconds:10_000_000)}
        token.cancel()
        do {_ = try await work.value;XCTFail("Cancellation was accepted as an image")}catch {}
        try assertReaped(marker)
        try FileManager.default.removeItem(at:marker)
        XCTAssertThrowsError(try MetafileImageDecoder.convert(bytes,executable:helper,timeout:0.5)) {error in
            guard let failure=error as? MetafileImageFailure, case .timedOut = failure else {return XCTFail("Expected decoder deadline, got \(error)")}
        }
        try assertReaped(marker)
    }
}
