// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

struct PatchColumnRectangle: Equatable {
    let anchorLine: Int, caretLine: Int
    let anchorX: CGFloat, caretX: CGFloat
}
struct PatchTextSelectionSnapshot: Equatable {
    let rows: [PatchLineEditSelection]
    let primarySelectionID: Int
    let rectangular: Bool
    var rectangle: PatchColumnRectangle?
    var rectangleAnchor: Int?
    var rectangleCaret: Int?
    var rectangleIsThin = false
    // Source case edits retain per-row lengths; deletion retains one row
    // without clearing rectangle mode. Do not rebuild these accepted ranges.
    var rectangleRowsExplicit = false
    var primary: PatchLineEditSelection { rows.first { $0.id == primarySelectionID } ?? rows[0] }
    var ranges: [NSRange] { rows.map(\.range) }
}
enum PatchColumnDirection: String, CaseIterable {
    case left, right, up, down, home, end, pageUp, pageDown
    var title: String {
        switch self {
        case .left: return "Extend Column Selection Left"
        case .right: return "Extend Column Selection Right"
        case .up: return "Extend Column Selection Up"
        case .down: return "Extend Column Selection Down"
        case .home: return "Extend Column Selection to Line Start"
        case .end: return "Extend Column Selection to Line End"
        case .pageUp: return "Extend Column Selection Page Up"
        case .pageDown: return "Extend Column Selection Page Down"
        }
    }
    var icon: MenuIcon {
        switch self {
        case .left: return .mergePreviousInline; case .right: return .mergeNextInline
        case .up, .pageUp: return .mergePreviousDifference; case .down, .pageDown: return .mergeNextDifference
        case .home: return .mergePreviousInline; case .end: return .mergeNextInline
        }
    }
    static func direction(for event: NSEvent) -> Self? {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .option, .shift] else { return nil }
        return [123: Self.left, 124: .right, 125: .down, 126: .up, 115: .home, 119: .end, 116: .pageUp, 121: .pageDown][Int(event.keyCode)]
    }
}

@MainActor final class PatchColumnTextGeometry {
    private weak var text: NSTextView?
    let index: PatchLineIndex
    init(text: NSTextView, index: PatchLineIndex? = nil) {
        self.text = text; self.index = index ?? PatchLineIndex(text: text.string)
    }
    func contentRange(_ line: Int) -> NSRange? {
        guard let text, let full = index.range(forLine: line) else { return nil }
        let value = text.string as NSString
        var end = NSMaxRange(full)
        while end > full.location, value.character(at: end - 1) == 10 || value.character(at: end - 1) == 13 { end -= 1 }
        return NSRange(location: full.location, length: end - full.location)
    }
    func point(atUTF16 offset: Int) -> NSPoint? {
        guard let text, let layout = text.layoutManager, let container = text.textContainer, offset >= 0, offset <= text.string.utf16.count else { return nil }
        layout.ensureLayout(for: container)
        let origin = text.textContainerOrigin
        if offset == text.string.utf16.count, (offset == 0 || index.lineStarts.last == offset) {
            return NSPoint(x: origin.x + layout.extraLineFragmentRect.minX, y: origin.y + layout.extraLineFragmentRect.midY)
        }
        let probe = min(offset, max(0, text.string.utf16.count - 1))
        let count = layout.getLineFragmentInsertionPoints(forCharacterAt: probe, alternatePositions: false, inDisplayOrder: false, positions: nil, characterIndexes: nil)
        var positions = [CGFloat](repeating: 0, count: count), indexes = [Int](repeating: 0, count: count)
        let actual = layout.getLineFragmentInsertionPoints(forCharacterAt: probe, alternatePositions: false, inDisplayOrder: false, positions: &positions, characterIndexes: &indexes)
        let glyph = layout.glyphIndexForCharacter(at: probe)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        if let at = indexes.prefix(actual).firstIndex(of: offset) { return NSPoint(x: origin.x + fragment.minX + positions[at], y: origin.y + fragment.midY) }
        let location = layout.location(forGlyphAt: glyph)
        return NSPoint(x: origin.x + fragment.minX + location.x, y: origin.y + fragment.midY)
    }
    func offset(onLine line: Int, atX x: CGFloat) -> Int? {
        guard let text, x.isFinite, let range = contentRange(line), let layout = text.layoutManager,
              let container = text.textContainer else { return nil }
        if range.length == 0 { return range.location }
        layout.ensureLayout(for: container)
        let count = layout.getLineFragmentInsertionPoints(forCharacterAt: range.location, alternatePositions: false, inDisplayOrder: true, positions: nil, characterIndexes: nil)
        var positions = [CGFloat](repeating: 0, count: count), indexes = [Int](repeating: 0, count: count)
        let actual = layout.getLineFragmentInsertionPoints(forCharacterAt: range.location, alternatePositions: false, inDisplayOrder: true, positions: &positions, characterIndexes: &indexes)
        guard actual <= count else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: range.location)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var best: (offset: Int, x: CGFloat, distance: CGFloat)?
        for at in 0..<actual where indexes[at] >= range.location && indexes[at] <= NSMaxRange(range) {
            let position = positions[at] + fragment.minX + text.textContainerOrigin.x, distance = abs(position - x)
            if best == nil || distance < best!.distance || (distance == best!.distance && position > best!.x) {
                best = (indexes[at], position, distance)
            }
        }
        return best?.offset ?? range.location
    }
 }

