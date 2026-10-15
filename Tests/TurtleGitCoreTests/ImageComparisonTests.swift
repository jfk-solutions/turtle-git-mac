import XCTest
import AppKit
import zlib
@testable import TurtleGitCore

final class ImageComparisonTests: XCTestCase {
    private func append(_ value: Int, count: Int, to data: inout Data) { for byte in 0..<count { data.append(UInt8((value >> (byte * 8)) & 255)) } }
    private func dib(header: Int = 40, bits: Int = 24, compression: Int = 0, palette: Data = Data(), pixels: Data) -> Data {
        var bytes = Data(); append(header, count: 4, to: &bytes)
        append(2, count: header == 12 ? 2 : 4, to: &bytes); append(1, count: header == 12 ? 2 : 4, to: &bytes)
        append(1, count: 2, to: &bytes); append(bits, count: 2, to: &bytes)
        if header != 12 {
            append(compression, count: 4, to: &bytes); append(pixels.count, count: 4, to: &bytes)
            append(3780, count: 4, to: &bytes); append(3780, count: 4, to: &bytes)
            append(bits <= 8 ? 2 : 0, count: 4, to: &bytes); append(0, count: 4, to: &bytes)
            bytes.append(Data(repeating: 0, count: header - bytes.count))
        }
        bytes.append(palette); bytes.append(pixels); return bytes
    }
    private func gzip(_ bytes: Data) throws -> Data {
        var stream = z_stream(); XCTAssertEqual(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(&stream) }
        var output = Data(count: bytes.count * 2 + 256)
        let produced = bytes.withUnsafeBytes { input in output.withUnsafeMutableBytes { target -> Int in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress); stream.avail_in = UInt32(input.count)
            stream.next_out = target.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = UInt32(target.count)
            XCTAssertEqual(deflate(&stream, Z_FINISH), Z_STREAM_END); return target.count - Int(stream.avail_out)
        } }
        output.count = produced; return output
    }
    func testPackedDIBHeadersPalettesAndBitfieldsDecodeWithoutMutatingOriginal() throws {
        let samples = [
            dib(header: 12, pixels: Data([0, 0, 255, 0, 255, 0, 0, 0])),
            dib(pixels: Data([0, 0, 255, 0, 255, 0, 0, 0])),
            dib(bits: 8, palette: Data([0, 0, 255, 0, 0, 255, 0, 0]), pixels: Data([0, 1, 0, 0])),
            dib(bits: 16, compression: 3, palette: Data([0, 248, 0, 0, 224, 7, 0, 0, 31, 0, 0, 0]), pixels: Data([0, 248, 224, 7]))
        ]
        for sample in samples {
            let before = sample, image = try XCTUnwrap(ComparisonImage(bytes: sample))
            XCTAssertEqual(image.size, CGSize(width: 2, height: 1)); XCTAssertEqual(sample, before)
            let bitmap = NSBitmapImageRep(cgImage: image.pixels)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 1, y: 0)?.usingColorSpace(.deviceRGB)).greenComponent, 0.9)
        }
        XCTAssertNil(ComparisonImage(bytes: Data([40, 0, 0, 0])))
        XCTAssertNil(ComparisonImage(bytes: dib(bits: 8, palette: Data(), pixels: Data([0]))))
    }
    func testSVGZGzipMembersCRCsAndTruncation() throws {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"3\"><rect width=\"2\" height=\"3\" fill=\"red\"/></svg>".utf8)
        let zipped = try gzip(svg), image = try XCTUnwrap(ComparisonImage(bytes: zipped))
        XCTAssertEqual(image.size, CGSize(width: 2, height: 3))
        let half = svg.count / 2, concatenated = try gzip(svg.prefix(half)) + gzip(svg.suffix(svg.count - half))
        XCTAssertEqual(ComparisonImage(bytes: concatenated)?.size, image.size)
        XCTAssertNil(ComparisonImage(bytes: Data(zipped.dropLast(4))))
        var corrupt = zipped; corrupt[corrupt.count - 8] ^= 255; XCTAssertNil(ComparisonImage(bytes: corrupt))
        XCTAssertFalse(ImageComparisonContainers.isSVG(Data("<not-svg/>".utf8)))
    }
    func testCursorVariantsRetainHotspotsAndNeverAnimate() throws {
        let first = try png(.red, width: 3, height: 2), second = try png(.green, width: 5, height: 4)
        var cursor = Data([0, 0, 2, 0, 2, 0]); var offset = 38
        for (index, bytes) in [first, second].enumerated() {
            cursor.append(contentsOf: [UInt8(index == 0 ? 3 : 5), UInt8(index == 0 ? 2 : 4), 0, 0])
            append(index + 1, count: 2, to: &cursor); append(index, count: 2, to: &cursor)
            append(bytes.count, count: 4, to: &cursor); append(offset, count: 4, to: &cursor); offset += bytes.count
        }
        cursor.append(first); cursor.append(second)
        let image = try XCTUnwrap(ComparisonImage(bytes: cursor)), next = try XCTUnwrap(image.frame(at: 1))
        XCTAssertEqual(image.frameCount, 2); XCTAssertTrue(image.isIconVariants); XCTAssertFalse(image.canAnimate)
        XCTAssertEqual(image.cursorHotspot, CGPoint(x: 1, y: 0)); XCTAssertEqual(next.cursorHotspot, CGPoint(x: 2, y: 1))
        XCTAssertEqual(image.size, CGSize(width: 3, height: 2)); XCTAssertEqual(next.size, CGSize(width: 5, height: 4)); XCTAssertEqual(next.id, image.id)
    }
    private func png(_ color: NSColor, width: Int = 3, height: Int = 2) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let rgb = color.usingColorSpace(.deviceRGB)!
        let pixels = bitmap.bitmapData!
        for y in 0..<height { for x in 0..<width {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = UInt8(rgb.redComponent * 255); pixels[offset + 1] = UInt8(rgb.greenComponent * 255)
            pixels[offset + 2] = UInt8(rgb.blueComponent * 255); pixels[offset + 3] = UInt8(rgb.alphaComponent * 255)
        } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    private func document(_ a: Data, _ b: Data) -> FileComparisonDocument {
        FileComparisonDocument(base: ComparisonFileContent(path: "old.png", revision: .workingTree, bytes: a, mode: "100644"), destination: ComparisonFileContent(path: "new.png", revision: .workingTree, bytes: b, mode: "100644"))
    }
    func testImageBytesDecodeWithoutExtensionAndKeepPixelDimensions() throws {
        let bytes = try png(.red, width: 7, height: 4)
        let image = try XCTUnwrap(ComparisonImage(bytes: bytes))
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image.pixels).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.9); XCTAssertLessThan(color.blueComponent, 0.1)
        XCTAssertEqual(image.size, CGSize(width: 7, height: 4)); XCTAssertEqual(image.frameCount, 1)
        XCTAssertNotNil(ImageComparisonDocument(document(bytes, try png(.blue))))
        XCTAssertNil(ComparisonImage(bytes: Data("not an image".utf8)))
    }
    func testMissingSidesAreImagesButMixedNonImageBytesAreNot() throws {
        let bytes = try png(.green)
        let added = try XCTUnwrap(ImageComparisonDocument(document(Data(), bytes)))
        XCTAssertNil(added.base); XCTAssertNotNil(added.destination)
        let removed = try XCTUnwrap(ImageComparisonDocument(document(bytes, Data())))
        XCTAssertNotNil(removed.base); XCTAssertNil(removed.destination)
        XCTAssertNil(ImageComparisonDocument(document(Data(), Data())))
        XCTAssertNil(ImageComparisonDocument(document(bytes, Data("plain text".utf8))))
        XCTAssertNil(ImageComparisonDocument(document(Data([0,1,2]), bytes)))
    }
    func testFitPreservesAspectRatioAndLinkedScrollClampsUnequalImages() {
        XCTAssertEqual(ImageComparisonGeometry.fittedScale(image: CGSize(width: 800, height: 200), viewport: CGSize(width: 400, height: 400)), 0.5)
        XCTAssertEqual(ImageComparisonGeometry.fittedScale(image: CGSize(width: 100, height: 400), viewport: CGSize(width: 300, height: 200)), 0.5)
        XCTAssertEqual(ImageComparisonGeometry.fittedScale(image: .zero, viewport: .zero), 1)
        XCTAssertEqual(ImageComparisonGeometry.linkedOrigin(CGPoint(x: -20,y: 900), content: CGSize(width: 200,height: 600), viewport: CGSize(width: 300,height: 100)), CGPoint(x: 0,y: 500))
    }
    func testSequentialLinkedSizingAndOriginalSizeMatchOtherPaneState() {
        var state = ImageComparisonSizing(base: CGSize(width: 80,height: 60), destination: CGSize(width: 160,height: 20))
        state.toggleWidths()
        XCTAssertEqual(state.displayed(base: true), CGSize(width: 80,height: 60))
        XCTAssertEqual(state.displayed(base: false), CGSize(width: 80,height: 10))
        state.toggleWidths() // Disabling a constraint retains each pane's zoom.
        XCTAssertEqual(state.destination.percent, 50)
        state.toggleHeights()
        XCTAssertEqual(state.displayed(base: false), CGSize(width: 480,height: 60))
        state.toggleWidths()
        XCTAssertEqual(state.displayed(base: true), CGSize(width: 80,height: 10))
        XCTAssertEqual(state.displayed(base: false), CGSize(width: 80,height: 10))
        state.zoom(zoomIn: true)
        XCTAssertEqual(state.displayed(base: true), CGSize(width: 96,height: 72))
        XCTAssertEqual(state.displayed(base: false), CGSize(width: 96,height: 72))
        state.originalSize() // Source applies 100% to base, then destination.
        XCTAssertEqual(state.base.percent, 200); XCTAssertEqual(state.destination.percent, 100)
        XCTAssertEqual(state.displayed(base: true), CGSize(width: 160,height: 20))
        XCTAssertEqual(state.displayed(base: false), CGSize(width: 160,height: 20))
        XCTAssertEqual(ImageComparisonGeometry.fittedScale(image: CGSize(width: 80,height: 60), viewport: CGSize(width: 500,height: 500)), 1)
    }
    func testSourceZoomQuantizationAndThresholds() {
        XCTAssertEqual(ImageComparisonGeometry.nextZoom(0.53, zoomIn: true), 0.6)
        XCTAssertEqual(ImageComparisonGeometry.nextZoom(0.53, zoomIn: false), 0.5)
        XCTAssertEqual(ImageComparisonGeometry.nextZoom(1, zoomIn: true), 1.2)
        XCTAssertEqual(ImageComparisonGeometry.nextZoom(1, zoomIn: false), 0.9)
        XCTAssertEqual(ImageComparisonGeometry.nextZoom(2, zoomIn: true), 2.1)
        XCTAssertEqual(ImageComparisonGeometry.nextZoom(2, zoomIn: false), 1.8)
        XCTAssertEqual(ImageComparisonGeometry.nextZoom(0.1, zoomIn: false), 0.1)
    }

}
