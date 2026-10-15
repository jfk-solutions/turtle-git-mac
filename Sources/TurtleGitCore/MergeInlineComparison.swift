import Foundation

/// UTF-16 ranges for inline display of paired source lines. Source text is never changed.
/// Token classes, matching and similarity gate follow SVNLineDiff. Matching uses
/// the bundled Subversion engine in process, including repeated-token LCS ties.
public struct MergeInlineComparison: Sendable {
    public let base: [NSRange]
    public let destination: [NSRange]
    public let baseMissing: [Int]
    public let destinationMissing: [Int]
    /// All modified chunks, including zero-width insertions/deletions. The
    /// source navigator visits chunk starts and ends on the current line only.
    public let basePositions: [NSRange]
    public let destinationPositions: [NSRange]
    public func navigationOffset(from caret: Int, base: Bool, forward: Bool) -> Int? {
        let positions = base ? basePositions : destinationPositions
        if forward {
            for range in positions {
                if range.location > caret { return range.location }
                if NSMaxRange(range) > caret { return NSMaxRange(range) }
            }
        } else {
            for range in positions.reversed() {
                if NSMaxRange(range) < caret { return NSMaxRange(range) }
                if range.location < caret { return range.location }
            }
        }
        return nil
    }
    public init?(base: String, destination: String, word: Bool = false, maximumLength: Int = 3000) {
        let a = Array(base.utf16), b = Array(destination.utf16)
        // The native caller applies the cutoff separately to each displayed
        // pane, matching BaseView's current-line guard. A short line can still
        // compare against a longer opposite line.
        guard !a.isEmpty, !b.isEmpty, min(a.count, b.count) <= maximumLength else { return nil }
        func tokens(_ units: [UInt16]) -> [Range<Int>] {
            guard word else { return units.indices.map { $0..<($0 + 1) } }
            func kind(_ unit: UInt16) -> Int {
                if unit == 32 || unit == 9 { return 2 }
                if let scalar = UnicodeScalar(UInt32(unit)), CharacterSet.alphanumerics.contains(scalar) { return 1 }
                return 3
            }
            var result: [Range<Int>] = [], start = 0, previous = kind(units[0])
            for index in units.indices.dropFirst() {
                let current = kind(units[index])
                if current != previous || current == 3 { result.append(start..<index); start = index }
                previous = current
            }
            result.append(start..<units.count); return result
        }
        let ar = tokens(a), br = tokens(b)
        let at = ar.map { Array(a[$0]) }, bt = br.map { Array(b[$0]) }
        guard let segments = SubversionInlineDiff.segments(base: at, destination: bt, word: word) else { return nil }
        var common = 0, removed = 0, added = 0, chunks = 0
        var left: [NSRange] = [], right: [NSRange] = [], leftMissing: [Int] = [], rightMissing: [Int] = []
        var leftPositions: [NSRange] = [], rightPositions: [NSRange] = []
        func offset(_ ranges: [Range<Int>], _ index: Int, _ end: Int) -> Int { index < ranges.count ? ranges[index].lowerBound : end }
        for segment in segments {
            if segment.common { common += segment.base.count; continue }
            let firstA = segment.base.lowerBound, firstB = segment.destination.lowerBound
            let i = segment.base.upperBound, j = segment.destination.upperBound
            chunks += 1; removed += segment.base.count; added += segment.destination.count
            let x = offset(ar, firstA, a.count), y = offset(br, firstB, b.count)
            leftPositions.append(NSRange(location: x, length: offset(ar, i, a.count) - x))
            rightPositions.append(NSRange(location: y, length: offset(br, j, b.count) - y))
            if i > firstA { left.append(NSRange(location: x, length: ar[i - 1].upperBound - x)) }
            if j > firstB { right.append(NSRange(location: y, length: br[j - 1].upperBound - y)) }
            if segment.base.count < segment.destination.count { leftMissing.append(x) }
            if segment.destination.count < segment.base.count { rightMissing.append(y) }
        }
        guard chunks > 0, common * 2 > removed + added + 2 * chunks else { return nil }
        self.base = left; self.destination = right
        baseMissing = leftMissing; destinationMissing = rightMissing
        basePositions = leftPositions; destinationPositions = rightPositions
    }
}

/// BaseView paints only changed rows, applies its length cutoff to the current
/// displayed line, and compares the opposite pane even when it is longer.
public enum MergeInlinePresentation {
    public static func comparison(cell: MergeSourceCell, other: MergeSourceCell, left: Bool,
                                  word: Bool, maximumLength: Int) -> MergeInlineComparison? {
        guard !cell.state.isUnchanged, cell.state != .empty, cell.state != .conflictEmpty,
              !cell.displayText.isEmpty, !other.displayText.isEmpty,
              cell.displayText.utf16.count <= maximumLength else { return nil }
        return MergeInlineComparison(base: left ? cell.displayText : other.displayText,
                                     destination: left ? other.displayText : cell.displayText,
                                     word: word, maximumLength: maximumLength)
    }
    public static func defaultEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "TurtleGitMerge.DisplayBinDiff") == nil || defaults.bool(forKey: "TurtleGitMerge.DisplayBinDiff")
    }
    public static func saveEnabled(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "TurtleGitMerge.DisplayBinDiff")
    }
}
