// AppKit adaptation of GitLogListBase::DrawTagBranch/DrawTrackingRoundRect.
// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

extension NSAttributedString.Key {
    static let logReference = NSAttributedString.Key("TurtleGit.LogReference")
}

/// Keep text and canonical identity in the real text field, rather than rasterizing labels.
final class LogReferenceStyle: NSObject {
    let label: HistoryReferenceLabel
    let color: NSColor
    init(_ label: HistoryReferenceLabel, color: NSColor) { self.label = label; self.color = color }
    var pointed: Bool { label.kind == .annotatedTag }
}

enum LogReferenceDrawing {
    struct Geometry {
        let body: CGRect
        let shadow: CGRect?
        let interior: CGRect
        let tip: [CGPoint]
    }
    /// Source uses a four-pixel RoundRect diameter and an eight-pixel tag tip.
    static func geometry(_ rect: CGRect, tracking: Bool, pointed: Bool) -> Geometry {
        let body = CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - (pointed ? 8 : 0)), height: rect.height)
        let interior = tracking ? body.insetBy(dx: 1, dy: 1) : body
        return Geometry(body: body, shadow: tracking ? interior.offsetBy(dx: 2, dy: 2) : nil, interior: interior,
            tip: pointed ? [CGPoint(x: body.maxX, y: body.minY), CGPoint(x: body.maxX + 8, y: body.midY.rounded(.towardZero)), CGPoint(x: body.maxX, y: body.maxY)] : [])
    }
    /// CColors::MixColors truncates signed channel deltas before subtraction.
    static func mix(_ channels: [Int], toward target: Int, amount: Int) -> [Int] {
        channels.map { $0 - ($0 - target) * amount / 255 }
    }
    static func edgeColor(_ color: NSColor, toward target: Int, amount: Int) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        let mixed = mix(channels, toward: target, amount: amount)
        return NSColor(srgbRed: CGFloat(mixed[0])/255, green: CGFloat(mixed[1])/255, blue: CGFloat(mixed[2])/255, alpha: 1)
    }
    static func paint(_ rect: CGRect, style: LogReferenceStyle) {
        let shape = geometry(rect, tracking: style.label.hasTracking, pointed: style.pointed)
        let color = style.color
        if let shadow = shape.shadow {
            edgeColor(color, toward: 0, amount: 100).setFill()
            NSBezierPath(roundedRect: shadow, xRadius: 2, yRadius: 2).fill()
            color.setFill(); NSBezierPath(roundedRect: shape.interior, xRadius: 2, yRadius: 2).fill()
        } else {
            color.setFill(); NSBezierPath(rect: shape.body).fill()
            for (inset, amount) in [(CGFloat(0), 100), (CGFloat(1), 50)] {
                let edge = shape.body.insetBy(dx: inset + 0.5, dy: inset + 0.5)
                guard edge.width > 0, edge.height > 0 else { continue }
                stroke([CGPoint(x: edge.minX, y: edge.maxY), CGPoint(x: edge.minX, y: edge.minY), CGPoint(x: edge.maxX, y: edge.minY)], color: edgeColor(color, toward: 255, amount: amount))
                stroke([CGPoint(x: edge.maxX, y: edge.minY), CGPoint(x: edge.maxX, y: edge.maxY), CGPoint(x: edge.minX, y: edge.maxY)], color: edgeColor(color, toward: 0, amount: amount))
            }
        }
        if !shape.tip.isEmpty {
            let triangle = NSBezierPath(); triangle.move(to: shape.tip[0]); triangle.line(to: shape.tip[1]); triangle.line(to: shape.tip[2]); triangle.close()
            color.setFill(); triangle.fill()
            stroke([shape.tip[0], shape.tip[1]], color: edgeColor(color, toward: 255, amount: 50), width: 2)
            stroke([shape.tip[1], shape.tip[2]], color: edgeColor(color, toward: 0, amount: 50), width: 2)
            // DrawTagBranch erases the rectangle's right bevel at the join.
            stroke([CGPoint(x: shape.body.maxX - 1, y: shape.body.maxY - 3), CGPoint(x: shape.body.maxX - 1, y: shape.body.minY)], color: color, width: 2)
        }
    }
    private static func stroke(_ points: [CGPoint], color: NSColor, width: CGFloat = 1) {
        let path = NSBezierPath(); path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
        color.setStroke(); path.lineWidth = width; path.stroke()
    }
}

