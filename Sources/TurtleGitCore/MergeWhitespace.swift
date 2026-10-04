import Foundation

public enum MergeWhitespaceCommand: String, CaseIterable, Sendable {
    case tabsToSpaces = "Convert tabs to spaces"
    case spacesToTabs = "Convert spaces to tabs"
    case trimRight = "Trim right"
}

/// Matches BaseView's leading-indentation conversions; line endings stay intact.
public enum MergeWhitespace {
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
