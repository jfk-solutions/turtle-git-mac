import SwiftUI
import TurtleGitCore

struct MergeInlineControls: View {
    let enabled: Bool
    let word: Bool
    let applyEnabled: (Bool) -> Void
    let applyWord: (Bool) -> Void
    var body: some View {
        Menu("Inline diff") {
            Toggle(isOn: Binding(get: { enabled }, set: applyEnabled)) { CommandLabel(title: "Inline diff", icon: .mergeInline) }
            Toggle(isOn: Binding(get: { word }, set: applyWord)) { CommandLabel(title: "Inline diff word-wise", icon: .mergeInlineWord) }.disabled(!enabled)
        }.fixedSize()
    }
}

/// Missing-character ticks are an overlay, never inserted into source text.
@MainActor enum MergeInlineTicks {
    static func draw(in view: NSTextView, offsets: [Int], dirtyRect: NSRect) {
        guard !offsets.isEmpty, let layout = view.layoutManager, let container = view.textContainer else { return }
        let length = (view.string as NSString).length, origin = view.textContainerOrigin
        ((view as? MergeWhitespaceDisplaying)?.whitespaceRenderer.palette.inlineRemoved ?? MergePalette.inlineRemoved).setFill()
        for offset in offsets where offset >= 0 && offset < length {
            guard view.textStorage?.attribute(.mergeFoldHidden, at: offset, effectiveRange: nil) == nil, view.textStorage?.attribute(.mergeFoldMarker, at: offset, effectiveRange: nil) == nil else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: offset, length: 1), actualCharacterRange: nil)
            guard glyphs.location < layout.numberOfGlyphs else { continue }
            let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let point = layout.location(forGlyphAt: glyphs.location)
            let marker = NSRect(x: origin.x + line.minX + point.x, y: origin.y + line.minY, width: 2, height: line.height)
            if marker.intersects(dirtyRect) { marker.fill() }
        }
    }
}

@MainActor protocol MergeInlineNavigationProviding: AnyObject {
    func canNavigateInline(forward: Bool) -> Bool
    func navigateInline(forward: Bool)
}

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

extension MergeGeneralPreferences {
    var nativeFont: NSFont {
        let value = NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: CGFloat(fontSize)) ?? NSFont(name: fontName, size: CGFloat(fontSize))
        return value.flatMap { $0.isFixedPitch ? $0 : nil } ?? .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }
}

