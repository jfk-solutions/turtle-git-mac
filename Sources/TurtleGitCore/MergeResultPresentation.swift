// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A source conflict hidden by comparison keys. Its Mine payload stays in the
/// result without inserting marker text; the range is always in UTF-16 units.
public struct IgnoredMergeConflict: Sendable, Equatable {
    public let range: NSRange
    public let mine: String
    public let base: String
    public let theirs: String
    public init(range:NSRange,mine:String,base:String,theirs:String) { self.range = range; self.mine = mine; self.base = base; self.theirs = theirs }
    public static func == (a:Self,b:Self) -> Bool { a.range == b.range && a.mine.utf8.elementsEqual(b.mine.utf8) && a.base.utf8.elementsEqual(b.base.utf8) && a.theirs.utf8.elementsEqual(b.theirs.utf8) }
    func shifted(by delta:Int) -> Self { .init(range:NSRange(location:range.location + delta,length:range.length),mine:mine,base:base,theirs:theirs) }
}

/// Editing provenance is independent of file contents, save state and theme.
/// UTF-16 runs retain unaffected colors through several disjoint edits.
public struct MergeResultPresentation: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        public let range: Range<Int>
        public let state: MergeSourceState
        /// DiffData's HideState survives independently of color/state changes.
        public let hiddenByComparison: Bool
        // nil distinguishes a legacy state-only inference from recorded source
        // HideState when an initial aligned record supplies the missing channel.
        fileprivate let recordedHiddenByComparison: Bool?
        public static func == (a:Self,b:Self) -> Bool {
            a.range == b.range && a.state == b.state && a.hiddenByComparison == b.hiddenByComparison && a.recordedHiddenByComparison == b.recordedHiddenByComparison
        }
        public init(range: Range<Int>, state: MergeSourceState, hiddenByComparison: Bool? = nil) {
            self.range = range; self.state = state
            self.recordedHiddenByComparison = hiddenByComparison
            self.hiddenByComparison = hiddenByComparison ?? state.isUnchanged
        }
    }
    public let text: String
    public let runs: [Run]
    public let foldAnchors: MergeFoldAnchors
    public let ignoredConflicts: [IgnoredMergeConflict]
    public let navigationMap: MergeNavigationMap
    public let sourceChoiceRevision: UInt64
    public static func == (a: Self, b: Self) -> Bool { a.text.utf8.elementsEqual(b.text.utf8) && a.runs == b.runs && a.foldAnchors == b.foldAnchors && a.ignoredConflicts == b.ignoredConflicts && a.navigationMap == b.navigationMap && a.sourceChoiceRevision == b.sourceChoiceRevision }
    public init(text: String, states: [MergeSourceState], hiddenByComparison: [Bool]? = nil, foldAnchors: MergeFoldAnchors = .init(), ignoredConflicts: [IgnoredMergeConflict] = [], navigationMap: MergeNavigationMap = .init()) {
        self.text = text; self.foldAnchors = foldAnchors; self.navigationMap = navigationMap; self.sourceChoiceRevision = 0
        let count = text.utf16.count, source = text as NSString
        self.ignoredConflicts = ignoredConflicts.filter { item in
            item.range.location >= 0 && item.range.length > 0 && item.range.location <= count && item.range.length <= count - item.range.location && source.substring(with:item.range).utf8.elementsEqual(item.mine.utf8)
        }.sorted { $0.range.location < $1.range.location }
        runs = Self.compact(MergeLineEndings.lineRanges(in: text).enumerated().map { index, range in
            Run(range: range.location..<NSMaxRange(range), state: states.indices.contains(index) && states[index] != .conflictedIgnored ? states[index] : .normal,
                hiddenByComparison: hiddenByComparison.flatMap { $0.indices.contains(index) ? $0[index] : nil })
        })
    }
    /// Capture the initial serialized presentation from the same source/result
    /// rows as the aligned editor. In particular, ignored common conflicts keep
    /// Hidden while ignored identical additions keep their original Shown flag.
    public init(text: String, comparison: MergeSourceComparison) {
        let flags: [Bool]?, length = text.utf16.count
        if let rows = comparison.alignedResultRows, rows.count == comparison.rows.count {
            let runs = comparison.navigationMap.entries.compactMap { entry -> Run? in
                guard !entry.sourceRows.isEmpty, entry.sourceRows.lowerBound >= 0,
                      entry.sourceRows.upperBound <= rows.count, entry.resultRange.location >= 0,
                      entry.resultRange.length > 0, entry.resultRange.location <= length,
                      entry.resultRange.length <= length - entry.resultRange.location else { return nil }
                return Run(range:entry.resultRange.location..<NSMaxRange(entry.resultRange),state:.normal,
                    hiddenByComparison:entry.sourceRows.allSatisfy { rows[$0].hiddenByComparison })
            }.sorted { $0.range.lowerBound < $1.range.lowerBound }
            flags = Self.hiddenLines(in:text,runs:runs)
        } else { flags = nil }
        self.init(text:text,states:comparison.resultLocator?.states ?? [],hiddenByComparison:flags,
            foldAnchors:.init(offsets:comparison.resultAnchors),ignoredConflicts:comparison.ignoredConflicts,navigationMap:comparison.navigationMap)
    }
    /// Serialized fallback for a result whose free edits no longer admit a
    /// checked aligned projection. Any Shown part keeps its whole line shown.
    public func hiddenByComparison() -> [Bool] { Self.hiddenLines(in:text,runs:runs) }
    private static func hiddenLines(in text:String,runs:[Run]) -> [Bool] {
        var cursor = 0
        return MergeLineEndings.lineRanges(in:text).map { line in
            while cursor < runs.count, runs[cursor].range.upperBound <= line.location { cursor += 1 }
            var index = cursor, covered = line.location, hidden = true
            while index < runs.count, runs[index].range.lowerBound < NSMaxRange(line) {
                let run = runs[index]
                if run.range.lowerBound > covered || !run.hiddenByComparison { hidden = false }
                covered = max(covered,run.range.upperBound);index += 1
            }
            return line.length > 0 && covered >= NSMaxRange(line) && hidden
        }
    }
    private init(text: String, runs: [Run], foldAnchors: MergeFoldAnchors, ignoredConflicts: [IgnoredMergeConflict], navigationMap: MergeNavigationMap, sourceChoiceRevision: UInt64) { self.sourceChoiceRevision = sourceChoiceRevision; self.navigationMap = navigationMap; self.text = text; self.runs = Self.compact(runs); self.foldAnchors = foldAnchors; self.ignoredConflicts = ignoredConflicts }
    private static func compact(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs where !run.range.isEmpty {
            if let previous = result.last, previous.state == run.state, previous.recordedHiddenByComparison == run.recordedHiddenByComparison, previous.range.upperBound == run.range.lowerBound {
                result[result.count - 1] = Run(range: previous.range.lowerBound..<run.range.upperBound, state: run.state, hiddenByComparison:run.recordedHiddenByComparison)
            } else { result.append(run) }
        }
        return result
    }
    public func replacing(_ range: NSRange, with replacement: String, state: MergeSourceState = .edited) -> Self? {
        let count = text.utf16.count
        guard range.location >= 0, range.length >= 0, range.location <= count, range.length <= count - range.location else { return nil }
        let value = NSMutableString(string: text); value.replaceCharacters(in: range, with: replacement)
        return remap(range, replacementLength: replacement.utf16.count, text: value as String, state: state)
    }
    /// Native typing can include grapheme/ending changes. Compare code units but
    /// retain the authoritative new String rather than constructing half a pair.
    public func reconciling(_ value: String, state: MergeSourceState = .edited) -> Self {
        guard !text.utf8.elementsEqual(value.utf8) else { return self }
        let old = Array(text.utf16), new = Array(value.utf16)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix, old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        return remap(NSRange(location: prefix, length: old.count - prefix - suffix), replacementLength: new.count - prefix - suffix, text: value, state: state)
    }
    private func remap(_ range: NSRange, replacementLength: Int, text value: String, state: MergeSourceState, markJoinedLine: Bool = true) -> Self {
        let end = NSMaxRange(range), delta = replacementLength - range.length
        var before: [Run] = [], after: [Run] = []
        for run in runs {
            let leftEnd = min(run.range.upperBound, range.location)
            if run.range.lowerBound < leftEnd { before.append(Run(range: run.range.lowerBound..<leftEnd, state: run.state, hiddenByComparison:run.recordedHiddenByComparison)) }
            let rightStart = max(run.range.lowerBound, end)
            if rightStart < run.range.upperBound { after.append(Run(range: rightStart + delta..<run.range.upperBound + delta, state: run.state, hiddenByComparison:run.recordedHiddenByComparison)) }
        }
        if replacementLength > 0 { before.append(Run(range: range.location..<range.location + replacementLength, state: state)) }
        var output = before + after
        if markJoinedLine, replacementLength == 0, !value.isEmpty {
            // A deletion edits the joined line even though it inserts no units.
            let point = min(range.location, value.utf16.count - 1)
            if let index = output.firstIndex(where: { $0.range.contains(point) }) {
                let run = output.remove(at: index)
                var parts: [Run] = []
                if run.range.lowerBound < point { parts.append(Run(range: run.range.lowerBound..<point, state: run.state, hiddenByComparison:run.recordedHiddenByComparison)) }
                parts.append(Run(range: point..<point + 1, state: state))
                if point + 1 < run.range.upperBound { parts.append(Run(range: point + 1..<run.range.upperBound, state: run.state, hiddenByComparison:run.recordedHiddenByComparison)) }
                output.insert(contentsOf: parts, at: index)
            }
        }
        var anchors = foldAnchors; anchors.reconcile(old: text, new: value)
        let remaining = ignoredConflicts.compactMap { item -> IgnoredMergeConflict? in
            let touched = range.length == 0 ? (range.location >= item.range.location && (range.location < NSMaxRange(item.range) || range.location == NSMaxRange(item.range) && !MergeLineEndings.hasFinalEnding(item.mine))) : NSIntersectionRange(range,item.range).length > 0
            if touched { return nil }
            return item.range.location >= end ? item.shifted(by:delta) : item
        }
        return Self(text: value, runs: output, foldAnchors: anchors, ignoredConflicts:remaining, navigationMap:navigationMap.replacing(range,replacementLength:replacementLength),sourceChoiceRevision:sourceChoiceRevision)
    }
    /// Source navigation groups adjacent ignored lines; marker conflicts keep
    /// their normal parsing and original EOF/separator rules.
    public func conflicts(document:TextConflictDocument? = nil) -> [MergeConflictBlock] {
        let markers = MergeText.conflicts(in:text,document:document)
        var ignored: [IgnoredMergeConflict] = []
        for item in ignoredConflicts where !markers.contains(where:{ NSIntersectionRange($0.range,item.range).length > 0 }) {
            if let last = ignored.last, NSMaxRange(last.range) == item.range.location {
                ignored[ignored.count - 1] = .init(range:NSRange(location:last.range.location,length:last.range.length + item.range.length),mine:last.mine + item.mine,base:last.base + item.base,theirs:last.theirs + item.theirs)
            } else { ignored.append(item) }
        }
        let ending = MergeLineEndings.predominantStyle(in:text).rawValue
        let blocks = markers + ignored.map { item in
            MergeConflictBlock(id:0,range:item.range,mine:item.mine,base:item.base,theirs:item.theirs,joiningLineEnding:ending,mineNeedsSeparator:!item.mine.isEmpty && !MergeLineEndings.hasFinalEnding(item.mine),theirsNeedsSeparator:!item.theirs.isEmpty && !MergeLineEndings.hasFinalEnding(item.theirs),isIgnored:true)
        }
        return blocks.sorted { $0.range.location < $1.range.location }.enumerated().map { $0.element.identified($0.offset) }
    }
    public func states(conflicts: [NSRange]) -> [MergeSourceState] {
        let conflicts = conflicts.sorted { $0.location < $1.location }
        var cursor = 0, conflict = 0, ignored = 0
        return MergeLineEndings.lineRanges(in: text).map { line in
            while conflict < conflicts.count, NSMaxRange(conflicts[conflict]) <= line.location { conflict += 1 }
            while ignored < ignoredConflicts.count, NSMaxRange(ignoredConflicts[ignored].range) <= line.location { ignored += 1 }
            if ignored < ignoredConflicts.count, NSIntersectionRange(line,ignoredConflicts[ignored].range).length > 0 { return .conflictedIgnored }
            if conflict < conflicts.count, NSIntersectionRange(line, conflicts[conflict]).length > 0 { return .conflicted }
            while cursor < runs.count, runs[cursor].range.upperBound <= line.location { cursor += 1 }
            var index = cursor, value: MergeSourceState = .normal
            while index < runs.count, runs[index].range.lowerBound < NSMaxRange(line) {
                let state = runs[index].state
                if state == .edited { value = .edited; break }
                if state == .resolved || value == .normal { value = state }
                index += 1
            }
            return value
        }
    }
}


