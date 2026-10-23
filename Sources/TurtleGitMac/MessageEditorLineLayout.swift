// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// SciEdit LinesJoin/LinesSplit expressed as edits in the original UTF-16 text.
/// TextKit supplies native word/character boundaries and measured glyph widths;
/// original whitespace is retained and automatic splitting never joins lines.
@MainActor enum MessageEditorLineLayout {
    struct Edit { let range: NSRange; let text: String }
    private struct Line { let start: Int; let contentsEnd: Int; let end: Int }
    private static func lines(_ text: NSString) -> [Line] {
        var result: [Line] = [], start = 0, cursor = 0
        while cursor < text.length {
            let char = text.character(at: cursor)
            if char == 10 || char == 13 {
                let contentsEnd = cursor
                cursor += 1
                if char == 13, cursor < text.length, text.character(at: cursor) == 10 { cursor += 1 }
                result.append(Line(start: start, contentsEnd: contentsEnd, end: cursor)); start = cursor
            } else { cursor += 1 }
        }
        result.append(Line(start: start, contentsEnd: text.length, end: text.length))
        return result
    }
    static func edits(text: String, range: NSRange, width: CGFloat, font: NSFont, join: Bool) -> [Edit] {
        let source = text as NSString
        guard width.isFinite, width > 0, range.location != NSNotFound,
              range.location >= 0, NSMaxRange(range) <= source.length else { return [] }
        let records = lines(source)
        let first = records.last(where: { $0.start <= range.location })!
        let last = records.last(where: { $0.start <= NSMaxRange(range) })!
        let touched = NSRange(location: first.start, length: last.end - first.start)
        guard touched.length > 0 else { return [] }
        let original = source.substring(with: touched)
        let working = original
        if join {
            let localEnd = NSMaxRange(range) - touched.location
            let value = working as NSString
            var changes: [Edit] = []
            var previousJoinedCharacter: unichar?
            for line in lines(value) {
                let start = line.start, end = line.end, contentsEnd = line.contentsEnd
                if contentsEnd > start { previousJoinedCharacter = value.character(at: contentsEnd - 1) }
                if contentsEnd < end, contentsEnd < localEnd {
                    let replacement = previousJoinedCharacter == 32 ? "" : " "
                    changes.append(Edit(range: NSRange(location: contentsEnd, length: end - contentsEnd), text: replacement))
                    if !replacement.isEmpty { previousJoinedCharacter = 32 }
                }
            }
            return changes.map { Edit(range: NSRange(location: touched.location + $0.range.location, length: $0.range.length), text: $0.text) }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []; paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 8
        let storage = NSTextStorage(string: working, attributes: [.font: font, .paragraphStyle: paragraph])
        let layout = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; container.lineBreakMode = .byWordWrapping
        layout.addTextContainer(container); storage.addLayoutManager(layout); layout.ensureLayout(for: container)
        let value = working as NSString
        var insertions: [Int] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, glyphs, _ in
            let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let end = NSMaxRange(chars)
            guard end > 0, end < value.length else { return }
            let previous = value.character(at: end - 1)
            if previous != 10 && previous != 13 && previous != 0x2028 && previous != 0x2029 { insertions.append(end) }
        }
        return insertions.map { Edit(range: NSRange(location: touched.location + $0, length: 0), text: "\n") }
    }
    static func mapped(_ range: NSRange, through edits: [Edit]) -> NSRange {
        func position(_ original: Int) -> Int {
            var delta = 0
            for edit in edits {
                if original < edit.range.location { break }
                let length = (edit.text as NSString).length
                if original < NSMaxRange(edit.range) { return edit.range.location + delta + min(original - edit.range.location, length) }
                delta += length - edit.range.length
            }
            return original + delta
        }
        let start = position(range.location), end = position(NSMaxRange(range))
        return NSRange(location: start, length: max(0, end - start))
    }
}
