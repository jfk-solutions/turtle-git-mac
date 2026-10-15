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
    }
    public let text: String
    public let runs: [Run]
    public let foldAnchors: MergeFoldAnchors
    public let ignoredConflicts: [IgnoredMergeConflict]
    public let navigationMap: MergeNavigationMap
    public let sourceChoiceRevision: UInt64
    public static func == (a: Self, b: Self) -> Bool { a.text.utf8.elementsEqual(b.text.utf8) && a.runs == b.runs && a.foldAnchors == b.foldAnchors && a.ignoredConflicts == b.ignoredConflicts && a.navigationMap == b.navigationMap && a.sourceChoiceRevision == b.sourceChoiceRevision }
    public init(text: String, states: [MergeSourceState], foldAnchors: MergeFoldAnchors = .init(), ignoredConflicts: [IgnoredMergeConflict] = [], navigationMap: MergeNavigationMap = .init()) {
        self.text = text; self.foldAnchors = foldAnchors; self.navigationMap = navigationMap; self.sourceChoiceRevision = 0
        let count = text.utf16.count, source = text as NSString
        self.ignoredConflicts = ignoredConflicts.filter { item in
            item.range.location >= 0 && item.range.length > 0 && item.range.location <= count && item.range.length <= count - item.range.location && source.substring(with:item.range).utf8.elementsEqual(item.mine.utf8)
        }.sorted { $0.range.location < $1.range.location }
        runs = Self.compact(MergeLineEndings.lineRanges(in: text).enumerated().map { index, range in
            Run(range: range.location..<NSMaxRange(range), state: states.indices.contains(index) && states[index] != .conflictedIgnored ? states[index] : .normal)
        })
    }
    private init(text: String, runs: [Run], foldAnchors: MergeFoldAnchors, ignoredConflicts: [IgnoredMergeConflict], navigationMap: MergeNavigationMap, sourceChoiceRevision: UInt64) { self.sourceChoiceRevision = sourceChoiceRevision; self.navigationMap = navigationMap; self.text = text; self.runs = Self.compact(runs); self.foldAnchors = foldAnchors; self.ignoredConflicts = ignoredConflicts }
    private static func compact(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs where !run.range.isEmpty {
            if let previous = result.last, previous.state == run.state, previous.range.upperBound == run.range.lowerBound {
                result[result.count - 1] = Run(range: previous.range.lowerBound..<run.range.upperBound, state: run.state)
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
            if run.range.lowerBound < leftEnd { before.append(Run(range: run.range.lowerBound..<leftEnd, state: run.state)) }
            let rightStart = max(run.range.lowerBound, end)
            if rightStart < run.range.upperBound { after.append(Run(range: rightStart + delta..<run.range.upperBound + delta, state: run.state)) }
        }
        if replacementLength > 0 { before.append(Run(range: range.location..<range.location + replacementLength, state: state)) }
        var output = before + after
        if markJoinedLine, replacementLength == 0, !value.isEmpty {
            // A deletion edits the joined line even though it inserts no units.
            let point = min(range.location, value.utf16.count - 1)
            if let index = output.firstIndex(where: { $0.range.contains(point) }) {
                let run = output.remove(at: index)
                var parts: [Run] = []
                if run.range.lowerBound < point { parts.append(Run(range: run.range.lowerBound..<point, state: run.state)) }
                parts.append(Run(range: point..<point + 1, state: state))
                if point + 1 < run.range.upperBound { parts.append(Run(range: point + 1..<run.range.upperBound, state: run.state)) }
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
                guard !cell.state.isRemoval, cell.state != .empty, cell.state != .conflictEmpty else {
                    entries.append(.init(sourceRows:row..<(row + 1),resultRange:NSRange(location:range.location + offset,length:0))); continue
                }
                var line = cell.text
                if normalize {
                    line = cell.displayText
                    if MergeLineEndings.hasFinalEnding(cell.text) || row < comparison.rows.count - 1 { line += ending }
                }
                let length = line.utf16.count
                if length > 0 { runs.append(.init(range:offset..<(offset + length),state:cell.state.isConflict ? .resolved : cell.state)) }
                entries.append(.init(sourceRows:row..<(row + 1),resultRange:NSRange(location:range.location + offset,length:length)))
                value += line; offset += length
            }
            return (value, runs, entries)
        }
        func joined(_ first: (String,[MergeResultPresentation.Run],[MergeNavigationMap.Entry]), _ second: (String,[MergeResultPresentation.Run],[MergeNavigationMap.Entry])) -> (String,[MergeResultPresentation.Run],[MergeNavigationMap.Entry]?) {
            let offset = first.0.utf16.count
            return (first.0 + second.0, first.1 + second.1.map { .init(range:($0.range.lowerBound + offset)..<($0.range.upperBound + offset),state:$0.state) },nil)
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
            if run.range.lowerBound < inserted.location { runs.append(.init(range:run.range.lowerBound..<min(run.range.upperBound,inserted.location),state:run.state)) }
            if run.range.upperBound > NSMaxRange(inserted) { runs.append(.init(range:max(run.range.lowerBound,NSMaxRange(inserted))..<run.range.upperBound,state:run.state)) }
        }
        runs += edit.runs.map { .init(range:($0.range.lowerBound + inserted.location)..<($0.range.upperBound + inserted.location),state:$0.state) }
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
        func append(_ text: String, state: MergeSourceState, range: NSRange) {
            let numbered = !state.isRemoval && state != .empty && state != .conflictEmpty
            if numbered { number += 1 }
            cells.append(.init(text:text,lineNumber:numbered ? number : nil,state:state)); ranges.append(range)
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
                    if cell.state.isRemoval { append(cell.text,state:cell.state,range:NSRange(location:entry.resultRange.location,length:0)) }
                    else { append("",state:.conflicted,range:conflict.range) }
                }
            } else if entry.resultRange.length == 0 {
                for row in entry.sourceRows {
                    let original = initial[row]
                    append(original.state.isRemoval ? original.text : "",state:original.state.isRemoval ? original.state : .empty,range:entry.resultRange)
                }
            } else {
                // A multi-row/multi-copy group needs a complete view mutation
                // model. Single-side choices retain per-row entries below.
                guard entry.sourceRows.count == 1 else { return nil }
                let payload = source.substring(with:entry.resultRange)
                guard MergeLineEndings.lineRanges(in:payload).count == 1 else { return nil }
                while runIndex < presentation.runs.count, presentation.runs[runIndex].range.upperBound <= entry.resultRange.location { runIndex += 1 }
                var state = runIndex < presentation.runs.count ? presentation.runs[runIndex].state : .normal
                var cursor = runIndex
                while cursor < presentation.runs.count, presentation.runs[cursor].range.lowerBound < NSMaxRange(entry.resultRange) {
                    let current = presentation.runs[cursor].state
                    if current == .edited { state = .edited; break }
                    if current == .resolved || state == .normal { state = current }
                    cursor += 1
                }
                if presentation.ignoredConflicts.contains(where: { NSIntersectionRange($0.range,entry.resultRange).length > 0 }) { state = .conflictedIgnored }
                append(payload,state:state,range:entry.resultRange)
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