/// A source block replacement is a value snapshot, including its result text.
/// The native owner additionally fences the source generation and modal state.
public struct MergeSourceBlockEdit: Sendable {
    public let sourceRows: Range<Int>
    public let range: NSRange
    public let replacement: String
    public let expectedText: String
    public let runs: [MergeResultPresentation.Run]
    public let replacementEntries: [MergeNavigationMap.Entry]?
    public init?(comparison: MergeSourceComparison, presentation: MergeResultPresentation,
                 rows: Range<Int>, choice: MergeBlockChoice) {
        guard !rows.isEmpty, rows.lowerBound >= 0, rows.upperBound <= comparison.rows.count,
              let range = presentation.navigationMap.exactResultRange(sourceRows:rows),
              range.location >= 0, NSMaxRange(range) <= presentation.text.utf16.count else { return nil }
        let ending = MergeLineEndings.predominantStyle(in:presentation.text).rawValue
        func payload(mine: Bool, normalize: Bool) -> (String, [MergeResultPresentation.Run], [MergeNavigationMap.Entry]) {
            var value = "", runs: [MergeResultPresentation.Run] = [], entries: [MergeNavigationMap.Entry] = [], offset = 0
            for row in rows {
                let cell = mine ? comparison.rows[row].mine : comparison.rows[row].theirs
                // BaseView::SaveFile excludes removed and empty view records;
                // ResolveState makes ConflictAdded writable, not ConflictEmpty.
                guard !cell.state.isExcludedFromResult else {
                    entries.append(.init(sourceRows:row..<(row + 1),resultRange:NSRange(location:range.location + offset,length:0))); continue
                }
                var line = cell.text
                if normalize {
                    line = cell.displayText
                    if MergeLineEndings.hasFinalEnding(cell.text) || row < comparison.rows.count - 1 { line += ending }
                }
                let length = line.utf16.count
                if length > 0 { runs.append(.init(range:offset..<(offset + length),state:cell.state.isConflict ? .resolved : cell.state,hiddenByComparison:cell.hiddenByComparison)) }
                entries.append(.init(sourceRows:row..<(row + 1),resultRange:NSRange(location:range.location + offset,length:length)))
                value += line; offset += length
            }
            return (value, runs, entries)
        }
        func joined(_ first: (String,[MergeResultPresentation.Run],[MergeNavigationMap.Entry]), _ second: (String,[MergeResultPresentation.Run],[MergeNavigationMap.Entry])) -> (String,[MergeResultPresentation.Run],[MergeNavigationMap.Entry]?) {
            let offset = first.0.utf16.count
            return (first.0 + second.0, first.1 + second.1.map { .init(range:($0.range.lowerBound + offset)..<($0.range.upperBound + offset),state:$0.state,hiddenByComparison:$0.recordedHiddenByComparison) },nil)
        }
        let text: (String,[MergeResultPresentation.Run],[MergeNavigationMap.Entry]?)
        switch choice {
        case .mine: text = payload(mine:true,normalize:true)
        case .theirs: text = payload(mine:false,normalize:true)
        case .mineThenTheirs: text = joined(payload(mine:true,normalize:true),payload(mine:false,normalize:false))
        case .theirsThenMine: text = joined(payload(mine:false,normalize:true),payload(mine:true,normalize:false))
        }
        sourceRows = rows; self.range = range; replacement = text.0; runs = text.1; replacementEntries = text.2; expectedText = presentation.text
    }
}

