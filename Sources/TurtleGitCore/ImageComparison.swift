import Foundation
import ImageIO
import CoreGraphics
import zlib
import AppKit

/// Decode the original Git/file bytes; no temporary previews or file mutations.
public struct ComparisonImage {
    public let id: UUID
    public let pixels: CGImage
    public let dpiX: Double?
    public let dpiY: Double?
    public let frameCount: Int
    public let frameIndex: Int
    public let animationDelay: TimeInterval
    public let isIconVariants: Bool
    public let cursorHotspot: CGPoint?
    private let cursorHotspots: [CGPoint]
    private let cursorFrames: [CGImageSource]?
    private let source: CGImageSource
    public var canAnimate: Bool { frameCount > 1 && !isIconVariants }
    public var size: CGSize { CGSize(width: pixels.width, height: pixels.height) }
    public init?(bytes: Data, cancellation: OperationCancellation? = nil) {
        guard cancellation?.isCancelled != true, !Task.isCancelled else { return nil }
        if bytes.starts(with: [0, 0, 2, 0]) {
            let hotspots = ImageComparisonContainers.cursorHotspots(bytes)
            guard !hotspots.isEmpty, let payloads = ImageComparisonContainers.cursorPayloads(bytes) else { return nil }
            let sources = payloads.compactMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            guard sources.count == payloads.count, let first = sources.first else { return nil }
            self.init(source: first, index: 0, id: UUID(), cursorHotspots: hotspots, cursorFrames: sources); return
        }
        guard let original = ImageComparisonContainers.payload(bytes) else { return nil }
        let payload: Data
        do { payload = try MetafileImageDecoder.convert(original, cancellation: cancellation) ?? original }
        catch { return nil }
        guard cancellation?.isCancelled != true, !Task.isCancelled else { return nil }
        if let source = CGImageSourceCreateWithData(payload as CFData, nil),
           let image = Self(source: source, index: 0, id: UUID(), cursorHotspots: ImageComparisonContainers.cursorHotspots(bytes)) { self = image; return }
        // AppKit supplies native vector rendering on systems whose ImageIO does
        // not rasterize SVG directly. Keep the private raster entirely in memory.
        guard ImageComparisonContainers.isSVG(payload), let native = NSImage(data: payload),
              native.size.width > 0, native.size.height > 0, native.size.width <= 32_768, native.size.height <= 32_768,
              native.size.width * native.size.height <= 67_108_864,
              let pixels = native.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = max(1, Int(ceil(native.size.width))), height = max(1, Int(ceil(native.size.height)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high; context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raster = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        let resolution = MetafileImageFormat.resolution(original)
        let properties = resolution.map { [kCGImagePropertyDPIWidth: $0.0, kCGImagePropertyDPIHeight: $0.1] as CFDictionary }
        CGImageDestinationAddImage(destination, raster, properties)
        guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithData(data, nil) else { return nil }
        self.init(source: source, index: 0, id: UUID(), cursorHotspots: [])
    }
    private init?(source: CGImageSource, index: Int, id: UUID, cursorHotspots: [CGPoint], cursorFrames: [CGImageSource]? = nil) {
        let count = cursorFrames?.count ?? CGImageSourceGetCount(source)
        guard (0..<count).contains(index) else { return nil }
        let selectedSource = cursorFrames?[index] ?? source, selectedIndex = cursorFrames == nil ? index : 0
        guard let pixels = CGImageSourceCreateImageAtIndex(selectedSource, selectedIndex, nil) else { return nil }
        self.cursorFrames = cursorFrames
        self.id = id; self.source = source; self.pixels = pixels; frameCount = count; frameIndex = index
        self.cursorHotspots = cursorHotspots
        cursorHotspot = cursorHotspots.indices.contains(index) ? cursorHotspots[index] : nil
        let type = CGImageSourceGetType(source) as String?
        isIconVariants = type == "com.microsoft.ico" || type == "com.microsoft.cur" || !cursorHotspots.isEmpty
        let properties = CGImageSourceCopyPropertiesAtIndex(selectedSource, selectedIndex, nil) as? [CFString: Any]
        dpiX = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        dpiY = (properties?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ??
            (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ??
            (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber)?.doubleValue ??
            (png?[kCGImagePropertyAPNGDelayTime] as? NSNumber)?.doubleValue ?? 0
        animationDelay = ImageComparisonFrames.delay(delay)
    }
    /// Decode only the requested frame/page/ICO representation, retaining source bytes.
    public func frame(at index: Int) -> ComparisonImage? { Self(source: source, index: index, id: id, cursorHotspots: cursorHotspots, cursorFrames: cursorFrames) }
}
/// Adapt packed Windows DIBs and compressed image data to native ImageIO without
/// writing temporary files or modifying the original Git/file bytes.
enum ImageComparisonContainers {
    static func payload(_ bytes: Data) -> Data? {
        if bytes.starts(with: [0x1f, 0x8b]) { return inflateGzip(bytes) }
        guard let header = u32(bytes, 0), [12, 40, 52, 56, 64, 108, 124].contains(header) else { return bytes }
        guard bytes.count >= header, u16(bytes, header == 12 ? 8 : 12) == 1,
              let bits = u16(bytes, header == 12 ? 10 : 14), [1, 4, 8, 16, 24, 32].contains(bits) else { return nil }
        let colors: Int, masks: Int
        if header == 12 { colors = bits <= 8 ? 1 << bits : 0; masks = 0 }
        else {
            guard let compression = u32(bytes, 16), let used = u32(bytes, 32), used <= 65_536 else { return nil }
            if bits <= 8, used > 1 << bits { return nil }
            colors = used > 0 ? used : bits <= 8 ? 1 << bits : 0
            masks = header == 40 ? (compression == 3 ? 12 : compression == 6 ? 16 : 0) : 0
        }
        let offset = header + masks + colors * (header == 12 ? 3 : 4)
        guard offset < bytes.count, bytes.count <= Int(UInt32.max) - 14 else { return nil }
        var result = Data([0x42, 0x4d]); append32(bytes.count + 14, to: &result)
        result.append(contentsOf: [0, 0, 0, 0]); append32(offset + 14, to: &result); result.append(bytes)
        return result
    }
    static func cursorHotspots(_ bytes: Data) -> [CGPoint] {
        guard u16(bytes, 0) == 0, u16(bytes, 2) == 2, let count = u16(bytes, 4), count > 0, count <= 256,
              bytes.count >= 6 + count * 16 else { return [] }
        var values: [CGPoint] = []
        for index in 0..<count {
            let entry = 6 + index * 16
            guard let x = u16(bytes, entry + 4), let y = u16(bytes, entry + 6),
                  let size = u32(bytes, entry + 8), let offset = u32(bytes, entry + 12), size > 0,
                  offset >= 6 + count * 16, offset <= bytes.count, size <= bytes.count - offset else { return [] }
            values.append(CGPoint(x: x, y: y))
        }
        return values
    }
    static func cursorPayloads(_ bytes: Data) -> [Data]? {
        let hotspots = cursorHotspots(bytes)
        guard !hotspots.isEmpty else { return nil }
        return hotspots.indices.map { index in
            let entry = 6 + index * 16, size = u32(bytes, entry + 8)!, offset = u32(bytes, entry + 12)!
            let payload = bytes.subdata(in: (bytes.startIndex + offset)..<(bytes.startIndex + offset + size))
            if payload.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return payload }
            let header = u32(payload, 0)
            let bits = u16(payload, header == 12 ? 10 : 14) ?? 32
            var icon = Data([0, 0, 1, 0, 1, 0])
            icon.append(bytes.subdata(in: (bytes.startIndex + entry)..<(bytes.startIndex + entry + 4)))
            icon.append(contentsOf: [1, 0, UInt8(bits & 255), UInt8((bits >> 8) & 255)])
            append32(size, to: &icon); append32(22, to: &icon); icon.append(payload); return icon
        }
    }
    private final class SVGProbe: NSObject, XMLParserDelegate {
        var found = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            found = elementName == "svg"; parser.abortParsing()
        }
    }
    static func isSVG(_ bytes: Data) -> Bool {
        let parser = XMLParser(data: bytes), probe = SVGProbe()
        parser.shouldResolveExternalEntities = false; parser.shouldProcessNamespaces = true; parser.delegate = probe
        _ = parser.parse(); return probe.found
    }
    private static func u16(_ data: Data, _ index: Int) -> Int? {
        guard index >= 0, index <= data.count - 2 else { return nil }
        return Int(data[data.startIndex + index]) | Int(data[data.startIndex + index + 1]) << 8
    }
    private static func u32(_ data: Data, _ index: Int) -> Int? {
        guard index >= 0, index <= data.count - 4 else { return nil }
        return (0..<4).reduce(0) { $0 | Int(data[data.startIndex + index + $1]) << ($1 * 8) }
    }
    private static func append32(_ value: Int, to data: inout Data) { for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> shift) & 255)) } }
    /// A bounded RFC 1952 stream, including concatenated members. CRC/truncation
    /// errors and decompression bombs fail before reaching the image decoder.
    private static func inflateGzip(_ bytes: Data) -> Data? {
        guard bytes.count <= Int(UInt32.max) else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        return bytes.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = UInt32(bytes.count)
            var result = Data(), chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                var status: Int32 = Z_OK
                let produced = chunk.withUnsafeMutableBytes { output -> Int in
                    stream.next_out = output.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = UInt32(output.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return output.count - Int(stream.avail_out)
                }
                guard result.count <= 67_108_864 - produced else { return nil }
                result.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END {
                    if stream.avail_in == 0 { return result }
                    guard inflateReset(&stream) == Z_OK else { return nil }
                } else if status != Z_OK || produced == 0 && stream.avail_in == 0 { return nil }
            }
        }
    }
}

