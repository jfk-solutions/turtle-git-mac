// Adapted from TortoiseGit Utils/MiscUI/SciEdit.cpp::StyleEnteredText/FindStyleChars.
// Copyright (C) 2009-2026 - TortoiseGit
// Copyright (C) 2003-2008, 2012-2020, 2025 - TortoiseSVN
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum MessageFormatting {
    static func ranges(in message: String, marker: UInt16) -> [NSRange] {
        let units = Array(message.utf16)
        var result: [NSRange] = [], lineStart = 0
        while lineStart < units.count {
            var lineEnd = lineStart
            while lineEnd < units.count && units[lineEnd] != 10 && units[lineEnd] != 13 { lineEnd += 1 }
            let line = Array(units[lineStart..<lineEnd])
            var start = 0
            while let range = find(line, marker: marker, start: start) {
                result.append(NSRange(location: lineStart + range.location, length: range.length))
                start = NSMaxRange(range)
            }
            lineStart = lineEnd + 1
        }
        return result
    }
    private static func find(_ line: [UInt16], marker: UInt16, start: Int) -> NSRange? {
        func advance(_ index: Int) -> Int {
            index + (line[index] >= 0xD800 && line[index] <= 0xDBFF ? 2 : 1)
        }
        func alphaNumeric(_ index: Int) -> Bool {
            guard line.indices.contains(index), let scalar = UnicodeScalar(line[index]) else { return false }
            return CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
        }
        // Upstream increments u once per UTF-8 scalar, then indexes a UTF-16
        // CString with u. Preserve that supplementary-character boundary quirk.
        var position = 0, unicodePosition = 0, first: Int?
        while position < start && position < line.count { position = advance(position); unicodePosition += 1 }
        while position < line.count && line[position] != 0 {
            if line[position] == marker, position + 1 < line.count, line[position + 1] != 0,
               alphaNumeric(unicodePosition + 1), unicodePosition == 0 || !alphaNumeric(unicodePosition - 1) {
                first = position + 1; position = advance(position); unicodePosition += 1; break
            }
            position = advance(position); unicodePosition += 1
        }
        guard let first else { return nil }
        while position < line.count && line[position] != 0 {
            if line[position] == marker, alphaNumeric(unicodePosition - 1),
               unicodePosition + 1 == line.count || (unicodePosition + 1 < line.count && !alphaNumeric(unicodePosition + 1)) {
                return NSRange(location: first, length: position - first)
            }
            position = advance(position); unicodePosition += 1
        }
        return nil
    }
}
