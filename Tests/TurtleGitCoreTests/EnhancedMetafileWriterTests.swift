// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import AppKit
@testable import TurtleGitCore

final class EnhancedMetafileWriterTests: XCTestCase {
    private let red = GraphVectorColor(red: 1, green: 0, blue: 0)
    private let green = GraphVectorColor(red: 0, green: 1, blue: 0)
    private let blue = GraphVectorColor(red: 0, green: 0, blue: 1)
    private struct Record { let type: UInt32; let bytes: Data }
    private func word(_ bytes: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
    private func records(_ bytes: Data) throws -> [Record] {
        var offset = 0, result = [Record]()
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { throw NSError(domain: "Truncated EMR header", code: 1) }
            let length = Int(word(bytes, offset + 4))
            guard length >= 8, length % 4 == 0, length <= bytes.count - offset else { throw NSError(domain: "Invalid EMR extent", code: 1) }
            result.append(Record(type: word(bytes, offset), bytes: bytes.subdata(in: offset..<(offset + length)))); offset += length
        }
        return result
    }
    private func pixels(_ bytes: Data) throws -> [UInt8] {
        let image = try XCTUnwrap(ComparisonImage(bytes: bytes), "Actual metafile reader refused exported EMF")
        XCTAssertEqual(image.pixels.width, 64); XCTAssertEqual(image.pixels.height, 64)
        var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
        try rgba.withUnsafeMutableBytes { memory in
            let context = try XCTUnwrap(CGContext(data: memory.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 256, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.interpolationQuality = .none; context.draw(image.pixels, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return rgba
    }
    private func expect(_ pixels: [UInt8], _ x: Int, _ y: Int, _ expected: [Int], tolerance: Int = 0,
                        file: StaticString = #filePath, line: UInt = #line) {
        let actual = (0..<4).map { Int(pixels[(y * 64 + x) * 4 + $0]) }
        XCTAssertTrue(zip(actual, expected).allSatisfy { abs($0.0 - $0.1) <= tolerance },
                      "Exported pixel (\(x),\(y)) = \(actual), expected \(expected)", file: file, line: line)
    }
    private var background: GraphVectorCommand {
        .fill(path: .rectangle(CGRect(x: 0, y: 0, width: 64, height: 64)), color: .white, rule: .nonZero)
    }

    func testEnhancedHeaderRecordBoundariesAndLargeThirtyTwoBitVectorGeometry() throws {
        let shape = GraphVectorPath(segments: [.move(CGPoint(x: 40000.25, y: 4.5)),
            .cubic(control1: CGPoint(x: 40100, y: 8), control2: CGPoint(x: 40200, y: 16), end: CGPoint(x: 40300, y: 20)),
            .quad(control: CGPoint(x: 40400, y: 24), end: CGPoint(x: 40500, y: 4)), .close])
        let bytes = try EnhancedMetafileWriter.encode(GraphVectorScene(size: CGSize(width: 50000, height: 2000), commands: [
            .fill(path: shape, color: red, rule: .evenOdd),
            .stroke(path: shape, color: .black, width: 1.5, dash: [4, 2])]))
        let parsed = try records(bytes), header = try XCTUnwrap(parsed.first)
        XCTAssertEqual(header.type, 1); XCTAssertEqual(header.bytes.count, 88)
        XCTAssertEqual(word(bytes, 40), 0x464d4520); XCTAssertEqual(word(bytes, 44), 0x10000)
        XCTAssertEqual(Int(word(bytes, 48)), bytes.count); XCTAssertEqual(Int(word(bytes, 52)), parsed.count)
        XCTAssertEqual(word(bytes, 16), 50000); XCTAssertEqual(word(bytes, 20), 2000)
        XCTAssertEqual(word(bytes, 32), UInt32((50000.0 * 2540 / 96).rounded()))
        XCTAssertEqual(parsed.last?.type, 14); XCTAssertEqual(parsed.last?.bytes.count, 20)
        XCTAssertTrue(parsed.contains { $0.type == 59 }); XCTAssertTrue(parsed.contains { $0.type == 5 })
        XCTAssertTrue(parsed.contains { $0.type == 62 }); XCTAssertTrue(parsed.contains { $0.type == 64 })
        XCTAssertFalse(parsed.contains { [76, 77, 80, 81, 114, 116].contains($0.type) }, "A vector-only graph became a page bitmap")
        let move = try XCTUnwrap(parsed.first { $0.type == 27 })
        XCTAssertEqual(Int32(bitPattern: word(move.bytes, 8)), 2_560_016, "Coordinate narrowed to Int16 or lost subpixel precision")
        let pen = try XCTUnwrap(parsed.first { $0.type == 95 })
        XCTAssertEqual(word(pen.bytes, 28), 0x12207, "Stroke must use geometric, butt/miter, user-style semantics")
        XCTAssertEqual(word(pen.bytes, 32), 96); XCTAssertEqual(word(pen.bytes, 48), 2)
        XCTAssertEqual(word(pen.bytes, 52), 256); XCTAssertEqual(word(pen.bytes, 56), 128)
        let curves = parsed.filter { $0.type == 5 }
        XCTAssertEqual(curves.count, 4, "Both fills and strokes must keep cubic and converted quadratic segments")
        XCTAssertEqual(curves.map { word($0.bytes, 24) }, [3,3,3,3])
    }

    func testExportedCompoundFillClipRestoreAndDashedStrokePaintActualGeometry() throws {
        let outer = GraphVectorPath.rectangle(CGRect(x: 8, y: 8, width: 48, height: 48))
        let hole = GraphVectorPath.rectangle(CGRect(x: 20, y: 20, width: 24, height: 24))
        let compound = GraphVectorPath(segments: outer.segments + hole.segments)
        let scene = GraphVectorScene(size: CGSize(width: 64, height: 64), commands: [background,
            .fill(path: compound, color: red, rule: .evenOdd), .save,
            .clip(path: .rectangle(CGRect(x: 0, y: 0, width: 32, height: 64)), rule: .nonZero),
            .fill(path: .rectangle(CGRect(x: 0, y: 28, width: 64, height: 8)), color: blue, rule: .nonZero), .restore,
            // Keep the exact-color samples inside a four-pixel outline; the
            // reader's antialiased mask fringe overlaps the center of a two-
            // pixel stroke. Dash length and phase remain independent of width.
            .stroke(path: GraphVectorPath(segments: [.move(CGPoint(x: 8, y: 52)), .line(CGPoint(x: 56, y: 52))]), color: green, width: 4, dash: [8,8])])
        let bytes = try EnhancedMetafileWriter.encode(scene), painted = try pixels(bytes)
        let pen=try XCTUnwrap(records(bytes).first{$0.type==95})
        XCTAssertEqual(word(pen.bytes,32),256);XCTAssertEqual(word(pen.bytes,52),512);XCTAssertEqual(word(pen.bytes,56),512)
        expect(painted, 12, 12, [255,0,0,255]); expect(painted, 24, 24, [255,255,255,255])
        expect(painted, 12, 32, [0,0,255,255]); expect(painted, 40, 32, [255,255,255,255])
        expect(painted, 48, 32, [255,0,0,255]); expect(painted, 4, 12, [255,255,255,255])
        expect(painted, 10, 52, [0,255,0,255]); expect(painted, 18, 52, [255,0,0,255])
        expect(painted, 26, 52, [0,255,0,255]); expect(painted, 34, 52, [255,0,0,255])
    }

    func testOnlyLocalRasterFallbackUsesPremultipliedAlphaWithVectorsRetained() throws {
        let raw = Data([255,0,0,255, 0,255,0,128, 0,0,255,0, 0,0,255,255])
        let scene = GraphVectorScene(size: CGSize(width: 64, height: 64), commands: [background,
            .fill(path: .rectangle(CGRect(x: 40, y: 8, width: 16, height: 16)), color: red, rule: .nonZero),
            .raster(GraphVectorRaster(rect: CGRect(x: 8, y: 8, width: 16, height: 16), width: 2, height: 2, rgba: raw))])
        let bytes = try EnhancedMetafileWriter.encode(scene), parsed = try records(bytes)
        let bitmaps = parsed.filter { $0.type == 114 }; XCTAssertEqual(bitmaps.count, 1)
        let bitmap = try XCTUnwrap(bitmaps.first)
        XCTAssertEqual(word(bitmap.bytes, 40), 0x01ff0000)
        XCTAssertEqual(word(bitmap.bytes, 84), 108); XCTAssertEqual(word(bitmap.bytes, 92), 148)
        XCTAssertEqual(word(bitmap.bytes, 100), 2); XCTAssertEqual(word(bitmap.bytes, 104), 2)
        XCTAssertEqual(Array(bitmap.bytes[148..<164]), [0,0,255,255, 0,128,0,128, 0,0,0,0, 255,0,0,255])
        XCTAssertEqual(raw, Data([255,0,0,255, 0,255,0,128, 0,0,255,0, 0,0,255,255]))
        XCTAssertEqual(parsed.filter { $0.type == 62 }.count, 2, "Surrounding graph geometry must stay vector")
        let painted = try pixels(bytes)
        expect(painted, 10, 10, [255,0,0,255]); expect(painted, 20, 10, [127,255,127,255], tolerance: 1)
        expect(painted, 10, 20, [255,255,255,255]); expect(painted, 20, 20, [0,0,255,255])
        expect(painted, 48, 16, [255,0,0,255]); expect(painted, 32, 16, [255,255,255,255])
    }

    func testMalformedUnresolvedAndCancelledScenesRefuseWithoutPartialDelivery() throws {
        let size = CGSize(width: 64, height: 64)
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try EnhancedMetafileWriter.encode(GraphVectorScene(size: size, commands: [background]), cancellation: token)) { XCTAssertTrue($0 is OperationCancellationFailure) }
        let invalidCommands: [[GraphVectorCommand]] = [
            [.text(GraphVectorText(text: "日本語🙂", origin: CGPoint(x: 8, y: 20)))],
            [.restore], [.save],
            [.fill(path: GraphVectorPath(segments: [.line(.zero)]), color: red, rule: .nonZero)],
            [.fill(path: .rectangle(CGRect(x: 0, y: 0, width: 1, height: 1)), color: GraphVectorColor(red: 1, green: 0, blue: 0, alpha: 0.5), rule: .nonZero)],
            [.stroke(path: GraphVectorPath(segments: [.move(.zero), .line(CGPoint(x: CGFloat.infinity, y: 0))]), color: red, width: 1, dash: [])],
            [.stroke(path: .rectangle(CGRect(x: 0, y: 0, width: 2, height: 2)), color: red, width: 1, dash: [0])],
            [.raster(GraphVectorRaster(rect: CGRect(x: 0, y: 0, width: 4, height: 4), width: 2, height: 2, rgba: Data([1,2,3,4])))]
        ]
        for commands in invalidCommands { XCTAssertThrowsError(try EnhancedMetafileWriter.encode(GraphVectorScene(size: size, commands: commands))) }
        XCTAssertThrowsError(try EnhancedMetafileWriter.encode(GraphVectorScene(size: CGSize(width: CGFloat.nan, height: 64))))
        XCTAssertThrowsError(try EnhancedMetafileWriter.encode(GraphVectorScene(size: CGSize(width: 1_000_001, height: 1))))
    }
}
