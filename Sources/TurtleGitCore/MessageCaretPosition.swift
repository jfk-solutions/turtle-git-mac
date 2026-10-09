// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One-based logical line and Scintilla-style column for AppKit UTF-16 positions.
public struct MessageCaretPosition: Equatable, Sendable {
    public let line: Int, column: Int
    public var text: String { "\(line)/\(column)" }
    public static func at(_ message: String, utf16Offset: Int) -> Self {
        let units = Array(message.utf16), end = min(max(0, utf16Offset), message.utf16.count)
        var i = 0, line = 1, column = 0
        while i < end {
            switch units[i] {
            case 13:
                if i + 1 < units.count && units[i + 1] == 10 {
                    if end == i + 1 { return Self(line: line, column: column + 1) }
                    i += 2
                } else { i += 1 }
                line += 1; column = 0
            case 10: line += 1; column = 0; i += 1
            case 9: column = (column / 8 + 1) * 8; i += 1
            default:
                let pair = (0xD800...0xDBFF).contains(units[i]) && i + 1 < units.count && (0xDC00...0xDFFF).contains(units[i + 1])
                i += pair ? 2 : 1; column += 1
            }
        }
        return Self(line: line, column: column + 1)
    }
}
/// Keeps the anchor through ordinary forward/backward selection extension.
/// An unrelated programmatic range establishes a new start anchor/end caret.
public struct MessageSelectionCaret: Sendable {
    private var anchor = 0
    public init() {}
    public mutating func observe(_ range: NSRange) -> Int {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0, range.length <= Int.max - range.location else { return 0 }
        if range.length == 0 { anchor = range.location; return anchor }
        let end = range.location + range.length
        if anchor == end { return range.location }
        if anchor != range.location { anchor = range.location }
        return end
    }
}