extension MergeResultPresentation {
    public func applyingSourceBlock(_ edit: MergeSourceBlockEdit) -> Self? {
        guard text.utf8.elementsEqual(edit.expectedText.utf8),
              navigationMap.exactResultRange(sourceRows:edit.sourceRows) == edit.range,
              let map = navigationMap.applyingSourceRows(edit.sourceRows,replacementLength:edit.replacement.utf16.count,replacementEntries:edit.replacementEntries),
              edit.range.location >= 0, NSMaxRange(edit.range) <= text.utf16.count else { return nil }
        let value = (text as NSString).replacingCharacters(in:edit.range,with:edit.replacement)
        let next = remap(edit.range,replacementLength:edit.replacement.utf16.count,text:value,state:.resolved,markJoinedLine:false)
        let inserted = NSRange(location:edit.range.location,length:edit.replacement.utf16.count)
        var runs: [Run] = []
        for run in next.runs {
            if run.range.lowerBound < inserted.location { runs.append(.init(range:run.range.lowerBound..<min(run.range.upperBound,inserted.location),state:run.state,hiddenByComparison:run.recordedHiddenByComparison)) }
            if run.range.upperBound > NSMaxRange(inserted) { runs.append(.init(range:max(run.range.lowerBound,NSMaxRange(inserted))..<run.range.upperBound,state:run.state,hiddenByComparison:run.recordedHiddenByComparison)) }
        }
        runs += edit.runs.map { .init(range:($0.range.lowerBound + inserted.location)..<($0.range.upperBound + inserted.location),state:$0.state,hiddenByComparison:$0.recordedHiddenByComparison) }
        return Self(text:next.text,runs:runs.sorted { $0.range.lowerBound < $1.range.lowerBound },foldAnchors:next.foldAnchors,ignoredConflicts:next.ignoredConflicts,navigationMap:map,sourceChoiceRevision:sourceChoiceRevision &+ 1)
    }
}