struct MergeViewControls: View {
    let preferences: MergeLocatorPreferences
    let apply: (MergeLocatorPreferences) -> Void
    let whitespace: MergeWhitespaceDisplayPreferences
    let applyWhitespace: (MergeWhitespaceDisplayPreferences) -> Void
    var wrapLines = false
    var applyWrap: (Bool) -> Void = { _ in }
    var collapsed = false
    var applyCollapsed: (Bool) -> Void = { _ in }
    var movedBlocks = true
    var canChangeMovedBlocks = false
    var applyMovedBlocks: (Bool) -> Void = { _ in }
    var toolbarVisible = true
    var applyToolbar: (Bool) -> Void = { _ in }
    var statusBarVisible = true
    var applyStatusBar: (Bool) -> Void = { _ in }
    var lineDiffBar: Bool? = nil
    var applyLineDiffBar: (Bool) -> Void = { _ in }
    var lineNumbers: Bool? = nil
    var applyLineNumbers: (Bool) -> Void = { _ in }
    var canSwitchSides = false
    var switchSides: () -> Void = {}
    var body: some View {
        Menu("View") {
            Toggle("Toolbar",isOn:Binding(get:{toolbarVisible},set:applyToolbar))
            Toggle("Status Bar",isOn:Binding(get:{statusBarVisible},set:applyStatusBar))
            if let lineDiffBar { Toggle("Line diff bar",isOn:Binding(get:{lineDiffBar},set:applyLineDiffBar)) }
            if let lineNumbers { Toggle("Line numbers",isOn:Binding(get:{lineNumbers},set:applyLineNumbers)) }
            Divider()
            Toggle("Moved blocks", isOn:Binding(get:{movedBlocks},set:applyMovedBlocks)).disabled(!canChangeMovedBlocks)
            Toggle("Wrap long lines", isOn: Binding(get: { wrapLines }, set: applyWrap))
            Toggle("Collapsed", isOn: Binding(get: { collapsed }, set: applyCollapsed))
            Button(action:switchSides) { CommandLabel(title:"Switch left and right view",icon:.mergeSwitch) }.disabled(!canSwitchSides)
            Divider()
            Toggle("Show Whitespaces", isOn: Binding(get: { whitespace.visible }, set: { var next = whitespace; next.visible = $0; applyWhitespace(next) }))
            Toggle("Line-ending icons", isOn: Binding(get: { whitespace.endingIcons }, set: { var next = whitespace; next.endingIcons = $0; applyWhitespace(next) }))
            Divider()
            Toggle("Locator bar", isOn: Binding(get: { preferences.visible }, set: { var next = preferences; next.visible = $0; apply(next) }))
            Toggle("Use fish-eye in locator bar", isOn: Binding(get: { preferences.fishEye }, set: { var next = preferences; next.fishEye = $0; apply(next) }))
        }.fixedSize()
    }
}
struct MergeLocatorHighlights: Equatable {
    var search = Set<Int>()
    var marked = Set<Int>()
    @MainActor static func read(_ scroll: NSScrollView?) -> Self {
        (scroll?.documentView as? MergeFindProviding)?.mergeFindHighlights.locatorHighlights ?? .init()
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
    var highlights: [MergeLocatorHighlights] = []
    let fishEye: Bool
    let enabled: Bool
    let navigate: (Int) -> Void
    var palette = MergePalette.Context()
    func makeNSView(context: Context) -> MergeLocatorNativeView { MergeLocatorNativeView() }
    func updateNSView(_ view: MergeLocatorNativeView, context: Context) {
        view.palette = palette; view.map = map; view.viewport = viewport; view.highlights = highlights; view.fishEye = fishEye; view.enabled = enabled; view.navigate = navigate
        view.needsDisplay = true
    }
}
/// Native counterpart of LocatorBar.cpp: Left / Bottom / Right stripes,
/// source colors, blue viewport, nonselecting drag and fourfold hover lens.
@MainActor final class MergeLocatorNativeView: NSView {
    var palette = MergePalette.Context()
    var map = MergeLocatorMap(columns: [])
    var viewport = MergeLocatorViewport()
    var highlights: [MergeLocatorHighlights] = []
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
        palette.color(MergeSourceState.normal).setFill(); bounds.fill()
        guard map.lineCount > 0 else { return }
        let scale = bounds.height / CGFloat(map.lineCount)
        let top = CGFloat(viewport.rows.lowerBound) * scale, bottom = CGFloat(viewport.rows.upperBound) * scale
        (dark ? NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.4, alpha: 1) : NSColor(calibratedRed: 180/255, green: 180/255, blue: 1, alpha: 1)).setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: bottom - top).fill()
        let width = bounds.width / 3
        for (column, runs) in map.columns.prefix(3).enumerated() {
            for run in runs where run.state != .normal {
                palette.color(run.state).setFill()
                NSRect(x: CGFloat(column) * width, y: CGFloat(run.rows.lowerBound) * scale, width: width, height: max(1, CGFloat(run.rows.count) * scale)).fill()
            }
            if highlights.indices.contains(column) {
                for (rows, scaleAmount) in [(highlights[column].marked, 200), (highlights[column].search, 30)] {
                    MergeFindHighlights.intense(palette.color(.normal), scale: scaleAmount).setFill()
                    for row in rows where row >= 0 && row < map.lineCount {
                        NSRect(x: CGFloat(column) * width, y: CGFloat(row) * scale, width: width, height: max(2, scale)).fill()
                    }
                }
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
    override func accessibilityValue() -> Any? { map.lineCount > 0 ? "Lines \(viewport.rows.lowerBound + 1)–\(min(map.lineCount, viewport.rows.upperBound)) of \(map.lineCount); \(highlights.reduce(0) { $0 + $1.marked.count }) marked lines; \(highlights.reduce(0) { $0 + $1.search.count }) search lines" : "Empty document" }
    override func accessibilityPerformIncrement() -> Bool { guard enabled, map.lineCount > 0 else { return false }; navigate(min(map.lineCount - 1, viewport.rows.upperBound)); return true }
    override func accessibilityPerformDecrement() -> Bool { guard enabled, map.lineCount > 0 else { return false }; navigate(max(0, viewport.rows.lowerBound - max(1, viewport.rows.count))); return true }
}

@MainActor protocol MergeWhitespaceDisplaying { var whitespaceRenderer: MergeWhitespaceRenderer { get } }
/// Draws source whitespace symbols over glyphs. No attributed-string characters,
/// selection offsets, clipboard values or original ending metadata are replaced.
@MainActor final class MergeWhitespaceRenderer {
    var palette = MergePalette.Context()
    private var text = "", cells: [String]?, others: [String]?
    private(set) var markers: [MergeWhitespaceMarker] = []
    private(set) var preferences = MergeWhitespaceDisplayPreferences()
    var highlightEndings = true, removal = false
    private var icons: [MergeLineEnding: NSImage] = [:]
    private var darkIcons: [MergeLineEnding: NSImage] = [:]
    private var colorRevision = -1
    func update(text: String, cells: [MergeSourceCell]?, otherCells: [MergeSourceCell]?, preferences: MergeWhitespaceDisplayPreferences) {
        let raw = cells?.map(\.text), other = otherCells?.map(\.text)
        if !self.text.utf8.elementsEqual(text.utf8) || self.cells != raw || others != other {
            self.text = text; self.cells = raw; others = other
            markers = MergeWhitespaceDisplay.markers(text: text, cells: cells, otherCells: otherCells)
        }
        self.preferences = preferences
    }
    func draw(in view: NSTextView, dirtyRect: NSRect) {
        guard let layout = view.layoutManager, let container = view.textContainer else { return }
        draw(layout: layout, container: container, origin: view.textContainerOrigin,
             appearance: view.effectiveAppearance, font: view.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
             textLength: (view.string as NSString).length, dirtyRect: dirtyRect)
    }
    func draw(layout: NSLayoutManager, container: NSTextContainer, origin: NSPoint, appearance: NSAppearance, font: NSFont, textLength: Int, dirtyRect: NSRect) {
        if colorRevision != palette.revision { colorRevision = palette.revision; darkIcons = [:] }
        guard preferences.visible else { return }
        let rect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let visibleGlyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        let visible = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        var low = 0, high = markers.count
        while low < high { let mid = (low + high) / 2; if markers[mid].offset < visible.location { low = mid + 1 } else { high = mid } }
        let advance = (" " as NSString).size(withAttributes: [.font: font]).width
        for marker in markers[low...] {
            if marker.offset > NSMaxRange(visible) { break }
            guard marker.offset < textLength,
                  layout.textStorage?.attribute(.mergeFoldHidden, at: marker.offset, effectiveRange: nil) == nil,
                  layout.textStorage?.attribute(.mergeFoldMarker, at: marker.offset, effectiveRange: nil) == nil else { continue }
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: marker.offset, length: 1), actualCharacterRange: nil)
            guard glyphs.location < layout.numberOfGlyphs else { continue }
            let fragment = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let point = layout.location(forGlyphAt: glyphs.location)
            let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let frame = NSRect(x: fragment.minX + point.x + origin.x, y: fragment.minY + origin.y,
                               width: max(advance, box.width), height: fragment.height)
            guard frame.intersects(dirtyRect) else { continue }
            palette.whitespace.setStroke(); palette.whitespace.setFill()
            let path = NSBezierPath(); path.lineWidth = 1
            func line(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ b: CGFloat) { path.move(to: NSPoint(x: x, y: y)); path.line(to: NSPoint(x: a, y: b)) }
            let x = frame.minX, y = frame.midY, right = x + advance - 1
            switch marker.kind {
            case .space: NSRect(x: x + advance / 2 - 1, y: y, width: 2, height: 2).fill()
            case .tab:
                let end = frame.maxX - 2
                line(x + 2, y, end, y); line(end - 3, y - 3, end, y); line(end - 3, y + 3, end, y); path.stroke()
            case .ending(let style, let changed):
                if preferences.endingIcons {
                    let icon: MenuIcon?
                    switch style { case .cr: icon = .mergeEndingCR; case .lf: icon = .mergeEndingLF; case .crlf: icon = .mergeEndingCRLF; default: icon = nil }
                    if let icon {
                        let target = NSRect(x: x, y: frame.minY, width: frame.height, height: frame.height)
                        if changed && highlightEndings { (removal ? palette.inlineRemoved : palette.inlineAdded).setFill(); target.fill() }
                        if icons[style] == nil { icons[style] = icon.image(size: frame.height) }
                        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        if dark, darkIcons[style] == nil, let original = icons[style] {
                            // Classic ICO masks become hard to see on dark
                            // AppKit backgrounds. Preserve the original alpha
                            // silhouette and use the native marker foreground.
                            var foreground = NSColor(calibratedWhite: 0.7, alpha: 1)
                            appearance.performAsCurrentDrawingAppearance {
                                if let resolved = palette.whitespace.usingColorSpace(.sRGB) { foreground = resolved.withAlphaComponent(1) }
                            }
                            let tint = foreground
                            darkIcons[style] = NSImage(size: original.size, flipped: false) { bounds in
                                original.draw(in: bounds)
                                tint.setFill(); bounds.fill(using: .sourceAtop)
                                return true
                            }
                        }
                        (dark ? darkIcons[style] : icons[style])?.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                    continue // The source icon mode draws CR/LF/CRLF only.
                }
                switch style {
                case .crlf:
                    line(right, frame.minY + 1, right, y)
                    fallthrough
                case .cr:
                    line(right, y, x, y); line(x + 4, y + 4, x, y); line(x + 4, y - 4, x, y)
                case .lfcr:
                    let middle = x + advance / 2, bottom = frame.maxY - 1
                    line(right, y - 2, middle, y - 2); line(middle, y - 2, middle, bottom)
                    line(middle - 4, bottom - 4, middle, bottom); line(middle + 4, bottom - 4, middle, bottom)
                case .verticalTab, .formFeed, .nextLine, .lineSeparator, .paragraphSeparator:
                    line(dirtyRect.minX, frame.maxY - 1, dirtyRect.maxX, frame.maxY - 1)
                    line(right, frame.maxY - advance - 2, x, frame.maxY - 2)
                    line(x + 5, frame.maxY - 2, x, frame.maxY - 2); line(x + 1, frame.maxY - 6, x, frame.maxY - 2)
                case .lf:
                    line(right, frame.maxY - advance, x, frame.maxY - 1)
                    line(x + 5, frame.maxY - 2, x, frame.maxY - 1); line(x + 1, frame.maxY - 6, x, frame.maxY - 1)
                }
                path.stroke()
            }
        }
    }
}

/// Screen-line entry positions remain UTF-16 offsets into the unchanged buffer.
/// TextKit, rather than an estimated character width, owns Unicode/tab wrapping.
@MainActor enum MergeWrappedCaret {
    static func starts(in view: NSTextView, row: NSRange) -> [Int] {
        let length = view.string.utf16.count
        guard row.location >= 0, row.location < length, NSMaxRange(row) <= length,
              let layout = view.layoutManager, let container = view.textContainer else { return [min(max(0,row.location),length)] }
        guard view.textStorage?.attribute(.mergeFoldHidden, at: row.location, effectiveRange: nil) == nil else { return [row.location] }
        layout.ensureLayout(for: container)
        let range = NSRange(location: row.location, length: max(1,row.length))
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var result: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, fragment, _ in
            let characters = layout.characterRange(forGlyphRange: fragment, actualGlyphRange: nil)
            let start = max(row.location,characters.location)
            if start <= NSMaxRange(row), result.last != start { result.append(start) }
        }
        return result.isEmpty ? [row.location] : result
    }
    static func subline(in starts: [Int], containing offset: Int) -> Int {
        starts.lastIndex(where: { $0 <= offset }) ?? 0
    }
    static func offset(in view: NSTextView, row: NSRange, reverse: Bool, subline: Int? = nil) -> Int {
        let values = starts(in: view, row: row)
        if let subline { return values[min(max(0,subline),values.count - 1)] }
        return reverse ? values.last! : values[0]
    }
}

