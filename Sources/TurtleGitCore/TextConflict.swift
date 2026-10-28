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
    public let isIgnored: Bool
    private let joiningLineEnding: String
    private let mineNeedsSeparator: Bool
    private let theirsNeedsSeparator: Bool
    init(id: Int, range: NSRange, mine: String, base: String, theirs: String, joiningLineEnding: String = "\n", mineNeedsSeparator: Bool = false, theirsNeedsSeparator: Bool = false, isIgnored: Bool = false) {
        self.id = id; self.range = range; self.mine = mine; self.base = base; self.theirs = theirs; self.joiningLineEnding = joiningLineEnding
        self.mineNeedsSeparator = mineNeedsSeparator; self.theirsNeedsSeparator = theirsNeedsSeparator; self.isIgnored = isIgnored
    }
    func identified(_ id: Int) -> Self {
        .init(id:id,range:range,mine:mine,base:base,theirs:theirs,joiningLineEnding:joiningLineEnding,mineNeedsSeparator:mineNeedsSeparator,theirsNeedsSeparator:theirsNeedsSeparator,isIgnored:isIgnored)
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
public struct MergeInputEncodingOverrides:Equatable,Sendable {
    public var base:ComparisonTextEncoding?,mine:ComparisonTextEncoding?,theirs:ComparisonTextEncoding?
    public init(base:ComparisonTextEncoding? = nil,mine:ComparisonTextEncoding? = nil,theirs:ComparisonTextEncoding? = nil) {
        self.base=base;self.mine=mine;self.theirs=theirs
    }
    public var isEmpty:Bool {base==nil && mine==nil && theirs==nil}
}
public struct MergeInputBytes:Sendable {
    public var base:Data,mine:Data,theirs:Data
    public init(base:Data,mine:Data,theirs:Data) {self.base=base;self.mine=mine;self.theirs=theirs}
}
public struct TextConflictDocument: Sendable {
    public let entry: ConflictEntry
    public let base: String
    public let mine: String
    public let theirs: String
    public let mineStage: Int
    public let theirsStage: Int
    public let initialResult: String
    /// Original generated result, retained across saves for source metadata.
    /// Ignored conflicts keep Mine text without inserting markers.
    public let generatedResult: String
    public let workingContents: Data?
    public let permissions: Int
    public let encoding: ComparisonTextEncoding
    public let baseEncoding: ComparisonTextEncoding?
    public let mineEncoding: ComparisonTextEncoding?
    public let theirsEncoding: ComparisonTextEncoding?
    public var conflictTitles: ConflictTitles? = nil
    public fileprivate(set) var mergeSources: MergeSourceComparison? = nil
    /// Accepted raw local inputs for activation checks; absent for immutable Git stages.
    public var externalSources: [MergeExternalSource] = []
    /// Actual accepted bytes, never an encoding of the displayed source text.
    public var rawInputs:MergeInputBytes? = nil
}
public struct TextConflictSaveFailure: LocalizedError, Sendable {
    public let savedDocument: TextConflictDocument
    public let gitError: String
    public let stageCancelled: Bool
    public init(savedDocument: TextConflictDocument, gitError: String, stageCancelled: Bool = false) {
        self.savedDocument = savedDocument; self.gitError = gitError; self.stageCancelled = stageCancelled
    }
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
        case .markers: return "Resolve the remaining conflicts before marking this file as resolved."
        case .block: return "The selected conflict block changed. Select a current conflict before applying a side."
        }
    }
}
extension GitRepository {
    public func textConflictDocument(path: String, engine: SubversionMergeConfiguration? = nil, mergePreferUTF8: Bool? = nil, mergeLegacyEncoding:ComparisonTextEncoding = .windows1252, inputEncodings:MergeInputEncodingOverrides = .init(), identityOptions: ConflictIdentityOptions = .init(), cancellation: OperationCancellation? = nil) throws -> TextConflictDocument {
        try cancellation?.check()
        guard let entry = try conflicts(paths: [path], cancellation: cancellation).first(where: { GitReferenceName.equal($0.path, path) }) else { throw ResolveFailure.stale }
        guard !entry.isSubmodule, [2, 3].allSatisfy({ stage in entry.stages.contains { $0.number == stage && ["100644", "100755"].contains($0.mode) } }),
              entry.stages.allSatisfy({ ["100644", "100755"].contains($0.mode) }) else { throw TextConflictFailure.unsupported }
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        func detect(_ data: Data) -> ComparisonTextEncoding? {
            if let mergePreferUTF8 { return ComparisonTextEncoding.detectMerge(data, preferUTF8: mergePreferUTF8,legacyEncoding:mergeLegacyEncoding) }
            return ComparisonTextEncoding.detect(data)
        }
        func text(_ data: Data) throws -> String {
            guard let encoding = detect(data), let text = encoding.decode(data) else { throw TextConflictFailure.encoding }
            return text
        }
        var sourceEncodings: [Int: ComparisonTextEncoding] = [:]
        var rawStages:[Int:Data]=[:]
        func content(_ stage: Int,_ override:ComparisonTextEncoding?) throws -> String {
            guard let object = entry.stages.first(where: { $0.number == stage })?.object else {rawStages[stage]=Data();return ""}
            let data = try run(["cat-file", "blob", object], cancellation: cancellation).stdout
            rawStages[stage]=data
            if let override {
                guard let value=override.decodeInput(data) else {throw TextConflictFailure.encoding}
                sourceEncodings[stage]=override.inputEncoding;return value
            }
            sourceEncodings[stage]=detect(data)
            return try text(data)
        }
        let rebase = try conflictIsRebase(cancellation: cancellation), mineStage = rebase ? 3 : 2, theirsStage = rebase ? 2 : 3
        let base = try content(1,inputEncodings.base), mine = try content(mineStage,inputEncodings.mine), theirs = try content(theirsStage,inputEncodings.theirs)
        let location = root.appendingPathComponent(path)
        let (working, workingPermissions) = try conflictWorkingSnapshot(location)
        if let working,inputEncodings.isEmpty { _ = try text(working) }
        let permissions = workingPermissions ?? (entry.stages.first { $0.number == mineStage }?.mode == "100755" ? 0o755 : 0o644)
        let result: String
        var sources: MergeSourceComparison?
        if var engine {
            engine.blameEncodings = [sourceEncodings[1], sourceEncodings[mineStage], sourceEncodings[theirsStage]]
            let presentation = try SubversionMergePresentation(plan: engine.plan(base: base, mine: mine, theirs: theirs, cancellation: cancellation))
            result = presentation.result; sources = presentation.sources
        } else {
            let temporary = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitMerge-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for (name, value) in [("mine", mine), ("base", base), ("theirs", theirs)] { try Data(value.utf8).write(to: temporary.appendingPathComponent(name)) }
            let merged = try run(["merge-file", "-p", "--diff3", "--marker-size=7", "-L", "Mine", "-L", "Base", "-L", "Theirs", "--", temporary.appendingPathComponent("mine").path, temporary.appendingPathComponent("base").path, temporary.appendingPathComponent("theirs").path], successfulExitCodes: 0...127, cancellation: cancellation)
            guard let value=ComparisonTextEncoding.utf8.decode(merged.stdout) else {throw TextConflictFailure.encoding};result=value
        }
        let encoding = working.flatMap(detect) ?? rawStages[mineStage].flatMap(detect) ?? sourceEncodings[mineStage] ?? .utf8
        var document = TextConflictDocument(entry: entry, base: base, mine: mine, theirs: theirs, mineStage: mineStage, theirsStage: theirsStage, initialResult: result, generatedResult: result, workingContents: working, permissions: permissions, encoding: encoding, baseEncoding: sourceEncodings[1], mineEncoding: sourceEncodings[mineStage], theirsEncoding: sourceEncodings[theirsStage])
        document.rawInputs=MergeInputBytes(base:rawStages[1] ?? Data(),mine:rawStages[mineStage] ?? Data(),theirs:rawStages[theirsStage] ?? Data())
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        guard try conflictIsRebase(cancellation: cancellation) == rebase else { throw ResolveFailure.stale }
        try cancellation?.check()
        document.mergeSources = sources; document.conflictTitles = try conflictTitles(rebase: rebase, options: identityOptions, cancellation: cancellation)
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        guard try conflictIsRebase(cancellation: cancellation) == rebase else { throw ResolveFailure.stale }
        try cancellation?.check(); return document
    }
    public func saveTextConflict(_ document: TextConflictDocument, result: String, markResolved: Bool, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init(), ignoredConflictsResolved: Bool = false, allowUnresolvedConflicts: Bool = false,cancellation:OperationCancellation? = nil) throws -> TextConflictDocument {
        try cancellation?.check()
        try validateConflicts([document.entry], using: .current, cancellation: cancellation)
        // Source HasConflictsWontKeep authorizes just this Save/Resolve attempt.
        // Never persist its answer in the document or waive filesystem/index CAS.
        if markResolved && !allowUnresolvedConflicts && (MergeText.hasMarkers(result) || !ignoredConflictsResolved && document.mergeSources?.ignoredConflicts.isEmpty == false) { throw TextConflictFailure.markers }
        guard !result.utf8.contains(0) else { throw TextConflictFailure.encoding }
        let location = root.appendingPathComponent(document.entry.path)
        let current: Data?, permissions: Int?
        do { (current, permissions) = try conflictWorkingSnapshot(location) }
        catch TextConflictFailure.unsupported { throw TextConflictFailure.changedWorkingFile }
        guard current == document.workingContents, permissions == nil || permissions == document.permissions else { throw TextConflictFailure.changedWorkingFile }
        if current != nil && MergePaneSaveAs.requiresSaveAs(at:location,permissions:permissions) { throw TextConflictFailure.readOnly }
        let selectedEncoding = encoding ?? document.encoding
        let contents = try selectedEncoding.encode(result)
        guard options.emptyResult != .delete || result.isEmpty else { throw MergeFileSaveFailure.nonemptyDeletion }
        let deleting = options.emptyResult == .delete
        try MergeWorkingFileSave.write(at: location, original: current, permissions: document.permissions, bytes: contents,
                                       delete: deleting, backup: options.backupOriginal, outputDirectories: options.outputDirectories) {
            try cancellation?.check()
            let (bytes, mode) = try self.conflictWorkingSnapshot(location)
            guard bytes == current, mode == permissions else { throw TextConflictFailure.changedWorkingFile }
        }
        var saved = TextConflictDocument(entry: document.entry, base: document.base, mine: document.mine, theirs: document.theirs, mineStage: document.mineStage, theirsStage: document.theirsStage, initialResult: result, generatedResult: document.generatedResult, workingContents: deleting ? nil : contents, permissions: document.permissions, encoding: selectedEncoding, baseEncoding: document.baseEncoding, mineEncoding: document.mineEncoding, theirsEncoding: document.theirsEncoding)
        saved.externalSources = document.externalSources
        saved.rawInputs = document.rawInputs
        saved.mergeSources = document.mergeSources; saved.conflictTitles = document.conflictTitles
        if markResolved {
            do {
                try cancellation?.check()
                try validateConflicts([document.entry], using: .current, cancellation: cancellation)
                let (bytes, mode) = try conflictWorkingSnapshot(location)
                guard bytes == saved.workingContents, mode == nil || mode == saved.permissions else { throw TextConflictFailure.changedWorkingFile }
                do { _ = try run(["add", "-f", "--", document.entry.path], cancellation: cancellation) }
                catch let completed as GitCommandCancellationFailure where completed.result.exitCode == 0 {
                    // Git completed the index publication before cancellation
                    // was observed. Return success rather than inventing a
                    // failed Resolve that a retry would find already resolved.
                }
                removeSourceMergeFiles(document.entry.path)
            } catch {
                throw TextConflictSaveFailure(savedDocument: saved, gitError: error.localizedDescription,
                    stageCancelled: cancellation?.isCancelled == true || error is OperationCancellationFailure)
            }
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
    public nonisolated let outputURL: URL
    private let explicitOutput:Bool
    private let allowMissingInputs:Bool
    private struct Snapshot {
        let bytes: Data?
        let permissions: Int
        let identity: String?
    }
    private var inputs: [String: Snapshot] = [:]
    private var savedSources: [Bool: SavedMergePane] = [:]
    public func bindSource(mine: Bool, target: SavedMergePane) throws {
        try target.validate()
        savedSources[mine] = target
        let paths = Set([baseURL.path, (savedSources[true]?.url ?? mineURL).path, (savedSources[false]?.url ?? theirsURL).path])
        inputs = inputs.filter { paths.contains($0.key) }
        let value = try snapshot(target.url, absentPermissions: target.content.permissions ?? 0o644)
        inputs[target.url.path] = value
        if outputs[target.url.path] != nil { outputs[target.url.path] = value }
    }
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
    public init(base: URL, theirs: URL, mine: URL, merged:URL? = nil,allowMissingInputs:Bool = false) throws {
        guard [base, theirs, mine,merged ?? mine].allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }) else { throw TextConflictFailure.unsupported }
        baseURL = base.standardizedFileURL; theirsURL = theirs.standardizedFileURL; mineURL = mine.standardizedFileURL
        outputURL=(merged ?? mine).standardizedFileURL;explicitOutput=merged != nil;self.allowMissingInputs=allowMissingInputs
    }
    private func source(_ url: URL, mergePreferUTF8: Bool?, legacyEncoding:ComparisonTextEncoding,override:ComparisonTextEncoding?) throws -> ComparisonFileContent {
        let raw = allowMissingInputs ? try MergeToolFileInput.read(at:url):try WorkingFileComparison.workingContent(at:url)
        let detected = mergePreferUTF8.map { raw.usingMergeEncoding(preferUTF8: $0,legacyEncoding:legacyEncoding) } ?? raw
        let value = try override.map {try detected.reinterpreting(encoding:$0)} ?? detected
        guard value.mode != "120000", value.text != nil, value.encoding != nil else { throw TextConflictFailure.encoding }
        return value
    }
    public func read(engine: SubversionMergeConfiguration, mergePreferUTF8: Bool? = nil, mergeLegacyEncoding:ComparisonTextEncoding = .windows1252,inputEncodings:MergeInputEncodingOverrides = .init(), cancellation: OperationCancellation? = nil) throws -> TextConflictDocument {
        try cancellation?.check()
        let activeMine = savedSources[true]?.url ?? mineURL, activeTheirs = savedSources[false]?.url ?? theirsURL
        let base = try source(baseURL, mergePreferUTF8: mergePreferUTF8,legacyEncoding:mergeLegacyEncoding,override:inputEncodings.base), theirs = try source(activeTheirs, mergePreferUTF8: mergePreferUTF8,legacyEncoding:mergeLegacyEncoding,override:inputEncodings.theirs), mine = try source(activeMine, mergePreferUTF8: mergePreferUTF8,legacyEncoding:mergeLegacyEncoding,override:inputEncodings.mine)
        // The default Mine output needs its own CAS receipt too. Source Save As
        // can later rebind Mine and remove it from inputs without authorizing a
        // newly captured overwrite of the original result location.
        let output = try snapshot(outputURL, absentPermissions: mine.permissions ?? 0o644)
        var engine = engine
        engine.blameEncodings = [base.encoding, mine.encoding, theirs.encoding]
        let presentation = try SubversionMergePresentation(plan: engine.plan(base: base.text!, mine: mine.text!, theirs: theirs.text!, cancellation: cancellation))
        try cancellation?.check()
        let currentOutput=try snapshot(outputURL,absentPermissions:output.permissions)
        guard currentOutput.bytes==output.bytes,currentOutput.permissions==output.permissions,currentOutput.identity==output.identity else {throw TextConflictFailure.changedWorkingFile}
        for (url, content) in [(baseURL,base), (activeTheirs,theirs), (activeMine,mine)] {
            let value = try snapshot(url, absentPermissions: content.permissions ?? 0o644)
            guard value.bytes == (content.isDeleted ? nil:content.bytes), value.permissions == content.permissions else { throw TextConflictFailure.changedWorkingFile }
            inputs[url.path] = value
            if outputs[url.path] != nil { outputs[url.path] = value }
        }
        var workingContents:Data?=mine.isDeleted ? nil:mine.bytes,permissions=mine.permissions ?? 0o644
        outputs[outputURL.path] = output
        if explicitOutput {workingContents=output.bytes;permissions=output.permissions}
        let outputEncoding=mergePreferUTF8.map {ComparisonTextEncoding.detectMerge(mine.bytes,preferUTF8:$0,legacyEncoding:mergeLegacyEncoding)} ?? ComparisonTextEncoding.detect(mine.bytes)
        var document = TextConflictDocument(entry: ConflictEntry(path: outputURL.lastPathComponent, stages: []),
            base: base.text!, mine: mine.text!, theirs: theirs.text!, mineStage: 2, theirsStage: 3,
            initialResult: presentation.result, generatedResult: presentation.result, workingContents: workingContents,
            permissions: permissions, encoding: outputEncoding ?? mine.encoding!, baseEncoding: base.encoding, mineEncoding: mine.encoding, theirsEncoding: theirs.encoding)
        document.rawInputs=MergeInputBytes(base:base.bytes,mine:mine.bytes,theirs:theirs.bytes)
        document.externalSources = [("base",baseURL,base),("mine",activeMine,mine),("theirs",activeTheirs,theirs)].map { role, url, content in
            MergeExternalSource(id:role,url:url,expectedBytes:content.bytes,expectedMissing:content.isDeleted,expectedPermissions:content.permissions)
        }
        document.mergeSources = presentation.sources; return document
    }
    /// Explicit output selection; own writes update aliases without accepting external changes.
    public func saveTo(_ output: URL, document: TextConflictDocument, result: String,
                       encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init(),cancellation:OperationCancellation? = nil) throws -> TextConflictDocument {
        try cancellation?.check()
        let output = output.standardizedFileURL
        guard output.isFileURL, !output.path.contains("\0"), !inputs.isEmpty else { throw TextConflictFailure.unsupported }
        let original = try outputs[output.path] ?? snapshot(output, absentPermissions: document.permissions)
        func validate() throws {
            try cancellation?.check()
            for (path, expected) in inputs {
                let current = try snapshot(URL(fileURLWithPath:path), absentPermissions:expected.permissions)
                guard current.bytes == expected.bytes, current.permissions == expected.permissions,current.identity == expected.identity else { throw TextConflictFailure.changedWorkingFile }
            }
            let current = try snapshot(output, absentPermissions:original.permissions)
            guard current.bytes == original.bytes, current.permissions == original.permissions,current.identity == original.identity else { throw TextConflictFailure.changedWorkingFile }
        }
        guard !result.utf8.contains(0) else { throw TextConflictFailure.encoding }
        guard options.emptyResult != .delete || result.isEmpty else { throw MergeFileSaveFailure.nonemptyDeletion }
        try validate()
        if original.bytes != nil && MergePaneSaveAs.requiresSaveAs(at:output,permissions:original.permissions) { throw TextConflictFailure.readOnly }
        let selected = encoding ?? document.encoding, bytes = try selected.encode(result), deleting = options.emptyResult == .delete
        try MergeWorkingFileSave.write(at:output, original:original.bytes, permissions:original.permissions, bytes:bytes,
                                       delete:deleting, backup:options.backupOriginal, outputDirectories:options.outputDirectories, validate:validate)
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
        saved.externalSources = document.externalSources.map { source in
            guard let captured = inputs[source.url.path] else { return source }
            return MergeExternalSource(id:source.id,url:source.url,expectedBytes:captured.bytes ?? Data(),expectedMissing:captured.bytes == nil,expectedPermissions:captured.permissions)
        }
        saved.rawInputs=document.rawInputs
        saved.mergeSources = document.mergeSources; saved.conflictTitles = document.conflictTitles; return saved
    }
    public func save(_ document: TextConflictDocument, result: String, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init()) throws -> TextConflictDocument {
        try saveTo(outputURL, document:document, result:result, encoding:encoding, options:options)
    }
    /// Ignore outside changes keeps a deliberately older view. It can be copied
    /// to an independently chosen file without accepting those outside bytes as
    /// the normal Save baseline. Source/output aliases remain protected.
    public func saveRetainedResultCopy(to output: URL, document: TextConflictDocument, result: String,
                                       encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init(),
                                       cancellation: OperationCancellation? = nil) throws -> TextConflictDocument {
        try cancellation?.check()
        guard options.emptyResult != .delete else { throw TextConflictFailure.unsupported }
        guard !result.utf8.contains(0) else { throw TextConflictFailure.encoding }
        let destination = output.standardizedFileURL
        let protected = [baseURL, mineURL, theirsURL, outputURL] + savedSources.values.map { $0.url }
        let target = try MergeToolOutputTarget(capturing: destination)
        let selected = encoding ?? document.encoding
        func validateDestination() throws {
            try cancellation?.check()
            let current = try snapshot(destination, absentPermissions: document.permissions)
            for source in protected {
                guard destination.resolvingSymlinksInPath().path != source.resolvingSymlinksInPath().path else { throw TextConflictFailure.changedWorkingFile }
                let other = try? snapshot(source, absentPermissions: document.permissions)
                guard current.identity == nil || current.identity != other?.identity else { throw TextConflictFailure.changedWorkingFile }
            }
            guard current.identity == nil || !inputs.values.contains(where: { $0.identity == current.identity }) else { throw TextConflictFailure.changedWorkingFile }
            try target.validate()
        }
        try validateDestination()
        guard !MergePaneSaveAs.requiresSaveAs(at: destination, permissions: target.content.permissions, absent: target.content.isDeleted) else { throw TextConflictFailure.readOnly }
        let bytes = try selected.encode(result)
        try MergeWorkingFileSave.write(at: destination, original: target.content.isDeleted ? nil : target.content.bytes,
            permissions: target.content.permissions ?? 0o644, bytes: bytes, delete: false,
            backup: options.backupOriginal, outputDirectories: options.outputDirectories, validate: validateDestination)
        let written = try MergeToolOutputTarget(capturing: destination)
        guard written.content.bytes == bytes else { throw TextConflictFailure.changedWorkingFile }
        let content = ComparisonFileContent(path: destination.path, revision: .workingTree, bytes: bytes,
            mode: written.content.mode, permissions: written.content.permissions, encoding: selected)
        return try document.recordingOwnedWorkingWrite(content)
    }
}