/// Result view records share source-row coordinates; serialized marker lines
/// are ranges, not extra aligned records. A mapping invalidated by free editing
/// refuses this projection instead of inventing correspondences.
public struct MergeAlignedResultProjection: Sendable {
    public let cells: [MergeSourceCell]
    public let serializedRanges: [NSRange]
    public init?(comparison: MergeSourceComparison, presentation: MergeResultPresentation) {
        guard let initial = comparison.alignedResultRows, initial.count == comparison.rows.count else { return nil }
        let source = presentation.text as NSString, conflicts = presentation.conflicts()
        var cells: [MergeSourceCell] = [], ranges: [NSRange] = [], expected = 0, serializedEnd = 0, number = 0, runIndex = 0
        func append(_ text: String, state: MergeSourceState, range: NSRange, hidden: Bool? = nil) {
            let numbered = !state.isExcludedFromResult
            if numbered { number += 1 }
            cells.append(.init(text:text,lineNumber:numbered ? number : nil,state:state,hiddenByComparison:hidden)); ranges.append(range)
        }
        for entry in presentation.navigationMap.entries.sorted(by: { $0.sourceRows.lowerBound < $1.sourceRows.lowerBound }) {
            guard entry.sourceRows.lowerBound == expected, !entry.sourceRows.isEmpty, entry.sourceRows.upperBound <= initial.count,
                  entry.resultRange.location == serializedEnd, NSMaxRange(entry.resultRange) <= source.length else { return nil }
            expected = entry.sourceRows.upperBound
            serializedEnd = NSMaxRange(entry.resultRange)
            let conflict = conflicts.first { !$0.isIgnored && NSIntersectionRange($0.range,entry.resultRange).length > 0 }
            if let conflict {
                guard entry.sourceRows.contains(where: { initial[$0].state == .conflicted }) else { return nil }
                for row in entry.sourceRows {
                    let cell = initial[row]
                    if cell.state.isRemoval { append(cell.text,state:cell.state,range:NSRange(location:entry.resultRange.location,length:0),hidden:cell.hiddenByComparison) }
                    else { append("",state:.conflicted,range:conflict.range,hidden:cell.hiddenByComparison) }
                }
            } else if entry.resultRange.length == 0 {
                for row in entry.sourceRows {
                    let original = initial[row]
                    let retained = original.state.isRemoval || original.state == .resolvedEmpty || [MergeSourceState.normal,.filtered,.edited,.resolved].contains(original.state) && original.lineNumber != nil && original.text.isEmpty
                    append(retained ? original.text : "",state:retained ? original.state : .empty,range:entry.resultRange,hidden:retained ? original.hiddenByComparison : false)
                }
            } else {
                // A multi-row/multi-copy group needs a complete view mutation
                // model. Single-side choices retain per-row entries below.
                guard entry.sourceRows.count == 1 else { return nil }
                let payload = source.substring(with:entry.resultRange)
                guard MergeLineEndings.lineRanges(in:payload).count == 1 else { return nil }
                while runIndex < presentation.runs.count, presentation.runs[runIndex].range.upperBound <= entry.resultRange.location { runIndex += 1 }
                var state = runIndex < presentation.runs.count ? presentation.runs[runIndex].state : .normal
                var cursor = runIndex, covered = entry.resultRange.location, hidden = true, hasRecordedHide = false
                while cursor < presentation.runs.count, presentation.runs[cursor].range.lowerBound < NSMaxRange(entry.resultRange) {
                    let run = presentation.runs[cursor], current = run.state
                    hasRecordedHide = hasRecordedHide || run.recordedHiddenByComparison != nil
                    if run.range.lowerBound > covered || !run.hiddenByComparison { hidden = false }
                    covered = max(covered,run.range.upperBound)
                    if current == .edited { state = .edited }
                    else if state != .edited && (current == .resolved || state == .normal) { state = current }
                    cursor += 1
                }
                if covered < NSMaxRange(entry.resultRange) { hidden = false }
                if presentation.ignoredConflicts.contains(where: { NSIntersectionRange($0.range,entry.resultRange).length > 0 }) { state = .conflictedIgnored }
                let original = initial[entry.sourceRows.lowerBound]
                if !hasRecordedHide, state == original.state, state != .edited && state != .resolved,
                   payload.utf8.elementsEqual(original.text.utf8) {
                    // Older callers may have created their serialized runs from
                    // states alone. An untouched aligned view record remains
                    // authoritative for its independent initial HideState.
                    hidden = original.hiddenByComparison
                }
                append(payload,state:state,range:entry.resultRange,hidden:hidden)
            }
        }
        guard expected == initial.count, serializedEnd == source.length else { return nil }
        self.cells = cells; serializedRanges = ranges
    }
    public func sourceRows(intersecting range: NSRange) -> Set<Int> {
        Set(serializedRanges.indices.filter {
            let current = serializedRanges[$0]
            return current.length > 0 && (range.length == 0 ? NSLocationInRange(range.location,current) : NSIntersectionRange(range,current).length > 0)
        })
    }
    public func sourceRows(serializedRows: Set<Int>, text: String) -> Set<Int> {
        let lines = MergeLineEndings.lineRanges(in:text)
        return serializedRows.reduce(into:Set<Int>()) { result,row in
            if lines.indices.contains(row) { result.formUnion(sourceRows(intersecting:lines[row])) }
        }
    }
}

