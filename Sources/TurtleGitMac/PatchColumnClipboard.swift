// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum PatchColumnClipboard {
    static let rectangularType = NSPasteboard.PasteboardType("org.turtlegit.column-selection")
    static let rectangularMarker = Data([1])
    @discardableResult static func write(text: String, rectangular: Bool, to board: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        if rectangular, !item.setData(rectangularMarker, forType: rectangularType) { return false }
        board.clearContents(); return board.writeObjects([item])
    }
    static func isRectangular(_ board: NSPasteboard) -> Bool { board.data(forType: rectangularType) == rectangularMarker }
}

/// Measure a column paste on captured native typography after selection deletion.
/// This is a private, unattached TextKit layout, never a desktop window and never
/// a UTF-16-column approximation of tabs or proportional-font screen positions.
@MainActor enum PatchRectanglePasteGeometry {
    struct Result { let insertions: [PatchRectanglePasteInsertion]; let caret: Int }
    @MainActor private final class Scratch {
        let storage: NSTextStorage
        let layout: NSLayoutManager
        let container: NSTextContainer
        let text: NSTextView
        init(_ value: NSAttributedString, source: NSTextView) {
            storage = NSTextStorage(attributedString: value); layout = NSLayoutManager()
            container = NSTextContainer(containerSize: source.textContainer?.containerSize ?? NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = source.textContainer?.lineFragmentPadding ?? 5
            storage.addLayoutManager(layout); layout.addTextContainer(container)
            text = NSTextView(frame: source.frame, textContainer: container)
            text.textContainerInset = source.textContainerInset
            text.typingAttributes = source.typingAttributes
        }
    }
    private static func clearedValue(source: NSTextView, plan: PatchLineEditPlan) -> NSMutableAttributedString? {
        let attributes = source.attributedString(), value = NSMutableAttributedString(string: "")
        for segment in plan.segments {
            switch segment {
            case let .source(range):
                guard range.location >= 0, range.length >= 0, range.location <= attributes.length, range.length <= attributes.length - range.location else { return nil }
                value.append(attributes.attributedSubstring(from: range))
            case let .inserted(text): value.append(NSAttributedString(string: text, attributes: source.typingAttributes))
            }
        }
        return value
    }
    private static func caret(for plan: PatchLineEditPlan, geometry: PatchColumnTextGeometry) -> Int? {
        guard plan.rectangular else { return plan.selectionCaret }
        let anchor = plan.rectangleAnchor ?? plan.selections.first?.anchor ?? plan.selectionAnchor
        let caret = plan.rectangleCaret ?? plan.selectionCaret
        guard let a = geometry.point(atUTF16: anchor), let c = geometry.point(atUTF16: caret),
              let first = geometry.index.lineIndex(atUTF16Offset: anchor), let last = geometry.index.lineIndex(atUTF16Offset: caret),
              let left = geometry.offset(onLine: min(first, last), atX: a.x),
              let right = geometry.offset(onLine: min(first, last), atX: plan.rectangleIsThin ? a.x : c.x) else { return nil }
        return min(left, right)
    }
    static func insertionPoint(source: NSTextView, cleared: PatchLineEditPlan) -> Int? {
        guard let value = clearedValue(source: source, plan: cleared) else { return nil }
        let clone = Scratch(value, source: source)
        return caret(for: cleared, geometry: PatchColumnTextGeometry(text: clone.text))
    }
    static func measure(source: NSTextView, cleared: PatchLineEditPlan, clipboard: String) -> Result? {
        let rows = PatchLineEditing.rectanglePasteRows(clipboard)
        guard !rows.isEmpty, rows.count <= 100_000, let value = clearedValue(source: source, plan: cleared) else { return nil }
        let originalCount = value.length, originalIndex = PatchLineIndex(text: value.string)
        let anchorLine = originalIndex.lineIndex(atUTF16Offset: cleared.rectangleAnchor ?? cleared.selectionAnchor)
        let caretLine = originalIndex.lineIndex(atUTF16Offset: cleared.rectangleCaret ?? cleared.selectionCaret)
        guard let a = anchorLine, let c = caretLine else { return nil }
        let firstLine = cleared.rectangular ? min(a, c) : c
        let appended = max(0, firstLine + rows.count - originalIndex.lineCount)
        if appended > 0 { value.append(NSAttributedString(string: String(repeating: "\n", count: appended), attributes: source.typingAttributes)) }
        let clone = Scratch(value, source: source), geometry = PatchColumnTextGeometry(text: clone.text)
        guard let caret = caret(for: cleared, geometry: geometry), let insertion = geometry.point(atUTF16: caret) else { return nil }
        var entries: [PatchRectanglePasteInsertion] = [], paddingWork = 0
        for (row, fragment) in rows.enumerated() {
            let line = firstLine + row
            guard let offset = geometry.offset(onLine: line, atX: insertion.x), let lineRange = geometry.index.range(forLine: line),
                  let at = geometry.point(atUTF16: offset) else { return nil }
            var padding = ""
            if row > 0, at.x < insertion.x {
                let lineValue = value.attributedSubstring(from: lineRange)
                let padded = Scratch(lineValue, source: source)
                let relative = offset - lineRange.location
                var width = at.x
                while width < insertion.x {
                    guard paddingWork < 1_000_000 else { return nil }
                    let location = relative + padding.utf16.count
                    let insertionAttributes = padded.storage.length > 0 ? padded.storage.attributes(at: min(max(0, location - 1), padded.storage.length - 1), effectiveRange: nil) : source.typingAttributes
                    let font = insertionAttributes[.font] as? NSFont
                    let advance = (" " as NSString).size(withAttributes: [.font: font ?? source.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width
                    guard advance > 0, advance.isFinite else { return nil }
                    let batch = min(8192, max(1, Int((insertion.x - width) / advance) - 1))
                    let spaces = String(repeating: " ", count: min(batch, 1_000_000 - paddingWork))
                    padded.storage.insert(NSAttributedString(string: spaces, attributes: insertionAttributes), at: relative + padding.utf16.count)
                    padding += spaces; paddingWork += spaces.utf16.count
                    let updated = PatchColumnTextGeometry(text: padded.text)
                    guard let next = updated.point(atUTF16: relative + padding.utf16.count), next.x > width else { return nil }
                    width = next.x
                }
            }
            let prefix = (line >= originalIndex.lineCount ? "\n" : "") + padding
            entries.append(.init(offset: min(offset, originalCount), prefix: prefix, text: fragment))
        }
        return .init(insertions: entries, caret: caret)
    }
}
