import Foundation
import CoreFoundation
import Darwin

/// BaseView edits its view records, rather than diffing the files after every
/// keystroke. Preserve opposite rows and untouched Removed/whitespace records.
public struct FileComparisonInPlaceEdit: Sendable {
    public let alignment: FileComparisonAlignment
    public let combined: OnePaneFileComparison?
    public let text: String
    public let caret: Int
    public let displayCaret: Int
    public let replacedRows: Range<Int>
    public let insertedRows: Range<Int>
    public let removedEmptyRows: [Int]
    public init(alignment: FileComparisonAlignment, combined: OnePaneFileComparison? = nil,
                base: Bool, range: NSRange, replacement: String, lineEnding: MergeLineEnding? = nil) throws {
        let source = combined?.cells ?? alignment.rows.map { base ? $0.base : $0.destination }
        let cells = source.isEmpty ? [MergeSourceCell(text:"",lineNumber:1,state:.normal)] : source
        var offsets: [Int] = [], length = 0
        for cell in cells { offsets.append(length); length += cell.displayText.utf16.count + 1 }
        guard range.location >= 0, range.length >= 0, range.location <= length, range.length <= length - range.location else { throw FileComparisonEditFailure.range }
        // RemoveSelectedText advances selected endpoints off Empty records.
        // Zero-length typing still deliberately edits its selected view record.
        let requestedRange = range
        guard let range = MergePaneInput.normalizedReplacementRange(in:cells.map { $0.displayText + "\n" }.joined(),cells:cells,selection:range) else { throw FileComparisonEditFailure.range }
        if requestedRange.length > 0, range.length == 0, replacement.isEmpty {
            self.alignment = alignment; self.combined = combined
            text = combined?.sourceSaveText ?? cells.filter(\.hasSourceCoordinate).map(\.text).joined()
            displayCaret = range.location
            let index = offsets.lastIndex { $0 <= min(range.location,max(0,length - 1)) } ?? 0
            caret = cells.prefix(index).filter { combined != nil ? !$0.state.isRemoval && !$0.state.isViewEmpty : $0.hasSourceCoordinate }.map(\.text).joined().utf16.count + min(cells[index].displayText.utf16.count,max(0,range.location - offsets[index]))
            replacedRows = index..<index; insertedRows = index..<index; removedEmptyRows = []
            return
        }
        func row(_ offset: Int) -> Int { offsets.lastIndex { $0 <= min(offset,max(0,length - 1)) } ?? 0 }
        let first = row(range.location), last = row(NSMaxRange(range)), oldRange = first..<(last + 1)
        let firstText = cells[first].displayText as NSString, lastText = cells[last].displayText as NSString
        let a = min(firstText.length,max(0,range.location - offsets[first]))
        let b = min(lastText.length,max(0,NSMaxRange(range) - offsets[last]))
        let prefix = firstText.substring(to:a), suffix = lastText.substring(from:b)
        let ending = NSMaxRange(range) > offsets[last] + lastText.length ? "" : (cells[last].text as NSString).substring(from:lastText.length)
        let original = combined?.sourceSaveText ?? cells.filter(\.hasSourceCoordinate).map(\.text).joined()
        let style = lineEnding ?? MergeLineEndings.predominantStyle(in:original)
        let inserted = MergeLineEndings.converting(replacement,to:style)
        var payload = prefix + inserted + suffix + ending
        let hasFollowingPayload = cells.dropFirst(last + 1).contains { combined != nil ? !$0.state.isRemoval && $0.state != .empty : $0.hasSourceCoordinate }
        if !payload.isEmpty, !MergeLineEndings.hasFinalEnding(payload), hasFollowingPayload { payload += style.rawValue }
        var lines = MergeRegexFilters.lines(payload)
        if lines.isEmpty || prefix.utf16.count + inserted.utf16.count == payload.utf16.count && MergeLineEndings.hasFinalEnding(payload) { lines.append("") }
        var target = cells
        let gap = MergeSourceCell(text:"",lineNumber:nil,state:.empty)
        var edited = lines.map { MergeSourceCell(text:$0,lineNumber:1,state:.edited) }
        if combined == nil, edited.count < oldRange.count { edited += Array(repeating:gap,count:oldRange.count - edited.count) }
        target.replaceSubrange(oldRange,with:edited)
        if first > 0, !payload.isEmpty, let previous = target[..<first].lastIndex(where: { combined != nil ? !$0.state.isRemoval && $0.state != .empty : $0.hasSourceCoordinate }),
           !MergeLineEndings.hasFinalEnding(target[previous].text) {
            let cell = target[previous]
            target[previous] = .init(text:cell.text + style.rawValue,lineNumber:cell.lineNumber,state:cell.state,hiddenByComparison:cell.hiddenByComparison)
        }
        var number = 0
        target = target.map { cell in
            let included = combined != nil ? !cell.state.isRemoval && cell.state != .empty && cell.state != .conflictEmpty : cell.lineNumber != nil
            if included { number += 1 }
            return .init(text:cell.text,lineNumber:included ? number : nil,state:cell.state,hiddenByComparison:cell.hiddenByComparison)
        }
        var rows: [FileComparisonRow] = []
        if let combined {
            let before = Array(combined.rows.prefix(first)), after = Array(combined.rows.dropFirst(last + 1))
            let retained = before + edited.map { OnePaneFileComparison.Row(cell:$0,alignmentRow:0,base:false) } + after
            let projected = retained.indices.map { OnePaneFileComparison.Row(cell:target[$0],alignmentRow:$0,base:retained[$0].base) }
            self.combined = OnePaneFileComparison(retainedRows:projected)
            for (index,row) in projected.enumerated() {
                let original = retained[index]
                let old = alignment.rows.indices.contains(original.alignmentRow) ? alignment.rows[original.alignmentRow].base : gap
                let left = row.base ? MergeSourceCell(text:row.cell.text,lineNumber:old.lineNumber,state:row.cell.state) : row.cell.state.isUnchanged ? old : gap
                let right = row.base && row.cell.state != .removedWhitespace ? gap : row.cell
                rows.append(.init(base:left,destination:right))
            }
        } else {
            var opposite = alignment.rows.map { base ? $0.destination : $0.base }
            if opposite.isEmpty { opposite = [gap] }
            if edited.count > oldRange.count { opposite.insert(contentsOf:Array(repeating:gap,count:edited.count - oldRange.count),at:last + 1) }
            rows = target.indices.map { base ? .init(base:target[$0],destination:opposite[$0]) : .init(base:opposite[$0],destination:target[$0]) }
            self.combined = nil
        }
        // CleanEmptyLines removes records only when every visible pane is an
        // Empty state. An ordinary blank line or an Edited empty line is real.
        let removed = combined == nil ? rows.indices.filter {
            [.empty,.conflictEmpty].contains(rows[$0].base.state) && [.empty,.conflictEmpty].contains(rows[$0].destination.state)
        } : []
        let removedSet = Set(removed)
        let retainedRows = rows.indices.filter { !removedSet.contains($0) }.map { rows[$0] }
        var differences: [Range<Int>] = [], start: Int?
        for index in 0...retainedRows.count {
            let changed = index < retainedRows.count && retainedRows[index].changed
            if changed, start == nil { start = index }
            if !changed, let begin = start { differences.append(begin..<index); start = nil }
        }
        self.alignment = .init(rows:retainedRows,differences:differences)
        text = self.combined?.sourceSaveText ?? target.filter(\.hasSourceCoordinate).map(\.text).joined()
        let includedPrefix = target.prefix(first).filter { combined != nil ? !$0.state.isRemoval && $0.state != .empty : $0.hasSourceCoordinate }.map(\.text).joined().utf16.count
        caret = includedPrefix + prefix.utf16.count + inserted.utf16.count
        var display = target.prefix(first).reduce(0) { $0 + $1.displayText.utf16.count + 1 }, remaining = prefix.utf16.count + inserted.utf16.count
        for cell in edited {
            if remaining <= cell.displayText.utf16.count { display += remaining; break }
            remaining -= cell.text.utf16.count; display += cell.displayText.utf16.count + 1
        }
        var skipped = 0, oldDisplay = 0
        for (index,cell) in target.enumerated() {
            let count = cell.displayText.utf16.count + 1
            if removedSet.contains(index), oldDisplay < display { skipped += min(count,display - oldDisplay) }
            oldDisplay += count
        }
        displayCaret = display - skipped
        replacedRows = oldRange
        insertedRows = (first - removed.filter { $0 < first }.count)..<(first + edited.count - removed.filter { $0 < first + edited.count }.count)
        removedEmptyRows = removed
    }
}