public enum MergeOpenMode: Int, Sendable { case merging = 0, applyUnifiedDiff = 1 }
public enum MergeOpenRequest: Sendable {
    case compare(base: URL, mine: URL, single: Bool)
    case merge(base: URL, theirs: URL, mine: URL)
    case patch(file: URL?, directory: URL?, clipboard: Data?)
    public static func selection(mode: MergeOpenMode, base: String, theirs: String, mine: String,
                                 diff: String, directory: String, clipboard: Data?) throws -> Self {
        let request = try lexicalSelection(mode: mode, base: base, theirs: theirs, mine: mine, diff: diff, directory: directory, clipboard: clipboard)
        try request.validateFileSystem()
        return request
    }
    /// Parse active fields before a sandbox owner asks for access. This does not
    /// claim that the named files exist or that their contents are accessible.
    public static func lexicalSelection(mode: MergeOpenMode, base: String, theirs: String, mine: String,
                                        diff: String, directory: String, clipboard: Data?) throws -> Self {
        func url(_ value: String) throws -> URL? {
            guard !value.isEmpty else { return nil }
            guard !value.contains("\0") else { throw RevisionComparisonFailure.selection }
            let expanded = (value as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
            return FileTransferPaths.fileURL(FileTransferPaths.lexicalPath(absolute))
        }
        if mode == .applyUnifiedDiff {
            let target = try url(directory)
            if let clipboard { guard !clipboard.isEmpty else { throw RevisionComparisonFailure.selection }; return .patch(file: nil, directory: target, clipboard: clipboard) }
            return .patch(file: try url(diff), directory: target, clipboard: nil)
        }
        let baseURL = try url(base), theirsURL = try url(theirs), mineURL = try url(mine)
        if let baseURL, let theirsURL, let mineURL { return .merge(base: baseURL, theirs: theirsURL, mine: mineURL) }
        let files = [baseURL, theirsURL, mineURL].compactMap { $0 }
        guard !files.isEmpty else { throw RevisionComparisonFailure.selection }
        return .compare(base: files[0], mine: files.last!, single: files.count == 1)
    }
    /// Call only after acquiring the active input grants. Missing inputs remain
    /// invalid in Open; command-line future-file handling is a separate policy.
    public func validateFileSystem() throws {
        let paths: [(URL, Bool)]
        switch self {
        case .compare(let base, let mine, _): paths = [(base, false), (mine, false)]
        case .merge(let base, let theirs, let mine): paths = [(base, false), (theirs, false), (mine, false)]
        case .patch(let file, let directory, _): paths = (file.map { [($0, false)] } ?? [])
            + (directory.map { [($0, true)] } ?? [])
        }
        for (url, folder) in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue == folder else { throw RevisionComparisonFailure.selection }
        }
    }
}

