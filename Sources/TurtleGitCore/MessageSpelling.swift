// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from TortoiseGit SciEdit.cpp::IsMisspelled/CheckSpelling.
import Foundation

public struct MessageSpellingPolicy: Equatable, Sendable {
    private let candidates: Set<[UInt16]>
    public init(candidates: [String] = []) { self.candidates = Set(candidates.map { Array($0.utf16) }) }
    private func known(_ value: String) -> Bool { candidates.contains(Array(value.utf16)) }
    /// Dictionary errors inside source identifiers and known filenames are checked
    /// against their whole token. Ranges use NSTextView's UTF-16 coordinates.
    public func suppresses(message: String, range: NSRange, misspelled: (String) -> Bool) -> Bool {
        let text = message as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= text.length, range.length <= text.length - range.location else { return false }
        let words = Self.words.matches(in: message, range: NSRange(location: 0, length: text.length))
        guard let match = words.first(where: { NSIntersectionRange($0.range, range).length == range.length }) else { return false }
        let full = text.substring(with: match.range)
        if known(full) { return true }
        // A dotted filename is ignored only when it occurs in the completion list.
        // Otherwise evaluate the actual word component, not its extension.
        let components = Self.components.matches(in: full, range: NSRange(location: 0, length: (full as NSString).length))
        guard let component = components.first(where: {
            NSIntersectionRange(NSRange(location: match.range.location + $0.range.location, length: $0.range.length), range).length == range.length
        }) else { return false }
        let word = (full as NSString).substring(with: component.range)
        if word.unicodeScalars.first.map({ CharacterSet.decimalDigits.contains($0) }) == true || known(word) { return true }
        // The pinned source splits before each uppercase letter and ignores
        // component words of at most two UTF-16 units.
        var pieces: [String] = [], current = ""
        for scalar in word.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar), !current.isEmpty { pieces.append(current); current = "" }
            current.unicodeScalars.append(scalar)
        }
        pieces.append(current)
        guard pieces.count > 1 else { return false }
        return pieces.allSatisfy { $0.utf16.count <= 2 || !misspelled($0) }
    }
    private static let words = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_]+(?:[.][\\p{L}\\p{N}_]+)?")
    private static let components = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_]+")
}
