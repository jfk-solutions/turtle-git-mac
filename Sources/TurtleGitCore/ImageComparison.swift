import Foundation
import ImageIO
import CoreGraphics

/// Decode the original Git/file bytes; no temporary previews or file mutations.
public struct ComparisonImage {
    public let pixels: CGImage
    public let dpiX: Double?
    public let dpiY: Double?
    public let frameCount: Int
    public var size: CGSize { CGSize(width: pixels.width, height: pixels.height) }
    public init?(bytes: Data) {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.pixels = pixels
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        dpiX = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        dpiY = (properties?[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
        frameCount = CGImageSourceGetCount(source)
    }
}
public struct ImageComparisonDocument {
    public let id = UUID()
    public let base: ComparisonImage?
    public let destination: ComparisonImage?
    public init?(_ document: FileComparisonDocument) {
        let a = ComparisonImage(bytes: document.base.bytes), b = ComparisonImage(bytes: document.destination.bytes)
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
