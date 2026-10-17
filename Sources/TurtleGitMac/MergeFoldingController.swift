import AppKit
import Combine
import TurtleGitCore

/// One controller belongs to a comparison window, rather than to individual
/// text views. All panes consume the same source-to-screen projection.
@MainActor final class MergeFoldingController: ObservableObject {
    @Published private(set) var collapsed: Bool
    @Published private(set) var projection = MergeFoldProjection(folding: MergeFolding(unchanged: []), collapsed: false)
    private(set) var folding = MergeFolding(unchanged: [])
    private let preferences: UserDefaults
    private var unchanged: [Bool] = []
    private var contextLines: Int
    private var retired = false
    private(set) var revision = 0
    var geometryChanged: () -> Void = {}
    var expanded: ([Range<Int>]) -> Void = { _ in }
    var actionsAllowed: () -> Bool = { true }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        let settings = MergeFoldingPreferences.load(from: preferences)
        collapsed = settings.collapsed; contextLines = settings.contextLines
    }

    /// A changed alignment starts a fresh source hide map, as upstream Reload
    /// does. Identical hosting updates preserve manually expanded sections.
    func update(unchanged: [Bool], force: Bool = false) {
        guard !retired else { return }
        let context = MergeFoldingPreferences.load(from: preferences).contextLines
        guard force || self.unchanged != unchanged || context != contextLines else { return }
        self.unchanged = unchanged; contextLines = context
        folding = MergeFolding(unchanged: unchanged, contextLines: context)
        refresh()
    }

    func setCollapsed(_ value: Bool) {
        guard !retired, actionsAllowed(), value != collapsed else { return }
        collapsed = value
        MergeFoldingPreferences(collapsed: value, contextLines: contextLines).saveCollapsed(to: preferences)
        refresh()
    }
    @discardableResult func expand(screenRow: Int) -> Bool {
        guard !retired, actionsAllowed(), collapsed, projection.rows.indices.contains(screenRow),
              case .marker(let range) = projection.rows[screenRow], let expandedRange = folding.expand(marker: range.lowerBound) else { return false }
        refresh(); expanded([expandedRange]); return true
    }
    @discardableResult func reveal(sourceRow: Int) -> Bool {
        reveal(sourceRows: [sourceRow])
    }
    @discardableResult func reveal(sourceRows: [Int]) -> Bool {
        guard !retired, actionsAllowed(), collapsed else { return false }
        let ranges = folding.reveal(rows: sourceRows)
        guard !ranges.isEmpty else { return false }
        refresh(); expanded(ranges); return true
    }
    func install(visibility: [MergeFolding.Visibility]) {
        guard !retired, folding.visibility != visibility else { return }
        folding = MergeFolding(visibility: visibility); refresh()
    }
    func retire() { retired = true; geometryChanged = {}; expanded = { _ in }; actionsAllowed = { false } }
    private func refresh() {
        revision &+= 1
        projection = MergeFoldProjection(folding: folding, collapsed: collapsed)
        geometryChanged()
    }

    /// Creates display rows only; original cells remain owned by the document.
    /// Consumers must map actions through projection before touching source data.
    func displayCells(_ cells: [MergeSourceCell]) -> [MergeSourceCell] {
        guard collapsed, cells.count == folding.visibility.count else { return cells }
        return projection.rows.map { row in
            switch row {
            case .source(let index): return cells[index]
            case .marker: return MergeSourceCell(text: "{...}", lineNumber: nil, state: .empty)
            }
        }
    }
}

extension NSAttributedString.Key {
    static let mergeFoldHidden = NSAttributedString.Key("TurtleGit.MergeFoldHidden")
    static let mergeFoldMarker = NSAttributedString.Key("TurtleGit.MergeFoldMarker")
}