extension MergeAlignedResultProjection {
    public var displayText: String { cells.map { $0.displayText + "\n" }.joined() }
    public var displayRanges: [NSRange] {
        var offset = 0
        return cells.map { cell in
            defer { offset += cell.displayText.utf16.count + 1 }
            return NSRange(location:offset,length:cell.displayText.utf16.count + 1)
        }
    }
    /// Navigation/choice coordinates only; typing edits view records directly.
    public func serializedRange(displayRange range: NSRange) -> NSRange? {
        let display = displayRanges
        guard let first = display.lastIndex(where: { $0.location <= range.location }),
              NSMaxRange(range) <= displayText.utf16.count else { return nil }
        let end = range.length == 0 ? range.location : NSMaxRange(range) - 1
        let last = display.lastIndex(where: { $0.location <= end }) ?? first
        let a = serializedRanges[first], b = serializedRanges[last]
        func offset(_ row:Int,_ location:Int) -> Int {
            let raw = serializedRanges[row]
            if cells[row].state == .conflicted { return raw.location }
            return raw.location + min(raw.length,min(cells[row].displayText.utf16.count,max(0,location - display[row].location)))
        }
        if range.length == 0 { return NSRange(location:offset(first,range.location),length:0) }
        let start = cells[first].state == .conflicted ? a.location : offset(first,range.location)
        let finish = cells[last].state == .conflicted ? NSMaxRange(b) : NSMaxRange(range) >= NSMaxRange(display[last]) ? NSMaxRange(b) : offset(last,NSMaxRange(range))
        return NSRange(location:start,length:max(0,finish - start))
    }
    public func displayRange(serializedRange range: NSRange) -> NSRange? {
        let display = displayRanges
        let rows = sourceRows(intersecting:range)
        guard let first = rows.min(), let last = rows.max() else {
            guard let row = serializedRanges.lastIndex(where: { $0.location <= range.location }) else { return nil }
            return NSRange(location:display[row].location + min(cells[row].displayText.utf16.count,max(0,range.location - serializedRanges[row].location)),length:0)
        }
        if cells[first].state == .conflicted || cells[last].state == .conflicted {
            return NSRange(location:display[first].location,length:NSMaxRange(display[last]) - display[first].location)
        }
        let start = display[first].location + min(cells[first].displayText.utf16.count,max(0,range.location - serializedRanges[first].location))
        let end = display[last].location + min(cells[last].displayText.utf16.count,max(0,NSMaxRange(range) - serializedRanges[last].location))
        return NSRange(location:start,length:max(0,end - start))
    }
}

