import Foundation

/// BaseView::DrawMargin symbols are independent of the editable color palette.
public enum MergeMarginSymbol: String, Sendable, Equatable, CaseIterable {
    case added, removed, conflict, ignoredConflict, edited, equal, whitespace, moved, marked
    public var title: String {
        switch self {
        case .added: return "Added line"
        case .removed: return "Removed line"
        case .conflict: return "Conflicted line"
        case .ignoredConflict: return "Ignored conflict"
        case .edited: return "Edited line"
        case .equal: return "Identical block"
        case .whitespace: return "Whitespace-only changes"
        case .moved: return "Moved block"
        case .marked: return "Marked block"
        }
    }
}

/// Port of BaseView's bounded GetWhitespaceBlock/GetWhitespaceString and
/// IsBlockWhitespaceOnly. Use original view records, never synthetic display LFs.
/// Only the paired source panes have peers; combined/result views do not.
public struct MergeMarginPresentation: Sendable {
    public let symbols: [MergeMarginSymbol?]
    public init(cells: [MergeSourceCell], peers: [MergeSourceCell]? = nil) {
        func ordinary(_ state: MergeSourceState) -> MergeMarginSymbol? {
            if state.isAddition { return .added }
            if state.isRemoval { return .removed }
            switch state {
            case .conflicted: return .conflict
            case .conflictedIgnored: return .ignoredConflict
            case .edited: return .edited
            default: return nil
            }
        }
        func equal(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        func stripped(_ value: String) -> String {
            String(String.UnicodeScalarView(value.unicodeScalars.filter { ![9,10,13,32].contains($0.value) }))
        }
        func block(_ records: [MergeSourceCell], _ row: Int) -> ClosedRange<Int> {
            var state = records[row].state, start = row, end = row
            while start > 0 && start > row - 8 {
                let previous = records[start - 1].state
                if state == .empty && previous != .normal { state = previous }
                guard previous == state || previous == .empty else { break }
                start -= 1
            }
            while end < records.count - 1 && end < row + 8 {
                let next = records[end + 1].state
                if state == .empty && next != .normal { state = next }
                guard next == state || next == .empty else { break }
                end += 1
            }
            return start...end
        }
        func payload(_ records: [MergeSourceCell], _ range: ClosedRange<Int>) -> String {
            guard range.reduce(0, { $0 + records[$1].displayText.utf16.count + 2 }) <= 8 * 256 else { return "" }
            return range.map { records[$0].text }.joined()
        }
        var result = cells.map { ordinary($0.state) }
        if let peers, !peers.isEmpty {
            // One forward pass also paints the bounded same-state block, as the
            // source's icon cache does, without doing string work while drawing.
            var classified = Set<Int>()
            for row in cells.indices where !classified.contains(row) && cells[row].state != .edited {
                let peer = min(row, peers.count - 1)
                let a = cells[row].displayText, b = peers[peer].displayText
                if cells[row].state == .normal && equal(a,b) || a.isEmpty && b.isEmpty { continue }
                if equal(a,b) { result[row] = .equal; continue }
                if equal(stripped(a),stripped(b)) { result[row] = .whitespace; continue }
                let range = block(cells,row), other = block(peers,peer)
                let mine = payload(cells,range), theirs = payload(peers,other)
                if !mine.isEmpty && equal(stripped(mine),stripped(theirs)) {
                    let symbol: MergeMarginSymbol = equal(mine,theirs) ? .equal : .whitespace
                    for index in range { result[index] = symbol; classified.insert(index) }
                }
            }
        }
        symbols = result
    }
    public func symbol(at row: Int, moved: Bool = false, marked: Bool = false) -> MergeMarginSymbol? {
        guard symbols.indices.contains(row) else { return nil }
        // DrawMargin applies these overrides after the whitespace classification.
        if marked { return .marked }
        if moved { return .moved }
        return symbols[row]
    }
}

public enum MergeSourceState: Sendable, Equatable, CaseIterable {
    case normal, removed, added, conflicted, resolved, resolvedEmpty, edited, empty, filtered
    case identicalRemoved, identicalAdded, theirsRemoved, theirsAdded, yoursRemoved, yoursAdded
    case conflictAdded, conflictEmpty, conflictedIgnored, removedWhitespace, addedWhitespace
    public var isRemoval: Bool { [.removed,.identicalRemoved,.theirsRemoved,.yoursRemoved].contains(self) }
    /// BaseView::IsStateEmpty deliberately excludes ConflictResolvedEmpty.
    public var isViewEmpty: Bool { self == .empty || self == .conflictEmpty }
    public var isExcludedFromResult: Bool { isRemoval || isViewEmpty || self == .resolvedEmpty }
    public var resolvedState: Self { self == .conflictEmpty ? .resolvedEmpty : isConflict ? .resolved : self }
    public var isAddition: Bool { [.added,.identicalAdded,.theirsAdded,.yoursAdded,.conflictAdded].contains(self) }
    public var isConflict: Bool { [.conflicted,.conflictAdded,.conflictEmpty,.conflictedIgnored].contains(self) }
    public var isUnchanged: Bool { self == .normal || self == .filtered }
}

/// CBaseView::UpdateStatusBar counts source state categories, not text rows or
/// conflict-marker matches. ConflictAdded counts as added; Empty/ConflictEmpty
/// gaps do not count. IdenticalRemoved padding follows the source removal count.
public struct MergeLineStatistics: Equatable, Sendable {
    public private(set) var added = 0, removed = 0, conflicted = 0
    public init(states: [MergeSourceState]) {
        for state in states {
            if state.isAddition {added += 1}
            else if state.isRemoval {removed += 1}
            else if state == .conflicted || state == .conflictedIgnored {conflicted += 1}
        }
    }
    public var isEmpty: Bool {added == 0 && removed == 0 && conflicted == 0}
}

public struct MergeSourceCell: Sendable {
    /// Original bytes represented by this line, including its line ending.
    public let text: String
    /// One-based source line number. Removed base lines and alignment gaps have none.
    public let lineNumber: Int?
    public let state: MergeSourceState
    /// Source HideState is independent of Find's modified-state categories.
    public let hiddenByComparison: Bool
    public init(text: String, lineNumber: Int?, state: MergeSourceState, hiddenByComparison: Bool? = nil) {
        self.text = text; self.lineNumber = lineNumber; self.state = state; self.hiddenByComparison = hiddenByComparison ?? state.isUnchanged
    }
    /// A combined Base whitespace row displays Mine's number but is not an
    /// extra line in the original Mine coordinate space.
    public var hasSourceCoordinate: Bool { lineNumber != nil && state != .removedWhitespace }
    public var displayText: String {
        MergeLineEndings.droppingFinalEnding(text)
    }
}

public struct MergeSourceRow: Sendable {
    public let mine: MergeSourceCell
    public let theirs: MergeSourceCell
}

/// Aligned, read-only source views. Numbered cells recover each source; removed
/// Base records and gaps retain view coordinates without adding source bytes.
public struct MergeSourceComparison: Sendable {
    public let rows: [MergeSourceRow]
    public let resultLocator: MergeLocatorResult?
    /// Alignment-row anchors into the initial editable result. Common rows only;
    /// conflict markers and removed/gap rows never acquire guessed anchors.
    public let resultAnchors: [Int: Int]
    public let ignoredConflicts: [IgnoredMergeConflict]
    public let navigationMap: MergeNavigationMap
    /// Diff3 view records, distinct from serialized marker lines. Removed Base
    /// records and blank conflict/empty records retain their aligned positions.
    public let alignedResultRows: [MergeSourceCell]?
    public init(rows: [MergeSourceRow], resultLocator: MergeLocatorResult? = nil, resultAnchors: [Int: Int] = [:], ignoredConflicts: [IgnoredMergeConflict] = [], navigationMap: MergeNavigationMap = .init(), alignedResultRows: [MergeSourceCell]? = nil) {
        self.alignedResultRows = alignedResultRows?.count == rows.count ? alignedResultRows : nil
        self.navigationMap = navigationMap; self.rows = rows; self.resultLocator = resultLocator; self.resultAnchors = resultAnchors; self.ignoredConflicts = ignoredConflicts
    }
    public init(base: String, mine: String, theirs: String) {
        alignedResultRows = nil
        resultLocator = nil; resultAnchors = [:]; ignoredConflicts = []; navigationMap = .init()
        let baseLines = Self.lines(base), mineLines = Self.lines(mine), theirLines = Self.lines(theirs)
        let mineHunks = Self.hunks(base: baseLines, side: mineLines, mine: true)
        let theirHunks = Self.hunks(base: baseLines, side: theirLines, mine: false)
        let all = (mineHunks + theirHunks).sorted {
            $0.base.lowerBound == $1.base.lowerBound ? $0.base.upperBound < $1.base.upperBound : $0.base.lowerBound < $1.base.lowerBound
        }
        var regions: [Region] = []
        for hunk in all {
            if let last = regions.last,
               hunk.base.lowerBound < last.base.upperBound || (hunk.base.lowerBound == last.base.upperBound && (last.base.isEmpty || hunk.base.isEmpty)) {
                regions[regions.count - 1].base = last.base.lowerBound..<max(last.base.upperBound, hunk.base.upperBound)
                regions[regions.count - 1].hunks.append(hunk)
            } else { regions.append(Region(base: hunk.base, hunks: [hunk])) }
        }
        var output: [MergeSourceRow] = [], baseline = 0, mineIndex = 0, theirIndex = 0
        func normal(_ text: String, _ number: Int) -> MergeSourceCell { MergeSourceCell(text: text, lineNumber: number + 1, state: .normal) }
        func gap(_ conflict: Bool = false) -> MergeSourceCell { MergeSourceCell(text: "", lineNumber: nil, state: conflict ? .conflicted : .empty) }
        func common(until limit: Int) {
            while baseline < limit {
                output.append(MergeSourceRow(mine: normal(mineLines[mineIndex], mineIndex), theirs: normal(theirLines[theirIndex], theirIndex)))
                baseline += 1; mineIndex += 1; theirIndex += 1
            }
        }
        for group in regions {
            let region = group.base
            common(until: region.lowerBound)
            let m = group.hunks.filter(\.mine), t = group.hunks.filter { !$0.mine }
            let mineCount = region.count + m.reduce(0) { $0 + $1.side.count - $1.base.count }
            let theirCount = region.count + t.reduce(0) { $0 + $1.side.count - $1.base.count }
            let mineChunk = Array(mineLines[mineIndex..<(mineIndex + mineCount)])
            let theirChunk = Array(theirLines[theirIndex..<(theirIndex + theirCount)])
            // A trailing insertion does not remove the region's unchanged base
            // rows. Keep those numbered and align only its appended text below.
            let preserveMine = m.isEmpty || m.allSatisfy { $0.base.isEmpty && $0.base.lowerBound == region.upperBound }
            let preserveTheirs = t.isEmpty || t.allSatisfy { $0.base.isEmpty && $0.base.lowerBound == region.upperBound }
            for offset in 0..<region.count {
                let old = baseLines[region.lowerBound + offset]
                output.append(MergeSourceRow(
                    mine: preserveMine ? normal(mineChunk[offset], mineIndex + offset) : MergeSourceCell(text: old, lineNumber: nil, state: .removed),
                    theirs: preserveTheirs ? normal(theirChunk[offset], theirIndex + offset) : MergeSourceCell(text: old, lineNumber: nil, state: .removed)))
            }
            let mineOffset = preserveMine ? region.count : 0, theirOffset = preserveTheirs ? region.count : 0
            let mineAdded = Array(mineChunk.dropFirst(mineOffset)), theirAdded = Array(theirChunk.dropFirst(theirOffset))
            let conflict = m.contains { mh in t.contains { th in
                (!mh.base.isEmpty && !th.base.isEmpty && mh.base.overlaps(th.base)) || (mh.base.isEmpty && th.base.isEmpty && mh.base.lowerBound == th.base.lowerBound)
            } }
            let difference = theirAdded.difference(from: mineAdded, by: Self.sameBytes)
            var removed = Set<Int>(), inserted = Set<Int>()
            for change in difference {
                switch change {
                case .remove(let index, _, _): removed.insert(index)
                case .insert(let index, _, _): inserted.insert(index)
                }
            }
            func cell(_ mine: Bool, _ index: Int, _ state: MergeSourceState) -> MergeSourceCell {
                MergeSourceCell(text: mine ? mineAdded[index] : theirAdded[index], lineNumber: (mine ? mineIndex + mineOffset : theirIndex + theirOffset) + index + 1, state: state)
            }
            var a = 0, b = 0
            while a < mineAdded.count || b < theirAdded.count {
                if removed.contains(a) || inserted.contains(b) {
                    let startA = a, startB = b
                    while removed.contains(a) { a += 1 }
                    while inserted.contains(b) { b += 1 }
                    for index in 0..<max(a - startA, b - startB) {
                        output.append(MergeSourceRow(
                            mine: startA + index < a ? cell(true, startA + index, conflict ? .conflicted : .added) : gap(conflict),
                            theirs: startB + index < b ? cell(false, startB + index, conflict ? .conflicted : .added) : gap(conflict)))
                    }
                } else {
                    output.append(MergeSourceRow(mine: cell(true, a, .added), theirs: cell(false, b, .added)))
                    a += 1; b += 1
                }
            }
            baseline = region.upperBound; mineIndex += mineCount; theirIndex += theirCount
        }
        common(until: baseLines.count)
        rows = output
    }
    /// Source GetSelectedText includes removed/conflict rows, skips Empty rows,
    /// and normalizes clipboard endings (LF on macOS). The terminal display-only
    /// LF is outside the selectable payload, matching a block ending at its text.
    public static func clipboardText(_ range: NSRange, cells: [MergeSourceCell]) throws -> String {
        let length = cells.reduce(0) { $0 + ($1.displayText as NSString).length + 1 }
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location else { throw FileComparisonEditFailure.range }
        let end = min(NSMaxRange(range), max(0, length - 1))
        guard end > range.location else { return "" }
        let selected = NSRange(location: range.location, length: end - range.location)
        var cursor = 0, result = ""
        for cell in cells {
            let text = (cell.displayText + "\n") as NSString
            let overlap = NSIntersectionRange(selected, NSRange(location: cursor, length: text.length))
            if cell.state != .empty, overlap.length > 0 {
                result += text.substring(with: NSRange(location: overlap.location - cursor, length: overlap.length))
            }
            cursor += text.length
        }
        return result
    }
    /// CBaseView::OnEditGotoline uses the last numbered source row, not
    /// the count of aligned display rows. Its chooser is absent for <= 1 line.
    public static func navigationLimit(cells: [MergeSourceCell]) -> Int? {
        guard let last = cells.reversed().compactMap(\.lineNumber).first, last > 1 else { return nil }
        return last
    }
    public static func navigationRange(line: Int, cells: [MergeSourceCell]) -> NSRange? {
        guard line > 0 else { return nil }
        var offset = 0
        for cell in cells {
            let length = (cell.displayText as NSString).length
            if cell.lineNumber == line { return NSRange(location: offset, length: length) }
            offset += length + 1
        }
        return nil
    }
    /// Raw Base/result panes have no alignment cells. Use the same nine-ending
    /// parser as the editor; do not invent a numbered line after a final ending.
    public static func navigationRanges(text: String) -> [NSRange] {
        let source = text as NSString
        return MergeLineEndings.lineRanges(in: text).map { range in
            let content = MergeLineEndings.droppingFinalEnding(source.substring(with: range))
            return NSRange(location: range.location, length: (content as NSString).length)
        }
    }
    private struct Hunk { let base: Range<Int>; let side: Range<Int>; let mine: Bool }
    private struct Region { var base: Range<Int>; var hunks: [Hunk] }
    private static func lines(_ text: String) -> [String] {
        let source = text as NSString
        return MergeLineEndings.lineRanges(in: text).map { source.substring(with: $0) }
    }
    private static func hunks(base: [String], side: [String], mine: Bool) -> [Hunk] {
        let difference = side.difference(from: base, by: sameBytes)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        var b = 0, s = 0, result: [Hunk] = []
        while b < base.count || s < side.count {
            if removed.contains(b) || inserted.contains(s) {
                let startBase = b, startSide = s
                while removed.contains(b) { b += 1 }
                while inserted.contains(s) { s += 1 }
                result.append(Hunk(base: startBase..<b, side: startSide..<s, mine: mine))
            } else { b += 1; s += 1 }
        }
        return result
    }
    private static func sameBytes(_ first: String, _ second: String) -> Bool { first.utf8.elementsEqual(second.utf8) }
}

/// Exact engine segment relationships. The native result omits alignment gaps
/// and contains marker lines, so source and result row numbers are not equal.
public struct MergeNavigationMap: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let sourceRows: Range<Int>
        public let resultRange: NSRange
        public init(sourceRows: Range<Int>, resultRange: NSRange) {
            self.sourceRows = sourceRows; self.resultRange = resultRange
        }
    }
    public let entries: [Entry]
    public init(entries: [Entry] = []) { self.entries = entries }
    /// A writable source selection must cover complete known mappings. Unlike
    /// navigation's union, this never expands a partial row selection to an
    /// entire engine conflict/group or bridges a mapping invalidated by typing.
    public func exactResultRange(sourceRows: Range<Int>) -> NSRange? {
        guard !sourceRows.isEmpty else { return nil }
        let matches = entries.filter { $0.sourceRows.overlaps(sourceRows) }.sorted { $0.sourceRows.lowerBound < $1.sourceRows.lowerBound }
        guard let first = matches.first else { return nil }
        var row = sourceRows.lowerBound, end = first.resultRange.location
        for entry in matches {
            guard entry.sourceRows.lowerBound == row, entry.sourceRows.upperBound <= sourceRows.upperBound,
                  entry.resultRange.location == end else { return nil }
            row = entry.sourceRows.upperBound; end = NSMaxRange(entry.resultRange)
        }
        guard row == sourceRows.upperBound else { return nil }
        return NSRange(location:first.resultRange.location,length:end - first.resultRange.location)
    }
    public func applyingSourceRows(_ rows: Range<Int>, replacementLength: Int, replacementEntries: [Entry]? = nil) -> Self? {
        guard let range = exactResultRange(sourceRows:rows) else { return nil }
        let replacement = replacementEntries ?? [Entry(sourceRows:rows,resultRange:NSRange(location:range.location,length:replacementLength))]
        let proposed = Self(entries:replacement)
        guard proposed.exactResultRange(sourceRows:rows) == NSRange(location:range.location,length:replacementLength) else { return nil }
        let delta = replacementLength - range.length
        let retained = entries.compactMap { entry -> Entry? in
            if entry.sourceRows.overlaps(rows) { return nil }
            if entry.sourceRows.lowerBound >= rows.upperBound {
                return Entry(sourceRows:entry.sourceRows,resultRange:NSRange(location:entry.resultRange.location + delta,length:entry.resultRange.length))
            }
            return entry
        }
        return Self(entries:(retained + replacement).sorted { $0.sourceRows.lowerBound < $1.sourceRows.lowerBound })
    }
    public func resultRange(sourceRows: Range<Int>) -> NSRange? {
        let matches = entries.filter { $0.sourceRows.overlaps(sourceRows) }.map(\.resultRange)
        guard let first = matches.first else { return nil }
        return matches.dropFirst().reduce(first) { NSUnionRange($0, $1) }
    }
    public func sourceRows(resultRange: NSRange) -> Range<Int>? {
        let matches = entries.filter {
            if resultRange.length == 0 { return $0.resultRange.length == 0 ? $0.resultRange.location == resultRange.location : NSLocationInRange(resultRange.location, $0.resultRange) }
            return NSIntersectionRange($0.resultRange, resultRange).length > 0
        }.map(\.sourceRows)
        guard let first = matches.first else { return nil }
        return matches.dropFirst().reduce(first) { min($0.lowerBound, $1.lowerBound)..<max($0.upperBound, $1.upperBound) }
    }
    /// Preserve edits wholly inside an engine group; invalidate ambiguous edits
    /// crossing group boundaries. Undo retains the complete previous mapping.
    public func replacing(_ range: NSRange, replacementLength: Int) -> Self {
        let end = NSMaxRange(range), delta = replacementLength - range.length
        return Self(entries: entries.compactMap { entry in
            let start = entry.resultRange.location, limit = NSMaxRange(entry.resultRange)
            if range.length == 0 && start == limit && start == range.location { return nil }
            if limit <= range.location { return entry }
            if start >= end {
                return Entry(sourceRows:entry.sourceRows,resultRange:NSRange(location:start + delta,length:entry.resultRange.length))
            }
            if range.location >= start && end <= limit {
                return Entry(sourceRows:entry.sourceRows,resultRange:NSRange(location:start,length:entry.resultRange.length + delta))
            }
            return nil
        })
    }
}