/// Keep the complete attributed document and all UTF-16 source coordinates.
/// Hidden paragraphs occupy a subpixel height; markers draw over their original
/// paragraph. No display placeholder can be inserted into edits or clipboard.
@MainActor final class MergeFoldTextLayout {
    weak var controller: MergeFoldingController?
    private var ranges: [NSRange] = []
    private var states: [MergeFolding.Visibility] = []
    private var originals: [(NSRange, [NSAttributedString.Key: Any])] = []
    func prepare(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        storage.beginEditing(); defer { storage.endEditing() }
        for (range, attributes) in originals where NSMaxRange(range) <= storage.length && range.length > 0 {
            if storage.attribute(.mergeFoldHidden, at: range.location, effectiveRange: nil) != nil || storage.attribute(.mergeFoldMarker, at: range.location, effectiveRange: nil) != nil {
                storage.setAttributes(attributes, range: range)
            }
        }
        originals = []
    }
    func apply(to view: NSTextView, controller: MergeFoldingController) {
        self.controller = controller
        guard let storage = view.textStorage else { return }
        // Observers must see a complete fold map, never restored/half-hidden rows.
        storage.beginEditing(); defer { storage.endEditing() }
        prepare(view)
        ranges = MergeLineEndings.lineRanges(in: view.string)
        states = controller.collapsed && ranges.count == controller.folding.visibility.count ? controller.folding.visibility : Array(repeating: .shown, count: ranges.count)
        let whole = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.mergeFoldHidden, range: whole)
        storage.removeAttribute(.mergeFoldMarker, range: whole)
        view.setAccessibilityCustomActions(controller.collapsed ? [NSAccessibilityCustomAction(name: "Expand unchanged section", handler: { [weak self, weak view] in
            guard let self, let view else { return false }; return self.expandSelection(in: view)
        })] : [])
        for (row, range) in ranges.enumerated() where states[row] != .shown {
            guard range.length > 0 else { continue }
            storage.enumerateAttributes(in: range) { attributes, run, _ in originals.append((run, attributes)) }
            let paragraph = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 0
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            if states[row] == .hidden {
                paragraph.minimumLineHeight = 0.01; paragraph.maximumLineHeight = 0.01
                storage.addAttributes([.mergeFoldHidden: true, .font: NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular)], range: range)
            } else {
                let height = view.layoutManager?.defaultLineHeight(for: view.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)) ?? 18
                paragraph.minimumLineHeight = height; paragraph.maximumLineHeight = height
                storage.addAttribute(.mergeFoldMarker, value: true, range: range)
            }
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
    }
    func draw(in view: NSTextView, dirtyRect: NSRect) {
        guard let layout = view.layoutManager, let container = view.textContainer else { return }
        for (row, range) in ranges.enumerated() where states[row] == .marker && range.length > 0 {
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            var rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect.origin.x += view.textContainerOrigin.x; rect.origin.y += view.textContainerOrigin.y
            guard rect.intersects(dirtyRect) else { continue }
            rect.size.width = max(rect.width, view.visibleRect.width)
            NSColor.textBackgroundColor.setFill(); rect.fill()
            let text = "{...}" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: view.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
            let size = text.size(withAttributes: attributes)
            let center = view.visibleRect.midX
            NSColor.separatorColor.setFill()
            NSRect(x: view.visibleRect.minX, y: rect.midY, width: max(0, center - size.width / 2 - view.visibleRect.minX - 6), height: 1).fill()
            NSRect(x: center + size.width / 2 + 6, y: rect.midY, width: max(0, view.visibleRect.maxX - center - size.width / 2 - 6), height: 1).fill()
            text.draw(at: NSPoint(x: center - size.width / 2, y: rect.minY), withAttributes: attributes)
        }
        _ = container
    }
    func canExpandSelection(in view: NSTextView) -> Bool {
        guard let controller, controller.collapsed, controller.actionsAllowed(),
              let row = ranges.firstIndex(where: { NSLocationInRange(view.selectedRange().location, $0) }) else { return false }
        return states[row] != .shown
    }
    @discardableResult func expandSelection(in view: NSTextView) -> Bool {
        guard canExpandSelection(in: view) else { return false }
        reveal(selection: view.selectedRange(), in: view, includeMarker: true)
        return true
    }
    func expand(at event: NSEvent, in view: NSTextView) -> Bool {
        guard event.clickCount == 2, let controller, controller.collapsed,
              let layout = view.layoutManager, let container = view.textContainer else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        let location = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
        let character = layout.characterIndex(for: location, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard let row = ranges.firstIndex(where: { NSLocationInRange(character, $0) }), states[row] == .marker,
              let screen = controller.projection.screenRow(containing: row) else { return false }
        return controller.expand(screenRow: screen)
    }
    func reveal(selection: NSRange, in view: NSTextView? = nil, includeMarker: Bool = false) {
        guard let controller, controller.collapsed, selection.location >= 0, selection.location != NSNotFound, selection.length >= 0 else { return }
        let (end, overflow) = selection.location.addingReportingOverflow(selection.length)
        guard !overflow else { return }
        let rows = ranges.enumerated().compactMap { row, range -> Int? in
            range.location <= end && NSMaxRange(range) >= selection.location && (states[row] == .hidden || selection.length > 0 || includeMarker) ? row : nil
        }
        if controller.reveal(sourceRows: rows), let view {
            apply(to: view, controller: controller)
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            view.needsDisplay = true
        }
    }
}
