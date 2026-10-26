// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Scintilla's logical-line margin, expressed as a native TextKit ruler. The
/// ruler never rewrites the document or inserts labels into its accessible text.
@MainActor final class PatchLineNumberGutter: NSRulerView {
    struct LineLabel { let line: Int; let label: String; let rect: NSRect }
    private weak var text: NSTextView?
    private var available: () -> Bool = { false }
    private var binding: String = ""
    private var observations: [NSObjectProtocol] = []
    private var contents = ""
    private(set) var lineIndex = PatchLineIndex(text: "")
    private var labelFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var foreground = NSColor.secondaryLabelColor
    private var fill = NSColor.textBackgroundColor
    var thicknessChanged: (() -> Void)?
    private var retired = false
    private(set) var isSelecting = false
    private var anchorLine = 0
    private var initialSelection = NSRange(location: 0, length: 0)
    private var initialAffinity: NSSelectionAffinity = .downstream
    private var dragContents = ""
    private var dragPoint = NSPoint.zero

    init(scroll: NSScrollView, text: NSTextView) {
        self.text = text
        super.init(scrollView: scroll, orientation: .verticalRuler)
        clientView = text
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        setAccessibilityIdentifier("UnifiedDiff.LineNumberGutter")
        setAccessibilityLabel(NSLocalizedString("Line numbers", comment: "Unified Diff ruler"))
        scroll.contentView.postsBoundsChangedNotifications = true
        var notifications: [(Notification.Name, AnyObject)] = [
            (NSView.boundsDidChangeNotification, scroll.contentView),
            (NSText.didChangeNotification, text)
        ]
        if let storage = text.textStorage { notifications.append((NSTextStorage.didProcessEditingNotification, storage)) }
        for (name, object) in notifications {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSView.boundsDidChangeNotification { self?.needsDisplay = true }
                    else { self?.documentChanged() }
                }
            })
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    override func layout() { super.layout(); needsDisplay = true }
    override var isFlipped: Bool { true }

    func bind(identity: UUID, revision: UUID, available: @escaping () -> Bool) {
        let next = identity.uuidString + revision.uuidString
        if binding != next { endSelection(); binding = next }
        self.available = available
    }
    func refresh(font: NSFont, dark: Bool, highContrast: Bool) {
        labelFont = font
        foreground = highContrast ? .labelColor : NSColor(white: dark ? 140.0 / 255 : 109.0 / 255, alpha: 1)
        fill = highContrast ? .textBackgroundColor : dark ? (text?.backgroundColor ?? .textBackgroundColor) : NSColor(white: 230.0 / 255, alpha: 1)
        documentChanged()
    }
    func documentChanged() {
        guard !retired, let text else { return }
        if !contents.utf16.elementsEqual(text.string.utf16) {
            if isSelecting { endSelection() }
            contents = text.string; lineIndex = PatchLineIndex(text: contents)
        }
        let width = ceil(("8" as NSString).size(withAttributes: [.font: labelFont]).width * CGFloat(lineIndex.marginColumns))
        if ruleThickness != width { ruleThickness = width; thicknessChanged?() }
        needsDisplay = true
    }
    func retire() {
        retired = true; endSelection(); available = { false }
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
        thicknessChanged = nil; clientView = nil; text = nil
    }
    private var live: Bool {
        guard !retired, NSApp.modalWindow == nil, let text, let window = text.window, window === self.window,
              scrollView?.documentView === text, (scrollView as? PatchScrollView)?.lineNumberGutter === self,
              superview is PatchTextHost, scrollView?.superview === superview,
              window.attachedSheet == nil else { return false }
        return available()
    }

    /// Rect of the first visual fragment only; wrapped continuation fragments do
    /// not acquire new logical line numbers.
    func rect(forLine line: Int) -> NSRect? {
        guard let text, let manager = text.layoutManager, let container = text.textContainer,
              let range = lineIndex.range(forLine: line) else { return nil }
        manager.ensureLayout(for: container)
        let fragment: NSRect
        if range.location < manager.firstUnlaidCharacterIndex() && range.location < lineIndex.utf16Length {
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            guard glyph < manager.numberOfGlyphs else { return nil }
            fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else if range.location == lineIndex.utf16Length {
            fragment = manager.extraLineFragmentRect
        } else { return nil }
        let height = fragment.height > 0 ? fragment.height : manager.defaultLineHeight(for: labelFont)
        let rect = NSRect(x: text.textContainerOrigin.x, y: fragment.minY + text.textContainerOrigin.y,
                          width: 1, height: height)
        let local = convert(rect, from: text)
        return NSRect(x: 0, y: local.minY, width: ruleThickness, height: height)
    }
    func visibleLabels() -> [LineLabel] {
        guard !retired, let text, let manager = text.layoutManager, let container = text.textContainer else { return [] }
        manager.ensureLayout(for: container)
        let visible = text.visibleRect.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lineIndex.lineIndex(atUTF16Offset: min(chars.location == NSNotFound ? 0 : chars.location, lineIndex.utf16Length)) ?? 0
        let last = lineIndex.lineIndex(atUTF16Offset: min(chars.location == NSNotFound ? lineIndex.utf16Length : NSMaxRange(chars), lineIndex.utf16Length)) ?? (lineIndex.lineCount - 1)
        return (first...max(first, last)).compactMap { line in
            guard let rect = rect(forLine: line), rect.intersects(bounds) else { return nil }
            return LineLabel(line: line, label: String(line + 1), rect: rect)
        }
    }
    // As a sibling this ruler is not registered with AppKit's formatting-ruler
    // tiler. Draw the native view's labels directly, independently of that state.
    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.clip()
        fill.setFill(); bounds.intersection(rect).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: foreground]
        let padding = ("8" as NSString).size(withAttributes: [.font: labelFont]).width
        for entry in visibleLabels() {
            let size = (entry.label as NSString).size(withAttributes: attributes)
            (entry.label as NSString).draw(at: NSPoint(x: ruleThickness - padding - size.width,
                y: entry.rect.minY + max(0, (entry.rect.height - size.height) / 2)), withAttributes: attributes)
        }
    }
    private func line(at point: NSPoint) -> Int? {
        guard let text, let manager = text.layoutManager, let container = text.textContainer else { return nil }
        manager.ensureLayout(for: container)
        var local = text.convert(point, from: self)
        local.x = 0
        local.y -= text.textContainerOrigin.y
        if local.y < 0 { return 0 }
        if local.y >= manager.usedRect(for: container).maxY { return lineIndex.lineCount - 1 }
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs else { return lineIndex.lineCount - 1 }
        return lineIndex.lineIndex(atUTF16Offset: manager.characterIndexForGlyph(at: glyph))
    }
    @discardableResult func beginSelection(at point: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard live, point.x.isFinite, point.y.isFinite, !modifiers.contains(.control), let text else { return false }
        endSelection()
        documentChanged()
        guard let current = line(at: point) else { return false }
        text.window?.makeFirstResponder(text)
        if modifiers.contains(.command) { text.selectAll(nil); return true }
        initialSelection = text.selectedRange(); initialAffinity = text.selectionAffinity
        let anchor = initialAffinity == .upstream ? NSMaxRange(initialSelection) : initialSelection.location
        let caret = initialAffinity == .upstream ? initialSelection.location : NSMaxRange(initialSelection)
        anchorLine = modifiers.contains(.shift) ? (lineIndex.anchorLine(selectionAnchor: anchor, selectionCaret: caret) ?? current) : current
        dragContents = text.string; dragPoint = point; isSelecting = true
        return continueSelection(at: point)
    }
    @discardableResult func continueSelection(at point: NSPoint) -> Bool {
        guard live, isSelecting, point.x.isFinite, point.y.isFinite, let text, text.string.utf16.elementsEqual(dragContents.utf16), let current = line(at: point),
              let selection = lineIndex.selection(anchorLine: anchorLine, currentLine: current) else { endSelection(); return false }
        dragPoint = point
        text.setSelectedRange(selection.range, affinity: selection.caretOffset < selection.anchorOffset ? .upstream : .downstream, stillSelecting: true)
        needsDisplay = true
        return true
    }
    func endSelection() {
        let finishing = isSelecting
        isSelecting = false
        if finishing, live, let text, text.string.utf16.elementsEqual(dragContents.utf16) {
            text.setSelectedRange(text.selectedRange(), affinity: text.selectionAffinity, stillSelecting: false)
        }
        dragContents = ""
    }
    func cancelSelection() {
        if live, isSelecting, let text, text.string.utf16.elementsEqual(dragContents.utf16) {
            text.setSelectedRange(initialSelection, affinity: initialAffinity, stillSelecting: false)
        }
        endSelection()
    }
    func autoscrollSelection() {
        guard live, isSelecting, let scroll = scrollView, let text else { endSelection(); return }
        let point = scroll.contentView.convert(dragPoint, from: self)
        let viewport = scroll.contentView.bounds
        let delta: CGFloat = point.y < viewport.minY ? -labelFont.pointSize : point.y > viewport.maxY ? labelFont.pointSize : 0
        if delta != 0 {
            let y = min(max(0, viewport.minY + delta), max(0, text.bounds.height - viewport.height))
            scroll.contentView.scroll(to: NSPoint(x: viewport.minX, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            _ = continueSelection(at: dragPoint)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard live else { return }
        if event.modifierFlags.contains(.control) { super.mouseDown(with: event); return }
        guard beginSelection(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags), isSelecting,
              let window else { return }
        while isSelecting && live {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: Date(timeIntervalSinceNow: 0.05), inMode: .eventTracking, dequeue: true) else { autoscrollSelection(); continue }
            if next.window !== window { NSApp.postEvent(next, atStart: true); endSelection(); break }
            if next.type == .leftMouseUp { _ = continueSelection(at: convert(next.locationInWindow, from: nil)); endSelection() }
            else if next.type == .keyDown { if next.keyCode == 53 { cancelSelection() } }
            else { _ = continueSelection(at: convert(next.locationInWindow, from: nil)); autoscrollSelection() }
        }
        endSelection()
    }
    override func menu(for event: NSEvent) -> NSMenu? { live ? text?.menu(for: event) : nil }
}

/// Own the line margin beside the native scroll view. This is deliberately not
/// installed as NSTextView's formatting ruler: AppKit otherwise adjusts the
/// text's minimum/frame size again when its clip view changes dimensions.
@MainActor final class PatchTextHost: NSView {
    let scroll: PatchScrollView
    let gutter: PatchLineNumberGutter
    private var arranging = false
    init(scroll: PatchScrollView, gutter: PatchLineNumberGutter) {
        self.scroll = scroll; self.gutter = gutter
        super.init(frame: .zero)
        autoresizesSubviews = false
        scroll.hasVerticalRuler = false; scroll.hasHorizontalRuler = false
        scroll.rulersVisible = false
        scroll.lineNumberGutter = gutter
        addSubview(scroll); addSubview(gutter)
        gutter.scrollView = scroll
        gutter.thicknessChanged = { [weak self] in self?.needsLayout = true }
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); needsLayout = true }
    override func layout() {
        super.layout()
        guard !arranging else { return }
        arranging = true; defer { arranging = false }
        let width = min(max(0, gutter.ruleThickness), max(0, bounds.width))
        let margin = NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
        let viewport = NSRect(x: margin.maxX, y: bounds.minY, width: max(0, bounds.width - width), height: bounds.height)
        if gutter.frame != margin { gutter.frame = margin }
        if scroll.frame != viewport { scroll.frame = viewport }
        scroll.tile()
        scroll.updateDocumentExtent()
        gutter.needsDisplay = true
    }
}
