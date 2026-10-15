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
    /// Reuse the source CheckUnicodeType classifier; decoding remains lossless.
    /// CP_ACP has no macOS equivalent, so ASCII/legacy uses the existing CP1252 adapter.
    public static func detectMerge(_ bytes: Data, preferUTF8: Bool) -> ComparisonTextEncoding? {
        let value: Self
        switch MessageCodeText.detect(bytes, useUTF8: preferUTF8) {
        case .binary: return nil
        case .ascii: value = .windows1252
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
        return ((original as NSString).replacingCharacters(in: NSRange(location: start, length: length), with: replacement), start + (replacement as NSString).length)
    }
    public static func exported(_ content: ComparisonFileContent, editedText: String? = nil) throws -> Data {
        try editedText.map { try encoded($0, like: content) } ?? content.bytes
    }
    public static func applying(_ replacement: String, range: NSRange, cells: [MergeSourceCell]) throws -> (text: String, caret: Int) {
        let source = try sourceRange(range, cells: cells)
        let original = cells.filter { $0.lineNumber != nil }.map(\.text).joined()
        let style: MergeLineEnding = MergeLineEndings.predominantStyle(in: original)
        let inserted = MergeLineEndings.converting(replacement, to: style)
        return ((original as NSString).replacingCharacters(in: source, with: inserted), source.location + (inserted as NSString).length)
    }
    public static func selectedText(_ range: NSRange, cells: [MergeSourceCell]) throws -> String {
        let source = try sourceRange(range, cells: cells)
        return (cells.filter { $0.lineNumber != nil }.map(\.text).joined() as NSString).substring(with: source)
    }
    public static func indentation(_ range: NSRange, cells: [MergeSourceCell], tabWidth: Int, useSpaces: Bool, smart: Bool, remove: Bool = false) throws -> (text: String, selection: NSRange)? {
        let selection = try sourceRange(range, cells: cells)
        let original = cells.filter { $0.lineNumber != nil }.map(\.text).joined()
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
    public func saveComparisonFile(_ snapshot: RevisionComparisonSnapshot, document: FileComparisonDocument, base: Bool, text: String, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init()) throws -> FileComparisonDocument {
        let original = base ? document.base : document.destination
        guard snapshot.root == root, snapshot.files.contains(where: { $0.path == document.destination.path }),
              original.revision == .workingTree, ["100644", "100755"].contains(original.mode ?? ""), original.permissions != nil else { throw FileComparisonEditFailure.unsupported }
        let saved = try FileComparisonEditing.saveWorkingContent(at: restoreLocation(original.path), original: original, text: text, encoding: encoding, options: options)
        return FileComparisonDocument(base: base ? saved : document.base, destination: base ? document.destination : saved)
    }
}


extension FileComparisonEditing {
    /// Same byte/permission checks for repository and standalone working files.
    public static func saveWorkingContent(at location: URL, original: ComparisonFileContent, text: String, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init()) throws -> ComparisonFileContent {
        guard location.isFileURL, original.revision == .workingTree,
              ["100644", "100755"].contains(original.mode ?? ""), let permissions = original.permissions else { throw FileComparisonEditFailure.unsupported }
        guard options.emptyResult != .delete || text.isEmpty else { throw MergeFileSaveFailure.nonemptyDeletion }
        let manager = FileManager.default
        func validate() throws {
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
                                       bytes: bytes, delete: deleting, backup: options.backupOriginal, validate: validate)
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
    mutating func rebindSavedPane(_ content: ComparisonFileContent, base: Bool) {
        guard var pane = panes[base] else { return }
        pane.content = content; pane.text = content.text; pane.encoding = content.encoding
        pane.savedMarks = pane.annotations.marked
        panes[base] = pane
    }
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

public enum MergeEmptyResult: Sendable, Equatable { case keep, delete }
public struct MergeFileSaveOptions: Sendable {
    public var backupOriginal: Bool
    public var emptyResult: MergeEmptyResult
    public init(backupOriginal: Bool = false, emptyResult: MergeEmptyResult = .keep) { self.backupOriginal = backupOriginal; self.emptyResult = emptyResult }
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
    static func write(at location: URL, original: Data?, permissions: Int, bytes: Data, delete: Bool, backup: Bool, validate: () throws -> Void) throws {
        let manager = FileManager.default
        let temporary = location.deletingLastPathComponent().appendingPathComponent(".TurtleGitSave-" + UUID().uuidString)
        let backupTemporary = location.deletingLastPathComponent().appendingPathComponent(".TurtleGitBackup-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary); try? manager.removeItem(at: backupTemporary) }
        if !delete {
            try bytes.write(to: temporary, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }
        try validate()
        if backup, let original {
            let target = URL(fileURLWithPath: location.path + ".bak")
            if let attributes = try? manager.attributesOfItem(atPath: target.path), attributes[.type] as? FileAttributeType != .typeRegular { throw MergeFileSaveFailure.backupTarget }
            try original.write(to: backupTemporary, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: backupTemporary.path)
            try validate()
            guard Darwin.rename(backupTemporary.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        try validate()
        if delete { if original != nil { try manager.removeItem(at: location) } }
        else { guard Darwin.rename(temporary.path, location.path) == 0 else { throw CocoaError(.fileWriteUnknown) } }
    }
}

/// IDD_ENCODING order and AutoLine semantics, independent of native controls.
public struct MergeFormatSelection: Equatable, Sendable {
    public var encoding: ComparisonTextEncoding
    public var ending: MergeLineEnding?
    public static let encodings: [ComparisonTextEncoding] = [.windows1252,.utf16LE,.utf16BE,.utf16LEBOM,.utf16BEBOM,.utf32LE,.utf32BE,.utf8,.utf8BOM]
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
