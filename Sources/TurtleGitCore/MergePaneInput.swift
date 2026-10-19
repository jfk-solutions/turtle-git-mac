import Foundation

/// View-coordinate editing for TortoiseMerge's Empty alignment records. Empty
/// states are not blank source lines; the display's last LF is only a caret row
/// terminator, not an extra character to delete from the document.
public enum MergePaneInput {
    public static func normalizedReplacementRange(in text:String,cells:[MergeSourceCell],selection:NSRange)->NSRange? {
        guard let geometry = Geometry(text:text,cells:cells), geometry.valid(selection) else { return nil }
        guard selection.length > 0 else { return selection }
        let start = geometry.forwardOffEmpty(selection.location)
        let end = geometry.forwardOffEmpty(NSMaxRange(selection))
        return NSRange(location:start,length:max(0,end - start))
    }

    public static func deletionRange(in text:String,cells:[MergeSourceCell],selection:NSRange,backward:Bool)->NSRange? {
        guard let geometry = Geometry(text:text,cells:cells), geometry.valid(selection), !cells.isEmpty else { return nil }
        if selection.length > 0 {
            guard let range = normalizedReplacementRange(in:text,cells:cells,selection:selection), range.length > 0 else { return nil }
            return range
        }
        let caret = min(selection.location,geometry.lastCaret), row = geometry.row(caret)
        let column = min(cells[row].displayText.utf16.count,max(0,caret - geometry.offsets[row]))
        let other:Int
        if backward {
            if column > 0 {
                other = geometry.offsets[row] + (cells[row].displayText as NSString).rangeOfComposedCharacterSequence(at:column - 1).location
            } else {
                guard let previous = cells.indices.prefix(row).last(where:{ !cells[$0].state.isViewEmpty }) else { return nil }
                other = geometry.offsets[previous] + cells[previous].displayText.utf16.count
            }
        } else {
            if column < cells[row].displayText.utf16.count {
                let character = (cells[row].displayText as NSString).rangeOfComposedCharacterSequence(at:column)
                other = geometry.offsets[row] + NSMaxRange(character)
            } else {
                guard row + 1 < cells.count else { return nil }
                other = geometry.offsets[row + 1]
            }
        }
        let proposed = NSRange(location:min(caret,other),length:abs(caret - other))
        guard let range = normalizedReplacementRange(in:text,cells:cells,selection:proposed),range.length > 0 else { return nil }
        return range
    }

    private struct Geometry {
        let cells:[MergeSourceCell]
        let offsets:[Int]
        let length:Int
        var lastCaret:Int { guard let last = cells.last, let offset = offsets.last else { return 0 }; return offset + last.displayText.utf16.count }
        init?(text:String,cells:[MergeSourceCell]) {
            var offsets:[Int] = [], offset = 0
            for cell in cells { offsets.append(offset); offset += cell.displayText.utf16.count + 1 }
            let expected = cells.map { $0.displayText + "\n" }.joined()
            guard text.utf8.elementsEqual(expected.utf8) || (!expected.isEmpty && text.utf8.elementsEqual(expected.dropLast().utf8)) else { return nil }
            self.cells = cells; self.offsets = offsets; length = text.utf16.count
        }
        func valid(_ range:NSRange)->Bool { range.location >= 0 && range.length >= 0 && range.location <= length && range.length <= length - range.location }
        func row(_ offset:Int)->Int { offsets.lastIndex(where:{ $0 <= min(offset,lastCaret) }) ?? 0 }
        func forwardOffEmpty(_ offset:Int)->Int {
            guard !cells.isEmpty else { return offset }
            var index = row(offset)
            guard cells[index].state.isViewEmpty else { return offset }
            while index + 1 < cells.count && cells[index].state.isViewEmpty { index += 1 }
            return offsets[index]
        }
    }
}
