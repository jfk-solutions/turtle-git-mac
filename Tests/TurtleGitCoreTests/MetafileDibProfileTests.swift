// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import CryptoKit
@testable import TurtleGitCore

final class MetafileDibProfileTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Metafile")
    private let consumers = ["emf-raster", "emf-scanlines", "emf-brush", "wmf-raster", "wmf-scanlines", "wmf-brush"]
    private struct Wire: Decodable {
        let file: String, consumer: String, variant: String, framingClassification: String, sha256: String
    }
    private struct Wires: Decodable { let caseCount: Int, cases: [Wire] }
    private struct Witness: Decodable {
        let file: String, input_sha256: String, rgba: String, rgba_sha256: String
        let width: Int, height: Int, load_status: Int, draw_status: Int, well_formed_profile_span: Bool
    }
    private struct Witnesses: Decodable { let cases: [Witness] }
    private struct Pixels: Equatable { let width: Int, height: Int, rgba: [UInt8] }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func wires() throws -> [Wire] {
        let data = try Data(contentsOf: root.appendingPathComponent("DIBProfiles/manifest.json"))
        let manifest = try JSONDecoder().decode(Wires.self, from: data)
        XCTAssertEqual(manifest.caseCount, 86); XCTAssertEqual(manifest.cases.count, 86)
        for item in manifest.cases {
            let bytes = try Data(contentsOf: root.appendingPathComponent("DIBProfiles/" + item.file))
            XCTAssertEqual(digest(bytes), item.sha256, item.file)
        }
        return manifest.cases
    }
    private func pixels(_ data: Data, name: String) throws -> Pixels {
        let image = try XCTUnwrap(ComparisonImage(bytes: data), "Refused valid profiled DIB: " + name)
        let width = image.pixels.width, height = image.pixels.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none
            context.draw(image.pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(width: width, height: height, rgba: rgba)
    }
    private func painting(_ item: Wire) throws -> Pixels {
        let url = root.appendingPathComponent("DIBProfiles/" + item.file), bytes = try Data(contentsOf: url)
        let result = try pixels(bytes, name: item.file)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Rendering changed input bytes")
        return result
    }
    private func equal(_ actual: Pixels, _ expected: Pixels, _ name: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, name, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, name, file: file, line: line)
        let pairs = zip(actual.rgba, expected.rgba)
        let first = pairs.enumerated().first { $0.element.0 != $0.element.1 }?.offset
        let maximum = pairs.map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
        XCTAssertTrue(actual.rgba == expected.rgba,
            "\(name): first differing byte \(String(describing: first)), maximum error \(maximum), actual SHA \(digest(Data(actual.rgba))), expected SHA \(digest(Data(expected.rgba)))",
            file: file, line: line)
    }
    private func baseline(_ consumer: String, _ all: [Wire]) throws -> Pixels {
        try painting(XCTUnwrap(all.first { $0.consumer == consumer && $0.variant == "v5-srgb" }))
    }
    private func color(_ r: Int, _ g: Int, _ b: Int, _ a: Int = 255) -> UInt32 {
        UInt32(r) << 24 | UInt32(g) << 16 | UInt32(b) << 8 | UInt32(a)
    }
    func testV4V5InactiveMetadataPreservesIndependentLiteralPixelsAcrossSixConsumers() throws {
        let all = try wires()
        let source = Array(Data(hex: "1020f040e020e8301080808024180c28b4dcbe6e32f8f8f88010407850b45c9c18d0d0d0000000ffffffaf7d4b2864a0"))
        let expected = Set(stride(from: 0, to: source.count, by: 3).map { color(Int(source[$0 + 2]), Int(source[$0 + 1]), Int(source[$0])) })
        for consumer in consumers {
            let reference = try baseline(consumer, all)
            let actual = Set(stride(from: 0, to: reference.rgba.count, by: 4).map { color(Int(reference.rgba[$0]), Int(reference.rgba[$0 + 1]), Int(reference.rgba[$0 + 2]), Int(reference.rgba[$0 + 3])) })
            XCTAssertTrue(expected.isSubset(of: actual), "Lost original BGR24 source colors: " + consumer)
            for item in all where item.consumer == consumer && item.framingClassification == "valid-inactive-colorspace-metadata" {
                equal(try painting(item), reference, item.file)
            }
        }
    }
    func testEmbeddedProfilesPreservePictureByteRGBThroughExplicitAndPackedLayouts() throws {
        let all = try wires()
        for consumer in consumers {
            let reference = try baseline(consumer, all)
            let items = all.filter { $0.consumer == consumer && $0.framingClassification == "valid-embedded-profile-span" && !$0.file.contains("-icm-") }
            XCTAssertEqual(items.count, consumer.hasPrefix("emf") ? 4 : 2, consumer)
            for item in items { equal(try painting(item), reference, item.file) }
        }
    }
    func testRecordedICMQueryOutsideDCAndSaveRestoreStayRenderableWithoutInventedConversion() throws {
        let all = try wires(), reference = try baseline("emf-raster", all)
        let items = all.filter { $0.file.contains("-icm-") }
        XCTAssertEqual(items.count, 14)
        for item in items { equal(try painting(item), reference, item.file) }
        // Pixels alone cannot distinguish internal saved ICM state when this
        // measured Picture load profile deliberately preserves byte RGB.
    }
    func testMalformedActiveProfileSpansRefuseInsteadOfBecomingImplicitPixels() throws {
        let items = try wires().filter { $0.framingClassification.hasPrefix("malformed-") }
        XCTAssertEqual(items.count, 30)
        for item in items {
            let url = root.appendingPathComponent("DIBProfiles/" + item.file), data = try Data(contentsOf: url)
            XCTAssertNil(ComparisonImage(bytes: data), item.file)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }
    func testInvalidRecordedICMValuesAndRecordExtentRefuse() throws {
        let url = root.appendingPathComponent("DIBProfiles/emf-raster-embedded-linear-rgb-before-icm-on.emf")
        let original = try Data(contentsOf: url)
        func word(_ data: Data, _ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
        }
        func put(_ data: inout Data, _ offset: Int, _ value: UInt32) {
            for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8)) }
        }
        var offset = Int(word(original, 4))
        while offset + 12 <= original.count && word(original, offset) != 98 {
            let size = Int(word(original, offset + 4))
            guard size >= 8, offset + size <= original.count else { return XCTFail("Invalid original record framing") }
            offset += size
        }
        XCTAssertEqual(word(original, offset), 98)
        for mode in [UInt32(0), 5, .max] {
            var bytes = original; put(&bytes, offset + 8, mode)
            XCTAssertNil(ComparisonImage(bytes: bytes), "Undefined ICM mode: \(mode)")
        }
        var oversized = original
        oversized.insert(contentsOf: [0, 0, 0, 0], at: offset + 12)
        put(&oversized, offset + 4, 16); put(&oversized, 48, UInt32(oversized.count))
        XCTAssertNil(ComparisonImage(bytes: oversized), "SETICMMODE must retain its exact DWORD payload")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testOriginalWindowsPictureWitnessesMatchFullRGBAAndNaturalExtent() throws {
        let folder = root.appendingPathComponent("DIBProfileWindows")
        let manifest = try JSONDecoder().decode(Witnesses.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.cases.count, 33)
        var accepted = 0
        for item in manifest.cases {
            let input = try Data(contentsOf: folder.appendingPathComponent(item.file))
            let output = try Data(contentsOf: folder.appendingPathComponent(item.rgba))
            XCTAssertEqual(digest(input), item.input_sha256); XCTAssertEqual(digest(output), item.rgba_sha256)
            XCTAssertEqual(item.load_status, 0); XCTAssertEqual(item.draw_status, 0)
            guard item.well_formed_profile_span else {
                XCTAssertNil(ComparisonImage(bytes: input), "Packed profile overlaps actual implicit pixels: " + item.file)
                continue
            }
            accepted += 1
            let actual = try pixels(input, name: item.file)
            XCTAssertEqual(actual.width, item.width, item.file); XCTAssertEqual(actual.height, item.height, item.file)
            equal(actual, Pixels(width: item.width, height: item.height, rgba: Array(output)), "Native Windows FALSE/Picture witness: " + item.file)
        }
        XCTAssertEqual(accepted, 31)
    }
}

private extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.utf8.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset), end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        })
    }
}
