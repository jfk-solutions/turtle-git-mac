// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Immutable display list shared by native graph presentation and export.
/// Coordinates use a top-left origin; text origins are baselines in that space.
public struct GraphVectorScene: Sendable {
    public var size: CGSize
    public var commands: [GraphVectorCommand]
    public init(size: CGSize, commands: [GraphVectorCommand] = []) { self.size = size; self.commands = commands }
}

public struct GraphVectorColor: Sendable, Equatable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let black = Self(red: 0, green: 0, blue: 0)
    public static let white = Self(red: 1, green: 1, blue: 1)
}

public enum GraphVectorFillRule: Sendable, Equatable { case nonZero, evenOdd }
public enum GraphVectorTextAlignment: Sendable, Equatable { case leading, center, trailing }

public struct GraphVectorPath: Sendable {
    public enum Segment: Sendable {
        case move(CGPoint), line(CGPoint)
        case cubic(control1: CGPoint, control2: CGPoint, end: CGPoint)
        case quad(control: CGPoint, end: CGPoint)
        case close
    }
    public var segments: [Segment]
    public init(segments: [Segment] = []) { self.segments = segments }
    public static func rectangle(_ rect: CGRect) -> Self {
        Self(segments: [.move(CGPoint(x: rect.minX, y: rect.minY)), .line(CGPoint(x: rect.maxX, y: rect.minY)),
            .line(CGPoint(x: rect.maxX, y: rect.maxY)), .line(CGPoint(x: rect.minX, y: rect.maxY)), .close])
    }
}

public struct GraphVectorText: Sendable {
    public var text: String
    public var origin: CGPoint
    public var fontName: String
    public var fontSize: CGFloat
    public var color: GraphVectorColor
    public var alignment: GraphVectorTextAlignment
    public var rotation: CGFloat
    public init(text: String, origin: CGPoint, fontName: String = "Helvetica", fontSize: CGFloat = 12,
                color: GraphVectorColor = .black, alignment: GraphVectorTextAlignment = .leading, rotation: CGFloat = 0) {
        self.text = text; self.origin = origin; self.fontName = fontName; self.fontSize = fontSize
        self.color = color; self.alignment = alignment; self.rotation = rotation
    }
}

/// Straight, row-major RGBA8 samples. The writer premultiplies only when encoding
/// an individual raster command; vector paths remain paths in the metafile.
public struct GraphVectorRaster: Sendable {
    public var rect: CGRect
    public var width: Int, height: Int
    public var rgba: Data
    public init(rect: CGRect, width: Int, height: Int, rgba: Data) {
        self.rect = rect; self.width = width; self.height = height; self.rgba = rgba
    }
}

public enum GraphVectorCommand: Sendable {
    case save, restore
    case clip(path: GraphVectorPath, rule: GraphVectorFillRule)
    case fill(path: GraphVectorPath, color: GraphVectorColor, rule: GraphVectorFillRule)
    case stroke(path: GraphVectorPath, color: GraphVectorColor, width: CGFloat, dash: [CGFloat])
    case text(GraphVectorText)
    case raster(GraphVectorRaster)
}