/// One-line TextKit drawing shares glyph positions with the badge painter, including
/// font changes, Unicode, upstream attachments and native tail truncation.
final class LogReferenceTextCell: NSTextFieldCell {
    struct BadgeFrame { let name: String; let range: NSRange; let rect: CGRect; let style: LogReferenceStyle }
    private(set) var badgeFrames: [BadgeFrame] = []

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let value = NSMutableAttributedString(attributedString: attributedStringValue)
        let full = NSRange(location: 0, length: value.length)
        guard full.length > 0 else { badgeFrames = []; return }
        // Preserve metadata/background attributes for accessibility and inspection;
        // only the drawing copy suppresses AppKit's flat background rectangles.
        value.enumerateAttribute(.logReference, in: full) { style, range, _ in
            if style is LogReferenceStyle { value.removeAttribute(.backgroundColor, range: range) }
        }
        value.enumerateAttribute(.foregroundColor, in: full) { color, range, _ in
            if color == nil { value.addAttribute(.foregroundColor, value: backgroundStyle == .emphasized ? NSColor.alternateSelectedControlTextColor : (textColor ?? .labelColor), range: range) }
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        value.addAttribute(.paragraphStyle, value: paragraph, range: full)
        let storage = NSTextStorage(attributedString: value), layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(0, cellFrame.width), height: max(1, cellFrame.height)))
        container.lineFragmentPadding = 0; container.maximumNumberOfLines = 1; container.lineBreakMode = .byTruncatingTail
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let glyphs = layout.glyphRange(for: container)
        let used = layout.usedRect(for: container)
        let origin = NSPoint(x: cellFrame.minX, y: cellFrame.minY + floor((cellFrame.height - used.height)/2))
        // Measure full labels independently of the ellipsis. The source clips
        // each label body to the column before adding its tag tip; it still
        // paints a sliver when the label text itself cannot fit.
        let naturalStorage = NSTextStorage(attributedString: value), naturalLayout = NSLayoutManager()
        let naturalContainer = NSTextContainer(containerSize: NSSize(width: max(cellFrame.width, ceil(value.size().width) + 1), height: max(1, cellFrame.height)))
        naturalContainer.lineFragmentPadding = 0; naturalContainer.maximumNumberOfLines = 1
        naturalStorage.addLayoutManager(naturalLayout); naturalLayout.addTextContainer(naturalContainer)
        let naturalGlyphs = naturalLayout.glyphRange(for: naturalContainer)
        let truncated = glyphs.length > 0 ? layout.truncatedGlyphRange(inLineFragmentForGlyphAt: glyphs.location) : NSRange(location: NSNotFound, length: 0)
        var clipsLabelText = false
        badgeFrames = []
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: cellFrame).addClip()
        value.enumerateAttribute(.logReference, in: full) { item, range, _ in
            guard let style = item as? LogReferenceStyle else { return }
            let badgeGlyphs = NSIntersectionRange(naturalLayout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), naturalGlyphs)
            guard badgeGlyphs.length > 0 else { return }
            let bounds = naturalLayout.boundingRect(forGlyphRange: badgeGlyphs, in: naturalContainer)
            let left = origin.x + bounds.minX, available = cellFrame.maxX - left
            guard available > 0 else { return }
            let tipWidth: CGFloat = style.pointed ? 8 : 0
            let rect = CGRect(x: left, y: cellFrame.minY, width: min(max(0, bounds.width - tipWidth), available) + tipWidth, height: cellFrame.height)
            let clipped = rect.intersection(cellFrame)
            guard !clipped.isNull && clipped.width > 0 else { return }
            badgeFrames.append(BadgeFrame(name: style.label.reference.name, range: range, rect: clipped, style: style))
            LogReferenceDrawing.paint(rect, style: style)
            let actualGlyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if truncated.location != NSNotFound && NSIntersectionRange(actualGlyphs, truncated).length > 0 { clipsLabelText = true }
        }
        // Ref labels use ordinary clipped text in the source; only the message
        // uses end ellipsis. When a ref occupies the clipped edge, draw its
        // natural glyphs under the column clip instead of adding an ellipsis.
        let drawingLayout = clipsLabelText ? naturalLayout : layout
        let drawingGlyphs = clipsLabelText ? naturalGlyphs : glyphs
        drawingLayout.drawBackground(forGlyphRange: drawingGlyphs, at: origin)
        drawingLayout.drawGlyphs(forGlyphRange: drawingGlyphs, at: origin)
    }
}