/// Explicit output formats; UTF-32 choices include a BOM, as upstream does.
public enum ComparisonTextEncoding: String, CaseIterable, Sendable {
    case windows1252 = "ASCII (Windows-1252)"
    case utf8 = "UTF-8", utf8BOM = "UTF-8 BOM"
    case utf16LE = "UTF-16LE", utf16LEBOM = "UTF-16LE BOM"
    case utf16BE = "UTF-16BE", utf16BEBOM = "UTF-16BE BOM"
    case utf32LE = "UTF-32LE", utf32BE = "UTF-32BE"
    case windows1250 = "ASCII (Windows-1250)", windows1251 = "ASCII (Windows-1251)"
    case windows1253 = "ASCII (Windows-1253)", windows1254 = "ASCII (Windows-1254)"
    case windows1255 = "ASCII (Windows-1255)", windows1256 = "ASCII (Windows-1256)"
    case windows1257 = "ASCII (Windows-1257)", windows1258 = "ASCII (Windows-1258)"
    case windows874 = "ASCII (Windows-874)", shiftJIS = "ASCII (Shift-JIS)"
    case gbk = "ASCII (GBK)", korean = "ASCII (Korean)", big5 = "ASCII (Big5)"
    public static let legacyChoices:[Self] = [.windows1252,.windows1250,.windows1251,.windows1253,.windows1254,.windows1255,.windows1256,.windows1257,.windows1258,.windows874,.shiftJIS,.gbk,.korean,.big5]
    public var legacyCodePage:UInt32? {
        switch self {
        case .windows1250:return 1250
        case .windows1251:return 1251
        case .windows1252:return 1252
        case .windows1253:return 1253
        case .windows1254:return 1254
        case .windows1255:return 1255
        case .windows1256:return 1256
        case .windows1257:return 1257
        case .windows1258:return 1258
        case .windows874:return 874
        case .shiftJIS:return 932
        case .gbk:return 936
        case .korean:return 949
        case .big5:return 950
        default:return nil
        }
    }
    public var legacyName:String { legacyCodePage == nil ? rawValue : String(rawValue.dropFirst(7).dropLast()) }
    public static func legacyEncoding(from defaults:UserDefaults = .standard)->Self {
        guard let raw = defaults.object(forKey:"TurtleGitMerge.LegacyCodePage") as? NSNumber else {return .windows1252}
        return legacyChoices.first { $0.legacyCodePage.map { Int64($0) == raw.int64Value } == true } ?? .windows1252
    }
    private var codec: String.Encoding {
        if let page = legacyCodePage {
            return .init(rawValue:CFStringConvertEncodingToNSStringEncoding(CFStringConvertWindowsCodepageToEncoding(page)))
        }
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE, .utf16LEBOM: return .utf16LittleEndian
        case .utf16BE, .utf16BEBOM: return .utf16BigEndian
        case .utf32LE: return .utf32LittleEndian
        case .utf32BE: return .utf32BigEndian
        default: preconditionFailure("Legacy codec must have a code page")
        }
    }
    private var bom: Data {
        switch self {
        case .utf8BOM: return Data([0xef, 0xbb, 0xbf])
        case .utf16LEBOM: return Data([0xff, 0xfe])
        case .utf16BEBOM: return Data([0xfe, 0xff])
        case .utf32LE: return Data([0xff, 0xfe, 0, 0])
        case .utf32BE: return Data([0, 0, 0xfe, 0xff])
        default: return Data()
        }
    }
    var hasBOM:Bool { !bom.isEmpty }
    /// AdjustUnicodeTypeForLoad normalizes BOM menu variants. Input decoding
    /// still consumes a matching header; output conversion remains independent.
    public var inputEncoding:Self {
        switch self {case .utf8BOM:return .utf8;case .utf16LEBOM:return .utf16LE;case .utf16BEBOM:return .utf16BE;default:return self}
    }
    public func decodeInput(_ bytes:Data)->String? {
        switch inputEncoding {
        case .utf8:return Self.utf8BOM.decode(bytes)
        case .utf16LE:return Self.utf16LEBOM.decode(bytes)
        case .utf16BE:return Self.utf16BEBOM.decode(bytes)
        default:return inputEncoding.decode(bytes)
        }
    }
    public func encode(_ text: String) throws -> Data {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }),
              let bytes = text.data(using: codec, allowLossyConversion: false),
              let recovered = decodePayload(bytes),
              recovered.utf8.elementsEqual(text.utf8) else { throw FileComparisonEditFailure.encoding }
        return bom + bytes
    }
    // UDiff is a byte-oriented document editor. Embedded NUL is data here;
    // compare/merge text saves retain their existing NUL rejection above.
    var patchBOM:Data {bom}
    func encodePatchPayload(_ text:String) throws ->Data {
        guard let bytes=text.data(using:codec,allowLossyConversion:false),
              let recovered=decodePayload(bytes),recovered.utf8.elementsEqual(text.utf8) else {throw FileComparisonEditFailure.encoding}
        return bytes
    }
    func decodePatchPayload(_ bytes:Data)->String? {
        guard let text=decodePayload(bytes),text.data(using:codec,allowLossyConversion:false)==bytes else{return nil}
        return text
    }
    public func decode(_ bytes: Data) -> String? {
        let body = !bom.isEmpty && bytes.starts(with: bom) ? Data(bytes.dropFirst(bom.count)) : bytes
        guard let text = decodePayload(body), !text.unicodeScalars.contains(where: { $0.value == 0 }),
              text.data(using: codec, allowLossyConversion: false) == body else { return nil }
        return text
    }
    /// Foundation treats a leading U+FEFF as a header. A sentinel keeps an
    /// actual text character intact after this format's BOM has been removed.
    private func decodePayload(_ bytes: Data) -> String? {
        guard let prefix = "x".data(using: codec), var text = String(data: prefix + bytes, encoding: codec), text.first == "x" else { return nil }
        text.removeFirst()
        return text
    }
    /// Reuse the source CheckUnicodeType classifier; decoding remains lossless.
    /// CP_ACP is supplied explicitly on macOS; retained documents own their codec.
    public static func detectMerge(_ bytes: Data, preferUTF8: Bool, legacyEncoding:Self = .windows1252) -> ComparisonTextEncoding? {
        let value: Self
        switch MessageCodeText.detect(bytes, useUTF8: preferUTF8) {
        case .binary: return nil
        case .ascii: value = legacyEncoding.legacyCodePage == nil ? .windows1252 : legacyEncoding
        case .utf8: value = .utf8
        case .utf8BOM: value = .utf8BOM
        case .utf16LE: value = .utf16LE
        case .utf16BE: value = .utf16BE
        case .utf16LEBOM: value = .utf16LEBOM
        case .utf16BEBOM: value = .utf16BEBOM
        case .utf32LE: value = .utf32LE
        case .utf32BE: value = .utf32BE
        }
        return value.decode(bytes) == nil ? nil : value
    }
    public static func preferUTF8(from defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: "TurtleGitMerge.UseUTF8") != nil { return defaults.bool(forKey: "TurtleGitMerge.UseUTF8") }
        return defaults.bool(forKey: "Merge.UseUTF8") // prior completion-scanner preference
    }
    public static func detect(_ bytes: Data) -> ComparisonTextEncoding? {
        for value in [Self.utf32LE, .utf32BE, .utf16LEBOM, .utf16BEBOM, .utf8BOM] {
            if bytes.starts(with: value.bom) { return value.decode(bytes) == nil ? nil : value }
        }
        if Self.utf8.decode(bytes) != nil { return .utf8 }
        // Require zero-byte evidence before considering BOM-less UTF-16;
        // arbitrary invalid UTF-8 remains binary until explicitly decoded.
        guard bytes.count >= 4, bytes.count % 2 == 0 else { return nil }
        let data = Array(bytes), count = data.count / 2
        let little = stride(from: 1, to: data.count, by: 2).filter { data[$0] == 0 }.count
        let big = stride(from: 0, to: data.count, by: 2).filter { data[$0] == 0 }.count
        guard max(little, big) * 4 >= count * 3, little != big else { return nil }
        let value: Self = little > big ? .utf16LE : .utf16BE
        guard let text = value.decode(bytes), text.unicodeScalars.contains(where: { $0.value >= 32 && $0.value != 127 }) else { return nil }
        return value
    }
}

