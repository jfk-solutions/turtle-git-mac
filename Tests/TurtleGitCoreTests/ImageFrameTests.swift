import XCTest
import ImageIO
import AppKit
@testable import TurtleGitCore

final class ImageFrameTests: XCTestCase {
    func sequence(type: CFString, colors: [NSColor], sizes: [CGSize]? = nil, delays: [Double] = []) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type, colors.count, nil))
        for (index,color) in colors.enumerated() {
            let size = sizes?[index] ?? CGSize(width: 4,height: 3)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0))
            let rgb = color.usingColorSpace(.deviceRGB)!
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * 4
                bitmap.bitmapData![offset] = UInt8(rgb.redComponent * 255); bitmap.bitmapData![offset + 1] = UInt8(rgb.greenComponent * 255)
                bitmap.bitmapData![offset + 2] = UInt8(rgb.blueComponent * 255); bitmap.bitmapData![offset + 3] = 255
            } }
            let properties: [CFString: Any] = delays.isEmpty ? [:] : [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[index], kCGImagePropertyGIFUnclampedDelayTime: delays[index]]]
            CGImageDestinationAddImage(destination,try XCTUnwrap(bitmap.cgImage),properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
    func testGIFLazyFramesPreserveIdentityColorsAndSourceDelays() throws {
        let data = try sequence(type: "com.compuserve.gif" as CFString,colors: [.red,.green,.blue],delays: [0.01,0.25,0.5])
        let first = try XCTUnwrap(ComparisonImage(bytes: data))
        XCTAssertEqual(first.frameCount,3); XCTAssertTrue(first.canAnimate); XCTAssertEqual(first.frameIndex,0)
        XCTAssertEqual(first.animationDelay,0.1,accuracy: 0.001)
        for index in 0..<3 {
            let frame = try XCTUnwrap(first.frame(at: index))
            XCTAssertEqual(frame.id,first.id); XCTAssertEqual(frame.frameIndex,index)
            let bitmap = NSBitmapImageRep(cgImage: frame.pixels), color = try XCTUnwrap(bitmap.colorAt(x: 1,y: 1)?.usingColorSpace(.deviceRGB))
            // GIF has no retained display-device profile; compare primary-color
            // dominance after AppKit color conversion, rather than zero channels.
            let actual = [color.redComponent,color.greenComponent,color.blueComponent]
            let primary = index
            XCTAssertGreaterThan(actual[primary],0.9)
            for channel in 0..<3 where channel != primary { XCTAssertLessThan(actual[channel],0.3) }

        }
        XCTAssertEqual(try XCTUnwrap(first.frame(at: 1)).animationDelay,0.25,accuracy: 0.001)
        XCTAssertNil(first.frame(at: -1)); XCTAssertNil(first.frame(at: 3))
        XCTAssertEqual(first.frameIndex,0)
    }
    func testTIFFPagesAndIconVariantsKeepDistinctDimensions() throws {
        let pages = try sequence(type: "public.tiff" as CFString,colors: [.red,.blue],sizes: [CGSize(width: 8,height: 5),CGSize(width: 3,height: 9)])
        let first = try XCTUnwrap(ComparisonImage(bytes: pages)), second = try XCTUnwrap(first.frame(at: 1))
        XCTAssertEqual(first.frameCount,2); XCTAssertTrue(first.canAnimate)
        XCTAssertEqual(first.size,CGSize(width: 8,height: 5)); XCTAssertEqual(second.size,CGSize(width: 3,height: 9))
        let resource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/TurtleGitCore/Resources/Icons/fitinwindow.ico")
        let icon = try XCTUnwrap(ComparisonImage(bytes: Data(contentsOf: resource)))
        XCTAssertEqual(icon.frameCount,2); XCTAssertTrue(icon.isIconVariants); XCTAssertFalse(icon.canAnimate)
        XCTAssertEqual(icon.size,CGSize(width: 48,height: 48))
        XCTAssertEqual(try XCTUnwrap(icon.frame(at: 1)).size,CGSize(width: 24,height: 24))
        var sizing = ImageComparisonSizing(base: icon.size,destination: second.size)
        sizing.setZoom(200,base: true)
        sizing.replacePixels(base: CGSize(width: 24,height: 24),destination: first.size)
        XCTAssertEqual(sizing.base.percent,200); XCTAssertEqual(sizing.displayed(base: true),CGSize(width: 48,height: 48))
        sizing.toggleWidths()
        let baseWidth = sizing.displayed(base: true).width
        XCTAssertEqual(sizing.displayed(base: false).width,48)
        sizing.replacePixels(base: CGSize(width: 12,height: 18),destination: CGSize(width: 30,height: 7))
        XCTAssertEqual(sizing.displayed(base: true).width,baseWidth)
        // Source SetZoom clears the initiating pane's explicit linked width.
        // That pane follows its retained 600-percent zoom after a frame change.
        XCTAssertEqual(sizing.destination.percent,600)
        XCTAssertEqual(sizing.displayed(base: false).width,180)
    }
    func testManualClampingPlaybackWrappingAndTimerFloor() {
        XCTAssertEqual(ImageComparisonFrames.next(0,count: 3,forward: false),0)
        XCTAssertEqual(ImageComparisonFrames.next(2,count: 3,forward: true),2)
        XCTAssertEqual(ImageComparisonFrames.next(2,count: 3,forward: true,wrapping: true),0)
        XCTAssertEqual(ImageComparisonFrames.next(0,count: 3,forward: false,wrapping: true),2)
        XCTAssertEqual(ImageComparisonFrames.next(10,count: 0,forward: true),0)
        XCTAssertEqual(ImageComparisonFrames.delay(0.01),0.1)
        XCTAssertEqual(ImageComparisonFrames.delay(0.25),0.25)
        XCTAssertEqual(ImageComparisonFrames.delay(.infinity),0.1)
    }
}
