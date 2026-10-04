import Foundation

public enum MergeLineEnding: String, CaseIterable, Sendable {
    case crlf = "\r\n", lf = "\n", cr = "\r", lfcr = "\n\r"
    case verticalTab = "\u{000b}", formFeed = "\u{000c}", nextLine = "\u{0085}"
    case lineSeparator = "\u{2028}", paragraphSeparator = "\u{2029}"
}

/// Line boundaries shared by conflict parsing and explicit ending conversion.
/// UTF-16 offsets match AppKit; text and missing final endings remain intact.
public enum MergeLineEndings {
    private struct Ending { let range: NSRange; let style: MergeLineEnding }
    private static func endings(in text: String) -> [Ending] {
        let units = Array(text.utf16)
        var result: [Ending] = [], counts: [MergeLineEnding: Int] = [:], index = 0
        while index < units.count {
            var length = 1
            let style: MergeLineEnding
            switch units[index] {
            case 13:
                if index + 1 < units.count, units[index + 1] == 10 { style = .crlf; length = 2 }
                else { style = .cr }
            case 10:
                if index + 1 < units.count, units[index + 1] == 13 {
                    // Match FileTextLines.cpp: early LF/CRLF mixtures should not
                    // consume the CR of the following CRLF as a rare LFCR pair.
                    let ordinary = counts[.crlf, default: 0] > 1 || counts[.lf, default: 0] > 1 || result.count < 2
                    if ordinary, index + 2 < units.count, units[index + 2] == 10 { style = .lf }
                    else { style = .lfcr; length = 2 }
                } else { style = .lf }
            case 11: style = .verticalTab
            case 12: style = .formFeed
            case 0x85: style = .nextLine
            case 0x2028: style = .lineSeparator
            case 0x2029: style = .paragraphSeparator
            default: index += 1; continue
            }
            result.append(Ending(range: NSRange(location: index, length: length), style: style))
            counts[style, default: 0] += 1; index += length
        }
        return result
    }
    static func lineRanges(in text: String) -> [NSRange] {
        var start = 0, ranges: [NSRange] = []
        for ending in endings(in: text) {
            let end = NSMaxRange(ending.range)
            ranges.append(NSRange(location: start, length: end - start)); start = end
        }
        let length = (text as NSString).length
        if start < length { ranges.append(NSRange(location: start, length: length - start)) }
        return ranges
    }
    public static func styles(in text: String) -> Set<MergeLineEnding> { Set(endings(in: text).map(\.style)) }
    static func mappingLineContents(_ text: String, transform: (String) -> String) -> String {
        let source = text as NSString
        var output = "", start = 0
        for ending in endings(in: text) {
            output += transform(source.substring(with: NSRange(location: start, length: ending.range.location - start)))
            output += source.substring(with: ending.range)
            start = NSMaxRange(ending.range)
        }
        output += transform(source.substring(from: start))
        return output
    }
    public static func lineNumber(in text: String, utf16Offset: Int) -> Int {
        let offset = min(max(utf16Offset, 0), (text as NSString).length)
        return endings(in: text).filter { NSMaxRange($0.range) <= offset }.count + 1
    }
    public static func converting(_ text: String, to style: MergeLineEnding) -> String {
        let source = text as NSString
        var output = "", start = 0
        for ending in endings(in: text) {
            output += source.substring(with: NSRange(location: start, length: ending.range.location - start))
            output += style.rawValue; start = NSMaxRange(ending.range)
        }
        output += source.substring(from: start)
        return output
    }
}
