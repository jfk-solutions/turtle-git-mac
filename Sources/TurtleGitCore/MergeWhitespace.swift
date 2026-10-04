import Foundation

public enum MergeWhitespaceCommand: String, CaseIterable, Sendable {
    case tabsToSpaces = "Convert tabs to spaces"
    case spacesToTabs = "Convert spaces to tabs"
    case trimRight = "Trim right"
}

/// Matches BaseView's leading-indentation conversions; line endings stay intact.
public enum MergeWhitespace {
    public static func indentSelection(in text: String, selection: NSRange, tabWidth: Int = 4, useSpaces: Bool = false, smart: Bool = false, remove: Bool = false) -> (range: NSRange, replacement: String)? {
        let source = text as NSString
        guard selection.location >= 0, selection.location <= source.length, selection.length > 0, selection.length <= source.length - selection.location,
              MergeLineEndings.lineNumber(in: text, utf16Offset: selection.location) != MergeLineEndings.lineNumber(in: text, utf16Offset: NSMaxRange(selection)) else { return nil }
        let ranges = MergeLineEndings.lineRanges(in: text).filter { NSIntersectionRange($0, selection).length > 0 }
        guard let first = ranges.first, let last = ranges.last else { return nil }
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        var working = text, delta = 0
        for lineRange in ranges {
            let start = lineRange.location + delta
            let line = (working as NSString).substring(with: NSRange(location: start, length: lineRange.length))
            var body = ""
            _ = MergeLineEndings.mappingLineContents(line) { if body.isEmpty { body = $0 }; return $0 }
            if remove {
                let units = Array(body.utf16)
                var count = 0
                while count < min(max(1, tabWidth), units.count) {
                    if units[count] == 32 { count += 1; continue }
                    if units[count] == 9 { count += 1 }
                    break
                }
                if count > 0 { working = (working as NSString).replacingCharacters(in: NSRange(location: start, length: count), with: ""); delta -= count }
            } else if !body.trimmingCharacters(in: .whitespaces).isEmpty {
                let insertion = tabInsertion(in: working, utf16Offset: start, tabWidth: tabWidth, useSpaces: useSpaces, smart: smart)
                working = (working as NSString).replacingCharacters(in: NSRange(location: start, length: 0), with: insertion)
                delta += (insertion as NSString).length
            }
        }
        return (range, (working as NSString).substring(with: NSRange(location: range.location, length: range.length + delta)))
    }
    public static func tabInsertion(in text: String, utf16Offset: Int, tabWidth: Int = 4, useSpaces: Bool = false, smart: Bool = false) -> String {
        let width = max(1, tabWidth), source = text as NSString
        let offset = min(max(utf16Offset, 0), source.length)
        var lines: [String] = []
        _ = MergeLineEndings.mappingLineContents(text) { lines.append($0); return $0 }
        let index = min(MergeLineEndings.lineNumber(in: text, utf16Offset: offset) - 1, lines.count - 1)
        func longestSpaces(_ line: String) -> Int {
            var longest = 0, run = 0
            for unit in line.utf16 {
                if unit == 32 { run += 1; longest = max(longest, run) } else { run = 0 }
            }
            return longest
        }
        var spaces = useSpaces
        if smart {
            spaces = false
            if lines[index].contains("\t") { spaces = false }
            else if longestSpaces(lines[index]) > width { spaces = true }
            else {
                for distance in 1...100 {
                    let above = index >= distance ? lines[index - distance] : ""
                    let below = index + distance < lines.count ? lines[index + distance] : ""
                    if above.contains("\t") || below.contains("\t") { break }
                    if longestSpaces(above) > width && longestSpaces(below) > width { spaces = true; break }
                }
            }
        }
        guard spaces else { return "\t" }
        let ranges = MergeLineEndings.lineRanges(in: text)
        let start = index < ranges.count ? ranges[index].location : source.length
        let prefix = (lines[index] as NSString).substring(to: min(max(offset - start, 0), (lines[index] as NSString).length))
        var column = 0
        for unit in prefix.utf16 { column += unit == 9 ? width - column % width : 1 }
        return String(repeating: " ", count: width - column % width)
    }
    public static func applying(_ command: MergeWhitespaceCommand, to text: String, tabWidth: Int = 4) -> String {
        let width = max(1, tabWidth)
        return MergeLineEndings.mappingLineContents(text) { line in
            let source = line as NSString
            switch command {
            case .tabsToSpaces:
                var position = 0, column = 0, hasTab = false
                while position < source.length {
                    let unit = source.character(at: position)
                    if unit == 32 { column += 1 }
                    else if unit == 9 { column += width - column % width; hasTab = true }
                    else { break }
                    position += 1
                }
                return hasTab ? String(repeating: " ", count: column) + source.substring(from: position) : line
            case .spacesToTabs:
                var position = 0, deleteCount = 0, tabs = 0, spaces = 0
                while position < source.length {
                    let unit = source.character(at: position)
                    position += 1
                    if unit == 32 {
                        spaces += 1
                        if spaces < width { continue }
                    } else if unit != 9 { break }
                    tabs += 1; spaces = 0; deleteCount = position
                }
                return deleteCount > 0 ? String(repeating: "\t", count: tabs) + source.substring(from: deleteCount) : line
            case .trimRight:
                var end = source.length
                while end > 0, source.character(at: end - 1) == 32 || source.character(at: end - 1) == 9 { end -= 1 }
                return source.substring(to: end)
            }
        }
    }
    public static func canApply(_ command: MergeWhitespaceCommand, to text: String, tabWidth: Int = 4) -> Bool {
        !applying(command, to: text, tabWidth: tabWidth).utf8.elementsEqual(text.utf8)
    }
}
