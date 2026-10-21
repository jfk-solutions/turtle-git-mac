// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum EnhancedMetafileWriterFailure: LocalizedError, Sendable {
    case invalidScene(String), unresolvedText, resourceLimit
    public var errorDescription: String? {
        switch self {
        case .invalidScene(let reason): return "Cannot export enhanced metafile: " + reason
        case .unresolvedText: return "Metafile text must be resolved into glyph outlines before export."
        case .resourceLimit: return "The enhanced metafile exceeds the supported export size."
        }
    }
}

/// Original MS-EMF writer. Both native .wmf and .emf graph destinations contain
/// enhanced metafiles, matching the source application's CreateEnhMetaFile route.
/// Vector positions use signed 32-bit, 1/64-pixel logical units plus a world
/// transform; no coordinate or shape is narrowed to classic WMF's 16-bit fields.
public enum EnhancedMetafileWriter {
    public static func encode(_ scene: GraphVectorScene, cancellation: OperationCancellation? = nil) throws -> Data {
        var encoder = Encoder(size: scene.size, cancellation: cancellation)
        return try encoder.encode(scene.commands)
    }

    private struct Encoder {
        let size: CGSize
        let cancellation: OperationCancellation?
        var output = Data()
        var records = 0, depth = 0, segments = 0, rasterPixels = 0
        let scale: CGFloat = 64
        let byteLimit = 64 * 1024 * 1024