/// Immutable all-pane edit, following BaseView's in-place view data editing.
/// Removed records stay visible, new result lines insert source gaps, and marker
/// serialization is independent of displayed blank conflict slots.
public struct MergeAlignedResultEdit: Sendable {
    public let comparison: MergeSourceComparison
    public let presentation: MergeResultPresentation
    public let displayCaret: Int
    public init(comparison:MergeSourceComparison,presentation:MergeResultPresentation,range:NSRange,replacement:String,lineEnding:MergeLineEnding? = nil) throws {
        guard let projection = MergeAlignedResultProjection(comparison:comparison,presentation:presentation) else { throw FileComparisonEditFailure.range }
        // A nonempty peer retains every existing source coordinate. Cleanup of
        // rows empty in all three panes is a separate view operation.
        let peer = MergeSourceCell(text:"",lineNumber:1,state:.normal)
        let alignment = FileComparisonAlignment(rows:projection.cells.map { .init(base:peer,destination:$0) },differences:[])
        let edit = try FileComparisonInPlaceEdit(alignment:alignment,base:false,range:range,replacement:replacement,lineEnding:lineEnding)
        let cells = edit.alignment.rows.map(\.destination)
        let gap = MergeSourceCell(text:"",lineNumber:nil,state:.empty)
        var sources = comparison.rows
        if sources.isEmpty { sources = [.init(mine:gap,theirs:gap)] }
        let extra = cells.count - sources.count
        if extra > 0 { sources.insert(contentsOf:Array(repeating:.init(mine:gap,theirs:gap),count:extra),at:edit.replacedRows.upperBound) }
        guard sources.count == cells.count else { throw FileComparisonEditFailure.range }
        func originalRow(_ row:Int) -> Int? {
            if row < edit.replacedRows.upperBound { return row }
            if row < edit.replacedRows.upperBound + max(0,extra) { return nil }
            return row - max(0,extra)
        }
        let origins = cells.indices.map(originalRow)
        let snapshot = try MergeAlignedResultSnapshot(sources:sources,cells:cells,origins:origins,comparison:comparison,presentation:presentation)
        self.presentation = snapshot.presentation; self.comparison = snapshot.comparison
        var caret = edit.displayCaret, offset = 0
        let retained = Set(snapshot.retainedIndices)
        for (row,cell) in cells.enumerated() {
            let length = cell.displayText.utf16.count + 1
            if !retained.contains(row), offset < edit.displayCaret { caret -= min(length,edit.displayCaret - offset) }
            offset += length
        }
        displayCaret = max(0,caret)
    }
}

/// One serialization path for typing and source block commands. The complete
/// geometry and byte provenance form a single immutable Undo snapshot.
private struct MergeAlignedResultSnapshot {
    let comparison:MergeSourceComparison
    let presentation:MergeResultPresentation
    let retainedIndices:[Int]
    init(sources incomingSources:[MergeSourceRow],cells incomingCells:[MergeSourceCell],origins incomingOrigins:[Int?],comparison:MergeSourceComparison,presentation:MergeResultPresentation) throws {
        guard incomingSources.count == incomingCells.count, incomingOrigins.count == incomingCells.count,
              let projection = MergeAlignedResultProjection(comparison:comparison,presentation:presentation) else { throw FileComparisonEditFailure.range }
        retainedIndices = incomingCells.indices.filter { row in
            !(incomingSources[row].mine.state.isViewEmpty && incomingSources[row].theirs.state.isViewEmpty && incomingCells[row].state.isViewEmpty)
        }
        let sources = retainedIndices.map { incomingSources[$0] }, origins = retainedIndices.map { incomingOrigins[$0] }
        var number = 0
        let cells = retainedIndices.map { index -> MergeSourceCell in
            let cell = incomingCells[index], numbered = !cell.state.isExcludedFromResult
            if numbered { number += 1 }
            return .init(text:cell.text,lineNumber:numbered ? number : nil,state:cell.state,hiddenByComparison:cell.hiddenByComparison)
        }
        let originalConflicts = presentation.conflicts().filter { !$0.isIgnored }
        let raw = presentation.text as NSString
        var text = "", entries:[MergeNavigationMap.Entry] = [], runs:[MergeResultPresentation.Run] = [], ignored:[IgnoredMergeConflict] = [], row = 0
        func append(_ value:String,state:MergeSourceState,hidden:Bool? = nil) {
            let start = text.utf16.count
            text += value
            if !value.isEmpty { runs.append(.init(range:start..<text.utf16.count,state:state,hiddenByComparison:hidden)) }
        }
        while row < cells.count {
            let cell = cells[row], start = text.utf16.count
            if cell.state == .conflicted {
                let first = row
                while row < cells.count && cells[row].state == .conflicted { row += 1 }
                let oldRows = (first..<row).compactMap { origins[$0] }
                let retained = originalConflicts.first { block in
                    let original = projection.sourceRows(intersecting:block.range).sorted()
                    return original == oldRows && original.count == row - first
                }
                let value:String
                if let retained { value = raw.substring(with:retained.range) }
                else {
                    func payload(_ mine:Bool) -> String {
                        (first..<row).map { mine ? sources[$0].mine : sources[$0].theirs }.filter { !$0.state.isExcludedFromResult }.map(\.text).joined()
                    }
                    func separated(_ value:String) -> String { value.isEmpty || MergeLineEndings.hasFinalEnding(value) ? value : value + "\n" }
                    value = "<<<<<<< Mine\n" + separated(payload(true)) + "=======\n" + separated(payload(false)) + ">>>>>>> Theirs\n"
                }
                let location = text.utf16.count
                if !text.isEmpty && !MergeLineEndings.hasFinalEnding(text) { append("\n",state:.edited) }
                append(value,state:.conflicted)
                entries.append(.init(sourceRows:first..<row,resultRange:NSRange(location:location,length:text.utf16.count - location)))
            } else {
                let included = !cell.state.isExcludedFromResult
                let payload = included ? cell.text : ""
                append(payload,state:cell.state,hidden:cell.hiddenByComparison)
                let target = NSRange(location:start,length:payload.utf16.count)
                entries.append(.init(sourceRows:row..<(row + 1),resultRange:target))
                if cell.state == .conflictedIgnored, let old = origins[row], projection.serializedRanges.indices.contains(old),
                   let metadata = presentation.ignoredConflicts.first(where: { $0.range == projection.serializedRanges[old] }) {
                    ignored.append(.init(range:target,mine:payload,base:metadata.base,theirs:metadata.theirs))
                }
                row += 1
            }
        }
        let map = MergeNavigationMap(entries:entries)
        self.presentation = presentation.installingAlignedText(text,runs:runs,ignored:ignored,map:map)
        self.comparison = .init(rows:sources,navigationMap:map,alignedResultRows:cells)
    }
}

