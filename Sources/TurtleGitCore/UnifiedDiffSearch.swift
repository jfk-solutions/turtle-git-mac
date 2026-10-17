// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Literal Scintilla UTF-8 search adapted to native UTF-16 selection ranges.
/// Folding comes from the pinned converter, independent of the host OS/locale.
public enum UnifiedDiffSearch {
    /// Searches once in the requested direction, without wrapping. Case-fold
    /// expansions must match complete source scalars, as in Document::FindText.
    public static func find(_ query: String, in text: String, from offset: Int,
                            backwards: Bool = false, matchCase: Bool = false) -> NSRange? {
        guard !query.isEmpty else { return nil }
        func fold(_ scalar: Unicode.Scalar) -> [UInt32] {
            matchCase ? [scalar.value] : UnifiedDiffCaseFold.mappings[scalar.value] ?? [scalar.value]
        }
        let pattern = query.unicodeScalars.flatMap(fold)
        guard !pattern.isEmpty else { return nil }
        // KMP retains overlaps without rescanning an adversarial long prefix.
        var prefix = [Int](repeating: 0, count: pattern.count)
        if pattern.count > 1 {
            for index in 1..<pattern.count {
                var length = prefix[index - 1]
                while length > 0 && pattern[index] != pattern[length] { length = prefix[length - 1] }
                if pattern[index] == pattern[length] { length += 1 }
                prefix[index] = length
            }
        }
        let cursor = max(0, min(offset, text.utf16.count))
        var starts = [Int?](repeating: nil, count: pattern.count)
        var position = 0, token = 0, matched = 0
        var last: NSRange?
        for scalar in text.unicodeScalars {
            let start = position
            position += scalar.value > 0xFFFF ? 2 : 1
            if backwards && position > cursor { break }
            if !backwards && start < cursor { continue }
            let folded = fold(scalar)
            for (index, value) in folded.enumerated() {
                starts[token % pattern.count] = index == 0 ? start : nil
                while matched > 0 && pattern[matched] != value { matched = prefix[matched - 1] }
                if pattern[matched] == value { matched += 1 }
                if matched == pattern.count {
                    let first = token - pattern.count + 1
                    if index == folded.count - 1, let beginning = starts[first % pattern.count] {
                        let result = NSRange(location: beginning, length: position - beginning)
                        if !backwards { return result }
                        last = result
                    }
                    matched = prefix[matched - 1]
                }
                token += 1
            }
        }
        return last
    }
}
