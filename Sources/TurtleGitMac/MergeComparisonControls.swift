import SwiftUI
import TurtleGitCore

struct MergeComparisonControls: View {
    let options: MergeComparisonOptions
    let apply: (MergeComparisonOptions) -> Void
    var supportsComments = false
    private func changing(_ update: (inout MergeComparisonOptions) -> Void) {
        var next = options; update(&next); apply(next)
    }
    var body: some View {
        Menu("Comparison") {
            ForEach(MergeWhitespaceComparison.allCases, id: \.rawValue) { value in
                Button { changing { $0.whitespace = value } } label: {
                    if options.whitespace == value { Label(value.title, systemImage: "checkmark") } else { Text(value.title) }
                }
            }
            Divider()
            Toggle("Ignore line endings", isOn: Binding(get: { options.ignoreEndings }, set: { value in changing { $0.ignoreEndings = value } }))
            Toggle("Ignore case changes", isOn: Binding(get: { options.ignoreCase }, set: { value in changing { $0.ignoreCase = value } }))
            Toggle("Ignore Comments", isOn: Binding(get: { options.ignoreComments }, set: { value in changing { $0.ignoreComments = value } })).disabled(!supportsComments)
        }.fixedSize()
    }
}

import AppKit

struct MergeLocatorControls: View {
    let preferences: MergeLocatorPreferences
    let apply: (MergeLocatorPreferences) -> Void
    var body: some View {
        Menu("View") {
            Toggle("Locator bar", isOn: Binding(get: { preferences.visible }, set: { var next = preferences; next.visible = $0; apply(next) }))
            Toggle("Use fish-eye in locator bar", isOn: Binding(get: { preferences.fishEye }, set: { var next = preferences; next.fishEye = $0; apply(next) }))
        }.fixedSize()
    }
}
struct MergeLocatorViewport: Equatable { var rows: Range<Int> = 0..<0 }
@MainActor enum MergeLocatorScrolling {
    static func viewport(_ scroll: NSScrollView?) -> MergeLocatorViewport {
        guard let scroll, let text = scroll.documentView as? NSTextView, let layout = text.layoutManager, let container = text.textContainer else { return .init() }
        var rect = text.visibleRect; rect.origin.x -= text.textContainerOrigin.x; rect.origin.y -= text.textContainerOrigin.y
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let top = max(0, MergeLineEndings.lineNumber(in: text.string, utf16Offset: chars.location) - 1)
        let bottom = max(top + 1, MergeLineEndings.lineNumber(in: text.string, utf16Offset: NSMaxRange(chars)))
        return .init(rows: top..<bottom)
    }
    static func scroll(_ scroll: NSScrollView, to row: Int) {
        guard let text = scroll.documentView as? NSTextView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let lines = MergeLineEndings.lineRanges(in: text.string)
        guard !lines.isEmpty else { return }
        let line = lines[min(lines.count - 1, max(0, row))]
        let glyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        var origin = scroll.contentView.bounds.origin
        origin.y = max(0, rect.minY + text.textContainerOrigin.y - scroll.contentView.bounds.height / 2)
        let proposed = NSRect(origin: origin, size: scroll.contentView.bounds.size)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(scroll.contentView); scroll.verticalRulerView?.needsDisplay = true
    }
}
struct MergeLocatorBar: NSViewRepresentable {
    let map: MergeLocatorMap
    let viewport: MergeLocatorViewport
    let fishEye: Bool
    let enabled: Bool
    let navigate: (Int) -> Void
    func makeNSView(context: Context) -> MergeLocatorNativeView { MergeLocatorNativeView() }
    func updateNSView(_ view: MergeLocatorNativeView, context: Context) {
        view.map = map; view.viewport = viewport; view.fishEye = fishEye; view.enabled = enabled; view.navigate = navigate
        view.needsDisplay = true
    }
}
/// Native counterpart of LocatorBar.cpp: Left / Bottom / Right stripes,
/// source colors, blue viewport, nonselecting drag and fourfold hover lens.
@MainActor final class MergeLocatorNativeView: NSView {
    var map = MergeLocatorMap(columns: [])
    var viewport = MergeLocatorViewport()
    var fishEye = true, enabled = true
    var navigate: (Int) -> Void = { _ in }
    private var hover: CGFloat?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { enabled }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.slider)
        setAccessibilityLabel("Difference locator")
        setAccessibilityHelp("Left, merged result, and right file overview. Click or drag to scroll; arrow keys move through the document.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next); tracking = next
    }
    private var dark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    private func paint() {
        NSColor.textBackgroundColor.setFill(); bounds.fill()
        guard map.lineCount > 0 else { return }
        let scale = bounds.height / CGFloat(map.lineCount)
        let top = CGFloat(viewport.rows.lowerBound) * scale, bottom = CGFloat(viewport.rows.upperBound) * scale
        (dark ? NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.4, alpha: 1) : NSColor(calibratedRed: 180/255, green: 180/255, blue: 1, alpha: 1)).setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: bottom - top).fill()
        let width = bounds.width / 3
        for (column, runs) in map.columns.prefix(3).enumerated() {
            for run in runs where run.state != .normal {
                MergePalette.color(run.state).setFill()
                NSRect(x: CGFloat(column) * width, y: CGFloat(run.rows.lowerBound) * scale, width: width, height: max(1, CGFloat(run.rows.count) * scale)).fill()
            }
        }
        NSColor.labelColor.setFill()
        for x in [width, 2 * width] { NSRect(x: x, y: 0, width: 1, height: bounds.height).fill() }
        for y in [top, bottom] { NSRect(x: 0, y: min(bounds.height - 2, max(0, y)), width: bounds.width, height: 2).fill() }
    }
    override func draw(_ dirtyRect: NSRect) {
        paint()
        guard fishEye, let hover, bounds.height > 0 else { return }
        let height = bounds.height / 10, start = min(bounds.height - height, max(0, hover - height / 2))
        let lens = NSRect(x: 0, y: start, width: bounds.width, height: height)
        NSGraphicsContext.saveGraphicsState(); lens.clip()
        let native = NSAffineTransform(); native.translateX(by: 0, yBy: start - 4 * (start + 3 * height / 8))
        native.scaleX(by: 1, yBy: 4); native.concat()
        paint(); NSGraphicsContext.restoreGraphicsState()
        (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.12).setFill(); lens.fill()
        NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: lens).stroke()
    }
    func navigate(toFraction fraction: Double) {
        guard enabled, map.lineCount > 0 else { return }
        navigate(map.row(at: fraction))
    }
    private func navigate(_ event: NSEvent) { navigate(toFraction: Double(convert(event.locationInWindow, from: nil).y / max(1, bounds.height))) }
    override func mouseDown(with event: NSEvent) { if enabled { window?.makeFirstResponder(self); navigate(event) } }
    override func mouseDragged(with event: NSEvent) { navigate(event) }
    override func mouseMoved(with event: NSEvent) { hover = convert(event.locationInWindow, from: nil).y; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        guard enabled, map.lineCount > 0 else { return }
        let current = (viewport.rows.lowerBound + viewport.rows.upperBound) / 2
        switch event.keyCode {
        case 126: navigate(max(0, current - 1))
        case 125: navigate(min(map.lineCount - 1, current + 1))
        case 116: navigate(max(0, current - max(1, viewport.rows.count)))
        case 121: navigate(min(map.lineCount - 1, current + max(1, viewport.rows.count)))
        case 115: navigate(0)
        case 119: navigate(map.lineCount - 1)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityValue() -> Any? { map.lineCount > 0 ? "Lines \(viewport.rows.lowerBound + 1)–\(min(map.lineCount, viewport.rows.upperBound)) of \(map.lineCount)" : "Empty document" }
    override func accessibilityPerformIncrement() -> Bool { guard enabled, map.lineCount > 0 else { return false }; navigate(min(map.lineCount - 1, viewport.rows.upperBound)); return true }
    override func accessibilityPerformDecrement() -> Bool { guard enabled, map.lineCount > 0 else { return false }; navigate(max(0, viewport.rows.lowerBound - max(1, viewport.rows.count))); return true }
}

@MainActor enum MergeEmptyResultPrompt {
    static func choose(window: NSWindow?, path: String) async -> MergeEmptyResult {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "File is empty."
        alert.informativeText = "Delete “\((path as NSString).lastPathComponent)” or keep the empty file?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel — Keep Empty File")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else { response = alert.runModal() }
        return response == .alertFirstButtonReturn ? .delete : .keep
    }
}
