// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Logical UDiff lines in the displayed text's UTF-16 coordinate space.
/// Scintilla's ordinary CR/LF rules differ from MergeLineEndings: LFCR is two
/// endings, Unicode separators are ordinary text, and a final ending creates
/// an empty last line. This index never changes or normalizes the input.
public struct PatchLineIndex: Equatable, Sendable {
    public let utf16Length: Int
    public let lineStarts: [Int]
    public var lineCount: Int { lineStarts.count }
    public var marginColumns: Int { Self.marginColumns(forLineCount: lineCount) }
    public var lineRanges: [NSRange] { lineStarts.indices.map { range(forLine: $0)! } }

    public init(text: String) {
        var starts = [0], offset = 0, previousWasCR = false
        for unit in text.utf16 {
            if unit == 10 && previousWasCR {
                // Replace the preceding CR endpoint; CRLF belongs to one line.
                starts[starts.count - 1] = offset + 1
            } else if unit == 10 || unit == 13 {
                starts.append(offset + 1)
            }
            previousWasCR = unit == 13
            offset += 1
        }
        lineStarts = starts; utf16Length = offset
    }

    /// Source UpdateLineCount reserves decimal digits plus two '8' cells.
    public static func marginColumns(forLineCount count: Int) -> Int {
        var number = max(1, count), digits = 0
        repeat { digits += 1; number /= 10 } while number > 0
        return digits + 2
    }
    public func range(forLine line: Int) -> NSRange? {
        guard lineStarts.indices.contains(line) else { return nil }
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : utf16Length
        return NSRange(location: start, length: end - start)
    }
    public func lineIndex(atUTF16Offset offset: Int) -> Int? {
        guard offset >= 0, offset <= utf16Length else { return nil }
        var lower = 0, upper = lineStarts.count
        while lower + 1 < upper {
            let middle = lower + (upper - lower) / 2
            if lineStarts[middle] <= offset { lower = middle } else { upper = middle }
        }
        return lower
    }
    /// For Shift-click, an existing backwards selection anchors the last
    /// selected line rather than the following line at its exclusive endpoint.
    public func anchorLine(selectionAnchor: Int, selectionCaret: Int) -> Int? {
        guard (0...utf16Length).contains(selectionAnchor), (0...utf16Length).contains(selectionCaret) else { return nil }
        return lineIndex(atUTF16Offset: selectionAnchor > selectionCaret ? selectionAnchor - 1 : selectionAnchor)
    }
    /// Keep the clicked anchor line fixed throughout dragging. Both complete
    /// logical lines and their original terminators are included. AppKit owns
    /// display-fragment hit testing, wrapping and selection affinity.
    public func selection(anchorLine: Int, currentLine: Int) -> PatchLineSelection? {
        guard let anchor = range(forLine: anchorLine), let current = range(forLine: currentLine) else { return nil }
        if currentLine < anchorLine {
            return .init(anchorOffset: NSMaxRange(anchor), caretOffset: current.location)
        }
        return .init(anchorOffset: anchor.location, caretOffset: NSMaxRange(current))
    }
}

public struct PatchLineSelection: Equatable, Sendable {
    public let anchorOffset: Int
    public let caretOffset: Int
    public var isReversed: Bool { caretOffset < anchorOffset }
    public var range: NSRange { NSRange(location: min(anchorOffset, caretOffset), length: abs(caretOffset - anchorOffset)) }
    fileprivate init(anchorOffset: Int, caretOffset: Int) { self.anchorOffset = anchorOffset; self.caretOffset = caretOffset }
}