/// CBaseView::SelectNextBlock searches visible screen rows in the active pane.
/// State blocks deliberately differ from the diff engine's changed regions.
public enum MergeBlockNavigation {
    public struct Target: Equatable, Sendable {
        public let rows: Range<Int>
        public let caret: Int
    }
    public static func sameChange(_ initial: MergeSourceState, _ current: MergeSourceState, direction: Int) -> Bool {
        if initial == current { return true }
        if direction > 0 {
            return (current == .empty && (initial == .added || initial == .removed))
                || (initial == .conflictAdded && current == .conflictEmpty)
        }
        return (initial == .empty && (current == .added || current == .removed))
            || (initial == .conflictEmpty && current == .conflictAdded)
    }
    /// OnContextMenu expands both directions against the clicked row's fixed
    /// state, including Normal/Filtered rows and hidden source rows.
    public static func block(states: [MergeSourceState], containing row: Int) -> Target? {
        guard states.indices.contains(row) else { return nil }
        var first = row, last = row
        while first > 0, sameChange(states[row],states[first - 1],direction:-1) { first -= 1 }
        while last + 1 < states.count, sameChange(states[row],states[last + 1],direction:1) { last += 1 }
        return Target(rows:first..<(last + 1),caret:row)
    }
    public static func target(states: [MergeSourceState], visibleRows: [Int], caret: Int,
                              direction: Int, conflictsOnly: Bool = false, skipCurrent: Bool = true) -> Target? {
        guard direction != 0, !visibleRows.isEmpty,
              visibleRows.allSatisfy({ states.indices.contains($0) }),
              zip(visibleRows, visibleRows.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        let step = direction > 0 ? 1 : -1
        var screen = visibleRows.firstIndex(of: caret)
            ?? visibleRows.lastIndex(where: { $0 <= caret }) ?? 0
        func valid(_ index: Int) -> Bool { visibleRows.indices.contains(index) }
        func state(_ index: Int) -> MergeSourceState { states[visibleRows[index]] }
        if skipCurrent {
            let initial = state(screen)
            while valid(screen), sameChange(initial, state(screen), direction: step) { screen += step }
        }
        while valid(screen) {
            let current = state(screen)
            if conflictsOnly ? current.isConflict : !current.isUnchanged { break }
            screen += step
        }
        guard valid(screen) else { return nil }
        let entry = screen, initial = state(screen)
        while valid(screen + step), sameChange(initial, state(screen + step), direction: step) { screen += step }
        return Target(rows: min(visibleRows[entry], visibleRows[screen])..<(max(visibleRows[entry], visibleRows[screen]) + 1),
                      caret: visibleRows[entry])
    }
}

/// LocatorBar.cpp compresses consecutive state runs and scales all panes by the
/// longest view. Three stripes are Left, Bottom, Right, also in two-pane mode.
public struct MergeLocatorMap: Sendable {
    public struct Run: Equatable, Sendable {
        public let rows: Range<Int>
        public let state: MergeSourceState
    }
    public let columns: [[Run]]
    public let lineCount: Int
    public init(columns: [[MergeSourceState]]) {
        lineCount = columns.map(\.count).max() ?? 0
        self.columns = columns.map { states in
            var runs: [Run] = [], start = 0
            for index in states.indices {
                if index + 1 == states.count || states[index + 1] != states[index] {
                    runs.append(Run(rows: start..<index + 1, state: states[index])); start = index + 1
                }
            }
            return runs
        }
    }
    public func row(at fraction: Double) -> Int {
        guard lineCount > 0, fraction.isFinite else { return 0 }
        return min(lineCount - 1, max(0, Int((min(1, max(0, fraction)) * Double(lineCount)).rounded(.down))))
    }
}
public struct MergeLocatorPreferences: Equatable, Sendable {
    public var visible: Bool
    public var fishEye: Bool
    public init(visible: Bool = true, fishEye: Bool = true) { self.visible = visible; self.fishEye = fishEye }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(visible: defaults.object(forKey: "TurtleGitMerge.LocatorBar") == nil ? true : defaults.bool(forKey: "TurtleGitMerge.LocatorBar"),
             fishEye: defaults.object(forKey: "TurtleGitMerge.UseFishEye") == nil ? true : defaults.bool(forKey: "TurtleGitMerge.UseFishEye"))
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: "TurtleGitMerge.LocatorBar"); defaults.set(fishEye, forKey: "TurtleGitMerge.UseFishEye")
    }
}
/// Initial result colors come from the actual Subversion presentation. During
/// editing, retain the unchanged prefix/suffix and mark the edited middle added;
/// conflict ranges override those colors. This never changes result text.
public struct MergeLocatorResult: Sendable {
    public let text: String
    public let states: [MergeSourceState]
    public init(text: String, spans: [(Range<Int>, MergeSourceState)]) {
        self.text = text
        var cursor = 0
        states = MergeLineEndings.lineRanges(in: text).map { line in
            while cursor < spans.count && spans[cursor].0.upperBound <= line.location { cursor += 1 }
            return cursor < spans.count ? spans[cursor].1 : .normal
        }
    }
    public func states(for result: String, conflicts: [NSRange]) -> [MergeSourceState] {
        let original = MergeRegexFilters.lines(text), current = MergeRegexFilters.lines(result)
        var prefix = 0, suffix = 0
        while prefix < min(original.count, current.count), original[prefix].utf8.elementsEqual(current[prefix].utf8) { prefix += 1 }
        while suffix < min(original.count, current.count) - prefix,
              original[original.count - suffix - 1].utf8.elementsEqual(current[current.count - suffix - 1].utf8) { suffix += 1 }
        let ranges = MergeLineEndings.lineRanges(in: result)
        var conflict = 0
        return ranges.enumerated().map { index, range in
            while conflict < conflicts.count && NSMaxRange(conflicts[conflict]) <= range.location { conflict += 1 }
            if conflict < conflicts.count && NSIntersectionRange(range, conflicts[conflict]).length > 0 { return .conflicted }
            if index < prefix { return states.indices.contains(index) ? states[index] : .normal }
            if index >= current.count - suffix {
                let old = original.count - (current.count - index)
                return states.indices.contains(old) ? states[old] : .normal
            }
            return .added
        }
    }
}