/// One captured load policy, independent of later preference edits.
public struct MergeTextEncodingPolicy:Equatable,Sendable {
    public let preferUTF8:Bool
    public let legacyEncoding:ComparisonTextEncoding
    public init(preferUTF8:Bool,legacyEncoding:ComparisonTextEncoding = .windows1252) {
        self.preferUTF8=preferUTF8
        self.legacyEncoding=legacyEncoding.legacyCodePage == nil ? .windows1252:legacyEncoding
    }
    public init(defaults:UserDefaults) {
        self.init(preferUTF8:ComparisonTextEncoding.preferUTF8(from:defaults),legacyEncoding:.legacyEncoding(from:defaults))
    }
    public func applying(_ content:ComparisonFileContent)->ComparisonFileContent {
        // A legacy fallback must not promote binary patch content via the
        // source detector's permissive BOM-less UTF16 guess. Keep the original
        // Unicode/binary decision for NUL-containing payloads.
        if content.bytes.contains(0),ComparisonTextEncoding.detect(content.bytes) == nil {return content}
        return content.usingMergeEncoding(preferUTF8:preferUTF8,legacyEncoding:legacyEncoding)
    }
    public func applying(_ document:FileComparisonDocument)->FileComparisonDocument {
        FileComparisonDocument(base:applying(document.base),destination:applying(document.destination))
    }
}