        func invalid(_ text: String) -> EnhancedMetafileWriterFailure { .invalidScene(text) }
        func scalar(_ value: CGFloat) throws -> Int32 {
            guard value.isFinite, abs(value) <= 1_000_000 else { throw invalid("a coordinate is invalid or outside the supported range.") }
            return Int32((value * scale).rounded())
        }
        func point(_ point: CGPoint) throws -> Data { try integers([scalar(point.x), scalar(point.y)]) }
        func integers(_ values: [Int32]) -> Data { words(values.map { UInt32(bitPattern: $0) }) }
        func words(_ values: [UInt32]) -> Data {
            var bytes = Data(); bytes.reserveCapacity(values.count * 4)
            for value in values { var little = value.littleEndian; withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) } }
            return bytes
        }
        func floats(_ values: [Float]) -> Data { words(values.map(\.bitPattern)) }
        func color(_ color: GraphVectorColor) throws -> UInt32 {
            let channels = [color.red, color.green, color.blue, color.alpha]
            guard channels.allSatisfy({ $0.isFinite && (0...1).contains($0) }), color.alpha == 1 else {
                throw invalid("vector brush and pen colors must be finite and opaque.")
            }
            return UInt32((color.red * 255).rounded()) | UInt32((color.green * 255).rounded()) << 8 | UInt32((color.blue * 255).rounded()) << 16
        }
        func bounds() -> Data { integers([0, 0, Int32(ceil(size.width)), Int32(ceil(size.height))]) }
        mutating func record(_ type: UInt32, _ body: Data = Data()) throws {
            try cancellation?.check()
            guard records < 1_000_000, body.count <= byteLimit - 8, output.count <= byteLimit - body.count - 11 else { throw EnhancedMetafileWriterFailure.resourceLimit }
            let padding = (4 - body.count % 4) % 4
            output.append(words([type, UInt32(body.count + 8 + padding)])); output.append(body)
            output.append(Data(repeating: 0, count: padding)); records += 1
        }
        mutating func path(_ path: GraphVectorPath) throws {
            guard path.segments.count <= 500_000 - segments else { throw EnhancedMetafileWriterFailure.resourceLimit }
            segments += path.segments.count
            try record(59)
            var current: CGPoint?, beginning: CGPoint?
            for (index, segment) in path.segments.enumerated() {
                if index % 256 == 0 { try cancellation?.check() }
                switch segment {
                case .move(let next):
                    try record(27, point(next)); current = next; beginning = next
                case .line(let next):
                    guard current != nil else { throw invalid("a path line has no starting point.") }
                    try record(54, point(next)); current = next
                case .cubic(let c1, let c2, let next):
                    guard current != nil else { throw invalid("a path curve has no starting point.") }
                    try record(5, bounds() + words([3]) + point(c1) + point(c2) + point(next)); current = next
                case .quad(let control, let next):
                    guard let previous = current else { throw invalid("a quadratic curve has no starting point.") }
                    let c1 = CGPoint(x: previous.x + (control.x - previous.x) * 2 / 3, y: previous.y + (control.y - previous.y) * 2 / 3)
                    let c2 = CGPoint(x: next.x + (control.x - next.x) * 2 / 3, y: next.y + (control.y - next.y) * 2 / 3)
                    try record(5, bounds() + words([3]) + point(c1) + point(c2) + point(next)); current = next
                case .close:
                    guard let first = beginning else { throw invalid("a closed path has no figure.") }
                    try record(61); current = first
                }
            }
            if path.segments.isEmpty {
                // Empty clip paths must exclude everything, rather than leave
                // the previous clip unchanged in readers that ignore empty paths.
                try record(27, integers([-128, -128])); try record(54, integers([-64, -128]))
                try record(54, integers([-64, -64])); try record(54, integers([-128, -64])); try record(61)
            }
            try record(60)
        }
        mutating func raster(_ raster: GraphVectorRaster) throws {
            guard raster.width > 0, raster.height > 0, raster.width <= 32768, raster.height <= 32768,
                  raster.width <= 16_777_216 / raster.height,
                  raster.rect.width.isFinite, raster.rect.height.isFinite, raster.rect.width > 0, raster.rect.height > 0 else {
                throw invalid("a label bitmap has invalid dimensions.")
            }
            let count = raster.width * raster.height
            guard count <= 16_777_216 - rasterPixels, raster.rgba.count == count * 4,
                  count <= (byteLimit - output.count - 164) / 4 else { throw EnhancedMetafileWriterFailure.resourceLimit }
            rasterPixels += count
            var pixels = Data(count: count * 4)
            try raster.rgba.withUnsafeBytes { sourceRaw in
                let source = sourceRaw.bindMemory(to: UInt8.self)
                try pixels.withUnsafeMutableBytes { raw in
                    let destination = raw.bindMemory(to: UInt8.self)
                    for offset in stride(from: 0, to: source.count, by: 4) {
                        if offset % 16384 == 0 { try cancellation?.check() }
                        let alpha = UInt32(source[offset + 3])
                        destination[offset] = UInt8((UInt32(source[offset + 2]) * alpha + 127) / 255)
                        destination[offset + 1] = UInt8((UInt32(source[offset + 1]) * alpha + 127) / 255)
                        destination[offset + 2] = UInt8((UInt32(source[offset]) * alpha + 127) / 255)
                        destination[offset + 3] = UInt8(alpha)
                    }
                }
            }
            try cancellation?.check()
            let dib = words([40]) + integers([Int32(raster.width), -Int32(raster.height)]) + words([0x00200001, 0, UInt32(pixels.count), 0, 0, 0, 0])
            let destination = try point(raster.rect.origin) + integers([scalar(raster.rect.width), scalar(raster.rect.height)])
            let body = bounds() + destination + words([0x01ff0000, 0, 0]) + floats([1, 0, 0, 1, 0, 0])
                + words([0, 0, 108, 40, 148, UInt32(pixels.count), UInt32(raster.width), UInt32(raster.height)]) + dib + pixels
            try record(114, body)
        }
        mutating func encode(_ commands: [GraphVectorCommand]) throws -> Data {
            try cancellation?.check()
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  size.width <= 1_000_000, size.height <= 1_000_000,
                  commands.count <= 100_000 else { throw EnhancedMetafileWriterFailure.resourceLimit }
            // Reserve the standard 88-byte EMF header; patch counts only after
            // every command succeeds, so cancellation never returns partial bytes.
            output = Data(repeating: 0, count: 88); records = 1
            try record(17, words([1])) // MM_TEXT
            try record(35, floats([1 / 64, 0, 0, 1 / 64, 0, 0]))
            try record(18, words([1])) // transparent stroke gaps
            for command in commands {
                try cancellation?.check()
                switch command {
                case .save:
                    guard depth < 128 else { throw EnhancedMetafileWriterFailure.resourceLimit }
                    try record(33); depth += 1
                case .restore:
                    guard depth > 0 else { throw invalid("the graph restores an unsaved drawing state.") }
                    try record(34, integers([-1])); depth -= 1
                case .clip(let shape, let rule):
                    try record(19, words([rule == .evenOdd ? 1 : 2])); try path(shape); try record(67, words([1]))
                case .fill(let shape, let paint, let rule):
                    let rgb = try color(paint)
                    try record(33); try record(39, words([1, 0, rgb, 0])); try record(37, words([1]))
                    try record(19, words([rule == .evenOdd ? 1 : 2])); try path(shape); try record(62, bounds())
                    try record(34, integers([-1])); try record(40, words([1]))
                case .stroke(let shape, let paint, let width, let dash):
                    let rgb = try color(paint)
                    guard width.isFinite, width >= 0, width <= 1024, (width == 0 || width * scale >= 0.5), dash.count <= 16,
                          dash.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 15625 && $0 * scale >= 0.5 }) else { throw invalid("the stroke width or dash pattern is unsupported.") }
                    // Match the shared CGContext/NSBezierPath default: butt
                    // caps and miter joins, rather than GDI's round defaults.
                    let style: UInt32 = 0x12200 | (dash.isEmpty ? 0 : 7)
                    let pen = words([2, 0, 0, 0, 0, style, UInt32((width * scale).rounded()), 0, rgb, 0, UInt32(dash.count)] + dash.map { UInt32(($0 * scale).rounded()) })
                    try record(33); try record(95, pen); try record(37, words([2])); try path(shape); try record(64, bounds())
                    try record(34, integers([-1])); try record(40, words([2]))
                case .text: throw EnhancedMetafileWriterFailure.unresolvedText
                case .raster(let bitmap): try raster(bitmap)
                }
            }
            guard depth == 0 else { throw invalid("the graph leaves an unclosed drawing state.") }
            try record(14, words([0, 0, 20]))
            let frame = integers([0, 0, Int32((size.width * 2540 / 96).rounded()), Int32((size.height * 2540 / 96).rounded())])
            let header = words([1, 88]) + bounds() + frame + words([0x464d4520, 0x10000, UInt32(output.count), UInt32(records), 3, 0, 0, 0]) + integers([960, 960, 254, 254])
            guard header.count == 88 else { throw invalid("the metafile header could not be encoded.") }
            output.replaceSubrange(0..<88, with: header)
            try cancellation?.check(); return output
        }
    }
}