extension TextConflictDocument {
    /// Regenerate from actual retained bytes. This changes the input decoder,
    /// not the output conversion or the accepted index/working-file receipts.
    public func reinterpretingInputs(_ overrides:MergeInputEncodingOverrides,engine:SubversionMergeConfiguration,cancellation:OperationCancellation? = nil) throws -> Self {
        try cancellation?.check()
        guard !overrides.isEmpty else{return self}
        guard let rawInputs else{throw TextConflictFailure.encoding}
        func decode(_ bytes:Data,_ override:ComparisonTextEncoding?,_ current:ComparisonTextEncoding?) throws -> (String,ComparisonTextEncoding?) {
            if let override {guard let text=override.decodeInput(bytes) else{throw TextConflictFailure.encoding};return(text,override.inputEncoding)}
            guard let current else{if bytes.isEmpty{return("",nil)};throw TextConflictFailure.encoding}
            guard let text=current.decodeInput(bytes) else{throw TextConflictFailure.encoding};return(text,current)
        }
        let base=try decode(rawInputs.base,overrides.base,baseEncoding),mine=try decode(rawInputs.mine,overrides.mine,mineEncoding),theirs=try decode(rawInputs.theirs,overrides.theirs,theirsEncoding)
        var engine=engine;engine.blameEncodings=[base.1,mine.1,theirs.1]
        let presentation=try SubversionMergePresentation(plan:engine.plan(base:base.0,mine:mine.0,theirs:theirs.0,cancellation:cancellation))
        try cancellation?.check()
        var next=Self(entry:entry,base:base.0,mine:mine.0,theirs:theirs.0,mineStage:mineStage,theirsStage:theirsStage,initialResult:presentation.result,generatedResult:presentation.result,workingContents:workingContents,permissions:permissions,encoding:encoding,baseEncoding:base.1,mineEncoding:mine.1,theirsEncoding:theirs.1)
        next.rawInputs=rawInputs;next.externalSources=externalSources;next.mergeSources=presentation.sources;next.conflictTitles=conflictTitles;return next
    }
    /// Keep conflict/index identity and the current result snapshot while Reload
    /// reads source panes whose SaveFileTo target has changed.
    public func replacingSources(mine: ComparisonFileContent?, theirs: ComparisonFileContent?, engine: SubversionMergeConfiguration, cancellation: OperationCancellation? = nil) throws -> Self {
        let mineText = mine?.text ?? self.mine, theirsText = theirs?.text ?? self.theirs
        var engine = engine
        engine.blameEncodings = [baseEncoding, mine?.encoding ?? mineEncoding, theirs?.encoding ?? theirsEncoding]
        let presentation = try SubversionMergePresentation(plan: engine.plan(base: base, mine: mineText, theirs: theirsText, cancellation: cancellation))
        var next = Self(entry: entry, base: base, mine: mineText, theirs: theirsText, mineStage: mineStage, theirsStage: theirsStage,
            initialResult: initialResult, generatedResult: presentation.result, workingContents: workingContents, permissions: permissions,
            encoding: encoding, baseEncoding: baseEncoding, mineEncoding: mine?.encoding ?? mineEncoding, theirsEncoding: theirs?.encoding ?? theirsEncoding)
        next.externalSources = externalSources.map { source in
            let replacement = source.id == "mine" ? mine : source.id == "theirs" ? theirs : nil
            guard let replacement else { return source }
            return MergeExternalSource(id:source.id,url:URL(fileURLWithPath:replacement.path),expectedBytes:replacement.bytes,expectedMissing:replacement.isDeleted,expectedPermissions:replacement.permissions)
        }
        next.mergeSources = presentation.sources; next.conflictTitles = conflictTitles
        if var bytes=rawInputs {bytes.mine=mine?.bytes ?? bytes.mine;bytes.theirs=theirs?.bytes ?? bytes.theirs;next.rawInputs=bytes}
        return next
    }
    public func recordingOwnedWorkingWrite(_ content: ComparisonFileContent) throws -> Self {
        guard let text = content.text, let encoding = content.encoding, let permissions = content.permissions else { throw TextConflictFailure.encoding }
        var next = Self(entry: entry, base: base, mine: mine, theirs: theirs, mineStage: mineStage, theirsStage: theirsStage,
            initialResult: text, generatedResult: generatedResult, workingContents: content.isDeleted ? nil : content.bytes, permissions: permissions,
            encoding: encoding, baseEncoding: baseEncoding, mineEncoding: mineEncoding, theirsEncoding: theirsEncoding)
        next.externalSources = externalSources
        next.rawInputs=rawInputs
        next.mergeSources = mergeSources; next.conflictTitles = conflictTitles
        return next
    }
}


