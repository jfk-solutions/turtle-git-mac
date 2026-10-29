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

final class LogReferenceMenuTarget: NSObject {
    let revisionHash: String, name: String
    init(hash: String, name: String) { self.revisionHash = hash; self.name = name }
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
    private(set) var interactionGeneration = UUID()
    override var attributedStringValue: NSAttributedString {
        didSet { invalidateReferenceGeometry() }
    }
    override var stringValue: String {
        didSet { invalidateReferenceGeometry() }
    }
    override var font: NSFont? {
        didSet { invalidateReferenceGeometry() }
    }
    func invalidateReferenceGeometry() { badgeFrames = []; interactionGeneration = UUID() }
    var uniqueBadgeFrames: [BadgeFrame] {
        var seen = Set<GitReferenceName>()
        return Array(badgeFrames.reversed().filter { seen.insert(GitReferenceName($0.name)).inserted }.reversed())
    }
    func reference(at point: NSPoint) -> RevisionReference? {
        // Source m_RefLabelPosMap retains the last rectangle for a canonical
        // name (a shared upstream can be painted beside several local refs).
        var seen = Set<Data>()
        for frame in badgeFrames.reversed() where seen.insert(Data(frame.name.utf8)).inserted {
            let r = frame.rect
            if point.x >= r.minX && point.x < r.maxX && point.y >= r.minY && point.y < r.maxY { return frame.style.label.reference }
        }
        return nil
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let previousFrames = badgeFrames
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
        let sameFrames = previousFrames.count == badgeFrames.count && zip(previousFrames, badgeFrames).allSatisfy { pair in
            GitReferenceName.equal(pair.0.name, pair.1.name) && pair.0.range == pair.1.range && pair.0.rect == pair.1.rect && pair.0.style.label == pair.1.style.label
        }
        if !sameFrames { interactionGeneration = UUID() }
        (controlView as? LogReferenceTextField)?.referenceGeometryChanged()
    }
}


/// Native tooltip and accessibility entry points share the painter's exact
/// clipped rectangles and canonical names, never shortened/symbolized text.
final class LogReferenceTextField: NSTextField {
    var tooltipForReference: ((String?) -> String?)?
    var onHoverReference: ((String?) -> Void)?
    var onReferenceMenu: ((String, NSPoint) -> Bool)?
    var referenceInteractionAllowed: () -> Bool = { true }
    private var hoverName: GitReferenceName?
    private var referenceTracking: NSTrackingArea?
    private var tooltipBounds = NSRect.null
    private var accessibleGeneration = UUID()
    private var accessibleBadges: [LogReferenceAccessibleBadge] = []
    private struct MessageSemantics:Equatable {
        let message:String,identity:String,revision:String,label:String
    }
    private var messageSemantics:MessageSemantics?
    private var semanticGeneration=UUID(),accessibleSemanticGeneration=UUID()
    private var messageAvailable:()->Bool = {true}
    private var accessibleMessage:LogMessageAccessibleText?
    /// Semantics come from the actual row, independently of painted references.
    /// Identical subjects on different commits/occurrences are distinct owners.
    func configureAccessibility(message:String,identity:String,revision:String,label:String,available:@escaping ()->Bool) {
        let next=MessageSemantics(message:message,identity:identity,revision:revision,label:label)
        messageAvailable=available
        if messageSemantics != next {
            messageSemantics=next;semanticGeneration=UUID()
            accessibleMessage=nil;accessibleBadges=[]
            referenceCell?.invalidateReferenceGeometry()
            NSAccessibility.post(element:self,notification:.layoutChanged)
        }
        setAccessibilityElement(true)
    }
    fileprivate func acceptsMessage(_ generation:UUID)->Bool {
        generation==semanticGeneration && messageSemantics != nil && window?.isVisible==true && window?.isMiniaturized==false &&
            !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty && messageAvailable()
    }
    fileprivate func messageFrame(_ generation:UUID)->NSRect {
        guard acceptsMessage(generation),let window else{return .zero}
        let rect=bounds.intersection(visibleRect)
        guard !rect.isNull,!rect.isEmpty else{return .zero}
        return window.convertToScreen(convert(rect,to:nil))
    }
    var referenceCell: LogReferenceTextCell? { cell as? LogReferenceTextCell }
    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { referenceCell?.invalidateReferenceGeometry() }
        super.setFrameSize(newSize)
    }
    override func setBoundsSize(_ newSize: NSSize) {
        if bounds.size != newSize { referenceCell?.invalidateReferenceGeometry() }
        super.setBoundsSize(newSize)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if referenceTracking == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            referenceTracking = area; addTrackingArea(area)
        }
        refreshTooltipBounds()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverName = nil; onHoverReference?(nil); accessibleBadges = [];accessibleMessage=nil;semanticGeneration=UUID() }
        else { updateTrackingAreas() }
    }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoverName = nil; onHoverReference?(nil) }
    func updateHover(at point: NSPoint) {
        let name = referenceCell?.reference(at: point)?.name
        let next = name.map { GitReferenceName($0) }
        guard next != hoverName else { return }; hoverName = next; onHoverReference?(name)
    }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        tooltip(at: point) ?? ""
    }
    func tooltip(at point: NSPoint) -> String? {
        guard window != nil, bounds.contains(point) else { return nil }
        let name = referenceCell?.reference(at: point)?.name
        onHoverReference?(name)
        return tooltipForReference?(name)
    }
    private func refreshTooltipBounds() {
        if tooltipBounds != bounds { tooltipBounds = bounds; removeAllToolTips(); addToolTip(bounds, owner: self, userData: nil) }
    }
    func referenceGeometryChanged() {
        refreshTooltipBounds()
        guard let cell = referenceCell,
            accessibleGeneration != cell.interactionGeneration || accessibleSemanticGeneration != semanticGeneration else { return }
        accessibleGeneration = cell.interactionGeneration;accessibleSemanticGeneration=semanticGeneration
        // Text has semantic, rather than painter, lifetime. A repaint can
        // rebuild badge geometry while AX is traversing the same native row.
        // Keep the same text element until its message/row owner changes.
        if accessibleMessage==nil,let semantics=messageSemantics {
            accessibleMessage=LogMessageAccessibleText(field:self,message:semantics.message,identity:semantics.identity,revision:semantics.revision,generation:semanticGeneration)
        }
        accessibleBadges = cell.uniqueBadgeFrames.map { LogReferenceAccessibleBadge(field: self, frame: $0, generation: accessibleGeneration,semanticGeneration:semanticGeneration) }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }
    fileprivate func ownsReference(_ name:String,generation:UUID,semanticGeneration:UUID)->Bool {
        acceptsMessage(semanticGeneration) && referenceCell?.interactionGeneration == generation &&
            referenceCell?.uniqueBadgeFrames.contains(where: {GitReferenceName.equal($0.name,name)}) == true
    }
    func accepts(_ name: String, generation: UUID,semanticGeneration:UUID) -> Bool {
        ownsReference(name,generation:generation,semanticGeneration:semanticGeneration) && referenceInteractionAllowed()
    }
    func showReferenceMenu(name: String, generation: UUID,semanticGeneration:UUID) -> Bool {
        guard accepts(name, generation: generation,semanticGeneration:semanticGeneration), let frame = referenceCell?.uniqueBadgeFrames.first(where: { GitReferenceName.equal($0.name, name) }) else { return false }
        return onReferenceMenu?(name, NSPoint(x: frame.rect.midX, y: frame.rect.midY)) == true
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String { messageSemantics?.label ?? "" }
    override func accessibilityIdentifier() -> String { messageSemantics.map {$0.identity + ".Message"} ?? "" }
    override func accessibilityHelp() -> String? { messageSemantics?.revision }
    override func accessibilityChildren() -> [Any]? {
        referenceGeometryChanged()
        guard acceptsMessage(semanticGeneration) else{return []}
        var children:[Any]=[]
        if let accessibleMessage {children.append(accessibleMessage)}
        children.append(contentsOf:accessibleBadges)
        return children
    }
}

