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

    /// Cached view-coordinate word geometry. Source word boundaries are the
    /// transitions between separator and letter runs, including line-edge rules;
    /// native composed characters remain indivisible.
    public struct WordDocument: Sendable {
        private struct Row: Sendable { let text:String, offset:Int, length:Int }
        private let rows:[Row]
        private let cells:[MergeSourceCell]?
        private let text:String
        private let limit:Int
        public init?(text:String,cells:[MergeSourceCell]? = nil) {
            self.text=text;self.cells=cells
            if let cells {
                guard let geometry=Geometry(text:text,cells:cells) else{return nil}
                rows=cells.indices.map { Row(text:cells[$0].displayText,offset:geometry.offsets[$0],length:cells[$0].displayText.utf16.count) }
                limit=geometry.lastCaret
            } else {
                let source=text as NSString
                var parsed=MergeLineEndings.lineRanges(in:text).map {range -> Row in
                    let value=MergeLineEndings.droppingFinalEnding(source.substring(with:range))
                    return Row(text:value,offset:range.location,length:value.utf16.count)
                }
                if parsed.isEmpty || MergeLineEndings.hasFinalEnding(text) {parsed.append(Row(text:"",offset:source.length,length:0))}
                rows=parsed;limit=source.length
            }
        }
        private func validCaret(_ offset:Int)->Bool {
            guard offset>=0,offset<=text.utf16.count else{return false}
            if offset==text.utf16.count{return true}
            let source=text as NSString
            if offset>0,source.character(at:offset)==10,source.character(at:offset-1)==13{return false}
            return source.rangeOfComposedCharacterSequence(at:offset).location==offset
        }
        public func destination(from offset:Int,forward:Bool,wordSeparators:String = MergeFindOptions().wordSeparators,hiddenRows:Set<Int> = []) -> Int? {
            guard validCaret(offset),hiddenRows.allSatisfy({rows.indices.contains($0)}) else{return nil}
            guard !rows.isEmpty else{return offset==0 ? 0:nil}
            let start=min(offset,limit)
            var low=0,high=rows.count
            while low<high {let mid=(low+high)/2;if rows[mid].offset<=start{low=mid+1}else{high=mid}}
            var row=max(0,low-1),column=min(rows[max(0,low-1)].length,max(0,start-rows[max(0,low-1)].offset))
            var line=rows[row].text as NSString
            let separators=Set(wordSeparators.utf16)
            func separator(_ unit:UInt16)->Bool {unit<=32 || separators.contains(unit)}
            func boundary()->Bool {
                guard line.length>0 else{return false}
                if column==0{return !separator(line.character(at:0))}
                if column>=line.length{return !separator(line.character(at:line.length-1))}
                return separator(line.character(at:column)) != separator(line.character(at:column-1))
            }
            func advance()->Bool {
                if !hiddenRows.contains(row) {
                    if forward,column<line.length {column=NSMaxRange(line.rangeOfComposedCharacterSequence(at:column));return true}
                    if !forward,column>0 {column=line.rangeOfComposedCharacterSequence(at:column-1).location;return true}
                }
                var next=row+(forward ? 1:-1)
                while rows.indices.contains(next),hiddenRows.contains(next){next += forward ? 1:-1}
                guard rows.indices.contains(next) else{return false}
                row=next;line=rows[row].text as NSString;column=forward ? 0:line.length;return true
            }
            if hiddenRows.contains(row),!rows.indices.contains(where: { !hiddenRows.contains($0) }) {return nil}
            while advance() {if boundary(){break}}
            guard !hiddenRows.contains(row) else{return nil}
            return min(limit,rows[row].offset+column)
        }
        public func deletionRange(selection:NSRange,backward:Bool,wordSeparators:String = MergeFindOptions().wordSeparators,hiddenRows:Set<Int> = []) -> NSRange? {
            let length=text.utf16.count
            guard selection.location>=0,selection.length>=0,selection.location<=length,selection.length<=length-selection.location,validCaret(selection.location),validCaret(NSMaxRange(selection)),hiddenRows.allSatisfy({rows.indices.contains($0)}) else{return nil}
            let range:NSRange
            if selection.length>0 {range=selection}
            else {
                let caret=min(selection.location,limit)
                guard let other=destination(from:caret,forward:!backward,wordSeparators:wordSeparators,hiddenRows:hiddenRows),other != caret else{return nil}
                range=NSRange(location:min(caret,other),length:abs(caret-other))
            }
            let normalized:NSRange?
            if let cells {normalized=MergePaneInput.normalizedReplacementRange(in:text,cells:cells,selection:range)}else{normalized=range}
            guard let normalized,normalized.length>0 else{return nil}
            return normalized
        }
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