extension WorkingTreePatchFileComparison {
    public func patchMergeDocument(engine:SubversionMergeConfiguration,preferUTF8:Bool? = nil,legacyEncoding:ComparisonTextEncoding = .windows1252,inputEncodings:MergeInputEncodingOverrides = .init(),cancellation:OperationCancellation? = nil) throws -> TextConflictDocument {
        guard let recoveryBase else {throw WorkingTreePatchFailure.review}
        let policy=textEncodingPolicy ?? preferUTF8.map {MergeTextEncodingPolicy(preferUTF8:$0,legacyEncoding:legacyEncoding)}
        guard [recoveryBase,document.base,document.destination].allSatisfy({$0.mode != nil && $0.mode != "120000"}),policy != nil || recoveryKind == .text || !inputEncodings.isEmpty else {throw WorkingTreePatchFailure.review}
        func content(_ value:ComparisonFileContent)->ComparisonFileContent {
            // Source patch preview has already decoded each original input and
            // may represent an unencodable patched pane privately as Unicode.
            // Reapplying the target ACP would corrupt that accepted pane.
            if usesDecodedTextPatch, textEncodingPolicy != nil { return value }
            return policy?.applying(value) ?? value
        }
        let base = try inputEncodings.base.map {try content(recoveryBase).reinterpreting(encoding:$0)} ?? content(recoveryBase)
        let mine = try inputEncodings.mine.map {try content(document.base).reinterpreting(encoding:$0)} ?? content(document.base)
        let theirs = try inputEncodings.theirs.map {try content(document.destination).reinterpreting(encoding:$0)} ?? content(document.destination)
        guard let baseText = base.text,let mineText = mine.text,let theirsText = theirs.text,let encoding = content(document.base).encoding ?? content(document.destination).encoding ?? mine.encoding ?? theirs.encoding else {throw TextConflictFailure.encoding}
        var engine = engine
        engine.blameEncodings = [base.encoding, mine.encoding, theirs.encoding]
        let merged = try SubversionMergePresentation(plan:engine.plan(base:baseText,mine:mineText,theirs:theirsText,cancellation:cancellation))
        var result = TextConflictDocument(entry:ConflictEntry(path:document.destination.path,stages:[]),base:baseText,mine:mineText,theirs:theirsText,mineStage:2,theirsStage:3,initialResult:merged.result,generatedResult:merged.result,workingContents:mine.bytes,permissions:mine.permissions ?? 0o644,encoding:encoding,baseEncoding:base.encoding,mineEncoding:mine.encoding,theirsEncoding:theirs.encoding)
        result.rawInputs=MergeInputBytes(base:recoveryBase.bytes,mine:document.base.bytes,theirs:document.destination.bytes)
        result.mergeSources = merged.sources;return result
    }
}
extension TextConflictDocument {
    public func recordingPatchSave(_ saved:WorkingTreePatchSaveResult) throws -> TextConflictDocument {
        guard let text = saved.document.destination.text else {throw TextConflictFailure.encoding}
        var next = TextConflictDocument(entry:entry,base:base,mine:mine,theirs:theirs,mineStage:mineStage,theirsStage:theirsStage,initialResult:text,generatedResult:generatedResult,workingContents:saved.document.destination.isDeleted ? nil : saved.document.destination.bytes,permissions:saved.document.destination.permissions ?? permissions,encoding:saved.document.destination.encoding ?? encoding,baseEncoding:baseEncoding,mineEncoding:mineEncoding,theirsEncoding:theirsEncoding)
        next.externalSources = externalSources
        next.rawInputs=rawInputs
        next.mergeSources = mergeSources;next.conflictTitles = conflictTitles;return next
    }
}
