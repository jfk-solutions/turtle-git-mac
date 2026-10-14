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
    private let joiningLineEnding: String
    private let mineNeedsSeparator: Bool
    private let theirsNeedsSeparator: Bool
    init(id: Int, range: NSRange, mine: String, base: String, theirs: String, joiningLineEnding: String = "\n", mineNeedsSeparator: Bool = false, theirsNeedsSeparator: Bool = false) {
        self.id = id; self.range = range; self.mine = mine; self.base = base; self.theirs = theirs; self.joiningLineEnding = joiningLineEnding
        self.mineNeedsSeparator = mineNeedsSeparator; self.theirsNeedsSeparator = theirsNeedsSeparator
    }
    public func replacement(_ choice: MergeBlockChoice) -> String {
        func joined(_ first: String, _ second: String, needsSeparator: Bool) -> String {
            if first.isEmpty || second.isEmpty || !needsSeparator { return first + second }
            return first + joiningLineEnding + second
        }
        switch choice {
        case .mine: return mine
        case .theirs: return theirs
        case .mineThenTheirs: return joined(mine, theirs, needsSeparator: mineNeedsSeparator)
        case .theirsThenMine: return joined(theirs, mine, needsSeparator: theirsNeedsSeparator)
        }
    }
}
public enum MergeText {
    /// Uses UTF-16 ranges for AppKit selection and replacement, retaining every
    /// original line ending and avoiding Unicode scalar/character index mismatch.
    public static func conflicts(in text: String, document: TextConflictDocument? = nil) -> [MergeConflictBlock] {
        let source = text as NSString
        var start: Int?, mineStart = 0, baseStart: Int?, separator: NSRange?
        var mineEnd: Int?, blocks: [MergeConflictBlock] = []
        let lines = MergeLineEndings.lineRanges(in: text)
        for range in lines {
            let line = source.substring(with: range).trimmingCharacters(in: .newlines)
            if line == "<<<<<<<" || line.hasPrefix("<<<<<<< ") {
                start = range.location; mineStart = NSMaxRange(range); baseStart = nil; separator = nil; mineEnd = nil
            } else if start != nil, separator == nil, line == "|||||||" || (start != nil && separator == nil && line.hasPrefix("||||||| ")) {
                mineEnd = range.location; baseStart = NSMaxRange(range)
            } else if start != nil, line == "=======", separator == nil {
                separator = range; if mineEnd == nil { mineEnd = range.location }
            } else if let startOffset = start, let separator, let endMine = mineEnd, line == ">>>>>>>" || line.hasPrefix(">>>>>>> ") {
                let mine = source.substring(with: NSRange(location: mineStart, length: endMine - mineStart))
                let base = baseStart.map { source.substring(with: NSRange(location: $0, length: separator.location - $0)) } ?? ""
                let theirs = source.substring(with: NSRange(location: NSMaxRange(separator), length: range.location - NSMaxRange(separator)))
                blocks.append(MergeConflictBlock(id: blocks.count, range: NSRange(location: startOffset, length: NSMaxRange(range) - startOffset), mine: mine, base: base, theirs: theirs))
                start = nil; baseStart = nil; mineEnd = nil
            }
        }
        // merge-file inserts a line ending before markers even when the original
        // final source line had none. Restore it only for the unchanged original
        // EOF conflict, never for an edited block or a block followed by context.
        guard let document, let last = blocks.last, NSMaxRange(last.range) == source.length,
              let original = conflicts(in: document.generatedResult).last,
              NSMaxRange(original.range) == (document.generatedResult as NSString).length,
              last.mine.utf8.elementsEqual(original.mine.utf8),
              last.base.utf8.elementsEqual(original.base.utf8),
              last.theirs.utf8.elementsEqual(original.theirs.utf8) else { return blocks }
        func originalEnding(_ chunk: String, _ side: String) -> String {
            guard !side.isEmpty, side.utf8.last != 10, chunk.utf8.last == 10 else { return chunk }
            let value = chunk as NSString
            // Try LF first: a source's literal trailing CR must not be stripped.
            for count in [1, 2] where count == 1 || chunk.hasSuffix("\r\n") {
                let candidate = value.substring(to: value.length - count)
                if !candidate.isEmpty && side.utf8.suffix(candidate.utf8.count).elementsEqual(candidate.utf8) { return candidate }
            }
            return chunk
        }
        let marker = source.substring(with: lines.first { $0.location == last.range.location } ?? NSRange(location: last.range.location, length: 0))
        let mine = originalEnding(last.mine, document.mine), theirs = originalEnding(last.theirs, document.theirs)
        blocks[blocks.count - 1] = MergeConflictBlock(id: last.id, range: last.range,
            mine: mine, base: last.base, theirs: theirs, joiningLineEnding: marker.hasSuffix("\r\n") ? "\r\n" : "\n",
            mineNeedsSeparator: !mine.utf8.elementsEqual(last.mine.utf8), theirsNeedsSeparator: !theirs.utf8.elementsEqual(last.theirs.utf8))
        return blocks
    }
    public static func hasMarkers(_ text: String) -> Bool {
        let source = text as NSString
        return MergeLineEndings.lineRanges(in: text).contains { range in
            let line = source.substring(with: range).trimmingCharacters(in: .newlines)
            return line == "<<<<<<<" || line.hasPrefix("<<<<<<< ") || line == ">>>>>>>" || line.hasPrefix(">>>>>>> ") || line == "|||||||" || line.hasPrefix("||||||| ")
        }
    }
    public static func applying(_ choice: MergeBlockChoice, block: Int, to text: String, document: TextConflictDocument? = nil) throws -> String {
        guard let conflict = conflicts(in: text, document: document).first(where: { $0.id == block }) else { throw TextConflictFailure.block }
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
    /// Original marker-delimited result, retained across saves for source metadata.
    public let generatedResult: String
    public let workingContents: Data?
    public let permissions: Int
    public let encoding: ComparisonTextEncoding
    public let baseEncoding: ComparisonTextEncoding?
    public let mineEncoding: ComparisonTextEncoding?
    public let theirsEncoding: ComparisonTextEncoding?
    public fileprivate(set) var mergeSources: MergeSourceComparison? = nil
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
        case .encoding: return "This file is binary or uses an unsupported text encoding. Choose a supported Unicode text file for the native merge editor."
        case .changedWorkingFile: return "The working file or its permissions changed while the merge was open. Reload before saving to review those changes."
        case .readOnly: return "The working file is read-only. Use Save As to export the merged result."
        case .markers: return "Resolve the remaining conflict markers before marking this file as resolved."
        case .block: return "The selected conflict block changed. Select a current conflict before applying a side."
        }
    }
}
extension GitRepository {
    public func textConflictDocument(path: String, engine: SubversionMergeConfiguration? = nil, mergePreferUTF8: Bool? = nil, cancellation: OperationCancellation? = nil) throws -> TextConflictDocument {
        try cancellation?.check()
        guard let entry = try conflicts(paths: [path], cancellation: cancellation).first(where: { $0.path == path }) else { throw ResolveFailure.stale }
        guard !entry.isSubmodule, [2, 3].allSatisfy({ stage in entry.stages.contains { $0.number == stage && ["100644", "100755"].contains($0.mode) } }),
              entry.stages.allSatisfy({ ["100644", "100755"].contains($0.mode) }) else { throw TextConflictFailure.unsupported }
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        func detect(_ data: Data) -> ComparisonTextEncoding? {
            if let mergePreferUTF8 { return ComparisonTextEncoding.detectMerge(data, preferUTF8: mergePreferUTF8) }
            return ComparisonTextEncoding.detect(data)
        }
        func text(_ data: Data) throws -> String {
            guard let encoding = detect(data), let text = encoding.decode(data) else { throw TextConflictFailure.encoding }
            return text
        }
        var sourceEncodings: [Int: ComparisonTextEncoding] = [:]
        func content(_ stage: Int) throws -> String {
            guard let object = entry.stages.first(where: { $0.number == stage })?.object else { return "" }
            let data = try run(["cat-file", "blob", object], cancellation: cancellation).stdout
            sourceEncodings[stage] = detect(data)
            return try text(data)
        }
        let rebase = try conflictIsRebase(cancellation: cancellation), mineStage = rebase ? 3 : 2, theirsStage = rebase ? 2 : 3
        let base = try content(1), mine = try content(mineStage), theirs = try content(theirsStage)
        let location = root.appendingPathComponent(path)
        let (working, workingPermissions) = try conflictWorkingSnapshot(location)
        if let working { _ = try text(working) }
        let permissions = workingPermissions ?? (entry.stages.first { $0.number == mineStage }?.mode == "100755" ? 0o755 : 0o644)
        let result: String
        var sources: MergeSourceComparison?
        if let engine {
            let presentation = try SubversionMergePresentation(plan: engine.plan(base: base, mine: mine, theirs: theirs, cancellation: cancellation))
            result = presentation.result; sources = presentation.sources
        } else {
            let temporary = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitMerge-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for (name, value) in [("mine", mine), ("base", base), ("theirs", theirs)] { try Data(value.utf8).write(to: temporary.appendingPathComponent(name)) }
            let merged = try run(["merge-file", "-p", "--diff3", "--marker-size=7", "-L", "Mine", "-L", "Base", "-L", "Theirs", "--", temporary.appendingPathComponent("mine").path, temporary.appendingPathComponent("base").path, temporary.appendingPathComponent("theirs").path], successfulExitCodes: 0...127, cancellation: cancellation)
            result = try text(merged.stdout)
        }
        let encoding = working.flatMap(detect) ?? sourceEncodings[mineStage] ?? .utf8
        var document = TextConflictDocument(entry: entry, base: base, mine: mine, theirs: theirs, mineStage: mineStage, theirsStage: theirsStage, initialResult: result, generatedResult: result, workingContents: working, permissions: permissions, encoding: encoding, baseEncoding: sourceEncodings[1], mineEncoding: sourceEncodings[mineStage], theirsEncoding: sourceEncodings[theirsStage])
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        guard try conflictIsRebase(cancellation: cancellation) == rebase else { throw ResolveFailure.stale }
        try cancellation?.check()
        document.mergeSources = sources; return document
    }
    public func saveTextConflict(_ document: TextConflictDocument, result: String, markResolved: Bool, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init()) throws -> TextConflictDocument {
        try validateConflicts([document.entry], using: .current)
        if markResolved && MergeText.hasMarkers(result) { throw TextConflictFailure.markers }
        guard !result.utf8.contains(0) else { throw TextConflictFailure.encoding }
        let location = root.appendingPathComponent(document.entry.path)
        let current: Data?, permissions: Int?
        do { (current, permissions) = try conflictWorkingSnapshot(location) }
        catch TextConflictFailure.unsupported { throw TextConflictFailure.changedWorkingFile }
        guard current == document.workingContents, permissions == nil || permissions == document.permissions else { throw TextConflictFailure.changedWorkingFile }
        if current != nil && !FileManager.default.isWritableFile(atPath: location.path) { throw TextConflictFailure.readOnly }
        let selectedEncoding = encoding ?? document.encoding
        let contents = try selectedEncoding.encode(result)
        guard options.emptyResult != .delete || result.isEmpty else { throw MergeFileSaveFailure.nonemptyDeletion }
        let deleting = options.emptyResult == .delete
        try MergeWorkingFileSave.write(at: location, original: current, permissions: document.permissions, bytes: contents,
                                       delete: deleting, backup: options.backupOriginal) {
            let (bytes, mode) = try self.conflictWorkingSnapshot(location)
            guard bytes == current, mode == permissions else { throw TextConflictFailure.changedWorkingFile }
        }
        var saved = TextConflictDocument(entry: document.entry, base: document.base, mine: document.mine, theirs: document.theirs, mineStage: document.mineStage, theirsStage: document.theirsStage, initialResult: result, generatedResult: document.generatedResult, workingContents: deleting ? nil : contents, permissions: document.permissions, encoding: selectedEncoding, baseEncoding: document.baseEncoding, mineEncoding: document.mineEncoding, theirsEncoding: document.theirsEncoding)
        saved.mergeSources = document.mergeSources
        if markResolved {
            do { _ = try run(["add", "-f", "--", document.entry.path]) }
            catch { throw TextConflictSaveFailure(savedDocument: saved, gitError: error.localizedDescription) }
        }
        return saved
    }
    func conflictWorkingSnapshot(_ location: URL) throws -> (Data?, Int?) {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: location.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return (nil, nil) }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw TextConflictFailure.unsupported }
        return (try Data(contentsOf: location), (attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

}

/// Standalone three-file Merge: no repository discovery, index or Git operation.
public actor WorkingTextMerge {
    public nonisolated let baseURL: URL
    public nonisolated let theirsURL: URL
    public nonisolated let mineURL: URL
    private struct Snapshot {
        let bytes: Data?
        let permissions: Int
        let identity: String?
    }
    private var inputs: [String: Snapshot] = [:]
    private var outputs: [String: Snapshot] = [:]
    private func snapshot(_ url: URL, absentPermissions: Int) throws -> Snapshot {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw TextConflictFailure.unsupported }
            let identity = (attributes[.systemNumber] as? NSNumber).flatMap { device in
                (attributes[.systemFileNumber] as? NSNumber).map { device.stringValue + ":" + $0.stringValue }
            }
            return Snapshot(bytes: try Data(contentsOf: url), permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? absentPermissions, identity: identity)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return Snapshot(bytes: nil, permissions: absentPermissions, identity: nil)
        }
    }
    public init(base: URL, theirs: URL, mine: URL) throws {
        guard [base, theirs, mine].allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }) else { throw TextConflictFailure.unsupported }
        baseURL = base.standardizedFileURL; theirsURL = theirs.standardizedFileURL; mineURL = mine.standardizedFileURL
    }
    private func source(_ url: URL, mergePreferUTF8: Bool?) throws -> ComparisonFileContent {
        let raw = try WorkingFileComparison.workingContent(at: url)
        let value = mergePreferUTF8.map { raw.usingMergeEncoding(preferUTF8: $0) } ?? raw
        guard value.mode != "120000", value.text != nil, value.encoding != nil else { throw TextConflictFailure.encoding }
        return value
    }
    public func read(engine: SubversionMergeConfiguration, mergePreferUTF8: Bool? = nil, cancellation: OperationCancellation? = nil) throws -> TextConflictDocument {
        try cancellation?.check()
        let base = try source(baseURL, mergePreferUTF8: mergePreferUTF8), theirs = try source(theirsURL, mergePreferUTF8: mergePreferUTF8), mine = try source(mineURL, mergePreferUTF8: mergePreferUTF8)
        let presentation = try SubversionMergePresentation(plan: engine.plan(base: base.text!, mine: mine.text!, theirs: theirs.text!, cancellation: cancellation))
        try cancellation?.check()
        for (url, content) in [(baseURL,base), (theirsURL,theirs), (mineURL,mine)] {
            let value = try snapshot(url, absentPermissions: content.permissions ?? 0o644)
            guard value.bytes == content.bytes, value.permissions == content.permissions else { throw TextConflictFailure.changedWorkingFile }
            inputs[url.path] = value
            if outputs[url.path] != nil { outputs[url.path] = value }
        }
        var document = TextConflictDocument(entry: ConflictEntry(path: mineURL.lastPathComponent, stages: []),
            base: base.text!, mine: mine.text!, theirs: theirs.text!, mineStage: 2, theirsStage: 3,
            initialResult: presentation.result, generatedResult: presentation.result, workingContents: mine.bytes,
            permissions: mine.permissions ?? 0o644, encoding: mine.encoding!, baseEncoding: base.encoding, mineEncoding: mine.encoding, theirsEncoding: theirs.encoding)
        document.mergeSources = presentation.sources; return document
    }
    /// Explicit output selection; own writes update aliases without accepting external changes.
    public func saveTo(_ output: URL, document: TextConflictDocument, result: String,
                       encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init()) throws -> TextConflictDocument {
        let output = output.standardizedFileURL
        guard output.isFileURL, !output.path.contains("\0"), !inputs.isEmpty else { throw TextConflictFailure.unsupported }
        let original = try outputs[output.path] ?? snapshot(output, absentPermissions: document.permissions)
        func validate() throws {
            for (path, expected) in inputs {
                let current = try snapshot(URL(fileURLWithPath:path), absentPermissions:expected.permissions)
                guard current.bytes == expected.bytes, current.permissions == expected.permissions else { throw TextConflictFailure.changedWorkingFile }
            }
            let current = try snapshot(output, absentPermissions:original.permissions)
            guard current.bytes == original.bytes, current.permissions == original.permissions else { throw TextConflictFailure.changedWorkingFile }
        }
        guard !result.utf8.contains(0) else { throw TextConflictFailure.encoding }
        guard options.emptyResult != .delete || result.isEmpty else { throw MergeFileSaveFailure.nonemptyDeletion }
        try validate()
        if original.bytes != nil && !FileManager.default.isWritableFile(atPath:output.path) { throw TextConflictFailure.readOnly }
        let selected = encoding ?? document.encoding, bytes = try selected.encode(result), deleting = options.emptyResult == .delete
        try MergeWorkingFileSave.write(at:output, original:original.bytes, permissions:original.permissions, bytes:bytes,
                                       delete:deleting, backup:options.backupOriginal, validate:validate)
        let observed = try? snapshot(output, absentPermissions:original.permissions)
        let expectedBytes = deleting ? nil : bytes
        let savedOutput = Snapshot(bytes:expectedBytes, permissions:original.permissions,
            identity:observed?.bytes == expectedBytes && observed?.permissions == original.permissions ? observed?.identity : nil)
        outputs[output.path] = savedOutput
        for (path, expected) in outputs where path != output.path && original.identity != nil && expected.identity == original.identity {
            guard let current = try? snapshot(URL(fileURLWithPath:path), absentPermissions:expected.permissions) else { continue }
            if current.bytes == savedOutput.bytes && current.permissions == savedOutput.permissions { outputs[path] = current }
        }
        // Atomic replacement breaks hard links. Inspect each spelling after the
        // write: only paths that now resolve to our output get the new baseline.
        for (path, expected) in inputs {
            if path == output.path { inputs[path] = savedOutput }
            else if original.identity != nil && original.identity == expected.identity {
                guard let current = try? snapshot(URL(fileURLWithPath:path), absentPermissions:original.permissions) else { continue }
                if current.bytes == savedOutput.bytes && current.permissions == savedOutput.permissions { inputs[path] = current }
            }
        }
        var saved = TextConflictDocument(entry:document.entry, base:document.base, mine:document.mine, theirs:document.theirs,
            mineStage:document.mineStage, theirsStage:document.theirsStage, initialResult:result, generatedResult:document.generatedResult,
            workingContents:deleting ? nil : bytes, permissions:original.permissions, encoding:selected,
            baseEncoding:document.baseEncoding, mineEncoding:document.mineEncoding, theirsEncoding:document.theirsEncoding)
        saved.mergeSources = document.mergeSources; return saved
    }
    public func save(_ document: TextConflictDocument, result: String, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init()) throws -> TextConflictDocument {
        try saveTo(mineURL, document:document, result:result, encoding:encoding, options:options)
    }
}

