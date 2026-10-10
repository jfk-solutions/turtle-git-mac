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
