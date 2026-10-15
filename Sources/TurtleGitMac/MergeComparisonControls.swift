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
        MergePalette.inlineRemoved.setFill()
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
    var body: some View {
        Menu("View") {
            Toggle("Wrap long lines", isOn: Binding(get: { wrapLines }, set: applyWrap))
            Toggle("Collapsed", isOn: Binding(get: { collapsed }, set: applyCollapsed))
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
    func makeNSView(context: Context) -> MergeLocatorNativeView { MergeLocatorNativeView() }
    func updateNSView(_ view: MergeLocatorNativeView, context: Context) {
        view.map = map; view.viewport = viewport; view.highlights = highlights; view.fishEye = fishEye; view.enabled = enabled; view.navigate = navigate
        view.needsDisplay = true
    }
}
/// Native counterpart of LocatorBar.cpp: Left / Bottom / Right stripes,
/// source colors, blue viewport, nonselecting drag and fourfold hover lens.
@MainActor final class MergeLocatorNativeView: NSView {
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
        MergePalette.color(MergeSourceState.normal).setFill(); bounds.fill()
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
            if highlights.indices.contains(column) {
                for (rows, scaleAmount) in [(highlights[column].marked, 200), (highlights[column].search, 30)] {
                    MergeFindHighlights.intense(MergePalette.color(.normal), scale: scaleAmount).setFill()
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

@MainActor protocol MergeWhitespaceDisplaying { var whitespaceRenderer: MergeWhitespaceRenderer { get } }
/// Draws source whitespace symbols over glyphs. No attributed-string characters,
/// selection offsets, clipboard values or original ending metadata are replaced.
@MainActor final class MergeWhitespaceRenderer {
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
        if colorRevision != MergePalette.revision { colorRevision = MergePalette.revision; darkIcons = [:] }
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
            MergePalette.whitespace.setStroke(); MergePalette.whitespace.setFill()
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
                        if changed && highlightEndings { (removal ? MergePalette.inlineRemoved : MergePalette.inlineAdded).setFill(); target.fill() }
                        if icons[style] == nil { icons[style] = icon.image(size: frame.height) }
                        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        if dark, darkIcons[style] == nil, let original = icons[style] {
                            // Classic ICO masks become hard to see on dark
                            // AppKit backgrounds. Preserve the original alpha
                            // silhouette and use the native marker foreground.
                            var foreground = NSColor(calibratedWhite: 0.7, alpha: 1)
                            appearance.performAsCurrentDrawingAppearance {
                                if let resolved = MergePalette.whitespace.usingColorSpace(.sRGB) { foreground = resolved.withAlphaComponent(1) }
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

/// TextKit wrapping with source-style shared row heights across aligned panes.
@MainActor final class MergeLineWrapping {
    private final class Entry {
        weak var scroll: NSScrollView?
        var aligned: Bool
        var enabled: Bool
        var applied: Bool?
        var leadingInset: CGFloat?
        var observers: [NSObjectProtocol] = []
        init(scroll: NSScrollView, aligned: Bool, enabled: Bool) { self.scroll = scroll; self.aligned = aligned; self.enabled = enabled }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
    private var entries: [String: Entry] = [:]
    private var queued = false, applying = false, retired = false
    var geometryChanged: () -> Void = {}
    private(set) var alignedHeights: [CGFloat] = []
    func update(_ scroll: NSScrollView, key: String, aligned: Bool, enabled: Bool) {
        guard !retired else { return }
        if entries[key]?.scroll !== scroll {
            let entry = Entry(scroll: scroll, aligned: aligned, enabled: enabled)
            scroll.contentView.postsFrameChangedNotifications = true
            for (name, object) in [(NSView.frameDidChangeNotification, scroll.contentView as AnyObject), (NSTextStorage.didProcessEditingNotification, (scroll.documentView as? NSTextView)?.textStorage as AnyObject?)] {
                guard let object else { continue }
                entry.observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.schedule() }
                })
            }
            entries[key] = entry
        }
        entries[key]?.aligned = aligned; entries[key]?.enabled = enabled
        schedule()
    }
    private func schedule() {
        guard !retired, !queued, !applying else { return }; queued = true
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.queued = false; self.apply() }
    }
    private func clipInsets(_ scroll: NSScrollView) -> NSEdgeInsets { scroll.contentView.contentInsets }
    private func apply() {
        guard !retired, !applying else { return }; applying = true; defer { applying = false }
        let visible = entries.values.compactMap { entry -> (Entry, NSScrollView, NSTextView)? in
            guard let scroll = entry.scroll, let view = scroll.documentView as? NSTextView, view.window != nil else { return nil }
            return (entry, scroll, view)
        }
        var measured: [(NSTextView, [NSRange], [CGFloat])] = []
        alignedHeights = []
        for (entry, scroll, view) in visible {
            guard let storage = view.textStorage, let layout = view.layoutManager, let container = view.textContainer else { continue }
            let clip = scroll.contentView, insets = clipInsets(scroll)
            let width = clip.bounds.width - insets.left - insets.right; guard width > 32 else { continue }
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
        geometryChanged()
    }
    func retire() { retired = true; entries = [:]; alignedHeights = []; geometryChanged = {} }
}


struct MergeLineStatisticsView: View {
    let statistics: MergeLineStatistics
    private func count(_ title:String,_ value:Int,_ state:MergeSourceState)->some View {
        HStack(spacing:4) {
            Rectangle().fill(Color(nsColor:MergePalette.color(state))).overlay(Rectangle().stroke(.secondary,lineWidth:0.5)).frame(width:8,height:8).accessibilityHidden(true)
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

@MainActor final class MergeBlockSelection {
    private var savedRange: NSRange?
    private var savedText = ""
    private var caret = 0
    func range(in view: NSTextView) -> NSRange? {
        guard let range = savedRange else { return nil }
        guard view.selectedRange() == NSRange(location:caret,length:0),
              savedText.utf8.elementsEqual(view.string.utf8) else { clear(in:view); return nil }
        return range
    }
    func install(_ range: NSRange, caret: Int, in view: NSTextView) {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= view.string.utf16.count,
              caret >= 0, caret <= view.string.utf16.count else { clear(in:view); return }
        savedRange = range; savedText = view.string; self.caret = caret
        view.setSelectedRange(NSRange(location:caret,length:0)); view.needsDisplay = true
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