public enum FileComparisonEditFailure: LocalizedError {
    case unsupported, changed, readOnly, range, encoding
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Choose a regular working-tree text file to edit."
        case .changed: return "The working file or its permissions changed. Reload before saving."
        case .readOnly: return "The working file is read-only."
        case .encoding: return "The selected encoding cannot represent this text without losing characters."
        case .range: return "The selected text changed. Select it again."
        }
    }
}
/// AppKit selections refer to aligned display rows; gaps and display-only final
/// newlines must never become bytes in the saved file.
public enum FileComparisonEditing {
    public struct Annotations: Equatable, Sendable {
        public var marked: Set<Int>
        public var edited: Set<Int>
        public init(marked: Set<Int> = [], edited: Set<Int> = []) { self.marked = marked; self.edited = edited }
        /// Retain row flags across insertion/deletion/re-alignment. Replacement
        /// lines inherit flags; deleted lines can retain flags on source gaps.
        public func remapped(from old: FileComparisonAlignment, to new: FileComparisonAlignment, targetBase: Bool, typing: Bool) -> Annotations {
            func target(_ row: FileComparisonRow) -> MergeSourceCell { targetBase ? row.base : row.destination }
            func other(_ row: FileComparisonRow) -> MergeSourceCell { targetBase ? row.destination : row.base }
            let before = old.rows.map(target).filter { $0.lineNumber != nil }.map(\.text).joined()
            let after = new.rows.map(target).filter { $0.lineNumber != nil }.map(\.text).joined()
            let changes = FileComparisonAlignment(base: before, destination: after)
            var lineMap: [Int: Int] = [:], changedLines = Set<Int>(), deletedLines = Set<Int>()
            for row in changes.rows {
                if let a = row.base.lineNumber, let b = row.destination.lineNumber { lineMap[a] = b }
                if row.changed {
                    if let b = row.destination.lineNumber { changedLines.insert(b) }
                    else if let a = row.base.lineNumber { deletedLines.insert(a) }
                }
            }
            let targetRows = Dictionary(uniqueKeysWithValues: new.rows.enumerated().compactMap { i, row in target(row).lineNumber.map { ($0, i) } })
            let otherRows = Dictionary(uniqueKeysWithValues: new.rows.enumerated().compactMap { i, row in other(row).lineNumber.map { ($0, i) } })
            func moved(_ indices: Set<Int>) -> Set<Int> {
                Set(indices.compactMap { index in
                    guard old.rows.indices.contains(index) else { return nil }
                    let row = old.rows[index]
                    if let line = target(row).lineNumber, let mapped = lineMap[line], let i = targetRows[mapped] { return i }
                    return other(row).lineNumber.flatMap { otherRows[$0] }
                })
            }
            var result = Annotations(marked: moved(marked), edited: moved(edited))
            if typing {
                result.edited.formUnion(changedLines.compactMap { targetRows[$0] })
                for row in old.rows where target(row).lineNumber.map({ deletedLines.contains($0) }) == true {
                    if let line = other(row).lineNumber, let i = otherRows[line] { result.edited.insert(i) }
                }
            }
            return result
        }
    }
    public enum MarkedSaveChoice: Sendable { case include, exclude, manualEditsOnly }
    public static func leavingOnlyMarked(_ alignment: FileComparisonAlignment, targetBase: Bool, annotations: Annotations) throws -> String {
        try resolvingMarkedBlocks(alignment, targetBase: targetBase, annotations: annotations, choice: .include)
    }
    public static func resolvingMarkedBlocks(_ alignment: FileComparisonAlignment, targetBase: Bool, annotations: Annotations, choice: MarkedSaveChoice) throws -> String {
        guard annotations.marked.union(annotations.edited).allSatisfy({ alignment.rows.indices.contains($0) }) else { throw FileComparisonEditFailure.range }
        func target(_ row: FileComparisonRow) -> MergeSourceCell { targetBase ? row.base : row.destination }
        let original = alignment.rows.map(target).filter { $0.lineNumber != nil }.map(\.text).joined()
        let style: MergeLineEnding = MergeLineEndings.predominantStyle(in: original)
        let lines = alignment.rows.enumerated().map { index, row in
            let keep: Bool
            switch choice {
            case .include: keep = annotations.marked.contains(index) || annotations.edited.contains(index)
            case .exclude: keep = !annotations.marked.contains(index) || annotations.edited.contains(index)
            case .manualEditsOnly: keep = annotations.edited.contains(index)
            }
            if keep { return target(row).lineNumber == nil ? "" : target(row).text }
            let source = targetBase ? row.destination : row.base
            return source.lineNumber == nil ? "" : MergeLineEndings.converting(source.text, to: style)
        }.filter { !$0.isEmpty }
        return lines.enumerated().map { index, line in
            if index < lines.count - 1, !MergeLineEndings.hasFinalEnding(line) { return line + style.rawValue }
            return line
        }.joined()
    }
    public enum BlockChoice: Sendable { case other, otherThenCurrent, currentThenOther }
    public static func takingOtherBlock(_ alignment: FileComparisonAlignment, difference: Int, targetBase: Bool, choice: BlockChoice = .other) throws -> (text: String, caret: Int) {
        guard alignment.differences.indices.contains(difference) else { throw FileComparisonEditFailure.range }
        return try takingOtherRows(alignment, rows: alignment.differences[difference], targetBase: targetBase, choice: choice)
    }
    public static func takingOtherRows(_ alignment: FileComparisonAlignment, rows range: Range<Int>, targetBase: Bool, choice: BlockChoice = .other) throws -> (text: String, caret: Int) {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= alignment.rows.count else { throw FileComparisonEditFailure.range }
        func target(_ row: FileComparisonRow) -> MergeSourceCell { targetBase ? row.base : row.destination }
        func other(_ row: FileComparisonRow) -> MergeSourceCell { targetBase ? row.destination : row.base }
        let original = alignment.rows.map(target).filter { $0.lineNumber != nil }.map(\.text).joined()
        let start = alignment.rows.prefix(range.lowerBound).map(target).filter { $0.lineNumber != nil }.reduce(0) { $0 + ($1.text as NSString).length }
        let length = alignment.rows[range].map(target).filter { $0.lineNumber != nil }.reduce(0) { $0 + ($1.text as NSString).length }
        let style: MergeLineEnding = MergeLineEndings.predominantStyle(in: original)
        // UseViewBlock normalizes incoming ended lines to the target style,
        // while preserving a source line that has no ending.
        let otherText = MergeLineEndings.converting(alignment.rows[range].map(other).filter { $0.lineNumber != nil }.map(\.text).joined(), to: style)
        let currentText = alignment.rows[range].map(target).filter { $0.lineNumber != nil }.map(\.text).joined()
        func both(_ first: String, _ second: String) -> String {
            let separator = !first.isEmpty && !second.isEmpty && !MergeLineEndings.hasFinalEnding(first) ? style.rawValue : ""
            return first + separator + second
        }
        let replacement: String
        switch choice { case .other: replacement = otherText; case .otherThenCurrent: replacement = both(otherText, currentText); case .currentThenOther: replacement = both(currentText, otherText) }
        if choice == .other {
            // UseViewBlock::VerifyEols makes every occupied record except the
            // last an ended line. A real empty EOF record counts as occupied;
            // alignment gaps do not. In particular, accepting an added EOF
            // record after an unterminated target line must supply its ending.
            let before = alignment.rows.prefix(range.lowerBound).map(target).filter { $0.lineNumber != nil }.map(\.text)
            let incoming = alignment.rows[range].map(other).filter { $0.lineNumber != nil }.map { MergeLineEndings.converting($0.text,to:style) }
            let after = alignment.rows.suffix(from:range.upperBound).map(target).filter { $0.lineNumber != nil }.map(\.text)
            let records = before + incoming + after
            let text = records.enumerated().map { index,value in
                index < records.count - 1 && !MergeLineEndings.hasFinalEnding(value) ? value + style.rawValue:value
            }.joined()
            let caret = (before + incoming).enumerated().reduce(0) { count,item in
                count + item.element.utf16.count + (item.offset < records.count - 1 && !MergeLineEndings.hasFinalEnding(item.element) ? style.rawValue.utf16.count:0)
            }
            return (text,caret)
        }
        return ((original as NSString).replacingCharacters(in: NSRange(location: start, length: length), with: replacement), start + (replacement as NSString).length)
    }
    public static func exported(_ content: ComparisonFileContent, editedText: String? = nil) throws -> Data {
        try editedText.map { try encoded($0, like: content) } ?? content.bytes
    }
    public static func applying(_ replacement: String, range: NSRange, cells: [MergeSourceCell]) throws -> (text: String, caret: Int) {
        let source = try sourceRange(range, cells: cells)
        let original = cells.filter { $0.hasSourceCoordinate }.map(\.text).joined()
        let style: MergeLineEnding = MergeLineEndings.predominantStyle(in: original)
        let inserted = MergeLineEndings.converting(replacement, to: style)
        return ((original as NSString).replacingCharacters(in: source, with: inserted), source.location + (inserted as NSString).length)
    }
    public static func selectedText(_ range: NSRange, cells: [MergeSourceCell]) throws -> String {
        let source = try sourceRange(range, cells: cells)
        return (cells.filter { $0.hasSourceCoordinate }.map(\.text).joined() as NSString).substring(with: source)
    }
    public static func indentation(_ range: NSRange, cells: [MergeSourceCell], tabWidth: Int, useSpaces: Bool, smart: Bool, remove: Bool = false) throws -> (text: String, selection: NSRange)? {
        let selection = try sourceRange(range, cells: cells)
        let original = cells.filter { $0.hasSourceCoordinate }.map(\.text).joined()
        if let edit = MergeWhitespace.indentSelection(in: original, selection: selection, tabWidth: tabWidth, useSpaces: useSpaces, smart: smart, remove: remove) {
            let result = (original as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            guard !result.utf8.elementsEqual(original.utf8) else { return nil }
            return (result, NSRange(location: edit.range.location, length: (edit.replacement as NSString).length))
        }
        guard !remove else { return nil }
        let remaining = (original as NSString).replacingCharacters(in: selection, with: "")
        let insertion = MergeWhitespace.tabInsertion(in: remaining, utf16Offset: selection.location, tabWidth: tabWidth, useSpaces: useSpaces, smart: smart)
        return ((remaining as NSString).replacingCharacters(in: NSRange(location: selection.location, length: 0), with: insertion), NSRange(location: selection.location + (insertion as NSString).length, length: 0))
    }
    public static func selectedRows(_ range: NSRange, cells: [MergeSourceCell]) throws -> Range<Int>? {
        _ = try sourceRange(range, cells: cells)
        guard range.length > 0, !cells.isEmpty else { return nil }
        func row(_ offset: Int) -> Int {
            var cursor = 0
            for (index, cell) in cells.enumerated() {
                cursor += (cell.displayText as NSString).length + 1
                if offset < cursor { return index }
            }
            return cells.count - 1
        }
        // Upstream block endpoints are inclusive, including a selection ending
        // at column zero of the next row. Clamp the synthetic final row to EOF.
        return row(range.location)..<(row(NSMaxRange(range)) + 1)
    }
    public static func sourceRange(_ range: NSRange, cells: [MergeSourceCell]) throws -> NSRange {
        let displayLength = cells.reduce(0) { $0 + ($1.displayText as NSString).length + 1 }
        guard range.location >= 0, range.length >= 0, range.location <= displayLength, range.length <= displayLength - range.location else { throw FileComparisonEditFailure.range }
        func sourceOffset(_ offset: Int) -> Int {
            var display = 0, source = 0
            for cell in cells {
                let payload = (cell.displayText as NSString).length, length = payload + 1
                if offset < display + length {
                    guard cell.hasSourceCoordinate else { return source }
                    return source + min(offset - display, payload)
                }
                display += length
                if cell.hasSourceCoordinate { source += (cell.text as NSString).length }
            }
            return source
        }
        let start = sourceOffset(range.location), end = sourceOffset(NSMaxRange(range))
        return NSRange(location: start, length: end - start)
    }
    public static func displayOffset(sourceOffset: Int, cells: [MergeSourceCell]) -> Int {
        var display = 0, source = 0
        for cell in cells {
            let payload = (cell.displayText as NSString).length
            if cell.hasSourceCoordinate {
                let length = (cell.text as NSString).length
                if sourceOffset <= source + payload { return display + max(0, sourceOffset - source) }
                if sourceOffset < source + length { return display + payload }
                source += length
            }
            display += payload + 1
        }
        return display
    }
    public static func encoded(_ text: String, like content: ComparisonFileContent, encoding: ComparisonTextEncoding? = nil) throws -> Data {
        guard content.text != nil, let value = encoding ?? content.encoding else { throw FileComparisonEditFailure.unsupported }
        return try value.encode(text)
    }

}
extension GitRepository {
    public func saveComparisonFile(_ snapshot: RevisionComparisonSnapshot, document: FileComparisonDocument, base: Bool, text: String, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init(), cancellation:OperationCancellation? = nil) throws -> FileComparisonDocument {
        try cancellation?.check()
        let original = base ? document.base : document.destination
        guard snapshot.root == root, snapshot.files.contains(where: { $0.path == document.destination.path }),
              original.revision == .workingTree, ["100644", "100755"].contains(original.mode ?? ""), original.permissions != nil else { throw FileComparisonEditFailure.unsupported }
        let saved = try FileComparisonEditing.saveWorkingContent(at: restoreLocation(original.path), original: original, text: text, encoding: encoding, options: options,cancellation:cancellation)
        return FileComparisonDocument(base: base ? saved : document.base, destination: base ? document.destination : saved)
    }
}


extension FileComparisonEditing {
    /// Same byte/permission checks for repository and standalone working files.
    public static func saveWorkingContent(at location: URL, original: ComparisonFileContent, text: String, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init(),cancellation:OperationCancellation? = nil) throws -> ComparisonFileContent {
        try cancellation?.check()
        guard location.isFileURL, original.revision == .workingTree,
              ["100644", "100755"].contains(original.mode ?? ""), let permissions = original.permissions else { throw FileComparisonEditFailure.unsupported }
        guard options.emptyResult != .delete || text.isEmpty else { throw MergeFileSaveFailure.nonemptyDeletion }
        let manager = FileManager.default
        func validate() throws {
            try cancellation?.check()
            if original.isDeleted {
                do { _ = try manager.attributesOfItem(atPath: location.path); throw FileComparisonEditFailure.changed }
                catch let failure as CocoaError where failure.code == .fileNoSuchFile || failure.code == .fileReadNoSuchFile { return }
            }
            guard let attributes = try? manager.attributesOfItem(atPath: location.path), attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == permissions,
                  (try? Data(contentsOf: location)) == original.bytes else { throw FileComparisonEditFailure.changed }
            guard permissions & 0o222 != 0, manager.isWritableFile(atPath: location.path) else { throw FileComparisonEditFailure.readOnly }
        }
        try validate()
        let bytes = try original.isDeleted ? (encoding ?? original.encoding ?? .utf8).encode(text) : FileComparisonEditing.encoded(text, like: original, encoding: encoding)
        let deleting = options.emptyResult == .delete
        try MergeWorkingFileSave.write(at: location, original: original.isDeleted ? nil : original.bytes, permissions: permissions,
                                       bytes: bytes, delete: deleting, backup: options.backupOriginal, outputDirectories: options.outputDirectories, validate: validate)
        return ComparisonFileContent(path: original.path, revision: original.revision, bytes: deleting ? Data() : bytes,
                                     mode: original.mode, permissions: permissions, encoding: encoding ?? original.encoding, isDeleted: deleting)
    }
}

/// Independent working-pane drafts; historical/binary panes remain immutable.
public struct FileComparisonDrafts {
    private struct Pane {
        var content: ComparisonFileContent
        var text: String?
        var annotations = FileComparisonEditing.Annotations()
        var savedMarks = Set<Int>()
        var savedEdits = Set<Int>()
        var editRevision: UUID?
        var savedEditRevision: UUID?
        var enabled = false
        var externallyChanged = false
        var encoding: ComparisonTextEncoding?
    }
    private var panes: [Bool: Pane]
    public init(_ document: FileComparisonDocument) {
        panes = [true: Pane(content: document.base, text: document.base.text, encoding: document.base.encoding), false: Pane(content: document.destination, text: document.destination.text, encoding: document.destination.encoding)]
        if canEdit(base: false) { panes[false]?.enabled = true }
    }
    public func canEdit(base: Bool) -> Bool {
        guard let pane = panes[base] else { return false }
        return pane.content.revision == .workingTree && ["100644", "100755"].contains(pane.content.mode ?? "") && pane.text != nil
    }
    public var preferredBase: Bool { !canEdit(base: false) && canEdit(base: true) }
    public func encoding(base: Bool) -> ComparisonTextEncoding? { panes[base]?.encoding }
    public mutating func setEncoding(_ value: ComparisonTextEncoding, base: Bool) throws {
        guard canEdit(base: base), let text = panes[base]?.text else { throw FileComparisonEditFailure.unsupported }
        _ = try value.encode(text)
        panes[base]?.encoding = value
    }
    public func text(base: Bool) -> String? { panes[base]?.text }
    public func annotations(base: Bool) -> FileComparisonEditing.Annotations { panes[base]?.annotations ?? .init() }
    public func editRevision(base: Bool) -> UUID? { panes[base]?.editRevision }
    public mutating func setEditRevision(_ revision: UUID?, base: Bool) { panes[base]?.editRevision = revision }
    public func editingEnabled(base: Bool) -> Bool { canEdit(base: base) && panes[base]?.enabled == true }
    public mutating func setEditing(_ enabled: Bool, base: Bool) { let eligible = canEdit(base: base); panes[base]?.enabled = enabled && eligible }
    public mutating func update(text: String, base: Bool) throws {
        guard canEdit(base: base) else { throw FileComparisonEditFailure.unsupported }
        panes[base]?.text = text
    }
    public mutating func update(annotations: FileComparisonEditing.Annotations, base: Bool) { panes[base]?.annotations = annotations }
    public func isDirty(base: Bool) -> Bool {
        guard canEdit(base: base), let pane = panes[base], let text = pane.text, let original = pane.content.text else { return false }
        return pane.externallyChanged || !text.utf8.elementsEqual(original.utf8) || pane.annotations.marked != pane.savedMarks || pane.annotations.edited != pane.savedEdits || pane.editRevision != pane.savedEditRevision || pane.encoding != pane.content.encoding
    }
    /// Keep the displayed version modified without accepting different disk
    /// bytes as its compare-and-swap save baseline.
    public mutating func markExternallyChanged(base: Bool) {
        guard canEdit(base: base) else { return }
        panes[base]?.externallyChanged = true
    }
    public var dirtySides: [Bool] { [false, true].filter { isDirty(base: $0) } }
    public var dirtyPaths: [String] { dirtySides.compactMap { panes[$0]?.content.path } }
    mutating func rebindSavedPane(_ content: ComparisonFileContent, base: Bool) {
        guard var pane = panes[base] else { return }
        pane.content = content; pane.text = content.text; pane.encoding = content.encoding
        pane.savedMarks = pane.annotations.marked
        pane.savedEdits = pane.annotations.edited
        pane.savedEditRevision = pane.editRevision
        pane.externallyChanged = false
        panes[base] = pane
    }
    public mutating func didSave(_ content: ComparisonFileContent, base: Bool) throws {
        guard let pane = panes[base], pane.content.path == content.path, pane.content.revision == content.revision else { throw RevisionComparisonFailure.selection }
        panes[base]?.content = content
        panes[base]?.savedMarks = pane.annotations.marked
        panes[base]?.savedEdits = pane.annotations.edited
        panes[base]?.savedEditRevision = pane.editRevision
        panes[base]?.externallyChanged = false
    }
    public mutating func remapAnnotations(from old: FileComparisonAlignment, to new: FileComparisonAlignment, base: Bool) {
        guard let pane = panes[base] else { return }
        panes[base]?.annotations = pane.annotations.remapped(from: old, to: new, targetBase: base, typing: false)
        panes[base]?.savedMarks = FileComparisonEditing.Annotations(marked: pane.savedMarks).remapped(from: old, to: new, targetBase: base, typing: false).marked
        panes[base]?.savedEdits = FileComparisonEditing.Annotations(edited: pane.savedEdits).remapped(from: old, to: new, targetBase: base, typing: false).edited
    }
    public func exported(base: Bool) throws -> Data {
        guard let pane = panes[base] else { throw RevisionComparisonFailure.selection }
        if canEdit(base: base), let text = pane.text { return try FileComparisonEditing.encoded(text, like: pane.content, encoding: pane.encoding) }
        return pane.content.bytes
    }
}

public enum MergeEmptyResult: Sendable, Equatable { case keep, delete }
/// A named output may have missing parents. Capture the last existing folder
/// before authorization, then create only the missing suffix under its identity.
/// Existing macOS aliases such as /var are resolved once, never followed anew
/// during creation or publication.
public struct MergeOutputDirectories: Sendable {
    public let output: URL
    public let ancestor: URL
    private let canonicalAncestor: URL
    private let identity: String
    private let components: [String]
    private static func identity(_ info: stat) -> String { "\(info.st_dev):\(info.st_ino)" }
    public init(capturing output: URL) throws {
        let output = output.standardizedFileURL
        guard output.isFileURL, !output.path.utf8.contains(0), !output.lastPathComponent.isEmpty else { throw FileComparisonEditFailure.unsupported }
        self.output = output
        var directory = output.deletingLastPathComponent(), missing: [String] = []
        while true {
            var info = stat()
            if fstatat(AT_FDCWD, directory.path, &info, 0) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw FileComparisonEditFailure.unsupported }
                ancestor = directory; canonicalAncestor = directory.resolvingSymlinksInPath(); identity = Self.identity(info)
                components = Array(missing.reversed()); return
            }
            guard errno == ENOENT, directory.path != "/" else { throw FileComparisonEditFailure.changed }
            let name = directory.lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { throw FileComparisonEditFailure.unsupported }
            missing.append(name); directory.deleteLastPathComponent()
        }
    }
    private func openAncestor() throws -> Int32 {
        guard ancestor.resolvingSymlinksInPath().path.utf8.elementsEqual(canonicalAncestor.path.utf8) else { throw FileComparisonEditFailure.changed }
        let fd = open(canonicalAncestor.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FileComparisonEditFailure.changed }
        var info = stat()
        guard fstat(fd, &info) == 0, Self.identity(info) == identity else { Darwin.close(fd); throw FileComparisonEditFailure.changed }
        return fd
    }
    /// Executes with a pinned destination directory. Failure removes only our
    /// still-empty new directories, never a peer's replacement or contents.
    fileprivate func withParent<T>(at output: URL, validate: () throws -> Void, _ body: (Int32, () throws -> Void) throws -> T) throws -> T {
        guard self.output.path.utf8.elementsEqual(output.standardizedFileURL.path.utf8) else { throw FileComparisonEditFailure.changed }
        var descriptors = [try openAncestor()]
        var created: [(parent: Int32, name: String, identity: String)] = []
        defer {
            for item in created.reversed() {
                var info = stat()
                if fstatat(item.parent, item.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                   info.st_mode & S_IFMT == S_IFDIR, Self.identity(info) == item.identity {
                    _ = unlinkat(item.parent, item.name, AT_REMOVEDIR)
                }
            }
            for fd in descriptors.reversed() { Darwin.close(fd) }
        }
        try validate()
        for name in components {
            try validate()
            let parent = descriptors.last!
            guard mkdirat(parent, name, 0o755) == 0 else { throw FileComparisonEditFailure.changed }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FileComparisonEditFailure.changed }
            var info = stat()
            guard fstat(fd, &info) == 0 else { Darwin.close(fd); throw FileComparisonEditFailure.changed }
            created.append((parent, name, Self.identity(info))); descriptors.append(fd)
        }
        func validateParent() throws {
            var named = try openAncestor()
            defer { Darwin.close(named) }
            for name in components {
                let child = openat(named, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw FileComparisonEditFailure.changed }
                Darwin.close(named); named = child
            }
            var actual = stat(), expected = stat()
            guard fstat(named, &actual) == 0, fstat(descriptors.last!, &expected) == 0,
                  Self.identity(actual) == Self.identity(expected) else { throw FileComparisonEditFailure.changed }
        }
        try validateParent()
        return try body(descriptors.last!, validateParent)
    }
}

