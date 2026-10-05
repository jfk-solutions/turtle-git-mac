// Adapted from TortoiseGit src/Utils/URLFinder.h.
// Copyright (C) 2009-2023 - TortoiseGit
// Copyright (C) 2003-2008, 2013, 2018, 2020 - TortoiseSVN
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// URLFinder's ASCII delimiters and bracket handling, with native UTF-16 ranges.
/// Scalar advancement mirrors SciEdit's AdvanceUTF8; Foundation does not guess
/// additional link types or strip punctuation differently.
public enum MessageURLFinder {
    private static let punctuation = Set("_/;?&=%:.#-+|><!@~".utf16)
    private static let trailing = Set(".-?;:><!".utf16)
    private static let prefixes = ["http://", "https://", "git://", "ftp://", "file://", "mailto:"]
    public static func ranges(in message: String) -> [NSRange] {
        let units = Array(message.utf16), count = units.count
        let text = message as NSString
        var result: [NSRange] = [], start: Int?, position = 0
        func advance(_ offset: Int) -> Int {
            guard offset < count else { return offset + 1 }
            return offset + (units[offset] >= 0xD800 && units[offset] <= 0xDBFF ? 2 : 1)
        }
        func valid(_ unit: UInt16) -> Bool {
            (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || (unit >= 48 && unit <= 57) || punctuation.contains(unit)
        }
        while position <= count {
            if position < count && valid(units[position]) {
                if start == nil { start = position }
                position = advance(position); continue
            }
            guard var first = start else { position = advance(position); continue }
            var strip = true
            if units[first] == 60 && position < count {
                while first <= position && units[first] == 60 { first += 1 }
                strip = false; position = first
                while position < count && units[position] != 13 && units[position] != 10 && units[position] != 62 { position = advance(position) }
            }
            var end = position
            while strip && end - 1 > first && trailing.contains(units[end - 1]) { end -= 1 }
            let range = NSRange(location: first, length: end - first)
            if isURLOrEmail(text.substring(with: range)) { result.append(range) }
            start = nil; position = advance(position)
        }
        return result
    }
    public static func target(for text: String) -> String {
        prefixes.contains(where: { text.hasPrefix($0) }) ? text : "mailto:" + text
    }
    static func styles(in message: String) -> [IssueMessageStyle] {
        let text = message as NSString
        return ranges(in: message).map { IssueMessageStyle(kind: .url, range: $0, url: target(for: text.substring(with: $0))) }
    }
    private static func isURLOrEmail(_ text: String) -> Bool {
        if let prefix = prefixes.first(where: { text.hasPrefix($0) }) { return text.utf16.count != prefix.utf16.count }
        // Adapt PathIsURL's scheme gate. Exact Windows classification of unusual
        // schemes remains under cross-platform audit; accepted prefixes above
        // are the upstream whitelist, including their case-sensitive comparison.
        if let colon = text.firstIndex(of: ":") {
            let scheme = text[..<colon].utf8
            if let first = scheme.first, (65...90).contains(first) || (97...122).contains(first),
               scheme.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43,45,46].contains($0) }) { return false }
        }
        let value = text as NSString, at = value.range(of: "@").location
        guard at != NSNotFound, at > 0 else { return false }
        let tail = NSRange(location: at, length: value.length - at)
        let dot = value.range(of: ".", range: tail).location
        return dot != NSNotFound && dot > at + 1 && value.range(of: ":", range: tail).location == NSNotFound
    }
}