/// BottomView::UseBlock/UseBothBlocks mutate result records and both source
/// layouts. In a both-order copy each source keeps its own original payload and
/// receives a gap opposite the other source's block.
public struct MergeAlignedSourceBlockEdit: Sendable {
    public let comparison:MergeSourceComparison
    public let presentation:MergeResultPresentation
    public let selectedRows:Range<Int>
    /// UseViewFile replaces every result record, so it needs no correspondence
    /// with a freely edited/externally loaded result. Rebuild all result ranges
    /// directly from the captured source view, retaining removed/gap records.
    public init(wholeFileFrom comparison: MergeSourceComparison, presentation: MergeResultPresentation, mine: Bool, lineEnding: MergeLineEnding) {
        var sources: [MergeSourceRow] = [], cells: [MergeSourceCell] = []
        var entries: [MergeNavigationMap.Entry] = [], runs: [MergeResultPresentation.Run] = []
        var text = "", number = 0
        for (index, row) in comparison.rows.enumerated() {
            let source = mine ? row.mine : row.theirs
            let resolved = Self.resolved(source, row: index, count: comparison.rows.count, ending: lineEnding.rawValue, normalize: true)
            if row.mine.state.isViewEmpty && row.theirs.state.isViewEmpty && resolved.state.isViewEmpty { continue }
            let included = !resolved.state.isExcludedFromResult, start = text.utf16.count, position = cells.count
            if included { number += 1; text += resolved.text }
            cells.append(.init(text: resolved.text, lineNumber: included ? number : nil, state: resolved.state, hiddenByComparison: resolved.hiddenByComparison))
            sources.append(row)
            entries.append(.init(sourceRows: position..<(position + 1), resultRange: NSRange(location: start, length: text.utf16.count - start)))
            if text.utf16.count > start { runs.append(.init(range: start..<text.utf16.count, state: resolved.state, hiddenByComparison: resolved.hiddenByComparison)) }
        }
        let map = MergeNavigationMap(entries: entries)
        self.comparison = .init(rows: sources, navigationMap: map, alignedResultRows: cells)
        self.presentation = presentation.installingAlignedText(text, runs: runs, ignored: [], map: map)
        selectedRows = cells.indices
    }
    private static func resolved(_ cell: MergeSourceCell, row: Int, count: Int, ending: String, normalize: Bool) -> MergeSourceCell {
        var text = cell.text
        if normalize, MergeLineEndings.hasFinalEnding(text) || row < count - 1 && cell.state != .conflictEmpty && cell.state != .identicalRemoved {
            text = cell.displayText + ending
        }
        return .init(text: text, lineNumber: cell.lineNumber, state: cell.state.resolvedState, hiddenByComparison:cell.hiddenByComparison)
    }
    public init(comparison:MergeSourceComparison,presentation:MergeResultPresentation,rows:Range<Int>,choice:MergeBlockChoice,lineEnding:MergeLineEnding? = nil) throws {
        guard !rows.isEmpty, rows.lowerBound >= 0, rows.upperBound <= comparison.rows.count,
              let projection = MergeAlignedResultProjection(comparison:comparison,presentation:presentation) else { throw FileComparisonEditFailure.range }
        let firstMine = choice == .mine || choice == .mineThenTheirs
        let both = choice == .mineThenTheirs || choice == .theirsThenMine
        let writable = projection.cells.filter { !$0.state.isExcludedFromResult && $0.state != .conflicted }.map(\.text).joined()
        let reference = MergeLineEndings.styles(in:writable).isEmpty ? comparison.rows.map(\.mine).filter(\.hasSourceCoordinate).map(\.text).joined() : writable
        let ending = (lineEnding ?? MergeLineEndings.predominantStyle(in:reference)).rawValue
        let gap = MergeSourceCell(text:"",lineNumber:nil,state:.empty)
        func original(_ row:Int,mine:Bool) -> MergeSourceCell { mine ? comparison.rows[row].mine : comparison.rows[row].theirs }
        func source(_ cell:MergeSourceCell,state:MergeSourceState) -> MergeSourceCell {
            .init(text:cell.text,lineNumber:cell.lineNumber,state:cell.state.isViewEmpty ? cell.state : state,hiddenByComparison:cell.hiddenByComparison)
        }
        var cells = projection.cells, sources = comparison.rows, origins:[Int?] = comparison.rows.indices.map { $0 }
        let firstCells = rows.map { Self.resolved(original($0,mine:firstMine),row:$0,count:comparison.rows.count,ending:ending,normalize:true) }
        if both {
            let secondCells = rows.map { Self.resolved(original($0,mine:!firstMine),row:$0,count:comparison.rows.count,ending:ending,normalize:false) }
            let firstSources = rows.map { row -> MergeSourceRow in
                let cell = source(original(row,mine:firstMine),state:.yoursAdded)
                return firstMine ? .init(mine:cell,theirs:gap) : .init(mine:gap,theirs:cell)
            }
            let secondSources = rows.map { row -> MergeSourceRow in
                let cell = source(original(row,mine:!firstMine),state:.theirsAdded)
                return firstMine ? .init(mine:gap,theirs:cell) : .init(mine:cell,theirs:gap)
            }
            cells.replaceSubrange(rows,with:firstCells + secondCells)
            sources.replaceSubrange(rows,with:firstSources + secondSources)
            origins.replaceSubrange(rows,with:Array(rows).map { Optional($0) } + Array(rows).map { Optional($0) })
        } else { cells.replaceSubrange(rows,with:firstCells) }
        // Source deliberately scans only indices > 0 here.
        if rows.lowerBound > 1, let previous = cells[..<rows.lowerBound].lastIndex(where: {
            !$0.state.isViewEmpty && (both || $0.state != .identicalRemoved)
        }), previous > 0, !MergeLineEndings.hasFinalEnding(cells[previous].text) {
            let cell = cells[previous]
            cells[previous] = .init(text:cell.text + ending,lineNumber:cell.lineNumber,state:cell.state,hiddenByComparison:cell.hiddenByComparison)
        }
        let snapshot = try MergeAlignedResultSnapshot(sources:sources,cells:cells,origins:origins,comparison:comparison,presentation:presentation)
        self.comparison = snapshot.comparison; self.presentation = snapshot.presentation
        let replaced = rows.lowerBound..<(rows.upperBound + (both ? rows.count : 0))
        let selected = snapshot.retainedIndices.enumerated().filter { replaced.contains($0.element) }.map(\.offset)
        let start = selected.first ?? snapshot.retainedIndices.filter { $0 < rows.lowerBound }.count
        selectedRows = start..<(selected.last.map { $0 + 1 } ?? start)
    }
}

