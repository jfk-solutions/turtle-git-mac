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
        // NSBitmapImageRep.colorAt can return generic calibrated RGB despite an
        // sRGB CGImage profile; converting that NSColor changes pure magenta.
        // Normalize the actual image to a named sRGB byte buffer instead.
        let width = image.pixels.width, height = image.pixels.height
        XCTAssertTrue((0..<width).contains(x) && (0..<height).contains(y))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return try bytes.withUnsafeMutableBytes { storage in
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image.pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
            let components = storage.bindMemory(to: UInt8.self), offset = (y * width + x) * 4
            let alpha = CGFloat(components[offset + 3]) / 255
            return (0..<3).map { alpha > 0 ? CGFloat(components[offset + $0]) / (255 * alpha) : 0 }
        }
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
    func testLinearGradientPresetColorsComposeBrushAndWorldTransforms() throws {
        let value = try image("plus-gradient-transform.emf")
        XCTAssertEqual(value.size, CGSize(width: 96, height: 64))
        // Normalized horizontal-axis fractions through brush [0,48,-24,0,64,4]
        // then world Translate(8,4), independent of renderer-generated SVG.
        try primary(value, 0, 70, 10)
        try primary(value, 1, 60, 32)
        try primary(value, 2, 49, 54)
        XCTAssertTrue(try rgb(value, 44, 30).allSatisfy { $0 > 0.9 }, "Brush/world transforms misplaced the painted rectangle")
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-gradient-transform.emf"))), as: UTF8.self)
        XCTAssertTrue(svg.contains("<linearGradient"), "Gradient was flattened to a solid color")
    }
    func testEllipticalPathGradientUsesBoundaryToCenterPresetOrderAndTransforms() throws {
        let value = try image("plus-gradient-radial.emf")
        // The boundary path is a four-Bezier ellipse (24x20 radii), not an
        // output-derived image. Brush/world translations align center(54.5,38.5)
        // with pixel(54,38); endpoint plateaus avoid testing near-stop blends.
        try primary(value, 0, 54, 38)
        try primary(value, 1, 66, 38)
        try primary(value, 2, 76, 38)
        XCTAssertTrue(try rgb(value, 20, 20).allSatisfy { $0 > 0.9 })
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-gradient-radial.emf"))), as: UTF8.self)
        XCTAssertTrue(svg.contains("<radialGradient"))
    }
    func testLinearGradientHorizontalBlendFactorsRetainPlateausAndMidpoint() throws {
        let value = try image("plus-gradient-blend.emf")
        try primary(value, 0, 16, 24)
        try primary(value, 2, 80, 24)
        let middle = try rgb(value, 48, 24)
        XCTAssertGreaterThan(middle[0], 0.35); XCTAssertGreaterThan(middle[2], 0.35)
        XCTAssertLessThan(middle[1], 0.25)
        XCTAssertEqual(middle[0], middle[2], accuracy: 0.08)
    }
    func testLinearGradientTileAndFlipRetainDifferentStopOrders() throws {
        let value = try image("plus-gradient-wrap.emf")
        // Each sample is just inside the second period at the same normalized
        // horizontal position: Tile restarts red; TileFlipX reflects from blue.
        try primary(value, 0, 24, 20)
        try primary(value, 2, 24, 52)
        XCTAssertTrue(try rgb(value, 92, 30).allSatisfy { $0 > 0.9 })
    }
    func testImageAttributesDefaultClampColorAndTileFlipPreserveOriginalPixels() throws {
        let plain = try image("plus-image-attributes.emf")
        try primary(plain, 0, 16, 16)
        try primary(plain, 1, 32, 16)
        try primary(plain, 2, 16, 32)
        let clamped = try image("plus-image-clamp.emf")
        for x in [16, 64] {
            let color = try rgb(clamped, x, 16)
            XCTAssertGreaterThan(color[0], 0.8); XCTAssertLessThan(color[1], 0.25); XCTAssertGreaterThan(color[2], 0.8)
        }
        try primary(clamped, 0, 32, 16)
        try primary(clamped, 1, 48, 16)
        let wrapped = try image("plus-image-wrap.emf")
        let tile = [0, 1, 0, 1, 0, 1], reflected = [1, 0, 0, 1, 1, 0]
        for index in 0..<6 {
            try primary(wrapped, tile[index], 8 + 16 * index, 12)
            try primary(wrapped, reflected[index], 8 + 16 * index, 40)
        }
    }
    func testRelativeSigned7And15AndAbsoluteInt16ImagePointsUseActualFlags() throws {
        let relative = try image("plus-image-relative.emf")
        // P=0x0800 wins over C=0x4000. Delta pairs (160,8),(-128,0),
        // (128,32) include both scalar widths/signs; world transform maps them.
        try primary(relative, 0, 68, 20)
        try primary(relative, 1, 36, 20)
        try primary(relative, 2, 68, 36)
        let absolute = try image("plus-image-int16.emf")
        // C alone means signed absolute Int16, including initial x=-16.
        try primary(absolute, 0, 24, 20)
        try primary(absolute, 1, 56, 20)
        try primary(absolute, 2, 24, 36)
        XCTAssertTrue(try rgb(absolute, 88, 52).allSatisfy { $0 > 0.9 })
    }
    func testOpaquePenAndHalfAlphaBrushPreserveSeparateSVGOpacity() throws {
        let value = try image("plus-alpha-pen.emf")
        try primary(value, 0, 20, 8)
        let translucent = try rgb(value, 20, 32)
        XCTAssertGreaterThan(translucent[0], 0.9)
        for channel in [1, 2] {
            XCTAssertGreaterThan(translucent[channel], 0.3)
            XCTAssertLessThan(translucent[channel], 0.85)
        }
        let svg = String(decoding: try XCTUnwrap(MetafileImageDecoder.convert(data("plus-alpha-pen.emf"))), as: UTF8.self)
        XCTAssertTrue(svg.contains("stroke=\"#ff0000\""))
        XCTAssertTrue(svg.contains("stroke-opacity=\"1\""))
        XCTAssertTrue(svg.contains("fill=\"#ff0000\""))
        let expression = try NSRegularExpression(pattern: #"fill-opacity="([0-9.]+)""#)
        let opacities = expression.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)).compactMap { match -> Double? in
            guard let range = Range(match.range(at: 1), in: svg) else { return nil }
            return Double(svg[range])
        }
        XCTAssertTrue(opacities.contains { abs($0 - 128.0 / 255.0) < 0.0001 }, "Inline ARGB brush alpha was not preserved as separate SVG opacity")
    }
    func testMalformedAndUnsupportedPaintingFailInsteadOfSuccessfulBlank() throws {
        for name in ["unsupported-region.emf", "unsupported-rop.emf", "unsupported-image-effect.emf", "unsupported-image-attributes.emf", "unsupported-image-wrap.emf", "unsupported-image-attribute-type.emf", "unsupported-gradient-stops.emf", "unsupported-image-tile-budget.emf", "unsupported-gradient-precision.emf"] {
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
