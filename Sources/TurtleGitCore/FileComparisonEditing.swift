import Foundation
import Darwin

/// Explicit output formats; UTF-32 choices include a BOM, as upstream does.
public enum ComparisonTextEncoding: String, CaseIterable, Sendable {
    case windows1252 = "ASCII (Windows-1252)"
    case utf8 = "UTF-8", utf8BOM = "UTF-8 BOM"
    case utf16LE = "UTF-16LE", utf16LEBOM = "UTF-16LE BOM"
    case utf16BE = "UTF-16BE", utf16BEBOM = "UTF-16BE BOM"
    case utf32LE = "UTF-32LE", utf32BE = "UTF-32BE"
    private var codec: String.Encoding {
        switch self {
        case .windows1252: return .windowsCP1252
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE, .utf16LEBOM: return .utf16LittleEndian
        case .utf16BE, .utf16BEBOM: return .utf16BigEndian
        case .utf32LE: return .utf32LittleEndian
        case .utf32BE: return .utf32BigEndian
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
    public func encode(_ text: String) throws -> Data {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }),
              let bytes = text.data(using: codec, allowLossyConversion: false),
              let recovered = decodePayload(bytes),
              recovered.utf8.elementsEqual(text.utf8) else { throw FileComparisonEditFailure.encoding }
        return bom + bytes
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
    public static func leavingOnlyMarked(_ alignment: FileComparisonAlignment, targetBase: Bool, annotations: Annotations) throws -> String {
        guard annotations.marked.union(annotations.edited).allSatisfy({ alignment.rows.indices.contains($0) }) else { throw FileComparisonEditFailure.range }
        func target(_ row: FileComparisonRow) -> MergeSourceCell { targetBase ? row.base : row.destination }
        let original = alignment.rows.map(target).filter { $0.lineNumber != nil }.map(\.text).joined()
        let style: MergeLineEnding = original.contains("\r\n") ? .crlf : .lf
        let lines = alignment.rows.enumerated().map { index, row in
            if annotations.marked.contains(index) || annotations.edited.contains(index) { return target(row).lineNumber == nil ? "" : target(row).text }
            let source = targetBase ? row.destination : row.base
            return source.lineNumber == nil ? "" : MergeLineEndings.converting(source.text, to: style)
        }.filter { !$0.isEmpty }
        return lines.enumerated().map { index, line in
            if index < lines.count - 1, line.utf16.last != 10, line.utf16.last != 13 { return line + (style == .crlf ? "\r\n" : "\n") }
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
        let style: MergeLineEnding = original.contains("\r\n") ? .crlf : .lf
        // UseViewBlock normalizes incoming ended lines to the target style,
        // while preserving a source line that has no ending.
        let otherText = MergeLineEndings.converting(alignment.rows[range].map(other).filter { $0.lineNumber != nil }.map(\.text).joined(), to: style)
        let currentText = alignment.rows[range].map(target).filter { $0.lineNumber != nil }.map(\.text).joined()
        func both(_ first: String, _ second: String) -> String {
            let separator = !first.isEmpty && !second.isEmpty && first.utf16.last != 10 && first.utf16.last != 13 ? (original.contains("\r\n") ? "\r\n" : "\n") : ""
            return first + separator + second
        }
        let replacement: String
        switch choice { case .other: replacement = otherText; case .otherThenCurrent: replacement = both(otherText, currentText); case .currentThenOther: replacement = both(currentText, otherText) }
        return ((original as NSString).replacingCharacters(in: NSRange(location: start, length: length), with: replacement), start + (replacement as NSString).length)
    }
    public static func exported(_ content: ComparisonFileContent, editedText: String? = nil) throws -> Data {
        try editedText.map { try encoded($0, like: content) } ?? content.bytes
    }
    public static func applying(_ replacement: String, range: NSRange, cells: [MergeSourceCell]) throws -> (text: String, caret: Int) {
        let source = try sourceRange(range, cells: cells)
        let original = cells.filter { $0.lineNumber != nil }.map(\.text).joined()
        let style: MergeLineEnding = original.contains("\r\n") ? .crlf : .lf
        let inserted = MergeLineEndings.converting(replacement, to: style)
        return ((original as NSString).replacingCharacters(in: source, with: inserted), source.location + (inserted as NSString).length)
    }
    public static func selectedText(_ range: NSRange, cells: [MergeSourceCell]) throws -> String {
        let source = try sourceRange(range, cells: cells)
        return (cells.filter { $0.lineNumber != nil }.map(\.text).joined() as NSString).substring(with: source)
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
    private static func sourceRange(_ range: NSRange, cells: [MergeSourceCell]) throws -> NSRange {
        let displayLength = cells.reduce(0) { $0 + ($1.displayText as NSString).length + 1 }
        guard range.location >= 0, range.length >= 0, range.location <= displayLength, range.length <= displayLength - range.location else { throw FileComparisonEditFailure.range }
        func sourceOffset(_ offset: Int) -> Int {
            var display = 0, source = 0
            for cell in cells {
                let payload = (cell.displayText as NSString).length, length = payload + 1
                if offset < display + length {
                    guard cell.lineNumber != nil else { return source }
                    return source + min(offset - display, payload)
                }
                display += length
                if cell.lineNumber != nil { source += (cell.text as NSString).length }
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
            if cell.lineNumber != nil {
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
    public func saveComparisonFile(_ snapshot: RevisionComparisonSnapshot, document: FileComparisonDocument, base: Bool, text: String, encoding: ComparisonTextEncoding? = nil) throws -> FileComparisonDocument {
        let original = base ? document.base : document.destination
        guard snapshot.root == root, snapshot.files.contains(where: { $0.path == document.destination.path }),
              original.revision == .workingTree, ["100644", "100755"].contains(original.mode ?? ""), original.permissions != nil else { throw FileComparisonEditFailure.unsupported }
        let saved = try FileComparisonEditing.saveWorkingContent(at: restoreLocation(original.path), original: original, text: text, encoding: encoding)
        return FileComparisonDocument(base: base ? saved : document.base, destination: base ? document.destination : saved)
    }
}


extension FileComparisonEditing {
    /// Same byte/permission checks for repository and standalone working files.
    public static func saveWorkingContent(at location: URL, original: ComparisonFileContent, text: String, encoding: ComparisonTextEncoding? = nil) throws -> ComparisonFileContent {
        guard location.isFileURL, original.revision == .workingTree,
              ["100644", "100755"].contains(original.mode ?? ""), let permissions = original.permissions else { throw FileComparisonEditFailure.unsupported }
        let manager = FileManager.default
        func validate() throws {
            guard let attributes = try? manager.attributesOfItem(atPath: location.path), attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == permissions,
                  (try? Data(contentsOf: location)) == original.bytes else { throw FileComparisonEditFailure.changed }
            guard permissions & 0o222 != 0, manager.isWritableFile(atPath: location.path) else { throw FileComparisonEditFailure.readOnly }
        }
        try validate()
        let bytes = try FileComparisonEditing.encoded(text, like: original, encoding: encoding)
        let temporary = location.deletingLastPathComponent().appendingPathComponent(".TurtleGitDiff-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        try validate()
        guard Darwin.rename(temporary.path, location.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return ComparisonFileContent(path: original.path, revision: original.revision, bytes: bytes, mode: original.mode, permissions: permissions, encoding: encoding ?? original.encoding)
    }
}

/// Independent working-pane drafts; historical/binary panes remain immutable.
public struct FileComparisonDrafts {
    private struct Pane {
        var content: ComparisonFileContent
        var text: String?
        var annotations = FileComparisonEditing.Annotations()
        var savedMarks = Set<Int>()
        var enabled = false
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
    public func editingEnabled(base: Bool) -> Bool { canEdit(base: base) && panes[base]?.enabled == true }
    public mutating func setEditing(_ enabled: Bool, base: Bool) { let eligible = canEdit(base: base); panes[base]?.enabled = enabled && eligible }
    public mutating func update(text: String, base: Bool) throws {
        guard canEdit(base: base) else { throw FileComparisonEditFailure.unsupported }
        panes[base]?.text = text
    }
    public mutating func update(annotations: FileComparisonEditing.Annotations, base: Bool) { panes[base]?.annotations = annotations }
    public func isDirty(base: Bool) -> Bool {
        guard canEdit(base: base), let pane = panes[base], let text = pane.text, let original = pane.content.text else { return false }
        return !text.utf8.elementsEqual(original.utf8) || pane.annotations.marked != pane.savedMarks || pane.encoding != pane.content.encoding
    }
    public var dirtySides: [Bool] { [false, true].filter { isDirty(base: $0) } }
    public var dirtyPaths: [String] { dirtySides.compactMap { panes[$0]?.content.path } }
    public mutating func didSave(_ content: ComparisonFileContent, base: Bool) throws {
        guard let pane = panes[base], pane.content.path == content.path, pane.content.revision == content.revision else { throw RevisionComparisonFailure.selection }
        panes[base]?.content = content
        panes[base]?.savedMarks = pane.annotations.marked
    }
    public mutating func remapAnnotations(from old: FileComparisonAlignment, to new: FileComparisonAlignment, base: Bool) {
        guard let pane = panes[base] else { return }
        panes[base]?.annotations = pane.annotations.remapped(from: old, to: new, targetBase: base, typing: false)
        panes[base]?.savedMarks = FileComparisonEditing.Annotations(marked: pane.savedMarks).remapped(from: old, to: new, targetBase: base, typing: false).marked
    }
    public func exported(base: Bool) throws -> Data {
        guard let pane = panes[base] else { throw RevisionComparisonFailure.selection }
        if canEdit(base: base), let text = pane.text { return try FileComparisonEditing.encoded(text, like: pane.content, encoding: pane.encoding) }
        return pane.content.bytes
    }
}