/// A successful new ordinary result owns this receipt even if its later Git Add
/// fails. Retrying Add validates the exact saved file, without repeating Save.
/// Save As/source copies must not request a receipt.
public struct MergeNewOutputReceipt: Sendable {
    public let url: URL
    private let target: MergeToolOutputTarget
    public static func capture(before: ComparisonFileContent, after: ComparisonFileContent, at url: URL) throws -> Self? {
        guard before.isDeleted, !after.isDeleted else { return nil }
        guard ["100644", "100755"].contains(after.mode ?? "") else { throw FileComparisonEditFailure.unsupported }
        let target = try MergeToolOutputTarget(capturing: url)
        guard !target.content.isDeleted, target.content.bytes == after.bytes, target.content.permissions == after.permissions,
              target.content.mode == after.mode else { throw FileComparisonEditFailure.changed }
        return Self(url: target.url, target: target)
    }
    public func validate() throws { try target.validate() }
    /// Preserve this session's initial-new intent after an accepted same-path
    /// ordinary resave. The caller has already applied the disk CAS receipt.
    public func refreshingSavedOutput(_ after: ComparisonFileContent) throws -> Self? {
        guard !after.isDeleted else { return nil }
        let absent = ComparisonFileContent(path: url.path, revision: .workingTree, bytes: Data(), mode: after.mode, permissions: after.permissions, isDeleted: true)
        return try Self.capture(before: absent, after: after, at: url)
    }
}

