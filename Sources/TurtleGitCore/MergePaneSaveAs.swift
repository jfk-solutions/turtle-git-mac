import Foundation

/// Ports CBaseView::SaveFile's view-row selection. Display gaps are not file
/// content; removed rows are retained only for the left pane's Save As command.
public enum MergePaneSaveAs {
    public static func sourceText(rows: [MergeSourceRow], mine: Bool, keepRemoved: Bool) -> String {
        func chosen(_ index: Int) -> MergeSourceCell { mine ? rows[index].mine : rows[index].theirs }
        func realConflict(_ cell: MergeSourceCell) -> Bool { cell.state == .conflicted && cell.lineNumber != nil }
        var output = "", index = 0
        while index < rows.count {
            let cell = chosen(index)
            if realConflict(cell) {
                var end = index + 1
                while end < rows.count && realConflict(chosen(end)) { end += 1 }
                // The pinned source adds these marker lines with NoEnding.
                // Keep their literal serialization rather than inserting an
                // unrequested Base section or normalizing source line endings.
                output += "<<<<<<< .mine"
                for row in rows[index..<end] { output += row.mine.text }
                output += "======="
                for row in rows[index..<end] { output += row.theirs.text }
                output += ">>>>>>> .theirs"
                index = end; continue
            }
            if cell.state != .empty && (keepRemoved || !cell.state.isExcludedFromResult) { output += cell.text }
            index += 1
        }
        return output
    }
    public static func sourceBytes(rows: [MergeSourceRow], mine: Bool, encoding: ComparisonTextEncoding) throws -> Data {
        try encoding.encode(sourceText(rows: rows, mine: mine, keepRemoved: !mine))
    }
}
