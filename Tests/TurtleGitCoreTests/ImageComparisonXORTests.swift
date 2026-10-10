import XCTest
import CoreGraphics
@testable import TurtleGitCore

final class ImageComparisonXORTests: XCTestCase {
    private func image(_ rgba: [UInt8], width: Int, height: Int = 1) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func bytes(_ image: CGImage) throws -> [UInt8] { Array(try XCTUnwrap(image.dataProvider?.data) as Data) }
    private let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    func testExactComplementedXORIsNotAnAbsoluteDifferenceBlend() throws {
        let a = try image([0x12,0x34,0x56,255], width: 1), b = try image([0xA5,0x3C,0xF0,255], width: 1)
        let rect = CGRect(x: 0,y: 0,width: 1,height: 1)
        let result = try XCTUnwrap(ImageComparisonXOR.render(base: a, destination: b, width: 1, height: 1, baseRect: rect, destinationRect: rect, background: white))
        XCTAssertEqual(try bytes(result), [0x48,0xF7,0x59,255])
        let unchanged = try XCTUnwrap(ImageComparisonXOR.render(base: a, destination: a, width: 1, height: 1, baseRect: rect, destinationRect: rect, background: CGColor(srgbRed: 0.1,green: 0.2,blue: 0.3,alpha: 1)))
        XCTAssertEqual(try bytes(unchanged), [255,255,255,255])
    }
    func testScalingAndPositionApplyBeforeXORAndMissingAreasUseBackground() throws {
        let a = try image([255,0,0,255, 0,0,255,255], width: 2)
        let b = try image([0,255,0,255], width: 1)
        let rect = CGRect(x: 0,y: 0,width: 4,height: 1)
        let scaled = try XCTUnwrap(ImageComparisonXOR.render(base: a, destination: b, width: 4, height: 1, baseRect: rect, destinationRect: rect, background: white))
        XCTAssertEqual(try bytes(scaled), [0,0,255,255, 0,0,255,255, 255,0,0,255, 255,0,0,255])
        let shifted = try XCTUnwrap(ImageComparisonXOR.render(base: b, destination: nil, width: 3, height: 1,
            baseRect: CGRect(x: 1,y: 0,width: 1,height: 1), destinationRect: .zero, background: white))
        XCTAssertEqual(try bytes(shifted), [255,255,255,255, 0,255,0,255, 255,255,255,255])
    }
    func testTransparentPixelsAreComparedAfterOpaqueBackgroundComposition() throws {
        let invisible = try image([0,0,0,0], width: 1)
        let rect = CGRect(x: 0,y: 0,width: 1,height: 1)
        let result = try XCTUnwrap(ImageComparisonXOR.render(base: invisible, destination: nil, width: 1, height: 1, baseRect: rect, destinationRect: rect, background: white))
        XCTAssertEqual(try bytes(result), [255,255,255,255])
        XCTAssertNil(ImageComparisonXOR.render(base: nil, destination: nil, width: 0, height: 1, baseRect: rect, destinationRect: rect, background: white))
        XCTAssertNil(ImageComparisonXOR.render(base: nil, destination: nil, width: Int.max, height: 1, baseRect: rect, destinationRect: rect, background: white))
    }
}