public enum MergeNewOutputFailure: LocalizedError {
    case indexChanged
    public var errorDescription: String? {
        "The merged result was saved, but the Git index already contains different content for this path. Review the index before adding the result."
    }
}

extension GitRepository {
    /// Only a caller with an actual authorized repository may invoke this policy.
    /// The literal path packet changes this result's index entry, never its peers.
    public func addNewMergeOutput(_ receipt: MergeNewOutputReceipt, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        let prefix = root.standardizedFileURL.path + "/", location = receipt.url.standardizedFileURL.path
        guard location.utf8.starts(with: prefix.utf8), RepositoryAccessLease.pathIsContained(receipt.url, by: root) else { throw FileComparisonEditFailure.unsupported }
        let path = String(location.dropFirst(prefix.count))
        guard !path.isEmpty, !path.split(separator: "/").contains(".git") else { throw FileComparisonEditFailure.unsupported }
        try receipt.validate(); try cancellation?.check()
        let snapshot = try captureCommitIndex(cancellation: cancellation)
        let lock = URL(fileURLWithPath: snapshot.location.path + ".lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GitFailure(arguments: ["add"], code: 1, message: "Could not lock the Git index: " + String(cString: strerror(errno))) }
        defer {
            var owned = stat(), current = stat()
            if fstat(descriptor, &owned) == 0, lstat(lock.path, &current) == 0,
               owned.st_dev == current.st_dev, owned.st_ino == current.st_ino { _ = unlink(lock.path) }
            Darwin.close(descriptor)
        }
        guard try commitIndexBytes(at: snapshot.location) == snapshot.bytes else { throw MergeNewOutputFailure.indexChanged }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: snapshot.location.path))?[.posixPermissions] as? NSNumber
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-new-merge-output-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateIndex = directory.appendingPathComponent("index"), environment = ["GIT_INDEX_FILE": directory.appendingPathComponent("index").path]
        if let bytes = snapshot.bytes { try bytes.write(to: privateIndex) }
        else { _ = try run(["read-tree", "--empty"], environmentOverrides: environment, cancellation: cancellation) }
        _ = try run(["-c", "core.splitIndex=false", "update-index", "--no-split-index"], environmentOverrides: environment, cancellation: cancellation)
        let prior = try run(["ls-files", "--stage", "-z", "--", path], environmentOverrides: environment, cancellation: cancellation).stdout
        try receipt.validate()
        _ = try run(["add", "--pathspec-from-file=-", "--pathspec-file-nul"], environmentOverrides: environment, cancellation: cancellation, input: literalPathPacket([path]))
        let prepared = try run(["ls-files", "--stage", "-z", "--", path], environmentOverrides: environment, cancellation: cancellation).stdout
        guard !prepared.isEmpty, prior.isEmpty || prior == prepared else { throw MergeNewOutputFailure.indexChanged }
        try cancellation?.check(); try receipt.validate()
        guard try commitIndexBytes(at: snapshot.location) == snapshot.bytes else { throw MergeNewOutputFailure.indexChanged }
        // A cancelled Add that actually completed may be retried. An exact
        // existing index entry is already accepted; never rewrite its peers.
        if prior == prepared { return }
        let bytes = try Data(contentsOf: privateIndex)
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let output = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
        defer { try? output.close() }
        try output.write(contentsOf: bytes); try output.synchronize()
        if let permissions { guard fchmod(descriptor, mode_t(permissions.uint16Value)) == 0 else { throw CocoaError(.fileWriteUnknown) } }
        try cancellation?.check(); try receipt.validate()
        guard try commitIndexBytes(at: snapshot.location) == snapshot.bytes else { throw MergeNewOutputFailure.indexChanged }
        guard Darwin.rename(lock.path, snapshot.location.path) == 0 else { throw GitFailure(arguments: ["add"], code: 1, message: "Could not publish the new result's Git index entry: " + String(cString: strerror(errno))) }
    }
}

