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
