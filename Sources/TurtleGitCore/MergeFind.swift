import Foundation

/// Literal, pane-local TortoiseMerge search. Ranges use native UTF-16 offsets.
public struct MergeFindOptions: Equatable, Sendable {
    public var matchCase: Bool
    public var modifiedOnly: Bool
    public var wholeWord: Bool
    public var searchUp: Bool
    public var wordSeparators: String
    public init(matchCase: Bool = false, modifiedOnly: Bool = false, wholeWord: Bool = false,
                searchUp: Bool = false, wordSeparators: String = "[]();:.,{}!@#$%^&*-+=|/\\<>'`~\"?") {
        self.matchCase = matchCase; self.modifiedOnly = modifiedOnly
        self.wholeWord = wholeWord; self.searchUp = searchUp; self.wordSeparators = wordSeparators
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(matchCase: defaults.bool(forKey: "TurtleGitMerge.FindMatchCase"),
             modifiedOnly: defaults.bool(forKey: "TurtleGitMerge.FindLimitToDiffs"),
             wholeWord: defaults.bool(forKey: "TurtleGitMerge.FindWholeWord"),
             wordSeparators: defaults.string(forKey: "TurtleGitMerge.WordSeparators") ?? Self().wordSeparators)
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(matchCase, forKey: "TurtleGitMerge.FindMatchCase")
        defaults.set(modifiedOnly, forKey: "TurtleGitMerge.FindLimitToDiffs")
        defaults.set(wholeWord, forKey: "TurtleGitMerge.FindWholeWord")
        // Search Up is intentionally session-local, as in CFindDlg.
    }
}

public struct MergeFindLine: Sendable {
    public let text: String
    public let offset: Int
    public let state: MergeSourceState
    public init(text: String, offset: Int, state: MergeSourceState) {
        self.text = text; self.offset = offset; self.state = state
    }
    public static func displayCells(_ cells: [MergeSourceCell]) -> [Self] {
        var offset = 0
        return cells.map { cell in
            defer { offset += (cell.displayText as NSString).length + 1 }
            return Self(text: cell.displayText, offset: offset, state: cell.state)
        }
    }
    public static func document(_ text: String, states: [MergeSourceState] = []) -> [Self] {
        let value = text as NSString
        return MergeLineEndings.lineRanges(in: text).enumerated().map { index, range in
            Self(text: MergeLineEndings.droppingFinalEnding(value.substring(with: range)), offset: range.location,
                 state: states.indices.contains(index) ? states[index] : .normal)
        }
    }
}

public enum MergeFind {
    public struct Match: Equatable, Sendable {
        public let range: NSRange
        public let wrapped: Bool
    }
    public static func matches(_ query: String, in lines: [MergeFindLine], options: MergeFindOptions) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let separators = Set(options.wordSeparators.utf16)
        func boundary(_ unit: UInt16) -> Bool { unit < 0x20 || unit == 0x20 || unit == 9 || separators.contains(unit) }
        var result: [NSRange] = []
        let flags: NSString.CompareOptions = options.matchCase ? [.literal] : [.literal, .caseInsensitive]
        for line in lines {
            guard line.state != .empty, !options.modifiedOnly || !line.state.isUnchanged else { continue }
            let text = line.text as NSString
            var cursor = 0
            while cursor < text.length {
                let range = text.range(of: query, options: flags, range: NSRange(location: cursor, length: text.length - cursor))
                guard range.location != NSNotFound, range.length > 0 else { break }
                let end = NSMaxRange(range)
                if !options.wholeWord || ((range.location == 0 || boundary(text.character(at: range.location - 1))) && (end == text.length || boundary(text.character(at: end)))) {
                    result.append(NSRange(location: line.offset + range.location, length: range.length))
                }
                cursor = end // Count and Replace All use nonoverlapping matches.
            }
        }
        return result
    }
    /// BaseView::Search searches a bounded initial line, then complete lines.
    /// It cannot navigate the forward, nonoverlapping Count/paint projection:
    /// a caret can start within one of those matches, and reverse Find chooses
    /// the rightmost overlapping occurrence. Replacement starts at the selected
    /// start; reverse Find also retains the source's start-column/end-line rule
    /// for a multiline selection.
    public static func navigate(_ query:String,in lines:[MergeFindLine],options:MergeFindOptions,
                                selection:NSRange,upwards:Bool,useSelectionStart:Bool=false)->Match? {
        guard !query.isEmpty,!lines.isEmpty,selection.location != NSNotFound,
              selection.location>=0,selection.length>=0,selection.location<=Int.max-selection.length else{return nil}
        var previousEnd=0
        for line in lines {
            let length=line.text.utf16.count
            guard line.offset>=previousEnd,line.offset<=Int.max-length else{return nil}
            previousEnd=line.offset+length
        }
        func point(_ offset:Int)->(row:Int,column:Int) {
            var low=0,high=lines.count
            while low<high {let middle=low+(high-low)/2;if lines[middle].offset<=offset {low=middle+1}else{high=middle}}
            let row=max(0,low-1)
            return (row,min(max(0,offset-lines[row].offset),lines[row].text.utf16.count))
        }
        let first=point(selection.location),last=point(selection.location+selection.length)
        let start=useSelectionStart ? first:last
        let column=upwards ? first.column:start.column
        let separators=Set(options.wordSeparators.utf16)
        let flags:NSString.CompareOptions=options.matchCase ? [.literal]:[.literal,.caseInsensitive]
        func wordBoundary(_ unit:UInt16)->Bool {unit<0x20 || unit==0x20 || separators.contains(unit)}
        func accepted(_ range:NSRange,in text:NSString)->Bool {
            !options.wholeWord || ((range.location==0 || wordBoundary(text.character(at:range.location-1))) &&
                (NSMaxRange(range)==text.length || wordBoundary(text.character(at:NSMaxRange(range)))))
        }
        func occurrence(in text:NSString)->NSRange? {
            if !upwards {
                var cursor=0
                while cursor<text.length {
                    let range=text.range(of:query,options:flags,range:NSRange(location:cursor,length:text.length-cursor))
                    guard range.location != NSNotFound,range.length>0 else{return nil}
                    if accepted(range,in:text){return range}
                    cursor=NSMaxRange(range) // StringFound skips a rejected whole-word candidate by its end.
                }
                return nil
            }
            // StringFound(SearchPrevious) enumerates starts one UTF-16 unit
            // apart; Count/ReplaceAll deliberately do not use this projection.
            var candidates=[NSRange](),cursor=0
            while cursor<text.length {
                let range=text.range(of:query,options:flags,range:NSRange(location:cursor,length:text.length-cursor))
                guard range.location != NSNotFound,range.length>0 else{break}
                candidates.append(range);cursor=range.location+1
            }
            var limit=text.length
            for range in candidates.reversed() where range.location<limit {
                if accepted(range,in:text){return range}
                // The source decrements start before its next strict-before
                // candidate lookup, including after a whole-word rejection.
                limit=range.location-1
            }
            return nil
        }
        var row=start.row,wrapped=false
        // The initial row is revisited in full only after crossing the boundary.
        for step in 0...lines.count {
            let line=lines[row]
            if line.state != .empty, !options.modifiedOnly || !line.state.isUnchanged {
                let text=line.text as NSString
                let cut=step==0 ? min(column,text.length):0
                let window:NSRange=step==0 ? (upwards ? NSRange(location:0,length:cut):NSRange(location:cut,length:text.length-cut)) : NSRange(location:0,length:text.length)
                if let found=occurrence(in:text.substring(with:window) as NSString) {
                    return Match(range:NSRange(location:line.offset+window.location+found.location,length:found.length),wrapped:wrapped)
                }
            }
            row += upwards ? -1:1
            if row<0 {row=lines.count-1;wrapped=true}
            else if row==lines.count {row=0;wrapped=true}
        }
        return nil
    }

    public static func next(in matches: [NSRange], selection: NSRange, upwards: Bool, includeSelection: Bool = false) -> Match? {
        guard !matches.isEmpty else { return nil }
        if upwards {
            let start = selection.location + (includeSelection ? selection.length : 0)
            if let range = matches.last(where: { NSMaxRange($0) <= start }) { return Match(range: range, wrapped: false) }
            return Match(range: matches.last!, wrapped: true)
        }
        let start = includeSelection ? selection.location : NSMaxRange(selection)
        if let range = matches.first(where: { $0.location >= start }) { return Match(range: range, wrapped: false) }
        return Match(range: matches.first!, wrapped: true)
    }
}