public struct MergeFileSaveOptions: Sendable {
    public var backupOriginal: Bool
    public var emptyResult: MergeEmptyResult
    public var outputDirectories: MergeOutputDirectories?
    public init(backupOriginal: Bool = false, emptyResult: MergeEmptyResult = .keep, outputDirectories: MergeOutputDirectories? = nil) {
        self.backupOriginal = backupOriginal; self.emptyResult = emptyResult; self.outputDirectories = outputDirectories
    }
    public static func backupEnabled(from defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: "TurtleGitMerge.Backup") }
    public static func saveBackupPreference(_ value: Bool, to defaults: UserDefaults = .standard) { defaults.set(value, forKey: "TurtleGitMerge.Backup") }
}
public enum MergeFileSaveFailure: LocalizedError {
    case nonemptyDeletion, backupTarget
    public var errorDescription: String? {
        switch self {
        case .nonemptyDeletion: return "Only an empty result can delete the working file."
        case .backupTarget: return "The .bak path is not a regular file. Move it before saving with Backup original file enabled."
        }
    }
}
/// Stage the new bytes and permissions before touching the current file. Unlike
/// the Windows MoveFileEx path, a failed preparation leaves the original intact.
/// Backups retain captured bytes/mode and replace only a regular .bak sibling.
enum MergeWorkingFileSave {
    /// Prepare a source FileSave backup without rewriting the current target.
    /// Patch review uses this after its generated patch has passed --check.
    static func backup(at location:URL,original:Data?,permissions:Int,validate:()throws->Void)throws {
        guard let original else{return}
        let manager=FileManager.default,target=URL(fileURLWithPath:location.path+".bak")
        let temporary=location.deletingLastPathComponent().appendingPathComponent(".TurtleGitBackup-"+UUID().uuidString)
        defer{try? manager.removeItem(at:temporary)}
        if let attributes=try? manager.attributesOfItem(atPath:target.path),attributes[.type] as? FileAttributeType != .typeRegular {throw MergeFileSaveFailure.backupTarget}
        try original.write(to:temporary,options:.withoutOverwriting)
        try manager.setAttributes([.posixPermissions:permissions],ofItemAtPath:temporary.path)
        try validate()
        guard Darwin.rename(temporary.path,target.path)==0 else{throw CocoaError(.fileWriteUnknown)}
    }
    static func write(at location: URL, original: Data?, permissions: Int, bytes: Data, delete: Bool, backup: Bool, outputDirectories: MergeOutputDirectories? = nil, validate: () throws -> Void) throws {
        // Deleting an already absent output must not create an empty hierarchy.
        if delete, original == nil { try validate(); return }
        let plan = try outputDirectories ?? MergeOutputDirectories(capturing: location)
        try plan.withParent(at: location, validate: validate) { parent, validateParent in
            let leaf = location.lastPathComponent
            let temporary = ".TurtleGitSave-" + UUID().uuidString
            let backupTemporary = ".TurtleGitBackup-" + UUID().uuidString
            defer { _ = unlinkat(parent, temporary, 0); _ = unlinkat(parent, backupTemporary, 0) }
            func posixFailure() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            func prepare(_ name: String, bytes: Data) throws {
                let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                guard fd >= 0 else { throw posixFailure() }
                defer { Darwin.close(fd) }
                try bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), min(65_536, raw.count - offset))
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw posixFailure() }
                        offset += count
                    }
                }
                guard fchmod(fd, mode_t(permissions)) == 0 else { throw posixFailure() }
            }
            if !delete { try prepare(temporary, bytes: bytes) }
            try validateParent(); try validate()
            if backup, let original {
                let name = leaf + ".bak"; var info = stat()
                if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard info.st_mode & S_IFMT == S_IFREG else { throw MergeFileSaveFailure.backupTarget }
                } else if errno != ENOENT { throw posixFailure() }
                try prepare(backupTemporary, bytes: original)
                try validateParent(); try validate()
                guard renameat(parent, backupTemporary, parent, name) == 0 else { throw posixFailure() }
            }
            try validateParent(); try validate()
            if delete {
                guard unlinkat(parent, leaf, 0) == 0 else { throw posixFailure() }
            } else {
                guard renameat(parent, temporary, parent, leaf) == 0 else { throw posixFailure() }
            }
        }
    }
}

