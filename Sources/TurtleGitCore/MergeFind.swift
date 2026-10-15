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