/// Source GetCharGroup/BuildMarkedWordArray boundaries differ from Find's
/// whole-word boundaries: punctuation runs are a character group of their own.
public enum MergeMarkedWord {
    private static func group(_ unit: UInt16?, separators: Set<UInt16>) -> Int {
        guard let unit else { return 0 }
        if unit == 32 || unit == 9 { return 2 }
        if unit < 32 { return 1 }
        return separators.contains(unit) ? 3 : 4
    }
    public static func selection(at offset: Int, in line: String, wordSeparators: String = MergeFindOptions().wordSeparators) -> NSRange? {
        let units = Array(line.utf16)
        guard offset >= 0, offset <= units.count, !units.isEmpty else { return nil }
        let separators = Set(wordSeparators.utf16)
        func at(_ index: Int) -> Int { group(units.indices.contains(index) ? units[index] : nil, separators: separators) }
        let target = max(at(offset - 1), at(offset))
        var start = offset, end = offset
        while start > 0 && at(start - 1) == target { start -= 1 }
        while end < units.count && at(end) == target { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
    public static func matches(_ word: String, in lines: [MergeFindLine], wordSeparators: String = MergeFindOptions().wordSeparators) -> [NSRange] {
        guard !word.isEmpty else { return [] }
        let separators = Set(wordSeparators.utf16)
        var result: [NSRange] = []
        for line in lines where line.state != .empty {
            let text = line.text as NSString, units = Array(line.text.utf16)
            func at(_ index: Int) -> Int { group(units.indices.contains(index) ? units[index] : nil, separators: separators) }
            var cursor = 0
            while cursor < text.length {
                let found = text.range(of: word, options: .literal, range: NSRange(location: cursor, length: text.length - cursor))
                guard found.location != NSNotFound, found.length > 0 else { break }
                let end = NSMaxRange(found)
                if at(found.location - 1) != at(found.location), at(end) != at(end - 1) {
                    result.append(NSRange(location: line.offset + found.location, length: found.length))
                }
                cursor = found.location + 1
            }
        }
        return result
    }
    /// Locator bands count matching rows once, even when a row has many matches.
    public static func rows(for matches: [NSRange], in lines: [MergeFindLine]) -> Set<Int> {
        var result = Set<Int>(), cursor = 0
        for (row, line) in lines.enumerated() {
            while cursor < matches.count && matches[cursor].location < line.offset { cursor += 1 }
            if cursor < matches.count, matches[cursor].location < line.offset + line.text.utf16.count { result.insert(row) }
        }
        return result
    }
}