/// Passive text preserves the native table's selection and keyboard semantics.
/// Its value includes the whole configured message even when painting truncates.
@MainActor final class LogMessageAccessibleText:NSAccessibilityElement {
    private weak var field:LogReferenceTextField?
    private let message:String,identity:String,revision:String
    private let generation:UUID
    init(field:LogReferenceTextField,message:String,identity:String,revision:String,generation:UUID) {
        self.field=field;self.message=message;self.identity=identity;self.revision=revision;self.generation=generation
        super.init();setAccessibilityElement(true);setAccessibilityRole(.staticText)
    }
    private var current:Bool {field?.acceptsMessage(generation)==true}
    override func accessibilityParent()->Any? {current ? field:nil}
    override func accessibilityValue()->Any? {current ? message:nil}
    override func accessibilityIdentifier()->String? {current ? identity + ".MessageText":nil}
    override func accessibilityHelp()->String? {current ? revision:nil}
    override func accessibilityFrame()->NSRect {field?.messageFrame(generation) ?? .zero}
    override func isAccessibilityEnabled()->Bool {current}
}

@MainActor final class LogReferenceAccessibleBadge: NSAccessibilityElement {
    private weak var field: LogReferenceTextField?
    let name: String
    private let label: String
    private let rect: NSRect
    private let generation: UUID,semanticGeneration:UUID
    init(field: LogReferenceTextField, frame: LogReferenceTextCell.BadgeFrame, generation: UUID,semanticGeneration:UUID) {
        self.field = field; name = frame.name; label = frame.style.label.text; rect = frame.rect; self.generation = generation;self.semanticGeneration=semanticGeneration
        super.init(); setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    private var current:Bool {field?.ownsReference(name,generation:generation,semanticGeneration:semanticGeneration)==true}
    override func accessibilityParent() -> Any? { current ? field:nil }
    override func accessibilityLabel() -> String? { current ? label:nil }
    override func accessibilityValue() -> Any? { current ? name:nil }
    override func accessibilityHelp() -> String? {
        guard let field, field.accepts(name, generation: generation,semanticGeneration:semanticGeneration) else { return nil }
        field.onHoverReference?(name)
        return field.tooltipForReference?(name)
    }
    override func accessibilityFrame() -> NSRect {
        guard let field, let window = field.window, current else { return .zero }
        return window.convertToScreen(field.convert(rect, to: nil))
    }
    override func isAccessibilityEnabled() -> Bool { field?.accepts(name, generation: generation,semanticGeneration:semanticGeneration) == true }
    override func accessibilityPerformPress() -> Bool { field?.showReferenceMenu(name: name, generation: generation,semanticGeneration:semanticGeneration) == true }
    override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }
}
