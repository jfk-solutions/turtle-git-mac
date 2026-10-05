import Foundation
import Darwin

public enum FileComparisonEditFailure: LocalizedError {
    case unsupported, changed, readOnly, range
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Choose a regular working-tree text file to edit."
        case .changed: return "The working file or its permissions changed. Reload before saving."
        case .readOnly: return "The working file is read-only."
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
    public static func encoded(_ text: String, like content: ComparisonFileContent) throws -> Data {
        guard content.text != nil, !text.utf8.contains(0) else { throw FileComparisonEditFailure.unsupported }
        if content.bytes.starts(with: [0xff, 0xfe]) { return Data([0xff, 0xfe]) + text.data(using: .utf16LittleEndian)! }
        if content.bytes.starts(with: [0xfe, 0xff]) { return Data([0xfe, 0xff]) + text.data(using: .utf16BigEndian)! }
        return (content.bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Data([0xef, 0xbb, 0xbf]) : Data()) + Data(text.utf8)
    }
}
extension GitRepository {
    public func saveComparisonFile(_ snapshot: RevisionComparisonSnapshot, document: FileComparisonDocument, base: Bool, text: String) throws -> FileComparisonDocument {
        let original = base ? document.base : document.destination
        guard snapshot.root == root, snapshot.files.contains(where: { $0.path == document.destination.path }),
              original.revision == .workingTree, ["100644", "100755"].contains(original.mode ?? ""), original.permissions != nil else { throw FileComparisonEditFailure.unsupported }
        let saved = try FileComparisonEditing.saveWorkingContent(at: restoreLocation(original.path), original: original, text: text)
        return FileComparisonDocument(base: base ? saved : document.base, destination: base ? document.destination : saved)
    }
}


extension FileComparisonEditing {
    /// Same byte/permission checks for repository and standalone working files.
    public static func saveWorkingContent(at location: URL, original: ComparisonFileContent, text: String) throws -> ComparisonFileContent {
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
        let bytes = try FileComparisonEditing.encoded(text, like: original)
        let temporary = location.deletingLastPathComponent().appendingPathComponent(".TurtleGitDiff-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        try validate()
        guard Darwin.rename(temporary.path, location.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return ComparisonFileContent(path: original.path, revision: original.revision, bytes: bytes, mode: original.mode, permissions: permissions)
    }
}
