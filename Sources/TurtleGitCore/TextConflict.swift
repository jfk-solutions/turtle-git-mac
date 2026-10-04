import Foundation

public enum MergeBlockChoice: String, CaseIterable, Sendable {
    case mine = "Use text block from Mine", theirs = "Use text block from Theirs"
    case mineThenTheirs = "Use Mine before Theirs", theirsThenMine = "Use Theirs before Mine"
}
public struct MergeConflictBlock: Identifiable, Sendable {
    public let id: Int
    public let range: NSRange
    public let mine: String
    public let base: String
    public let theirs: String
    public func replacement(_ choice: MergeBlockChoice) -> String {
        switch choice {
        case .mine: return mine
        case .theirs: return theirs
        case .mineThenTheirs: return mine + theirs
        case .theirsThenMine: return theirs + mine
        }
    }
}
public enum MergeText {
    /// Uses UTF-16 ranges for AppKit selection and replacement, retaining every
    /// original line ending and avoiding Unicode scalar/character index mismatch.
    public static func conflicts(in text: String) -> [MergeConflictBlock] {
        let source = text as NSString
        var offset = 0, start: Int?, mineStart = 0, baseStart: Int?, separator: NSRange?
        var mineEnd: Int?, blocks: [MergeConflictBlock] = []
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let line = source.substring(with: range).trimmingCharacters(in: .newlines)
            if line == "<<<<<<<" || line.hasPrefix("<<<<<<< ") {
                start = range.location; mineStart = NSMaxRange(range); baseStart = nil; separator = nil; mineEnd = nil
            } else if start != nil, separator == nil, line == "|||||||" || (start != nil && separator == nil && line.hasPrefix("||||||| ")) {
                mineEnd = range.location; baseStart = NSMaxRange(range)
            } else if start != nil, line == "=======", separator == nil {
                separator = range; if mineEnd == nil { mineEnd = range.location }
            } else if let startOffset = start, let separator, let endMine = mineEnd, line == ">>>>>>>" || (start != nil && separator != nil && line.hasPrefix(">>>>>>> ")) {
                let mine = source.substring(with: NSRange(location: mineStart, length: endMine - mineStart))
                let base = baseStart.map { source.substring(with: NSRange(location: $0, length: separator.location - $0)) } ?? ""
                let theirs = source.substring(with: NSRange(location: NSMaxRange(separator), length: range.location - NSMaxRange(separator)))
                blocks.append(MergeConflictBlock(id: blocks.count, range: NSRange(location: startOffset, length: NSMaxRange(range) - startOffset), mine: mine, base: base, theirs: theirs))
                start = nil; baseStart = nil; mineEnd = nil
            }
            offset = NSMaxRange(range)
        }
        return blocks
    }
    public static func hasMarkers(_ text: String) -> Bool {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).contains {
            $0 == "<<<<<<<" || $0.hasPrefix("<<<<<<< ") || $0 == ">>>>>>>" || $0.hasPrefix(">>>>>>> ") || $0 == "|||||||" || $0.hasPrefix("||||||| ")
        }
    }
    public static func applying(_ choice: MergeBlockChoice, block: Int, to text: String) throws -> String {
        guard let conflict = conflicts(in: text).first(where: { $0.id == block }) else { throw TextConflictFailure.block }
        return (text as NSString).replacingCharacters(in: conflict.range, with: conflict.replacement(choice))
    }
}
public struct TextConflictDocument: Sendable {
    public let entry: ConflictEntry
    public let base: String
    public let mine: String
    public let theirs: String
    public let mineStage: Int
    public let theirsStage: Int
    public let initialResult: String
    public let workingContents: Data?
    public let permissions: Int
}
public struct TextConflictSaveFailure: LocalizedError, Sendable {
    public let savedDocument: TextConflictDocument
    public let gitError: String
    public var errorDescription: String? { "The merged working file was saved, but Git could not mark it resolved.\n" + gitError }
}
public enum TextConflictFailure: LocalizedError {
    case unsupported, encoding, changedWorkingFile, readOnly, markers, block
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "This editor handles regular text files with both conflict sides. Submodules, symlinks and delete/modify conflicts use other workflows."
        case .encoding: return "This file is binary or uses an unsupported text encoding. The native text merge editor currently supports UTF-8 text."
        case .changedWorkingFile: return "The working file or its permissions changed while the merge was open. Reload before saving to review those changes."
        case .readOnly: return "The working file is read-only. Use Save As to export the merged result."
        case .markers: return "Resolve the remaining conflict markers before marking this file as resolved."
        case .block: return "The selected conflict block changed. Select a current conflict before applying a side."
        }
    }
}
extension GitRepository {
    public func textConflictDocument(path: String) throws -> TextConflictDocument {
        guard let entry = try conflicts(paths: [path]).first(where: { $0.path == path }) else { throw ResolveFailure.stale }
        guard !entry.isSubmodule, [2, 3].allSatisfy({ stage in entry.stages.contains { $0.number == stage && ["100644", "100755"].contains($0.mode) } }),
              entry.stages.allSatisfy({ ["100644", "100755"].contains($0.mode) }) else { throw TextConflictFailure.unsupported }
        try validateConflicts([entry], using: .current)
        func text(_ data: Data) throws -> String {
            guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw TextConflictFailure.encoding }
            return String(decoding: data, as: UTF8.self)
        }
        func content(_ stage: Int) throws -> String {
            guard let object = entry.stages.first(where: { $0.number == stage })?.object else { return "" }
            return try text(run(["cat-file", "blob", object]).stdout)
        }
        let rebase = try conflictIsRebase(), mineStage = rebase ? 3 : 2, theirsStage = rebase ? 2 : 3
        let base = try content(1), mine = try content(mineStage), theirs = try content(theirsStage)
        let location = root.appendingPathComponent(path)
        let (working, workingPermissions) = try conflictWorkingSnapshot(location)
        if let working { _ = try text(working) }
        let permissions = workingPermissions ?? (entry.stages.first { $0.number == mineStage }?.mode == "100755" ? 0o755 : 0o644)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMerge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (name, value) in [("mine", mine), ("base", base), ("theirs", theirs)] { try Data(value.utf8).write(to: temporary.appendingPathComponent(name)) }
        let merged = try run(["merge-file", "-p", "--diff3", "--marker-size=7", "-L", "Mine", "-L", "Base", "-L", "Theirs", "--", temporary.appendingPathComponent("mine").path, temporary.appendingPathComponent("base").path, temporary.appendingPathComponent("theirs").path], successfulExitCodes: 0...127)
        let result = try text(merged.stdout)
        return TextConflictDocument(entry: entry, base: base, mine: mine, theirs: theirs, mineStage: mineStage, theirsStage: theirsStage, initialResult: result, workingContents: working, permissions: permissions)
    }
    public func saveTextConflict(_ document: TextConflictDocument, result: String, markResolved: Bool) throws -> TextConflictDocument {
        try validateConflicts([document.entry], using: .current)
        if markResolved && MergeText.hasMarkers(result) { throw TextConflictFailure.markers }
        guard !result.utf8.contains(0) else { throw TextConflictFailure.encoding }
        let location = root.appendingPathComponent(document.entry.path)
        let current: Data?, permissions: Int?
        do { (current, permissions) = try conflictWorkingSnapshot(location) }
        catch TextConflictFailure.unsupported { throw TextConflictFailure.changedWorkingFile }
        guard current == document.workingContents, permissions == nil || permissions == document.permissions else { throw TextConflictFailure.changedWorkingFile }
        if current != nil && !FileManager.default.isWritableFile(atPath: location.path) { throw TextConflictFailure.readOnly }
        let contents = Data(result.utf8)
        try contents.write(to: location, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: document.permissions], ofItemAtPath: location.path)
        let saved = TextConflictDocument(entry: document.entry, base: document.base, mine: document.mine, theirs: document.theirs, mineStage: document.mineStage, theirsStage: document.theirsStage, initialResult: result, workingContents: contents, permissions: document.permissions)
        if markResolved {
            do { _ = try run(["add", "-f", "--", document.entry.path]) }
            catch { throw TextConflictSaveFailure(savedDocument: saved, gitError: error.localizedDescription) }
        }
        return saved
    }
    private func conflictWorkingSnapshot(_ location: URL) throws -> (Data?, Int?) {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: location.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return (nil, nil) }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw TextConflictFailure.unsupported }
        return (try Data(contentsOf: location), (attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

}
