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
        return min(viewport.width / image.width, viewport.height / image.height)
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