public enum MergeOpenMode: Int, Sendable { case merging = 0, applyUnifiedDiff = 1 }
public enum MergeOpenRequest: Sendable {
    case compare(base: URL, mine: URL, single: Bool)
    case merge(base: URL, theirs: URL, mine: URL)
    case patch(file: URL?, directory: URL?, clipboard: Data?)
    public static func selection(mode: MergeOpenMode, base: String, theirs: String, mine: String,
                                 diff: String, directory: String, clipboard: Data?) throws -> Self {
        func url(_ value: String, folder: Bool = false) throws -> URL? {
            guard !value.isEmpty else { return nil }
            guard !value.contains("\0") else { throw RevisionComparisonFailure.selection }
            let location = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory), isDirectory.boolValue == folder else { throw RevisionComparisonFailure.selection }
            return location
        }
        if mode == .applyUnifiedDiff {
            let target = try url(directory, folder: true)
            if let clipboard { guard !clipboard.isEmpty else { throw RevisionComparisonFailure.selection }; return .patch(file: nil, directory: target, clipboard: clipboard) }
            return .patch(file: try url(diff), directory: target, clipboard: nil)
        }
        let baseURL = try url(base), theirsURL = try url(theirs), mineURL = try url(mine)
        if let baseURL, let theirsURL, let mineURL { return .merge(base: baseURL, theirs: theirsURL, mine: mineURL) }
        let files = [baseURL, theirsURL, mineURL].compactMap { $0 }
        guard !files.isEmpty else { throw RevisionComparisonFailure.selection }
        return .compare(base: files[0], mine: files.last!, single: files.count == 1)
    }
}
