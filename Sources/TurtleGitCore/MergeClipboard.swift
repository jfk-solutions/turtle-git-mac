import Foundation

/// Native LF adaptation of CBaseView::GetSelectedText/OnEditCopy. Clipboard
/// payloads include removed/conflict rows, unlike editable source projections.
public enum MergeClipboard {
    public static func sourceText(selection: NSRange, cells: [MergeSourceCell], blockRows: Range<Int>? = nil) throws -> String {
        if selection.length > 0 { return try MergeSourceComparison.clipboardText(selection, cells: cells) }
        _ = try MergeSourceComparison.clipboardText(selection, cells: cells) // validate caret
        guard let rows = blockRows, !rows.isEmpty else { return "" }
        guard rows.lowerBound >= 0, rows.upperBound <= cells.count else { throw FileComparisonEditFailure.range }
        return cells[rows].filter { $0.state != .empty }.map(\.displayText).joined(separator: "\n")
    }
    /// A caret inside a changed aligned row selects that contiguous block.
    /// A normal row does not implicitly select an unrelated nearby change.
    public static func changedBlock(selection: NSRange, cells: [MergeSourceCell]) -> Range<Int>? {
        guard selection.length == 0, selection.location >= 0 else { return nil }
        var cursor = 0
        for (row, cell) in cells.enumerated() {
            cursor += (cell.displayText as NSString).length + 1
            guard selection.location < cursor else { continue }
            guard cell.state != .normal else { return nil }
            var lower = row, upper = row + 1
            while lower > 0, cells[lower - 1].state != .normal { lower -= 1 }
            while upper < cells.count, cells[upper].state != .normal { upper += 1 }
            return lower..<upper
        }
        return nil
    }
    public static func documentText(selection: NSRange, document: String, block: NSRange? = nil) throws -> String {
        let text = document as NSString
        guard selection.location >= 0, selection.length >= 0, selection.location <= text.length,
              selection.length <= text.length - selection.location else { throw FileComparisonEditFailure.range }
        let selected = selection.length > 0 ? selection : block ?? selection
        guard selected.location >= 0, selected.length >= 0, selected.location <= text.length,
              selected.length <= text.length - selected.location else { throw FileComparisonEditFailure.range }
        var value = text.substring(with: selected)
        if selection.length == 0 { value = MergeLineEndings.droppingFinalEnding(value) }
        return MergeLineEndings.converting(value, to: .lf)
    }
    public static func pastedText(_ text: String, document: String) -> String {
        MergeLineEndings.converting(text, to: MergeLineEndings.predominantStyle(in: document))
    }
}
