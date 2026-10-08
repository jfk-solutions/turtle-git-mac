import Foundation

public enum MergeSourceState: Sendable, Equatable { case normal, removed, added, conflicted, empty }

public struct MergeSourceCell: Sendable {
    /// Original bytes represented by this line, including its line ending.
    public let text: String
    /// One-based source line number. Removed base lines and alignment gaps have none.
    public let lineNumber: Int?
    public let state: MergeSourceState
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
    public init(base: String, mine: String, theirs: String) {
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
    private struct Hunk { let base: Range<Int>; let side: Range<Int>; let mine: Bool }
    private struct Region { var base: Range<Int>; var hunks: [Hunk] }
    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // Foundation splits the LF inside CRLF without splitting Unicode graphemes.
        let pieces = text.components(separatedBy: "\n")
        var lines = pieces.dropLast().map { $0 + "\n" }
        if let last = pieces.last, !last.isEmpty { lines.append(last) }
        return lines
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
