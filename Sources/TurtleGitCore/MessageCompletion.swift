// Adapted from TortoiseGit CommitDlg.cpp::GetAutocompletionList and
// SciEdit.cpp::DoAutoCompletion. GPL-2.0-or-later.
// Copyright (C) 2003-2021, 2023-2025 - TortoiseGit
// SciEdit: Copyright (C) 2009-2026 - TortoiseGit
// Copyright (C) 2003-2008, 2012-2020, 2025 - TortoiseSVN
import Foundation

public enum MessageCompletion {
    public struct Request {
        public let range: NSRange
        public let candidates: [String]
    }
    public static func request(message: String, selection: NSRange, candidates: [String], minimum: Int, styling: Bool) -> Request? {
        guard let full = wordRange(message: message, selection: selection, styling: false),
              let trimmed = wordRange(message: message, selection: selection, styling: styling) else { return nil }
        let text = message as NSString
        for range in [trimmed, full] {
            let found = matches(prefix: text.substring(with: range), candidates: candidates, minimum: minimum)
            if !found.isEmpty { return Request(range: range, candidates: found) }
        }
        return nil
    }
    public static func wordRange(message: String, selection: NSRange, styling: Bool) -> NSRange? {
        let units = Array(message.utf16), end = selection.location
        func word(_ unit: UInt16) -> Bool {
            if [39, 45, 95].contains(unit) { return true }
            guard let scalar = UnicodeScalar(unit) else { return false }
            return CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
        }
        guard selection.length == 0, end >= 0, end <= units.count, end == units.count || !word(units[end]) else { return nil }
        var start = end
        while start > 0 && word(units[start - 1]) { start -= 1 }
        guard start != end else { return nil }
        let full = NSRange(location: start, length: end - start)
        var trimmed = full
        if styling {
            for marker in [UInt16(42), 95, 94] {
                if trimmed.length > 0 && units[NSMaxRange(trimmed) - 1] == marker { trimmed.length -= 1 }
                if trimmed.length > 0 && units[trimmed.location] == marker { trimmed.location += 1; trimmed.length -= 1 }
            }
        }
        return trimmed
    }
    public static func fileCandidates(paths: [String], removeExtensions: Bool = false) -> [String] {
        var values = Set<[UInt16]>()
        for path in paths {
            values.insert(Array(path.utf16))
            var last = path.startIndex
            for index in path.indices where path[index] == "/" {
                last = path.index(after: index); values.insert(Array(path[last...].utf16))
            }
            if removeExtensions, let dot = path.lastIndex(of: "."), dot > last { values.insert(Array(path[last..<dot].utf16)) }
        }
        return values.map { String(decoding: $0, as: UTF16.self) }.sorted(by: less)
    }
    public static func matches(prefix: String, candidates: [String], minimum: Int) -> [String] {
        guard prefix.utf16.count >= max(0, minimum) else { return [] }
        var variants = [prefix, prefix.lowercased(), prefix.uppercased()]
        if prefix.contains("-") {
            for variant in [prefix.lowercased(), prefix.uppercased()] {
                // ASCII '-' keeps its location across the casing used here.
                // Locate it again because Unicode case expansion changes indices.
                guard let split = variant.firstIndex(of: "-") else { continue }
                for part in [String(variant[..<split]), String(variant[variant.index(after: split)...])] where part.utf16.count >= max(0, minimum) { variants.append(part) }
            }
        }
        let sorted = candidates.sorted(by: less)
        var result = Set<[UInt16]>()
        for variant in variants {
            var low = 0, high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if less(sorted[middle], variant) { low = middle + 1 } else { high = middle }
            }
            for candidate in sorted.dropFirst(low) {
                let head = String(decoding: candidate.utf16.prefix(variant.utf16.count), as: UTF16.self)
                let comparison = (variant as NSString).compare(head, options: [.caseInsensitive, .literal])
                if comparison == .orderedDescending { continue }
                if comparison == .orderedAscending { break }
                result.insert(Array(candidate.utf16))
            }
        }
        return result.map { String(decoding: $0, as: UTF16.self) }.sorted(by: less)
    }
    private static func less(_ left: String, _ right: String) -> Bool { left.utf16.lexicographicallyPrecedes(right.utf16) }
}
