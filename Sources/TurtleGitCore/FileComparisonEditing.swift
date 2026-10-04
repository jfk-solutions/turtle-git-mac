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
    public enum BlockChoice: Sendable { case other, otherThenCurrent, currentThenOther }
    public static func takingOtherBlock(_ alignment: FileComparisonAlignment, difference: Int, targetBase: Bool, choice: BlockChoice = .other) throws -> (text: String, caret: Int) {
        guard alignment.differences.indices.contains(difference) else { throw FileComparisonEditFailure.range }
        let range = alignment.differences[difference]
        func target(_ row: FileComparisonRow) -> MergeSourceCell { targetBase ? row.base : row.destination }
        func other(_ row: FileComparisonRow) -> MergeSourceCell { targetBase ? row.destination : row.base }
        let original = alignment.rows.map(target).filter { $0.lineNumber != nil }.map(\.text).joined()
        let start = alignment.rows.prefix(range.lowerBound).map(target).filter { $0.lineNumber != nil }.reduce(0) { $0 + ($1.text as NSString).length }
        let length = alignment.rows[range].map(target).filter { $0.lineNumber != nil }.reduce(0) { $0 + ($1.text as NSString).length }
        let otherText = alignment.rows[range].map(other).filter { $0.lineNumber != nil }.map(\.text).joined()
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
        let original = cells.filter { $0.lineNumber != nil }.map(\.text).joined()
        let start = sourceOffset(range.location), end = sourceOffset(NSMaxRange(range))
        let style: MergeLineEnding = original.contains("\r\n") ? .crlf : .lf
        let inserted = MergeLineEndings.converting(replacement, to: style)
        return ((original as NSString).replacingCharacters(in: NSRange(location: start, length: end - start), with: inserted), start + (inserted as NSString).length)
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
              original.revision == .workingTree, ["100644", "100755"].contains(original.mode ?? ""), let permissions = original.permissions else { throw FileComparisonEditFailure.unsupported }
        let location = try restoreLocation(original.path), manager = FileManager.default
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
        let saved = ComparisonFileContent(path: original.path, revision: original.revision, bytes: bytes, mode: original.mode, permissions: permissions)
        return FileComparisonDocument(base: base ? saved : document.base, destination: base ? document.destination : saved)
    }
}