public enum ImageComparisonFrames {
    public static func next(_ current: Int, count: Int, forward: Bool, wrapping: Bool = false) -> Int {
        guard count > 0 else { return 0 }
        let bounded = min(count - 1, max(0, current))
        if forward { return bounded == count - 1 ? (wrapping ? 0 : bounded) : bounded + 1 }
        return bounded == 0 ? (wrapping ? count - 1 : 0) : bounded - 1
    }
    public static func delay(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 0.1 }
        return min(2_147_483.647, max(0.1, seconds))
    }
}

public struct ImageComparisonDocument {
    public let id = UUID()
    public let base: ComparisonImage?
    public let destination: ComparisonImage?
    /// Explicit image-viewer inputs may have empty or unsupported image sides.
    public init(base: ComparisonImage?, destination: ComparisonImage?) { self.base = base; self.destination = destination }
    public init?(_ document: FileComparisonDocument, cancellation: OperationCancellation? = nil) {
        let a = ComparisonImage(bytes: document.base.bytes, cancellation: cancellation), b = ComparisonImage(bytes: document.destination.bytes, cancellation: cancellation)
        guard a != nil || b != nil,
              a != nil || document.base.bytes.isEmpty,
              b != nil || document.destination.bytes.isEmpty else { return nil }
        base = a; destination = b
    }
}
/// Pure viewport calculations shared by native panes and geometry tests.
public enum ImageComparisonGeometry {
    public static func fittedScale(image: CGSize, viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(1, viewport.width / image.width, viewport.height / image.height)
    }
    /// CPicWindow::Zoom quantizes to tens, with 20-percent steps between 100 and 200.
    public static func nextZoom(_ scale: CGFloat, zoomIn: Bool) -> CGFloat {
        guard scale.isFinite, scale >= 0, scale < CGFloat(Int.max / 100) else { return 1 }
        var percent = Int(scale * 100)
        if percent % 10 != 0 { percent = percent / 10 * 10 + (zoomIn ? 0 : 10) }
        if !zoomIn && percent <= 20 { return 0.1 }
        let step = (zoomIn && percent < 100) || (!zoomIn && percent <= 100) ? 10 :
            (zoomIn && percent < 200) || (!zoomIn && percent <= 200) ? 20 : 10
        return CGFloat(percent + (zoomIn ? step : -step)) / 100
    }
    public static func linkedOrigin(_ origin: CGPoint, content: CGSize, viewport: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, origin.x), max(0, content.width - viewport.width)),
                y: min(max(0, origin.y), max(0, content.height - viewport.height)))
    }
}