@MainActor final class MergeReadingScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers:Bool {true}
    var beforeTracking: () -> Void = {}, afterTracking: () -> Void = {}
    override func mouseDown(with event: NSEvent) {
        beforeTracking(); defer { afterTracking() }; super.mouseDown(with:event)
    }
}

/// TextKit wrapping with source-style shared row heights across aligned panes.
@MainActor final class MergeLineWrapping {
    private struct Anchor {
        let row: Int, fraction: CGFloat
    }
    private final class Entry {
        weak var scroll: NSScrollView?
        var aligned: Bool
        var enabled: Bool
        var applied: Bool?
        var leadingInset: CGFloat?
        var measuredWidth: CGFloat?
        var text = "", tops: [CGFloat] = [], bottom: CGFloat = 0
        var anchor: Anchor?
        var geometryDirty = true
        var observers: [NSObjectProtocol] = []
        init(scroll: NSScrollView, aligned: Bool, enabled: Bool) { self.scroll = scroll; self.aligned = aligned; self.enabled = enabled }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
    private var entries: [String: Entry] = [:]
    private var queued = false, applying = false, retired = false
    private var inputDepth = 0
    var geometryChanged: () -> Void = {}
    private(set) var alignedHeights: [CGFloat] = []
    var isGeometryPending: Bool {
        applying || queued || entries.values.contains { $0.geometryDirty && $0.scroll?.window != nil }
    }
    #if DEBUG
    var viewportDiagnostics: String {
        entries.sorted { $0.key < $1.key }.map { key, entry in
            "\(key):row=\(entry.anchor?.row.description ?? "nil"),fraction=\(entry.anchor?.fraction.description ?? "nil"),dirty=\(entry.geometryDirty),queued=\(queued)"
        }.joined(separator:"; ")
    }
    #endif
    func update(_ scroll: NSScrollView, key: String, aligned: Bool, enabled: Bool) {
        guard !retired else { return }
        if entries[key]?.scroll !== scroll {
            let entry = Entry(scroll: scroll, aligned: aligned, enabled: enabled)
            for vertical in [true,false] {
                guard let old = vertical ? scroll.verticalScroller : scroll.horizontalScroller,
                      !(old is MergeReadingScroller) else { continue }
                let scroller = MergeReadingScroller(frame:old.frame)
                scroller.controlSize = old.controlSize; scroller.scrollerStyle = old.scrollerStyle
                scroller.beforeTracking = { [weak self] in self?.beginViewportInput() }
                scroller.afterTracking = { [weak self] in self?.endViewportInput() }
                if vertical { scroll.verticalScroller = scroller } else { scroll.horizontalScroller = scroller }
            }
            scroll.contentView.postsFrameChangedNotifications = true
            for (name, object) in [(NSView.frameDidChangeNotification, scroll.contentView as AnyObject), (NSTextStorage.willProcessEditingNotification, (scroll.documentView as? NSTextView)?.textStorage as AnyObject?)] {
                guard let object else { continue }
                entry.observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self, weak entry] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.applying else { return }
                        entry?.geometryDirty = true; self.schedule()
                    }
                })
            }
            // Capture reading position against the last settled geometry. A
            // frame notification can arrive after TextKit has already reflowed.
            scroll.contentView.postsBoundsChangedNotifications = true
            entry.observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { [weak self, weak entry] _ in
                MainActor.assumeIsolated {
                    guard let self, let entry, self.inputDepth > 0, !self.retired, !self.isGeometryPending,
                          let scroll = entry.scroll, let width = entry.measuredWidth else { return }
                    let insets = self.clipInsets(scroll)
                    guard abs(scroll.contentView.bounds.width - insets.left - insets.right - width) < 0.5 else { return }
                    self.captureAnchor(entry)
                }
            })
            entries[key] = entry
        }
        guard let entry = entries[key] else { return }
        if entry.aligned != aligned || entry.enabled != enabled { entry.geometryDirty = true }
        entry.aligned = aligned; entry.enabled = enabled
        let insets = clipInsets(scroll)
        let width = scroll.contentView.bounds.width - insets.left - insets.right
        if (entry.measuredWidth.map({ abs($0 - width) > 0.5 }) ?? true) || entry.leadingInset != insets.left { entry.geometryDirty = true }
        if entry.geometryDirty { schedule() }
    }
    private func schedule() {
        guard !retired, !queued, !applying else { return }; queued = true
        DispatchQueue.main.async { [weak self] in guard let self, self.queued else { return }; self.queued = false; self.apply() }
    }
    /// Input owns the next viewport/caret. Drain an older queued reflow before
    /// accepting that input, so its saved anchor cannot overwrite the new intent.
    func prepareForInput() {
        guard !retired, !applying, queued else { return }
        queued = false; apply()
    }
    func beginViewportInput() { prepareForInput(); if !retired { inputDepth += 1 } }
    func endViewportInput() { inputDepth = max(0,inputDepth - 1); recordViewportIntent() }
    /// Automatic TextKit caret visibility is not a new reading-position choice.
    /// Only an input scope or an explicitly completed navigation records one.
    func recordViewportIntent() {
        guard !retired, !applying else { return }
        prepareForInput()
        for entry in entries.values { captureAnchor(entry) }
    }
    private func clipInsets(_ scroll: NSScrollView) -> NSEdgeInsets { scroll.contentView.contentInsets }
    private func captureAnchor(_ entry: Entry) {
        guard let scroll = entry.scroll, let view = scroll.documentView as? NSTextView, !entry.tops.isEmpty,
              entry.text.utf8.elementsEqual(view.string.utf8) else { entry.anchor = nil; return }
        let y = scroll.contentView.bounds.minY - view.textContainerOrigin.y
        var low = 0, high = entry.tops.count
        while low < high {
            let middle = (low + high) / 2
            if entry.tops[middle] <= y { low = middle + 1 } else { high = middle }
        }
        let row = max(0,low - 1), end = row + 1 < entry.tops.count ? entry.tops[row + 1] : entry.bottom
        entry.anchor = Anchor(row: row, fraction: min(0.999999,max(0,(y - entry.tops[row]) / max(0.01,end - entry.tops[row]))))
    }
    private func cacheGeometry(_ entry: Entry, view: NSTextView) {
        guard let layout = view.layoutManager, let container = view.textContainer else { return }
        layout.ensureLayout(for: container)
        entry.text = view.string
        entry.tops = MergeLineEndings.lineRanges(in: view.string).map { range in
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            return glyph < layout.numberOfGlyphs ? layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY : layout.extraLineFragmentRect.minY
        }
        entry.bottom = layout.usedRect(for: container).maxY
        entry.geometryDirty = false
    }
    private func restore(_ anchor: Anchor, entry: Entry, scroll: NSScrollView, view: NSTextView) {
        guard entry.tops.indices.contains(anchor.row) else { return }
        let ranges = MergeLineEndings.lineRanges(in: view.string)
        guard ranges.indices.contains(anchor.row), view.textStorage?.attribute(.mergeFoldHidden, at: ranges[anchor.row].location, effectiveRange: nil) == nil else { return }
        let start = entry.tops[anchor.row], end = anchor.row + 1 < entry.tops.count ? entry.tops[anchor.row + 1] : entry.bottom
        var proposed = scroll.contentView.bounds
        proposed.origin.y = start + anchor.fraction * max(0.01,end - start) + view.textContainerOrigin.y
        let target = scroll.contentView.constrainBoundsRect(proposed).origin
        guard abs(target.y - scroll.contentView.bounds.minY) > 0.01 || abs(target.x - scroll.contentView.bounds.minX) > 0.01 else { return }
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func apply() {
        guard !retired, !applying else { return }
        let visible = entries.values.compactMap { entry -> (Entry, NSScrollView, NSTextView)? in
            guard let scroll = entry.scroll, let view = scroll.documentView as? NSTextView, view.window != nil else { return nil }
            return (entry, scroll, view)
        }
        // Identical representable updates must not enqueue another paragraph
        // rewrite and geometry callback. A new/changed peer reflows the group.
        guard visible.contains(where: { entry, scroll, _ in
            let insets = clipInsets(scroll)
            let width = scroll.contentView.bounds.width - insets.left - insets.right
            return entry.geometryDirty || entry.applied != entry.enabled || entry.leadingInset != insets.left || (entry.measuredWidth.map { abs($0 - width) > 0.5 } ?? true)
        }) else { return }
        applying = true; defer { applying = false; geometryChanged() }
        // An edit/replacement invalidates the old text-coordinate anchors for
        // the entire aligned group. Typing and model caret requests keep ownership.
        let aligned = visible.filter { $0.0.aligned }
        let alignedChanged = aligned.contains { !$0.0.text.utf8.elementsEqual($0.2.string.utf8) }
        let master = aligned.first { $0.2.window?.firstResponder === $0.2 } ?? aligned.first
        let sharedAnchor = alignedChanged ? nil : master?.0.anchor
        let saved = visible.map { entry, _, view -> Anchor? in
            guard entry.text.utf8.elementsEqual(view.string.utf8) else { return nil }
            return entry.aligned ? sharedAnchor : entry.anchor
        }
        var measured: [(NSTextView, [NSRange], [CGFloat])] = []
        alignedHeights = []
        for (entry, scroll, view) in visible {
            guard let storage = view.textStorage, let layout = view.layoutManager, let container = view.textContainer else { continue }
            let clip = scroll.contentView, insets = clipInsets(scroll)
            let width = clip.bounds.width - insets.left - insets.right; guard width > 32 else { continue }
            entry.measuredWidth = width
            let previousInset = entry.leadingInset
            let wrappingChanged = entry.applied != entry.enabled; entry.applied = entry.enabled; entry.leadingInset = insets.left
            scroll.hasHorizontalScroller = !entry.enabled
            view.isHorizontallyResizable = !entry.enabled
            view.autoresizingMask = entry.enabled ? [.width] : []
            container.widthTracksTextView = entry.enabled
            container.lineBreakMode = .byWordWrapping
            view.maxSize = NSSize(width: entry.enabled ? width : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if entry.enabled { view.setFrameSize(NSSize(width: width, height: max(view.frame.height, scroll.contentSize.height))) }
            container.containerSize = NSSize(width: entry.enabled ? max(1, width - 2 * view.textContainerInset.width) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            // Rulers occupy clip-view insets. Zero hides the first glyphs under
            // the ruler; the leading position is minus that inset. Preserve a
            // user's horizontal offset when only ruler geometry changes.
            if wrappingChanged || previousInset != insets.left {
                var proposed = clip.bounds
                proposed.origin.x = wrappingChanged ? -insets.left : clip.bounds.minX + (previousInset ?? insets.left) - insets.left
                clip.scroll(to: clip.constrainBoundsRect(proposed).origin); scroll.reflectScrolledClipView(clip)
            }
            let ranges = MergeLineEndings.lineRanges(in: view.string)
            storage.beginEditing()
            for range in ranges {
                let paragraph = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.paragraphSpacing = 0; storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
            storage.endEditing(); layout.ensureLayout(for: container)
            if entry.enabled && entry.aligned {
                let minimum = layout.defaultLineHeight(for: view.font ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular))
                let heights = ranges.map { range -> CGFloat in
                    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    if storage.attribute(.mergeFoldHidden, at: range.location, effectiveRange: nil) != nil { return 0.01 }
                    return max(minimum, layout.boundingRect(forGlyphRange: glyphs, in: container).height)
                }
                measured.append((view, ranges, heights))
            }
            view.needsDisplay = true; scroll.verticalRulerView?.needsDisplay = true
        }
        if measured.count > 1 {
            let count = measured.map { $0.1.count }.max() ?? 0
            alignedHeights = (0..<count).map { index in measured.map { $0.2.indices.contains(index) ? $0.2[index] : 0 }.max() ?? 0 }
            for (view, ranges, heights) in measured {
                guard let storage = view.textStorage else { continue }
                storage.beginEditing()
                for (index, range) in ranges.enumerated() {
                    let padding = max(0, alignedHeights[index] - heights[index]); guard padding > 0.1 else { continue }
                    let paragraph = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    paragraph.paragraphSpacing = padding; storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
                }
                storage.endEditing(); view.layoutManager?.ensureLayout(for: view.textContainer!); view.needsDisplay = true
            }
        }
        // Complete the common geometry before restoring any scroll position:
        // peer scroll observers must see the new row heights in every pane.
        for (entry, scroll, view) in visible {
            guard let layout = view.layoutManager, let container = view.textContainer else { continue }
            layout.ensureLayout(for: container)
            let height = max(scroll.contentSize.height, layout.usedRect(for: container).maxY + 2 * view.textContainerInset.height)
            if abs(view.frame.height - height) > 0.1 { view.setFrameSize(NSSize(width: view.frame.width, height: height)) }
            cacheGeometry(entry, view: view)
        }
        for (index, item) in visible.enumerated() {
            if let anchor = saved[index] { restore(anchor, entry: item.0, scroll: item.1, view: item.2) }
        }
        for (entry, _, _) in visible { captureAnchor(entry) }
        // A scroller appearing/disappearing can change the usable width during
        // layout. Reconcile that one real geometry change after this pass.
        if visible.contains(where: { entry, scroll, _ in
            let insets = clipInsets(scroll), width = scroll.contentView.bounds.width - insets.left - insets.right
            return entry.measuredWidth.map { abs($0 - width) > 0.5 && width > 32 } ?? false
        }) {
            for (entry, scroll, _) in visible {
                let insets = clipInsets(scroll), width = scroll.contentView.bounds.width - insets.left - insets.right
                if entry.measuredWidth.map({ abs($0 - width) > 0.5 }) ?? true { entry.geometryDirty = true }
            }
            DispatchQueue.main.async { [weak self] in self?.schedule() }
        }
    }
    func retire() { retired = true; queued = false; inputDepth = 0; entries = [:]; alignedHeights = []; geometryChanged = {} }
}


struct MergeLineStatisticsView: View {
    let statistics: MergeLineStatistics
    var palette = MergePalette.Context()
    private func count(_ title:String,_ value:Int,_ state:MergeSourceState)->some View {
        HStack(spacing:4) {
            Rectangle().fill(Color(nsColor:palette.color(state))).overlay(Rectangle().stroke(.secondary,lineWidth:0.5)).frame(width:8,height:8).accessibilityHidden(true)
            Text("\(title): \(value)")
        }
    }
    var body: some View {
        HStack(spacing:12) {
            if statistics.removed > 0 {count("Removed",statistics.removed,.removed)}
            if statistics.added > 0 {count("Added",statistics.added,.added)}
            if statistics.conflicted > 0 {count("Conflicted",statistics.conflicted,.conflicted)}
            Spacer(minLength:0)
        }.font(.caption).accessibilityElement(children:.combine)
    }
}

/// Source DrawBlockLine/GetViewSelection is independent of text selection.
/// Exposing the range also lets native accessibility/QA inspect that distinction.
@MainActor protocol MergeBlockSelecting: AnyObject {
    var mergeSelectedBlockRange: NSRange? { get }
    var mergeBlockBoundaryRects: [NSRect] { get }
    func selectContextBlock(at displayOffset: Int)
}

struct MergeMarginStamp: Equatable {
    let values: [Int]
    let text: String
    static func == (a: Self, b: Self) -> Bool { a.values == b.values && a.text.utf8.elementsEqual(b.text.utf8) }
}
@MainActor protocol MergeMarginSelecting: AnyObject {
    var marginSelectionAllowed: Bool { get }
    var marginSelectionStamp: MergeMarginStamp { get }
    func beginMarginSelection()
    func selectMargin(rows: Range<Int>, selection: NSRange, caret: Int)
    func expandMarginFold(row: Int) -> Bool
}

enum MergeMarginGeometry {
    static func range(rows: Range<Int>, in view: NSTextView) -> NSRange? {
        let ranges = MergeSourceComparison.navigationRanges(text:view.string)
        guard !rows.isEmpty, ranges.indices.contains(rows.lowerBound), ranges.indices.contains(rows.upperBound - 1) else { return nil }
        return NSRange(location:ranges[rows.lowerBound].location,length:NSMaxRange(ranges[rows.upperBound - 1]) - ranges[rows.lowerBound].location)
    }
}

@MainActor final class MergeBlockSelection {
    private var savedRange: NSRange?
    private var savedText = ""
    private var expectedSelection = NSRange(location:0,length:0)
    func range(in view: NSTextView) -> NSRange? {
        guard let range = savedRange else { return nil }
        guard view.selectedRange() == expectedSelection,
              savedText.utf8.elementsEqual(view.string.utf8) else { clear(in:view); return nil }
        return range
    }
    func install(_ range: NSRange, caret: Int, selection: NSRange? = nil, in view: NSTextView) {
        let selected = selection ?? NSRange(location:caret,length:0)
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= view.string.utf16.count,
              caret >= 0, caret <= view.string.utf16.count, selected.location >= 0, selected.length >= 0,
              NSMaxRange(selected) <= view.string.utf16.count else { clear(in:view); return }
        savedRange = range; savedText = view.string; expectedSelection = selected
        view.setSelectedRange(selected,affinity:caret == selected.location ? .upstream:.downstream,stillSelecting:false); view.needsDisplay = true
    }
    func moveCaret(_ offset: Int, in view: NSTextView) {
        guard let range = range(in:view) else { view.setSelectedRange(NSRange(location:offset,length:0)); return }
        install(range,caret:offset,in:view)
    }
    func clear(in view: NSTextView) {
        guard savedRange != nil else { return }
        savedRange = nil; savedText = ""; view.needsDisplay = true
    }
    static func rows(_ range: NSRange, cells: [MergeSourceCell]) -> Range<Int>? {
        let lines = MergeFindLine.displayCells(cells)
        guard let first = lines.lastIndex(where: { $0.offset <= range.location }),
              let last = lines.lastIndex(where: { $0.offset <= NSMaxRange(range) }) else { return nil }
        return first..<(last + 1)
    }
    func boundaryRects(in view: NSTextView) -> [NSRect] {
        guard let range = range(in:view), let layout = view.layoutManager, let container = view.textContainer else { return [] }
        layout.ensureLayout(for:container)
        func fragment(_ offset: Int) -> NSRect? {
            if offset == view.string.utf16.count, layout.extraLineFragmentTextContainer === container { return layout.extraLineFragmentRect }
            guard layout.numberOfGlyphs > 0 else { return nil }
            let glyph = layout.glyphIndexForCharacter(at:min(offset,max(0,view.string.utf16.count - 1)))
            return layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
        }
        guard let first = fragment(range.location), let last = fragment(NSMaxRange(range)) else { return [] }
        let visible = view.visibleRect, origin = view.textContainerOrigin
        return [NSRect(x:visible.minX,y:first.minY + origin.y,width:visible.width,height:2),
                NSRect(x:visible.minX,y:max(first.minY,last.maxY - 2) + origin.y,width:visible.width,height:2)]
    }
    func draw(in view: NSTextView, dirtyRect: NSRect) {
        (view.window?.firstResponder === view ? NSColor.labelColor : NSColor.secondaryLabelColor).setFill()
        for rect in boundaryRects(in:view) where rect.intersects(dirtyRect) { NSBezierPath(rect:rect).fill() }
    }
    func centerCaret(in view: NSTextView) {
        guard let scroll = view.enclosingScrollView, let layout = view.layoutManager, let container = view.textContainer else { return }
        layout.ensureLayout(for:container)
        let offset = min(view.selectedRange().location,max(0,view.string.utf16.count - 1))
        guard layout.numberOfGlyphs > 0 else { return }
        let glyph = layout.glyphIndexForCharacter(at:offset)
        let rect = layout.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
        let clip = scroll.contentView
        var point = clip.bounds.origin
        point.y = rect.midY + view.textContainerOrigin.y - clip.bounds.height / 2
        clip.scroll(to:clip.constrainBoundsRect(NSRect(origin:point,size:clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }
}


/// A two-pane owner keeps its divider ratio independently of combined view.
/// SwiftUI's rebuilt split would otherwise inherit the single pane's width.
struct MergeComparisonSplit: NSViewRepresentable {
    let model: FileComparisonWindowModel
    func makeNSView(context: Context) -> MergeComparisonSplitView {
        let view = MergeComparisonSplitView()
        view.preferences = model.comparisonDefaults; view.isVertical = true; view.dividerStyle = .thin
        let saved = model.comparisonDefaults.double(forKey: MergeComparisonSplitView.key)
        view.fraction = saved.isFinite && (0.1...0.9).contains(saved) ? saved : 0.5
        for base in [true, false] {
            let pane = NSHostingView(rootView: FileComparisonPane(model: model, base: base))
            // The split owns these frames. Child intrinsic/min/max sizes must
            // not feed a second content-sized layout back into its parent.
            pane.sizingOptions = []
            view.addArrangedSubview(pane)
        }
        return view
    }
    func updateNSView(_ view: MergeComparisonSplitView, context: Context) { view.layoutPanes() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MergeComparisonSplitView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
}
@MainActor final class MergeComparisonSplitView: NSSplitView {
    static let key = "TurtleGitMerge.TwoPaneSplitFraction"
    var preferences: UserDefaults?
    var fraction: CGFloat = 0.5
    private var applying = false, tracking = false
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if tracking { super.resizeSubviews(withOldSize:oldSize) } else { layoutPanes() }
    }
    override func mouseDown(with event: NSEvent) {
        tracking = true;super.mouseDown(with:event);tracking = false;recordDivider()
    }
    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        super.setPosition(position,ofDividerAt:dividerIndex)
        if !applying && !tracking { recordDivider() }
    }
    func recordDivider() {
        let usable = bounds.width - dividerThickness
        guard !applying,arrangedSubviews.count == 2,usable > 0 else { return }
        fraction = min(0.9,max(0.1,arrangedSubviews[0].frame.width / usable))
        preferences?.set(Double(fraction),forKey:Self.key)
    }
    func layoutPanes() {
        guard !applying,arrangedSubviews.count == 2,bounds.width > dividerThickness else { return }
        applying = true;defer { applying = false }
        let usable = bounds.width - dividerThickness,minimum = min(300,usable / 2)
        let width = min(usable - minimum,max(minimum,usable * fraction))
        let left = NSRect(x:0,y:0,width:width,height:bounds.height)
        let right = NSRect(x:width + dividerThickness,y:0,width:usable - width,height:bounds.height)
        var changed = false
        if arrangedSubviews[0].frame != left { arrangedSubviews[0].frame = left; changed = true }
        if arrangedSubviews[1].frame != right { arrangedSubviews[1].frame = right; changed = true }
        if changed { needsDisplay = true }
    }
}


@MainActor protocol MergeTypingProviding: AnyObject {
    var mergeOverwrite: Bool { get }
    var mergeTypingAllowed: Bool { get }
    var canCycleCurrentEnding: Bool { get }
    func toggleMergeOverwrite()
    func cycleCurrentEnding()
}

struct MergeTypingModeControl: View {
    let overwrite:Bool
    let enabled:Bool
    let toggle:()->Void
    var body: some View {
        Button(overwrite ? "OVR" : "INS",action:toggle)
            .font(.system(.caption,design:.monospaced)).buttonStyle(.borderless)
            .foregroundStyle(overwrite ? Color.orange : Color.secondary)
            .accessibilityLabel(overwrite ? "Overwrite mode" : "Insert mode")
            .help("Toggle Insert/Overwrite mode (Insert key)").disabled(!enabled)
    }
}


@MainActor enum MergeTypingCaret {
    static func draw(in view:NSTextView,rect:NSRect,color:NSColor,on:Bool) {
        var block = rect
        if let layout = view.layoutManager,let container = view.textContainer,view.selectedRange().location < view.string.utf16.count {
            let chars = (view.string as NSString).rangeOfComposedCharacterSequence(at:view.selectedRange().location)
            let glyphs = layout.glyphRange(forCharacterRange:chars,actualCharacterRange:nil)
            block.size.width = max(rect.width,layout.boundingRect(forGlyphRange:glyphs,in:container).width)
        }
        if block.width < 3 {block.size.width = (" " as NSString).size(withAttributes:[.font:view.font ?? NSFont.monospacedSystemFont(ofSize:12,weight:.regular)]).width}
        guard on else {view.setNeedsDisplay(block);return}
        color.withAlphaComponent(0.35).setFill();block.fill()
    }
}

enum MergeUnresolvedSaveChoice: Sendable {
    case saveAnyway, continueResolving, cancel
}

/// One editor owns each save question and output panel. Programmatic cancellation
/// aborts saving; the visible empty-file Cancel button still means Keep, upstream.
@MainActor final class MergeSaveChoices {
    private(set) var question:NSAlert?
    private(set) var panel:NSSavePanel?
    private weak var owner:NSWindow?
    private var cancelled=false
    func reset() {cancelled=false}
    func cancel() {
        cancelled=true
        if let question,question.window.sheetParent === owner {owner?.endSheet(question.window,returnCode:.abort);question.window.orderOut(nil)}
        if let panel,panel.sheetParent === owner {owner?.endSheet(panel,returnCode:.cancel);panel.orderOut(nil)}
    }
    private func ask(_ alert:NSAlert,window:NSWindow?) async -> NSApplication.ModalResponse? {
        guard !cancelled,let window,window.attachedSheet==nil,question==nil,panel==nil else {return nil}
        owner=window;question=alert
        let answer=await withCheckedContinuation {continuation in alert.beginSheetModal(for:window) {continuation.resume(returning:$0)}}
        // The reply can arrive before AppKit finishes detaching the sheet.
        // Keep this save's question and operation alive until focus/navigation
        // can safely return to the editor, including on owner cancellation.
        while alert.window.sheetParent != nil || window.attachedSheet === alert.window {
            try? await Task.sleep(nanoseconds:5_000_000)
        }
        question=nil;owner=nil
        return cancelled ? nil : answer
    }
    func empty(window:NSWindow?,path:String) async -> MergeEmptyResult? {
        let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="File is empty."
        alert.informativeText="Delete “\((path as NSString).lastPathComponent)” or keep the empty file?"
        alert.addButton(withTitle:"Delete");alert.addButton(withTitle:"Cancel — Keep Empty File").keyEquivalent="\u{1b}"
        guard let answer=await ask(alert,window:window) else {return nil}
        return answer == .alertFirstButtonReturn ? .delete : .keep
    }
    func unresolved(window:NSWindow?,message:String) async -> Bool {
        await unresolvedResolution(window:window,message:message) == .saveAnyway
    }
    func unresolvedResolution(window:NSWindow?,message:String) async -> MergeUnresolvedSaveChoice {
        let alert=NSAlert();alert.alertStyle = .warning;alert.messageText=message
        alert.informativeText="Save the file with unresolved conflicts, or return to the first conflict and continue resolving it."
        alert.addButton(withTitle:"Save Anyway").keyEquivalent=""
        let resolving=alert.addButton(withTitle:"Continue Resolving");resolving.keyEquivalent="\r"
        alert.addButton(withTitle:"Cancel").keyEquivalent="\u{1b}"
        alert.window.defaultButtonCell=resolving.cell as? NSButtonCell
        guard let answer=await ask(alert,window:window) else {return .cancel}
        switch answer {
        case .alertFirstButtonReturn:return .saveAnyway
        case .alertSecondButtonReturn:return .continueResolving
        default:return .cancel
        }
    }
    func marked(window:NSWindow?) async -> FileComparisonEditing.MarkedSaveChoice? {
        let alert=NSAlert();alert.alertStyle = .warning;alert.messageText="Marked Blocks"
        alert.informativeText="You have marked changed blocks. How should those blocks be saved? Manual edits are retained with every choice."
        for title in ["Save and Include","Save and Exclude","Save Only Manual Edits","Cancel"] {alert.addButton(withTitle:title)}
        guard let answer=await ask(alert,window:window) else {return nil}
        switch answer {
        case .alertFirstButtonReturn:return .include
        case .alertSecondButtonReturn:return .exclude
        case .alertThirdButtonReturn:return .manualEditsOnly
        default:return nil
        }
    }
    func output(window:NSWindow?,name:String,directory:URL? = nil) async -> URL? {
        guard !cancelled,let window,window.attachedSheet==nil,question==nil,panel==nil else {return nil}
        let panel=NSSavePanel();panel.title="Save merged result";panel.nameFieldStringValue=name;panel.canCreateDirectories=true;panel.directoryURL=directory
        owner=window;self.panel=panel
        let answer=await withCheckedContinuation {continuation in panel.beginSheetModal(for:window) {continuation.resume(returning:$0)}}
        self.panel=nil;owner=nil
        return !cancelled && answer == .OK ? panel.url : nil
    }
}

/// Atomic saves and .bak files need the containing folder, not just a leaf-file
/// grant. Acquire it only for an explicit save, under that save's existing owner.
@MainActor final class MergeSaveFolderAccess {
    var requireScope=GitRuntime.isAppStoreBuild
    var readingEditorConfig = false
    var chooseFolder:((NSWindow?,URL) async -> URL?)?
    var makeLease:(URL)->RepositoryAccessLease = {RepositoryAccessLease(url:$0)}
    private(set) var panel:NSOpenPanel?
    func cancel() {
        if let panel {panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.orderOut(nil)}
    }
    func authorize(file:URL,permissions:[RepositoryAccessLease],window:NSWindow?,cancellation:OperationCancellation) async throws -> [RepositoryAccessLease]? {
        try cancellation.check()
        guard requireScope else {return []}
        let file=file.standardizedFileURL,parent=file.deletingLastPathComponent()
        if permissions.contains(where:{$0.permits(file) && $0.permits(parent)}) {return []}
        let plan = try await Task.detached { try MergeOutputDirectories(capturing: file) }.value
        try cancellation.check()
        let requested = plan.ancestor
        let selected:URL?
        if let chooseFolder {selected=await chooseFolder(window,requested)}
        else {
            guard let window,window.attachedSheet==nil,panel==nil else {return nil}
            let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
            panel.directoryURL=requested;panel.prompt=readingEditorConfig ? "Read EditorConfig" : "Allow Save";panel.title=readingEditorConfig ? "Read EditorConfig" : "Allow saving in this folder"
            panel.message=readingEditorConfig ? "Choose the folder containing “" + file.lastPathComponent + "” to read its EditorConfig settings." : "Choose the folder containing “" + file.lastPathComponent + "” to allow saving and backups."
            self.panel=panel
            let answer=await withCheckedContinuation {continuation in panel.beginSheetModal(for:window) {continuation.resume(returning:$0)}}
            self.panel=nil;selected=answer == .OK ? panel.url : nil
        }
        try cancellation.check()
        guard let selected else {return nil}
        let permission=makeLease(selected)
        guard permission.permits(file),permission.permits(parent) else {throw RepositoryAccessFailure.securityScopeUnavailable}
        return [permission]
    }
}

/// Saving bytes and authorizing an index change are distinct operations. A
/// caller keeps its saved baseline and receipt until this owned Add or Resolve
/// completes. Both actions use the same bounded repository/metadata authority.
@MainActor final class MergeNewOutputAdd {
    var requiresScope = GitRuntime.isAppStoreBuild
    var executable: (() throws -> URL)?
    var resolveRepository: ((URL, OperationCancellation) async throws -> (GitRepository, [RepositoryAccessLease])?)?
    var addOutput:(GitRepository,MergeNewOutputReceipt,OperationCancellation) async throws -> Void = {repository,receipt,token in
        try await repository.addNewMergeOutput(receipt,cancellation:token)
    }
    var chooseRepository: ((NSWindow?, URL) async -> URL?)?
    var makeLease: (URL) -> RepositoryAccessLease = { RepositoryAccessLease(url: $0) }
    private(set) var panel: NSOpenPanel?
    private var retainedPermissions: [RepositoryAccessLease] = []
    func cancel() {
        if let panel {
            if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }
            else { panel.cancel(nil) }
            panel.orderOut(nil)
        }
    }
    private func covers(_ root: URL, with permissions: [RepositoryAccessLease]) -> Bool {
        !requiresScope || permissions.contains { $0.hasSecurityScope && $0.contains(root) }
    }
    private enum Action { case add, resolve }
    private enum Authorization {
        case noRepository
        case repository(GitRepository,[RepositoryAccessLease])
    }
    private func chooseFolder(_ start: URL, message: String, window: NSWindow?, action: Action) async -> URL? {
        if let chooseRepository { return await chooseRepository(window, start) }
        guard panel == nil, window?.attachedSheet == nil else { return nil }
        let chooser = NSOpenPanel(); chooser.canChooseFiles = false; chooser.canChooseDirectories = true
        chooser.allowsMultipleSelection = false; chooser.directoryURL = start
        chooser.title = action == .resolve ? NSLocalizedString("Mark saved file as resolved", comment: "") : NSLocalizedString("Add saved file to Git", comment: "")
        chooser.prompt = action == .resolve ? NSLocalizedString("Allow Resolve", comment: "") : NSLocalizedString("Allow Add", comment: ""); chooser.message = message
        panel = chooser
        let answer = await withCheckedContinuation { continuation in
            if let window, window.isVisible { chooser.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            else { chooser.begin { continuation.resume(returning: $0) } }
        }
        while chooser.sheetParent != nil || window?.attachedSheet === chooser {
            try? await Task.sleep(nanoseconds:5_000_000)
        }
        panel = nil; return answer == .OK ? chooser.url : nil
    }
    private func authorize(file: URL, repository: GitRepository?, permissions: [RepositoryAccessLease],
        window: NSWindow?, action: Action, cancellation: OperationCancellation) async throws -> Authorization? {
        try cancellation.check()
        let effectivePermissions = permissions + retainedPermissions
        let resolved: (GitRepository, [RepositoryAccessLease])
        if let resolveRepository {
            guard let value = try await resolveRepository(file, cancellation) else { return nil }
            resolved = value
        } else {
            let parent = file.deletingLastPathComponent(), scoped = requiresScope
            // Marker discovery stops at the live grant boundary. Do not start
            // Git's upward repository walk with only a narrow output grant.
            let discovered = try await Task.detached {
                try RepositoryMetadataAccess.discoverMergeOutputRepository(at: parent, permissions: effectivePermissions,
                    requireSecurityScope: scoped, cancellation: cancellation)
            }.value
            try cancellation.check()
            if case .noRepository=discovered,action == .add {
                // AutoAdd is a native extension to the upstream /noui launch
                // (its AddCommand body is compiled out). A proven plain-folder
                // Save needs no Git runtime, chooser or fabricated staging.
                return .noRepository
            }
            let git: URL
            if let executable { git = try executable() }
            else if let repository { git = repository.executable }
            else { git = try GitRuntime.executable() }
            let askpass:URL?
            if let repository {askpass=repository.askpass} else {askpass=GitAskpassRuntime.bundled()}
            func atRoot(_ root: URL) -> GitRepository {
                GitRepository(root:root, executable:git, askpass:askpass,
                    diffDetection:repository?.diffDetection ?? .load(), libgit2Configuration:repository?.libgit2Configuration)
            }
            if case let .repository(root)=discovered,covers(root, with: effectivePermissions) {
                resolved = (atRoot(root), [])
            } else {
                guard let selected = await chooseFolder(parent,
                    message: action == .resolve ? NSLocalizedString("Choose the Git repository folder to mark the saved file as resolved. The file is already saved.", comment: "") : NSLocalizedString("Choose the Git repository folder to add the saved file. The file is already saved.", comment: ""), window: window, action: action) else { return nil }
                try cancellation.check()
                let grant = makeLease(selected)
                guard covers(selected, with: [grant]), RepositoryAccessLease.pathIsContained(file, by: selected) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                resolved = (atRoot(selected), [grant])
            }
        }
        var held = effectivePermissions + resolved.1, acquired = resolved.1
        defer { withExtendedLifetime(held) {} }
        try cancellation.check()
        guard covers(resolved.0.root, with: held), RepositoryAccessLease.pathIsContained(file, by: resolved.0.root) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        retainedPermissions += resolved.1
        let expectedRoot = resolved.0.root, rootPermissions = held, scoped = requiresScope
        let markedRoot = try await Task.detached {
            try RepositoryMetadataAccess.settingsRepository(at: expectedRoot, permissions: rootPermissions,
                requireSecurityScope: scoped, cancellation: cancellation)
        }.value
        guard let markedRoot, GitReferenceName.equal(markedRoot.resolvingSymlinksInPath().standardizedFileURL.path, expectedRoot.resolvingSymlinksInPath().standardizedFileURL.path) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        if requiresScope {
            for _ in 0..<256 {
                let currentPermissions = held, root = resolved.0.root
                let needed = try await Task.detached {
                    try RepositoryMetadataAccess.next(at: root, permissions: currentPermissions, cancellation: cancellation)
                }.value
                guard let needed else { break }
                guard let selected = await chooseFolder(needed.folder, message: needed.explanation, window: window, action: action) else { return nil }
                try cancellation.check()
                let grant = makeLease(selected)
                guard covers(needed.folder, with: [grant]) else { throw RepositoryAccessFailure.securityScopeUnavailable }
                held.append(grant); acquired.append(grant); retainedPermissions.append(grant)
            }
            let finalPermissions = held, root = resolved.0.root
            let remaining = try await Task.detached {
                try RepositoryMetadataAccess.next(at: root, permissions: finalPermissions, cancellation: cancellation)
            }.value
            guard remaining == nil else { throw RepositoryMetadataAccessFailure.tooManyDependencies }
        }
        let actual = try await resolved.0.discoverRoot(cancellation: cancellation)
        guard GitReferenceName.equal(actual.resolvingSymlinksInPath().standardizedFileURL.path, resolved.0.root.resolvingSymlinksInPath().standardizedFileURL.path), covers(actual, with: held) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        try cancellation.check()
        return .repository(resolved.0, acquired)
    }
    func perform(_ receipt: MergeNewOutputReceipt, repository: GitRepository? = nil,
        permissions: [RepositoryAccessLease], window: NSWindow?, cancellation: OperationCancellation) async throws -> [RepositoryAccessLease]? {
        guard let authority=try await authorize(file:receipt.url,repository:repository,permissions:permissions,window:window,action:.add,cancellation:cancellation) else {return nil}
        guard case let .repository(git,acquired)=authority else {return []}
        let authorized=(git,acquired)
        let held=permissions+retainedPermissions+authorized.1
        defer {withExtendedLifetime(held) {}}
        try await addOutput(authorized.0,receipt,cancellation)
        return authorized.1
    }
    func resolveSaved(_ receipt: MergeSavedOutputReceipt, repository: GitRepository? = nil,
        permissions: [RepositoryAccessLease], window: NSWindow?, allowUnresolvedConflicts: Bool = false,
        cancellation: OperationCancellation, validate: (() throws -> Void)? = nil) async throws -> (permissions: [RepositoryAccessLease], repository: GitRepository)? {
        guard let authority=try await authorize(file:receipt.url,repository:repository,permissions:permissions,window:window,action:.resolve,cancellation:cancellation) else {return nil}
        guard case let .repository(git,acquired)=authority else {throw RepositoryAccessFailure.securityScopeUnavailable}
        let authorized=(git,acquired)
        let held=permissions+retainedPermissions+authorized.1
        defer {withExtendedLifetime(held) {}}
        try cancellation.check();try validate?()
        try await authorized.0.resolveSavedMergeOutput(receipt,allowUnresolvedConflicts:allowUnresolvedConflicts,cancellation:cancellation)
        // The index publication has succeeded. A late Cancel cannot undo it or
        // turn that accepted result into an apparent failed retry.
        return (authorized.1,authorized.0)
    }

}

/// One pane read owns its folder sheet, child process and access leases until
/// drain. Models may retire it immediately without accepting a late result.
@MainActor final class MergeEditorConfigRead {
    let cancellation = OperationCancellation()
    let folderAccess = MergeSaveFolderAccess()
    var resolve: @Sendable (URL, OperationCancellation) throws -> MergeEditorConfigProperties = {
        try EditorConfigRuntime.resolve(file:$0,cancellation:$1)
    }
    init() { folderAccess.readingEditorConfig = true }
    func cancel() { cancellation.cancel(); folderAccess.cancel() }
    func read(file:URL, permissions:[RepositoryAccessLease], window:NSWindow?, authorized: (([RepositoryAccessLease]) -> Void)? = nil) async throws -> MergeEditorConfigProperties? {
        MergeRegexOperations.activeRequests += 1
        defer { MergeRegexOperations.activeRequests -= 1 }
        guard let acquired = try await folderAccess.authorize(file:file,permissions:permissions,window:window,cancellation:cancellation) else { return nil }
        try cancellation.check()
        authorized?(acquired)
        let held = permissions + acquired
        defer { withExtendedLifetime(held) {} }
        let resolve = resolve, cancellation = cancellation
        return try await Task.detached { try resolve(file,cancellation) }.value
    }
}

/// One editor serializes its pane reads so a single native permission sheet is
/// owned at a time. Granted folders remain scoped to this editor and are reused
/// only where their actual lease covers a subsequent reflected/actual target.
@MainActor final class MergeEditorConfigAccess {
    private var permissions: [RepositoryAccessLease] = []
    private var tail: Task<Void, Never>?
    private var latest: UUID?
    private var deniedParents: [UUID: Set<Data>] = [:]
    private var latestGroup: UUID?
    private var retired = false
    func read(_ read: MergeEditorConfigRead, file: URL, permissions existing: [RepositoryAccessLease], window: NSWindow?, group: UUID = UUID()) async throws -> MergeEditorConfigProperties? {
        guard !retired else { throw OperationCancellationFailure.cancelled }
        MergeRegexOperations.activeRequests += 1
        defer { MergeRegexOperations.activeRequests -= 1 }
        if tail == nil, latestGroup != group { deniedParents.removeAll() }
        latestGroup = group
        let previous = tail, id = UUID()
        let parent = Data(((file.path as NSString).deletingLastPathComponent).utf8)
        let task = Task { @MainActor [self] () throws -> MergeEditorConfigProperties? in
            await previous?.value
            try read.cancellation.check()
            guard !retired else { throw OperationCancellationFailure.cancelled }
            // A cancelled folder chooser does not produce the same question for
            // every remaining pane of one reload. A later explicit read can retry.
            guard deniedParents[group]?.contains(parent) != true else { return nil }
            let result = try await read.read(file: file, permissions: existing + permissions, window: window, authorized: { [weak self] acquired in
                guard let self, !self.retired else { return }
                self.permissions += acquired
            })
            if result == nil, !read.cancellation.isCancelled { deniedParents[group, default: []].insert(parent) }
            return result
        }
        latest = id
        tail = Task { _ = try? await task.value }
        defer { if latest == id { tail = nil; latest = nil } }
        return try await task.value
    }
    func retire() { retired = true; permissions.removeAll(); deniedParents.removeAll() }
}

struct MergePaneTabCommand {
    enum Action { case width(Int), spaces(Bool), smart(Bool), editorConfig(Bool) }
    let epoch: UUID
    let writable: Bool
    let editorConfigLoaded: Bool
}


/// Decorative connections use the editors' actual glyph geometry, including
/// wrapping and independent scroll offsets. They never intercept editor input.
struct CurvedDiffConnections: NSViewRepresentable {
    let editors: () -> (NSScrollView?, NSScrollView?)
    let blocks: [Range<Int>]
    var leftRanges: [NSRange]? = nil
    var rightRanges: [NSRange]? = nil
    var tint: NSColor = .systemBlue
    var conflictBorders:[Bool]? = nil
    func makeNSView(context: Context) -> CurvedDiffConnectionView { CurvedDiffConnectionView() }
    func updateNSView(_ view: CurvedDiffConnectionView, context: Context) {
        view.editors = editors; view.blocks = blocks; view.leftRanges=leftRanges;view.rightRanges=rightRanges;view.tint=tint;view.conflictBorders=conflictBorders; view.needsDisplay = true
    }
    static func dismantleNSView(_ view: CurvedDiffConnectionView, coordinator: ()) { view.retire() }
}
@MainActor final class CurvedDiffConnectionView: NSView {
    var editors: () -> (NSScrollView?, NSScrollView?) = { (nil, nil) }
    var blocks: [Range<Int>] = []
    var leftRanges: [NSRange]?, rightRanges: [NSRange]?
    var tint: NSColor = .systemBlue
    var conflictBorders:[Bool]?
    private var observations: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification, NSText.didChangeNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil, let view = note.object as? NSView, view.window === self.window else { return }
                    self.needsDisplay = true
                }
            })
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func retire() { observations.forEach(NotificationCenter.default.removeObserver); observations = []; editors = { (nil,nil) } }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    override func layout() { super.layout(); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    private func spans(_ scroll: NSScrollView?, ranges: [Range<Int>], characters: [NSRange]?) -> [NSRect?] {
        guard let text = scroll?.documentView as? NSTextView, let layout = text.layoutManager, let container = text.textContainer else { return ranges.map { _ in nil } }
        layout.ensureLayout(for: container)
        let lines = MergeLineEndings.lineRanges(in: text.string)
        let input = characters ?? ranges.map { rows in
            guard !rows.isEmpty, rows.lowerBound < lines.count else { return NSRange(location:text.string.utf16.count,length:0) }
            let first=lines[max(0,rows.lowerBound)],last=lines[min(lines.count-1,rows.upperBound-1)]
            return NSRange(location:first.location,length:NSMaxRange(last)-first.location)
        }
        return input.map { range in
            guard range.location >= 0, NSMaxRange(range) <= text.string.utf16.count else { return nil }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            if range.length == 0 {
                if range.location == text.string.utf16.count { rect=layout.extraLineFragmentRect }
                else if layout.numberOfGlyphs > 0 {rect=layout.lineFragmentRect(forGlyphAt:min(glyphs.location,layout.numberOfGlyphs-1),effectiveRange:nil)}
                rect.size.height=2
            }
            rect.origin.x += text.textContainerOrigin.x; rect.origin.y += text.textContainerOrigin.y
            if rect.height < 2 { rect.size.height = layout.defaultLineHeight(for: text.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)) }
            return convert(rect, from: text)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let (left, right) = editors()
        (left?.backgroundColor ?? right?.backgroundColor ?? .textBackgroundColor).setFill(); bounds.fill()
        let a = spans(left, ranges: blocks, characters:leftRanges), b = spans(right, ranges: blocks, characters:rightRanges)
        for index in 0..<min(a.count,b.count) {
            guard let l = a[index], let r = b[index], max(l.maxY,r.maxY) >= 0, min(l.minY,r.minY) <= bounds.height else { continue }
            let path = NSBezierPath(), width = bounds.width, bend = width * 0.5
            path.move(to: NSPoint(x: 0, y: l.minY))
            path.curve(to: NSPoint(x: width, y: r.minY), controlPoint1: NSPoint(x: bend, y: l.minY), controlPoint2: NSPoint(x: bend, y: r.minY))
            path.line(to: NSPoint(x: width, y: r.maxY))
            path.curve(to: NSPoint(x: 0, y: l.maxY), controlPoint1: NSPoint(x: bend, y: r.maxY), controlPoint2: NSPoint(x: bend, y: l.maxY))
            path.close(); tint.withAlphaComponent(0.18).setFill(); path.fill()
            (conflictBorders?.indices.contains(index)==true && conflictBorders?[index]==true ? NSColor.systemRed:tint).withAlphaComponent(0.65).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
}
