// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
@testable import TurtleGitCore

final class MetafileDirectScanlineTests: XCTestCase {
    private let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private let red = [255, 0, 0, 255], green = [0, 255, 0, 255]
    private let blue = [0, 0, 255, 255], yellow = [255, 255, 0, 255], white = [255, 255, 255, 255]

    private struct Painting {
        let bytes: [UInt8]
        func pixel(_ x: Int, _ y: Int) -> [Int] { (0..<4).map { Int(bytes[(y * 64 + x) * 4 + $0]) } }
    }
    private func painting(_ filename: String) throws -> Painting {
        let url = directory.appendingPathComponent(filename), original = try Data(contentsOf: url)
        let image = try XCTUnwrap(ComparisonImage(bytes: original), "Direct scanline image refused: \(filename)")
        XCTAssertEqual(image.pixels.width, 64, filename); XCTAssertEqual(image.pixels.height, 64, filename)
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 256, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(image.pixels, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        XCTAssertEqual(try Data(contentsOf: url), original, "Rendering changed source bytes: \(filename)")
        return Painting(bytes: bytes)
    }
    private func expect(_ image: Painting, _ x: Int, _ y: Int, _ expected: [Int], _ name: String,
                        tolerance: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        let actual = image.pixel(x, y)
        XCTAssertTrue(zip(actual, expected).allSatisfy { abs($0.0 - $0.1) <= tolerance },
                      "\(name) at (\(x),\(y)): \(actual), expected \(expected)", file: file, line: line)
    }

    func testFullAndCroppedDirectScanlinesPaintIndependentDevicePixels() throws {
        for name in ["classic-scanlines-full-bottom.emf", "classic-scanlines-full-top.emf",
                     "classic-scanlines-wmf-full-bottom.wmf", "classic-scanlines-wmf-full-top.wmf"] {
            let image = try painting(name)
            expect(image, 12, 12, red, name); expect(image, 32, 12, green, name)
            expect(image, 12, 32, blue, name); expect(image, 32, 32, yellow, name)
            expect(image, 4, 12, white, name); expect(image, 44, 32, white, name)
        }
        let crop = try painting("classic-scanlines-crop.emf")
        expect(crop, 10, 10, red, "crop"); expect(crop, 20, 10, green, "crop")
        expect(crop, 10, 22, blue, "crop"); expect(crop, 20, 22, yellow, "crop")
        expect(crop, 26, 22, white, "crop bounded source")
        let outside = try painting("classic-scanlines-source-outside.emf")
        expect(outside, 14, 10, blue, "partially outside source")
        expect(outside, 10, 10, white, "crop shifts destination"); expect(outside, 14, 22, white, "crop lower edge")
        let negative = try painting("classic-scanlines-wmf-negative-destination.wmf")
        expect(negative, 4, 4, red, "signed WMF destination"); expect(negative, 16, 16, yellow, "signed WMF destination")
        expect(negative, 28, 16, white, "signed WMF clipping")
    }

    func testPartialScanlineBandsPaletteFormatsAndCompressedColors() throws {
        for name in ["classic-scanlines-partial-bottom.emf", "classic-scanlines-partial-top.emf",
                     "classic-scanlines-wmf-partial-bottom.wmf", "classic-scanlines-wmf-partial-top.wmf"] {
            let image = try painting(name)
            expect(image, 16, 28, red, name); expect(image, 16, 20, white, name)
            expect(image, 16, 36, white, name); expect(image, 4, 28, white, name)
        }
        for orientation in ["top", "bottom"] {
            let image = try painting("classic-scanlines-band-asymmetric-\(orientation).emf")
            expect(image, 16, 25, red, orientation + " band upper rows")
            expect(image, 16, 30, blue, orientation + " band lower rows")
        }
        for depth in [1, 4, 8] {
            let name = "classic-scanlines-depth-\(depth).emf", image = try painting(name)
            expect(image, 12, 12, red, name); expect(image, 32, 12, green, name)
        }
        for name in ["classic-scanlines-depth-16.emf", "classic-scanlines-depth-24.emf", "classic-scanlines-depth-32.emf", "classic-scanlines-bitfields.emf"] {
            let image = try painting(name)
            expect(image, 12, 12, red, name); expect(image, 32, 12, green, name)
            expect(image, 12, 32, blue, name); expect(image, 32, 32, yellow, name)
        }
        for name in ["classic-scanlines-core.emf", "classic-scanlines-palette.emf", "classic-scanlines-wmf-palette.wmf", "classic-scanlines-rle4.emf", "classic-scanlines-rle8.emf"] {
            let image = try painting(name)
            expect(image, 12, 12, red, name); expect(image, 32, 32, green, name)
        }
        for name in ["classic-scanlines-png.emf", "classic-scanlines-wmf-png.wmf", "classic-scanlines-png-alpha.emf", "classic-scanlines-jpeg.emf"] {
            let image = try painting(name)
            // Alpha 0,128,255 in the PNG are reserved for this classic copy:
            // every encoded red sample is copied opaquely, without white blending.
            for x in [12, 24, 36] { expect(image, x, 16, red, name, tolerance: name.contains("jpeg") ? 2 : 0) }
            expect(image, 44, 16, white, name)
        }
    }

    func testDefaultLogicalPaletteDirectPixelsAndPartialBands() throws {
        // DEFAULT_PALETTE is the documented common-display 20-entry playback
        // profile. These records intentionally never select a custom palette.
        for kind in ["", "wmf-"] {
            let suffix = kind.isEmpty ? ".emf" : ".wmf"
            let name = "classic-scanlines-" + kind + "default-palette" + suffix
            let image = try painting(name)
            expect(image, 12, 12, [0, 0, 0, 255], name)
            expect(image, 32, 32, [128, 0, 0, 255], name)
            expect(image, 4, 12, white, name)
            for orientation in ["top", "bottom"] {
                let bandName = "classic-scanlines-" + kind + "default-palette-band-" + orientation + suffix
                let band = try painting(bandName)
                expect(band, 12, 28, red, bandName)
                expect(band, 32, 28, green, bandName)
                expect(band, 12, 20, white, bandName)
                expect(band, 12, 36, white, bandName)
            }
        }
    }

    func testDirectScanlinesTransformOriginOnlyAndRespectClipRestoreAndSourceCopy() throws {
        let scaled = try painting("classic-scanlines-transform-origin.emf")
        expect(scaled, 16, 16, red, "transformed origin"); expect(scaled, 36, 16, green, "unscaled source width")
        expect(scaled, 16, 36, blue, "unscaled source height"); expect(scaled, 48, 16, white, "not stretched")
        let rotated = try painting("classic-scanlines-transform-rotate.emf")
        expect(rotated, 44, 12, red, "rotated origin"); expect(rotated, 44, 28, blue, "unrotated pixels")
        expect(rotated, 36, 12, white, "source rectangle not rotated")
        let clipped = try painting("classic-scanlines-clip-restore.emf")
        expect(clipped, 20, 20, red, "source-copy ignores ROP2 BLACK"); expect(clipped, 28, 28, yellow, "clip interior")
        expect(clipped, 12, 20, white, "clip exterior"); expect(clipped, 36, 28, white, "clip exterior")
        expect(clipped, 52, 52, blue, "restored clip")
        let wmf = try painting("classic-scanlines-wmf-map-origin.wmf")
        expect(wmf, 12, 12, red, "WMF transformed origin"); expect(wmf, 36, 12, green, "WMF device extent")
        expect(wmf, 44, 12, white, "WMF no stretching")
        let selected = try painting("classic-scanlines-wmf-selected-clip.wmf")
        expect(selected, 20, 20, red, "copied device clip")
        expect(selected, 12, 20, white, "device clip left boundary")
        expect(selected, 36, 20, white, "device clip independent of subsequent mapping")
        let bands = try painting("classic-scanlines-two-bands.emf")
        expect(bands, 16, 12, red, "upper physical band"); expect(bands, 16, 36, blue, "lower physical band")
        let noop = try painting("classic-scanlines-noop.emf")
        XCTAssertTrue(stride(from: 0, to: noop.bytes.count, by: 4).allSatisfy { Array(noop.bytes[$0..<($0+4)]) == [255,255,255,255] })
    }

    func testMalformedDirectScanlinesRefuseEntirePaintedPrefixAndPreserveSource() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("unsupported-scanlines-") }.sorted { $0.path < $1.path }
        XCTAssertGreaterThanOrEqual(files.count, 18)
        for url in files {
            let original = try Data(contentsOf: url)
            XCTAssertNil(ComparisonImage(bytes: original), "Malformed direct record painted its valid prefix: \(url.lastPathComponent)")
            XCTAssertEqual(try Data(contentsOf: url), original, url.lastPathComponent)
        }
    }
}