/// TortoiseIDiff's SRCINVERT followed by InvertRect: bytewise complement of
/// the XOR of two opaque rendered RGB panes. A difference blend is not equivalent.
public enum ImageComparisonXOR {
    public static func render(base: CGImage?, destination: CGImage?, width: Int, height: Int,
                              baseRect: CGRect, destinationRect: CGRect, background: CGColor) -> CGImage? {
        guard width > 0, height > 0, width <= Int.max / 4,
              height <= Int.max / (width * 4),
              [baseRect, destinationRect].allSatisfy({ [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let rowBytes = width * 4
        func pane(_ image: CGImage?, _ rect: CGRect) -> CGContext? {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: rowBytes, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            context.setFillColor(background); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            if let image { context.draw(image, in: CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)) }
            return context
        }
        guard let a = pane(base, baseRect), let b = pane(destination, destinationRect),
              let left = a.data?.assumingMemoryBound(to: UInt8.self),
              let right = b.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for offset in stride(from: 0, to: rowBytes * height, by: 4) {
            for channel in 0..<3 { left[offset + channel] = ~(left[offset + channel] ^ right[offset + channel]) }
            left[offset + 3] = 255
        }
        return a.makeImage()
    }
}

/// Per-picture zoom and linked dimensions mirror CPicWindow's sequential updates.
public struct ImageComparisonSizing {
    public struct Pane {
        public let pixels: CGSize
        public fileprivate(set) var percent = 100
        fileprivate var width: CGFloat?
        fileprivate var height: CGFloat?
        public var displayed: CGSize { CGSize(width: width.flatMap { $0 != 0 ? $0 : nil } ?? floor(pixels.width * CGFloat(percent) / 100),
                                             height: height.flatMap { $0 != 0 ? $0 : nil } ?? floor(pixels.height * CGFloat(percent) / 100)) }
    }
    public private(set) var base: Pane
    public private(set) var destination: Pane
    public private(set) var widths = false
    public private(set) var heights = false
    public var overlay = false
    public init(base: CGSize, destination: CGSize) { self.base = Pane(pixels: base); self.destination = Pane(pixels: destination) }
    /// Frame/ICO dimensions change without resetting zoom or linked extents.
    public mutating func replacePixels(base: CGSize, destination: CGSize) {
        func replacing(_ old: Pane, pixels: CGSize) -> Pane {
            var next = Pane(pixels: pixels); next.percent = old.percent; next.width = old.width; next.height = old.height; return next
        }
        self.base = replacing(self.base, pixels: base); self.destination = replacing(self.destination, pixels: destination)
    }
    public func pane(base: Bool) -> Pane { base ? self.base : destination }
    private mutating func assign(_ pane: Pane, base: Bool) { if base { self.base = pane } else { destination = pane } }
    public mutating func setZoom(_ percent: Int, base: Bool, linked: Bool = false) {
        var current = pane(base: base)
        guard current.percent != 0, percent > 0 else { return }
        current.percent = percent; assign(current, base: base)
        guard !linked else { return }
        if overlay { setZoom(percent, base: !base, linked: true) }
        if heights {
            current.height = nil; assign(current, base: base)
            var other = pane(base: !base)
            let target = floor(current.pixels.height * CGFloat(percent) / 100)
            other.height = target; assign(other, base: !base)
            if other.pixels.height > 0 { setZoom(Int(target * 100 / other.pixels.height), base: !base, linked: true) }
        }
        if widths {
            current.width = nil; assign(current, base: base)
            var other = pane(base: !base)
            let target = floor(current.pixels.width * CGFloat(percent) / 100)
            other.width = target; assign(other, base: !base)
            if other.pixels.width > 0 { setZoom(Int(target * 100 / other.pixels.width), base: !base, linked: true) }
        }
    }
    public mutating func toggleWidths() { widths.toggle(); reapplyZooms() }
    public mutating func toggleHeights() { heights.toggle(); reapplyZooms() }
    private mutating func reapplyZooms() { setZoom(base.percent, base: true); setZoom(destination.percent, base: false) }
    public mutating func originalSize() { setZoom(100, base: true); setZoom(100, base: false) }
    public mutating func zoom(zoomIn: Bool) {
        setZoom(Int((ImageComparisonGeometry.nextZoom(CGFloat(base.percent) / 100, zoomIn: zoomIn) * 100).rounded()), base: true)
        if !widths && !heights && !overlay {
            setZoom(Int((ImageComparisonGeometry.nextZoom(CGFloat(destination.percent) / 100, zoomIn: zoomIn) * 100).rounded()), base: false)
        }
    }
    public mutating func fit(baseViewport: CGSize, destinationViewport: CGSize) {
        for isBase in [true, false] {
            let size = pane(base: isBase).pixels, viewport = isBase ? baseViewport : destinationViewport
            let scale = ImageComparisonGeometry.fittedScale(image: size, viewport: viewport)
            setZoom(max(1, Int(floor(scale * 100))), base: isBase)
        }
    }
    public func displayed(base: Bool) -> CGSize {
        var pane = pane(base: base)
        if !widths { pane.width = nil }; if !heights { pane.height = nil }
        return pane.displayed
    }
}

public enum ImageComparisonBlend {
    public static func sliderValue(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return (min(1, max(0, value)) * 16).rounded() / 16
    }
    public static func toggled(_ value: Double) -> Double { value == 0 ? 1 : 0 }
    public static func wheel(_ value: Double, steps: Double) -> Double { min(1, max(0, value - steps / 4)) }
}