/// BaseView's whole-view format commands change record payload/endings without
/// resolving conflicts, changing row states or serializing removed records.
public struct MergeAlignedResultTransform: Sendable {
    public enum Operation:Sendable { case lineEndings(MergeLineEnding), cycleLineEnding(row:Int), whitespace(MergeWhitespaceCommand,tabWidth:Int) }
    public let comparison:MergeSourceComparison
    public let presentation:MergeResultPresentation
    public let changedRows:Set<Int>
    public init(comparison:MergeSourceComparison,presentation:MergeResultPresentation,operation:Operation) throws {
        guard let projection = MergeAlignedResultProjection(comparison:comparison,presentation:presentation) else { throw FileComparisonEditFailure.range }
        var changed = Set<Int>()
        let cells = projection.cells.enumerated().map { row,cell -> MergeSourceCell in
            guard !cell.state.isViewEmpty else { return cell }
            let text:String
            switch operation {
            case .lineEndings(let ending):
                text = MergeLineEndings.hasFinalEnding(cell.text) ? cell.displayText + ending.rawValue : cell.text
            case .cycleLineEnding(let target): text = row == target ? MergeTyping.cycledLine(cell.text) ?? cell.text : cell.text
            case .whitespace(let command,let width): text = MergeWhitespace.applying(command,to:cell.text,tabWidth:width)
            }
            guard !text.utf8.elementsEqual(cell.text.utf8) else { return cell }
            changed.insert(row)
            let state:MergeSourceState
            if case .cycleLineEnding = operation { state = .edited } else { state = cell.state }
            return .init(text:text,lineNumber:cell.lineNumber,state:state,hiddenByComparison:cell.hiddenByComparison)
        }
        changedRows = changed
        if changed.isEmpty { self.comparison = comparison; self.presentation = presentation }
        else {
            let snapshot = try MergeAlignedResultSnapshot(sources:comparison.rows,cells:cells,origins:cells.indices.map { $0 },comparison:comparison,presentation:presentation)
            self.comparison = snapshot.comparison; self.presentation = snapshot.presentation
        }
    }
}

extension MergeResultPresentation {
    fileprivate func installingAlignedText(_ text:String,runs:[Run],ignored:[IgnoredMergeConflict],map:MergeNavigationMap) -> Self {
        Self(text:text,runs:runs,foldAnchors:.init(),ignoredConflicts:ignored,navigationMap:map,sourceChoiceRevision:sourceChoiceRevision &+ 1)
    }
}