/// IDD_ENCODING order and AutoLine semantics, independent of native controls.
public struct MergeFormatSelection: Equatable, Sendable {
    public var encoding: ComparisonTextEncoding
    public var ending: MergeLineEnding?
    public static let encodings: [ComparisonTextEncoding] = [.windows1252,.utf16LE,.utf16BE,.utf16LEBOM,.utf16BEBOM,.utf32LE,.utf32BE,.utf8,.utf8BOM]
    public static func encodingChoices(legacy:ComparisonTextEncoding)->[ComparisonTextEncoding] {
        [legacy.legacyCodePage == nil ? .windows1252 : legacy] + encodings.dropFirst()
    }
    public init(encoding: ComparisonTextEncoding, ending: MergeLineEnding? = nil) { self.encoding = encoding; self.ending = ending }
    public static func initial(encoding: ComparisonTextEncoding, text: String) -> Self {
        let styles = MergeLineEndings.styles(in:text)
        return .init(encoding:encoding,ending:styles.count == 1 ? styles.first : nil)
    }
    public func applying(to text: String) throws -> String {
        let value = ending.map { MergeLineEndings.converting(text,to:$0) } ?? text
        _ = try encoding.encode(value)
        return value
    }
}

/// Changes one view record's ending without re-diffing its neighbours or losing
/// one-pane removed rows. Display text/caret coordinates do not change.
public struct FileComparisonLineEndingEdit: Sendable {
    public let alignment:FileComparisonAlignment
    public let combined:OnePaneFileComparison?
    public let text:String
    public let alignmentRow:Int
    public init?(alignment:FileComparisonAlignment,combined:OnePaneFileComparison? = nil,base:Bool,row:Int) {
        let cells = combined?.cells ?? alignment.rows.map { base ? $0.base : $0.destination }
        guard cells.indices.contains(row),!cells[row].state.isViewEmpty,
              let changed = MergeTyping.cycledLine(cells[row].text) else {return nil}
        let cell = cells[row]
        let updated = MergeSourceCell(text:changed,lineNumber:cell.lineNumber ?? 1,state:.edited,hiddenByComparison:false)
        var rows = alignment.rows
        if let combined {
            let gap = MergeSourceCell(text:"",lineNumber:nil,state:.empty)
            var rightNumber = 0
            var projected:[OnePaneFileComparison.Row] = []
            rows = []
            for (index,original) in combined.rows.enumerated() {
                let value = index == row ? updated : original.cell
                let oldLeft = alignment.rows.indices.contains(original.alignmentRow) ? alignment.rows[original.alignmentRow].base : gap
                let left = original.base || original.cell.state.isUnchanged ? oldLeft : gap
                let included = index == row || !original.cell.state.isRemoval && original.cell.state != .empty
                if included {rightNumber += 1}
                let right = included ? MergeSourceCell(text:value.text,lineNumber:rightNumber,state:value.state,hiddenByComparison:value.hiddenByComparison) : gap
                rows.append(.init(base:left,destination:right))
                projected.append(.init(cell:included ? right : value,alignmentRow:index,base:index == row ? false : original.base))
            }
            alignmentRow = row
            let next = OnePaneFileComparison(retainedRows:projected)
            self.combined = next;text = next.sourceSaveText
        } else {
            guard rows.indices.contains(row),cell.hasSourceCoordinate else {return nil}
            alignmentRow = row;self.combined = nil
            rows[row] = base ? .init(base:updated,destination:rows[row].destination) : .init(base:rows[row].base,destination:updated)
            text = rows.map {base ? $0.base : $0.destination}.filter(\.hasSourceCoordinate).map(\.text).joined()
        }
        var differences:[Range<Int>] = [],start:Int?
        for index in 0...rows.count {
            let changed = index < rows.count && rows[index].changed
            if changed,start == nil {start = index}
            if !changed,let first = start {differences.append(first..<index);start = nil}
        }
        self.alignment = .init(rows:rows,differences:differences)
    }
}
