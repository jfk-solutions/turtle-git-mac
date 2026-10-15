import Foundation

public enum MergeSourceState: Sendable, Equatable, CaseIterable {
    case normal, removed, added, conflicted, resolved, edited, empty, filtered
    case identicalRemoved, identicalAdded, theirsRemoved, theirsAdded, yoursRemoved, yoursAdded
    case conflictAdded, conflictEmpty, conflictedIgnored, removedWhitespace, addedWhitespace
    public var isRemoval: Bool { [.removed,.identicalRemoved,.theirsRemoved,.yoursRemoved].contains(self) }
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

/// Aligned, read-only source views. Display-only base rows and gaps never become
/// part of the editable result, and filtering numbered cells recovers each source.
public struct MergeSourceComparison: Sendable {
    public let rows: [MergeSourceRow]
    public let resultLocator: MergeLocatorResult?
    /// Alignment-row anchors into the initial editable result. Common rows only;
    /// conflict markers and removed/gap rows never acquire guessed anchors.
    public let resultAnchors: [Int: Int]
    public let ignoredConflicts: [IgnoredMergeConflict]
    public init(rows: [MergeSourceRow], resultLocator: MergeLocatorResult? = nil, resultAnchors: [Int: Int] = [:], ignoredConflicts: [IgnoredMergeConflict] = []) {
        self.rows = rows; self.resultLocator = resultLocator; self.resultAnchors = resultAnchors; self.ignoredConflicts = ignoredConflicts
    }
    public init(base: String, mine: String, theirs: String) {
        resultLocator = nil; resultAnchors = [:]; ignoredConflicts = []
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