/// Public TextKit insertion points provide the column geometry, including tab
/// expansion, ligatures and proportional fonts. No virtual-space padding is
/// introduced while selecting: Scintilla's default is VirtualSpace::None.
@MainActor final class PatchColumnSelectionController {
    private weak var text: PatchTextView.PatchText?
    private var cached: PatchTextSelectionSnapshot?
    private weak var cachedModel: PatchWindowModel?
    private var documentRevision = -1
    private var applying = false
    private var keyboardX: CGFloat?
    private var observing: NSObjectProtocol?
    private var initial: PatchTextSelectionSnapshot?
    private var dragPoint: NSPoint = .zero
    private var dragRevision: UUID?
    private var dragDocumentRevision = -1
    private var selectionGeneration = 0
    private var dragGeneration = -1
    private(set) var isSelecting = false
    init(text: PatchTextView.PatchText) {
        self.text = text
        if let storage = text.textStorage {
            observing = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
                    self?.externalSelectionChanged()
                }
            }
        }
    }
    deinit { if let observing { NotificationCenter.default.removeObserver(observing) } }
    func retire() {
        isSelecting = false; initial = nil; cached = nil; cachedModel = nil
        if let observing { NotificationCenter.default.removeObserver(observing) }; observing = nil
        text = nil
    }
    private var sourceAvailable: Bool {
        guard let text, let coordinator = text.coordinator, let window = text.window,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !text.hasMarkedText(), coordinator.model.canFind, coordinator.model.error == nil,
              coordinator.model.sourceOwnerID == coordinator.identity, coordinator.model.sourceAttached() else { return false }
        return true
    }
    var available: Bool { sourceAvailable && text?.window?.firstResponder === text }
    func externalSelectionChanged() {
        guard !applying else { return }
        cached = nil; cachedModel = nil; isSelecting = false; initial = nil; keyboardX = nil; selectionGeneration &+= 1
    }
    func snapshot() -> PatchTextSelectionSnapshot {
        guard let text else { return .init(rows: [.init(id: 0, anchor: 0, caret: 0)], primarySelectionID: 0, rectangular: false) }
        if let cached, cachedModel === text.coordinator?.model, documentRevision == text.coordinator?.model.documentResetRevision { return cached }
        let ranges = text.selectedRanges.map(\.rangeValue)
        let reverse = text.selectionAffinity == .upstream
        let rows = (ranges.isEmpty ? [text.selectedRange()] : ranges).enumerated().map {
            PatchLineEditSelection(id: $0.offset, anchor: reverse ? NSMaxRange($0.element) : $0.element.location,
                                   caret: reverse ? $0.element.location : NSMaxRange($0.element))
        }
        return .init(rows: rows, primarySelectionID: rows[0].id, rectangular: false)
    }
    func collapseToPrimary() {
        let state = snapshot()
        _ = applySnapshot(.init(rows: [state.primary], primarySelectionID: state.primarySelectionID, rectangular: false))
    }
    @discardableResult func applySnapshot(_ requested: PatchTextSelectionSnapshot, stillSelecting: Bool = false) -> Bool {
        var state = requested
        if state.rectangular, !state.rectangleRowsExplicit, let anchor = state.rectangleAnchor, let caret = state.rectangleCaret,
           let rebuilt = snapshotForRectangle(anchor: anchor, caret: caret, primarySelectionID: state.primarySelectionID, previousRows: state.rows, thin: state.rectangleIsThin) { state = rebuilt; state.rectangleIsThin = requested.rectangleIsThin }
        guard let text, let model = text.coordinator?.model, !model.retired, !state.rows.isEmpty,
              state.rows.contains(where: { $0.id == state.primarySelectionID }),
              Set(state.rows.map(\.id)).count == state.rows.count else { return false }
        let count = text.string.utf16.count
        guard state.rows.allSatisfy({ $0.anchor >= 0 && $0.caret >= 0 && $0.anchor <= count && $0.caret <= count }) else { return false }
        applying = true; defer { applying = false }
        keyboardX = nil
        cached = state; cachedModel = model; documentRevision = model.documentResetRevision
        let ordered = [state.primary] + state.rows.filter { $0.id != state.primarySelectionID }
        text.setSelectedRanges(ordered.map { NSValue(range: $0.range) }, affinity: state.primary.isReversed ? .upstream : .downstream, stillSelecting: stillSelecting)
        return true
    }
    private var index: PatchLineIndex { (text?.enclosingScrollView as? PatchScrollView)?.lineNumberGutter?.lineIndex ?? PatchLineIndex(text: text?.string ?? "") }
    func point(atUTF16 offset: Int) -> NSPoint? {
        guard let text else { return nil }
        return PatchColumnTextGeometry(text: text, index: index).point(atUTF16: offset)
    }
    func offset(onLine line: Int, atX x: CGFloat) -> Int? {
        guard let text else { return nil }
        return PatchColumnTextGeometry(text: text, index: index).offset(onLine: line, atX: x)
    }
    private func corner(at point: NSPoint) -> (line: Int, offset: Int, point: NSPoint)? {
        guard let text, point.x.isFinite, point.y.isFinite, let layout = text.layoutManager, let container = text.textContainer else { return nil }
        layout.ensureLayout(for: container)
        let local = NSPoint(x: point.x - text.textContainerOrigin.x, y: point.y - text.textContainerOrigin.y)
        let position: Int
        if local.y < 0 { position = 0 }
        else if local.y >= layout.usedRect(for: container).maxY { position = text.string.utf16.count }
        else { position = min(text.string.utf16.count, layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)) }
        guard let line = index.lineIndex(atUTF16Offset: position), let offset = offset(onLine: line, atX: point.x), let actual = self.point(atUTF16: offset) else { return nil }
        return (line, offset, actual)
    }
    private func rectangleSnapshot(_ rectangle: PatchColumnRectangle) -> PatchTextSelectionSnapshot? {
        let step = rectangle.caretLine >= rectangle.anchorLine ? 1 : -1
        var rows: [PatchLineEditSelection] = []
        for line in stride(from: rectangle.anchorLine, through: rectangle.caretLine, by: step) {
            guard let anchor = offset(onLine: line, atX: rectangle.anchorX), let caret = offset(onLine: line, atX: rectangle.caretX) else { return nil }
            rows.append(.init(id: rows.count, anchor: anchor, caret: caret))
        }
        return .init(rows: rows, primarySelectionID: rows.last!.id, rectangular: true, rectangle: rectangle)
    }
    private func rectangle(for state: PatchTextSelectionSnapshot) -> PatchColumnRectangle? {
        // Recompute pixel X from retained offsets after font/style changes.
        guard let first = state.rows.first, let anchorLine = index.lineIndex(atUTF16Offset: first.anchor),
              let caretLine = index.lineIndex(atUTF16Offset: state.primary.caret),
              let anchor = point(atUTF16: first.anchor), let caret = point(atUTF16: state.primary.caret) else { return nil }
        return .init(anchorLine: anchorLine, caretLine: caretLine, anchorX: anchor.x, caretX: state.rectangleIsThin ? anchor.x : caret.x)
    }
    func snapshotForRectangle(anchor: Int, caret: Int, primarySelectionID: Int,
                              previousRows: [PatchLineEditSelection] = [], thin: Bool = false) -> PatchTextSelectionSnapshot? {
        guard let first = index.lineIndex(atUTF16Offset: anchor), let last = index.lineIndex(atUTF16Offset: caret),
              let a = point(atUTF16: anchor), let c = point(atUTF16: caret),
              let rebuilt = rectangleSnapshot(.init(anchorLine: first, caretLine: last, anchorX: a.x, caretX: thin ? a.x : c.x)) else { return nil }
        var byLine: [Int: [PatchLineEditSelection]] = [:]
        for row in previousRows { if let line = index.lineIndex(atUTF16Offset: row.caret) { byLine[line, default: []].append(row) } }
        var used: Set<Int> = [primarySelectionID]
        var nextID = max(0, (previousRows.map(\.id).max() ?? -1) + 1)
        let rows = rebuilt.rows.enumerated().map { position, row -> PatchLineEditSelection in
            if position == rebuilt.rows.count - 1 { return .init(id: primarySelectionID, anchor: row.anchor, caret: row.caret) }
            let line = index.lineIndex(atUTF16Offset: row.caret)!
            let id: Int
            if let retained = byLine[line]?.first(where: { !used.contains($0.id) }) { id = retained.id }
            else {
                while used.contains(nextID) { nextID += 1 }
                id = nextID; nextID += 1
            }
            used.insert(id)
            return .init(id: id, anchor: row.anchor, caret: row.caret)
        }
        return .init(rows: rows, primarySelectionID: primarySelectionID, rectangular: true, rectangle: rebuilt.rectangle, rectangleIsThin: thin)
    }
    @discardableResult func beginRectangle(at point: NSPoint, extending: Bool = false) -> Bool {
        guard available, let text, let corner = corner(at: point) else { return false }
        let before = snapshot()
        let previous = extending ? rectangle(for: before) : nil
        let shape = PatchColumnRectangle(anchorLine: previous?.anchorLine ?? corner.line, caretLine: corner.line,
                                         anchorX: previous?.anchorX ?? corner.point.x, caretX: corner.point.x)
        guard let selection = rectangleSnapshot(shape) else { return false }
        initial = before; isSelecting = true; dragPoint = point; dragGeneration = selectionGeneration
        dragRevision = text.coordinator?.model.sourceCallbackRevision; dragDocumentRevision = text.coordinator?.model.documentResetRevision ?? -1
        return applySnapshot(selection, stillSelecting: true)
    }
    @discardableResult func continueRectangle(at point: NSPoint) -> Bool {
        guard dragCurrent, let shape = rectangle(for: snapshot()), let corner = corner(at: point),
              let state = rectangleSnapshot(.init(anchorLine: shape.anchorLine, caretLine: corner.line, anchorX: shape.anchorX, caretX: corner.point.x)) else { endRectangle(); return false }
        dragPoint = point
        return applySnapshot(state, stillSelecting: true)
    }
    private var dragCurrent: Bool {
        guard isSelecting, available, let text, text.coordinator?.model.sourceCallbackRevision == dragRevision,
              text.coordinator?.model.documentResetRevision == dragDocumentRevision else { return false }
        return selectionGeneration == dragGeneration
    }
    func endRectangle() {
        let state = snapshot(); isSelecting = false; initial = nil
        if available { _ = applySnapshot(state) }
    }
    func cancelRectangle() {
        let before = initial, current = dragCurrent
        isSelecting = false; initial = nil
        if current, let before { _ = applySnapshot(before) }
    }
    @discardableResult func extendRectangle(direction: PatchColumnDirection) -> Bool {
        guard available, let text, var shape = rectangle(for: snapshot()) else { return false }
        let primary = snapshot().primary
        let desiredX = keyboardX ?? shape.caretX
        switch direction {
        case .up: shape = .init(anchorLine: shape.anchorLine, caretLine: max(0, shape.caretLine - 1), anchorX: shape.anchorX, caretX: desiredX)
        case .down: shape = .init(anchorLine: shape.anchorLine, caretLine: min(index.lineCount - 1, shape.caretLine + 1), anchorX: shape.anchorX, caretX: desiredX)
        case .pageUp, .pageDown:
            let height = text.layoutManager?.defaultLineHeight(for: text.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)) ?? 16
            let distance = max(1, Int(text.visibleRect.height / max(1, height)) - 1)
            let line = min(index.lineCount - 1, max(0, shape.caretLine + (direction == .pageUp ? -distance : distance)))
            shape = .init(anchorLine: shape.anchorLine, caretLine: line, anchorX: shape.anchorX, caretX: desiredX)
        case .home, .end:
            let geometry = PatchColumnTextGeometry(text: text, index: index)
            guard let range = geometry.contentRange(shape.caretLine) else { return false }
            var target = NSMaxRange(range)
            if direction == .home {
                let value = text.string as NSString
                target = range.location
                while target < NSMaxRange(range), value.character(at: target) == 9 || value.character(at: target) == 32 { target += 1 }
                if target == primary.caret { target = range.location }
            }
            guard let point = point(atUTF16: target) else { return false }
            shape = .init(anchorLine: shape.anchorLine, caretLine: shape.caretLine, anchorX: shape.anchorX, caretX: point.x)
        case .left, .right:
            let value = text.string as NSString
            let next: Int
            if direction == .left { next = primary.caret > 0 ? value.rangeOfComposedCharacterSequence(at: primary.caret - 1).location : 0 }
            else { next = primary.caret < value.length ? NSMaxRange(value.rangeOfComposedCharacterSequence(at: primary.caret)) : value.length }
            guard let line = index.lineIndex(atUTF16Offset: next), let point = point(atUTF16: next) else { return false }
            shape = .init(anchorLine: shape.anchorLine, caretLine: line, anchorX: shape.anchorX, caretX: point.x)
        }
        guard let offset = offset(onLine: shape.caretLine, atX: shape.caretX), let actual = point(atUTF16: offset),
              let state = rectangleSnapshot(.init(anchorLine: shape.anchorLine, caretLine: shape.caretLine, anchorX: shape.anchorX, caretX: actual.x)) else { return false }
        _ = applySnapshot(state)
        if [.up, .down, .pageUp, .pageDown].contains(direction) { keyboardX = desiredX }
        text.scrollRangeToVisible(state.primary.range)
        return true
    }
    func autoscrollRectangle() {
        guard dragCurrent, let text, let scroll = text.enclosingScrollView else { return }
        let point = scroll.contentView.convert(dragPoint, from: text), viewport = scroll.contentView.bounds
        let line = text.layoutManager?.defaultLineHeight(for: text.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)) ?? 16
        let dy: CGFloat = point.y < viewport.minY ? -line : point.y > viewport.maxY ? line : 0
        let dx: CGFloat = point.x < viewport.minX ? -line : point.x > viewport.maxX ? line : 0
        if dx != 0 || dy != 0 {
            let windowPoint = text.convert(dragPoint, to: nil)
            scroll.contentView.scroll(to: .init(x: min(max(0, viewport.minX + dx), max(0, text.bounds.width - viewport.width)),
                                               y: min(max(0, viewport.minY + dy), max(0, text.bounds.height - viewport.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            dragPoint = text.convert(windowPoint, from: nil)
            _ = continueRectangle(at: dragPoint)
        }
    }
    @discardableResult func mouseDown(with event: NSEvent) -> Bool {
        guard let text, let window = text.window, event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command), !text.hasMarkedText() else { return false }
        guard sourceAvailable else { return true }
        window.makeFirstResponder(text)
        guard beginRectangle(at: text.convert(event.locationInWindow, from: nil), extending: event.modifierFlags.contains(.shift)) else { return true }
        while isSelecting && dragCurrent {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: Date(timeIntervalSinceNow: 0.05), inMode: .eventTracking, dequeue: true) else { autoscrollRectangle(); continue }
            if next.window !== window { NSApp.postEvent(next, atStart: true); endRectangle(); break }
            if next.type == .leftMouseUp { _ = continueRectangle(at: text.convert(next.locationInWindow, from: nil)); endRectangle() }
            else if next.type == .keyDown { if next.keyCode == 53 { cancelRectangle() } }
            else { _ = continueRectangle(at: text.convert(next.locationInWindow, from: nil)); autoscrollRectangle() }
        }
        if isSelecting { endRectangle() }
        return true
    }
}
