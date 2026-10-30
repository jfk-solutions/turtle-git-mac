// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
import CryptoKit
@testable import TurtleGitCore

/// Expected pixels are retained Windows captures, never the port's filter output.
final class MetafileHalftoneWindowsCorpusTests: XCTestCase {
    private struct Entry: Decodable {
        let id: String
        let group: String?
        let input: String?
        let frame: [Int]
        let sampleRect: [Int]
        let wireSHA256: String
        let wireBase64: String
        let expectedRGBASHA256: String
        let expectedRGBABase64: String
    }
    private struct SignedGeometryCorpus: Decodable {
        let schema: Int
        let caseCount: Int
        let derivedCaseCount: Int
        let cases: [Entry]
    }
    private struct SamplingCorpus: Decodable {
        let schema: Int
        let caseCount: Int
        let cases: [SamplingEntry]
    }
    private struct SamplingEntry: Decodable {
        let id: String
        let group: String
        let state: Int
        let requestedQuarterPhase: Int
        let selfSource: Bool
        let destinationClipped: Bool
        let entry: Entry
        enum CodingKeys: String, CodingKey {
            case id, group, state, requestedQuarterPhase, destinationClipped
            case selfSource = "self"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            group = try values.decode(String.self, forKey: .group)
            state = try values.decode(Int.self, forKey: .state)
            requestedQuarterPhase = try values.decode(Int.self, forKey: .requestedQuarterPhase)
            selfSource = try values.decode(Bool.self, forKey: .selfSource)
            destinationClipped = try values.decode(Bool.self, forKey: .destinationClipped)
            entry = try Entry(from: decoder)
        }
    }
    private struct Corpus: Decodable {
        let schema: Int
        let caseCount: Int
        let uniformControls: Int
        let diagnosticCount: Int
        let continuityControl: Entry
        let cases: [Entry]
    }
    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    func testWMFBitmap16WindowsHalftoneBasisMatchesIndependentPixelMeasurements() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Metafile/Bitmap16Halftone/windows-basis-2026-10-30.json")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.schema, 1)
        XCTAssertEqual(corpus.caseCount, 611)
        XCTAssertEqual(corpus.cases.count, 611)
        XCTAssertEqual(corpus.uniformControls, 11)
        XCTAssertEqual(corpus.diagnosticCount, 600)
        XCTAssertEqual(Set(corpus.cases.map(\.id)).count, 611)
        XCTAssertEqual(corpus.cases.filter { $0.group?.hasSuffix("-control") == true }.count, 11)
        // Keep the independent colored control first. Grayscale impulse agreement
        // alone cannot establish the component arithmetic used for real pictures.
        try assertMeasuredEntries([corpus.continuityControl] + corpus.cases)
    }
    func testWMFBitmap16WindowsSamplingDomainsMatchOriginalUncutMeasurements() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Metafile/Bitmap16Halftone/windows-sampling-2026-10-30.json")
        let corpus = try JSONDecoder().decode(SamplingCorpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.schema, 1)
        XCTAssertEqual(corpus.caseCount, 400)
        XCTAssertEqual(corpus.cases.count, 400)
        XCTAssertEqual(Set(corpus.cases.map(\.id)).count, 400)
        let groups = Dictionary(grouping: corpus.cases, by: \.group).mapValues(\.count)
        XCTAssertEqual(groups, ["constant64": 4, "destination-clip": 4,
            "enlargement-control": 4, "fractional-phase": 32,
            "fractional-self-source": 8, "guarded-crop": 12,
            "heldout-pattern2d": 8, "matched-constant128": 68, "mixed-axis": 8,
            "point-impulse2d": 6, "point-impulse2d-continuity-ratio": 6,
            "ratio": 36, "saved-mode": 8, "self-source": 16, "signed-impulse": 180])
        XCTAssertEqual(Dictionary(grouping: corpus.cases, by: \.state).mapValues(\.count),
                       [0: 388, 1: 4, 2: 4, 3: 4])
        XCTAssertEqual(Dictionary(grouping: corpus.cases, by: \.requestedQuarterPhase).mapValues(\.count),
                       [0: 346, 1: 24, 2: 12, 3: 18])
        XCTAssertEqual(corpus.cases.filter(\.selfSource).count, 36)
        XCTAssertEqual(corpus.cases.filter(\.destinationClipped).count, 6)
        // Keep the recorded source/destination and complete measured target,
        // including pixels outside the active clip. No synthetic cropped wire,
        // matte substitution, alpha rewrite or phase normalization is allowed.
        XCTAssertTrue(corpus.cases.allSatisfy { $0.entry.frame == [64, 40] })
        try assertMeasuredEntries(corpus.cases.map(\.entry))
    }
    func testWMFBitmap16WindowsSignedGeometryAndIntegerBoxMatchFullMeasuredFrames() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Metafile")
        let corpus = try JSONDecoder().decode(SignedGeometryCorpus.self, from: Data(contentsOf:
            fixtures.appendingPathComponent("Bitmap16Halftone/windows-signed-geometry-2026-10-30.json")))
        XCTAssertEqual(corpus.schema, 1)
        XCTAssertEqual(corpus.caseCount, 55)
        XCTAssertEqual(corpus.derivedCaseCount, 48)
        XCTAssertEqual(corpus.cases.count, 55)
        XCTAssertEqual(Set(corpus.cases.map(\.id)).count, 55)
        let controls = corpus.cases.filter { $0.group == "unchanged-retained-control" }
        XCTAssertEqual(Set(controls.map(\.id)), ["b33", "b66", "b498", "b528", "b310", "continuity"])
        XCTAssertEqual(corpus.cases.filter { $0.group == "unchanged-historical-fixture" }.map(\.id), ["integer-box"])
        let transforms = ["src-x-negative-zero-anchor", "src-x-negative-inclusive-anchor",
            "src-x-negative-edge-anchor", "dst-x-negative-original-anchor",
            "dst-x-negative-edge-anchor", "both-x-negative-edge-anchors",
            "src-y-negative-edge-anchor", "src-y-negative-inclusive-anchor",
            "dst-y-negative-edge-anchor", "both-y-negative-edge-anchors",
            "both-xy-negative-edge-anchors", "dst-offcanvas-minus-one",
            "dst-plus-quarter-xy", "dst-minus-quarter-xy",
            "src-outside-minus-one-xy", "src-outside-plus-one-xy"]
        for input in ["b33", "b310", "continuity"] {
            let derived = corpus.cases.filter { $0.input == input && $0.id != input }
            XCTAssertEqual(Set(derived.map(\.id)), Set(transforms.map { input + "-" + $0 }))
        }
        for entry in corpus.cases {
            XCTAssertEqual(entry.sampleRect, [0, 0, entry.frame[0], entry.frame[1]],
                           "Full Windows frame must include unchanged background and clipped/outside pixels")
        }
        let integerBox = try XCTUnwrap(corpus.cases.first { $0.id == "integer-box" })
        let historicalWire = try Data(contentsOf: fixtures.appendingPathComponent("wmf-bitmap16-halftone-integer-box.wmf"))
        XCTAssertEqual(Data(base64Encoded: integerBox.wireBase64), historicalWire,
                       "Integer-box oracle must use the exact historical fixture wire")
        XCTAssertEqual(integerBox.wireSHA256, "795c8c2e60d7414053003406311eaf2b6a77e631e469ab4dc0ec77bae236645a")
        try assertMeasuredEntries(corpus.cases)
    }
    private func assertMeasuredEntries(_ entries: [Entry]) throws {
        for entry in entries {
            try autoreleasepool {
                let wire = try XCTUnwrap(Data(base64Encoded: entry.wireBase64), entry.id)
                let expected = try XCTUnwrap(Data(base64Encoded: entry.expectedRGBABase64), entry.id)
                XCTAssertEqual(digest(wire), entry.wireSHA256, "Changed independent input: \(entry.id)")
                XCTAssertEqual(digest(expected), entry.expectedRGBASHA256, "Changed measured output: \(entry.id)")
                guard entry.frame.count == 2, entry.sampleRect.count == 4 else {
                    return XCTFail("Invalid retained frame: \(entry.id)")
                }
                let width = entry.frame[0], height = entry.frame[1]
                let x = entry.sampleRect[0], y = entry.sampleRect[1]
                let columns = entry.sampleRect[2], rows = entry.sampleRect[3]
                guard width > 0, height > 0, width <= 240, height <= 160,
                      x >= 0, y >= 0, columns > 0, rows > 0,
                      x + columns <= width, y + rows <= height else {
                    return XCTFail("Invalid measured rectangle: \(entry.id)")
                }
                XCTAssertEqual(expected.count, columns * rows * 4, entry.id)
                let image = try XCTUnwrap(ComparisonImage(bytes: wire), "Native decode refused \(entry.id)")
                guard image.pixels.width == width, image.pixels.height == height else {
                    return XCTFail("Changed intrinsic frame: \(entry.id), \(image.pixels.width)x\(image.pixels.height)")
                }
                var rgba = Data(count: width * height * 4)
                try rgba.withUnsafeMutableBytes { storage in
                    let context = try XCTUnwrap(CGContext(data: storage.baseAddress,
                        width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    context.interpolationQuality = .none
                    context.draw(image.pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                var actual = Data()
                for row in 0..<rows {
                    let start = ((y + row) * width + x) * 4
                    actual.append(rgba[start..<(start + columns * 4)])
                }
                XCTAssertEqual(actual, expected,
                    "Windows Bitmap16 sampled raster \(entry.id) \(entry.group ?? "RGB continuity"); exact measured RGBA, no matte or fitted tolerance")
            }
        }
    }
}
