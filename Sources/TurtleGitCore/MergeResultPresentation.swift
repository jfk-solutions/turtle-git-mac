// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

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
    public static func == (a: Self, b: Self) -> Bool { a.text.utf8.elementsEqual(b.text.utf8) && a.runs == b.runs && a.foldAnchors == b.foldAnchors }
    public init(text: String, states: [MergeSourceState], foldAnchors: MergeFoldAnchors = .init()) {
        self.text = text; self.foldAnchors = foldAnchors
        runs = Self.compact(MergeLineEndings.lineRanges(in: text).enumerated().map { index, range in
            Run(range: range.location..<NSMaxRange(range), state: states.indices.contains(index) ? states[index] : .normal)
        })
    }
    private init(text: String, runs: [Run], foldAnchors: MergeFoldAnchors) { self.text = text; self.runs = Self.compact(runs); self.foldAnchors = foldAnchors }
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
    private func remap(_ range: NSRange, replacementLength: Int, text value: String, state: MergeSourceState) -> Self {
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
        if replacementLength == 0, !value.isEmpty {
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
        return Self(text: value, runs: output, foldAnchors: anchors)
    }
    public func states(conflicts: [NSRange]) -> [MergeSourceState] {
        let conflicts = conflicts.sorted { $0.location < $1.location }
        var cursor = 0, conflict = 0
        return MergeLineEndings.lineRanges(in: text).map { line in
            while conflict < conflicts.count, NSMaxRange(conflicts[conflict]) <= line.location { conflict += 1 }
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
