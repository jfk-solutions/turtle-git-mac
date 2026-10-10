import XCTest
import AppKit
@testable import TurtleGitCore

final class ImageComparisonTests: XCTestCase {
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
