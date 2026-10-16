import Foundation

public struct ConflictSide: Sendable {
    public let stage: Int
    public let reference: String
    public let commit: String?
    public let status: String
}
public struct DeleteConflictDetails: Sendable {
    public let entry: ConflictEntry
    public let first: ConflictSide
    public let second: ConflictSide
    public var keepTitle: String { entry.stages.contains { $0.number == 1 } ? "Modified" : "Created" }
    public var changedStage: Int { entry.stages.contains { $0.number == 2 } ? 2 : 3 }
    public var canCompare: Bool { entry.stages.contains { $0.number == 1 } }
}
public enum DeleteConflictFailure: LocalizedError {
    case unsupported
    public var errorDescription: String? { "This dialog handles file delete/modify conflicts. Text merge and submodule conflicts use separate editors." }
}
extension GitRepository {
    public func deleteConflictDetails(path: String, identityOptions: ConflictIdentityOptions = .init(), cancellation: OperationCancellation? = nil) throws -> DeleteConflictDetails {
        guard let entry = try conflicts(paths: [path], cancellation: cancellation).first(where: { $0.path == path }) else { throw ResolveFailure.stale }
        guard entry.isDeleteModify else { throw DeleteConflictFailure.unsupported }
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        let titles = try conflictTitles(options: identityOptions, cancellation: cancellation)
        let rebase = titles.rebase
        func side(_ stage: Int, reference: String, commit: String?) -> ConflictSide {
            let present = entry.stages.contains { $0.number == stage }
            return ConflictSide(stage: stage, reference: reference, commit: commit, status: present ? (entry.stages.contains { $0.number == 1 } ? "Modified" : "Created") : "Deleted")
        }
        let stage2 = side(2, reference: titles.stage2.title, commit: titles.stage2.commit)
        let stage3 = side(3, reference: titles.stage3.title, commit: titles.stage3.commit)
        try cancellation?.check()
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        return DeleteConflictDetails(entry: entry, first: rebase ? stage3 : stage2, second: rebase ? stage2 : stage3)
    }
    public func resolveDeleteConflict(_ entry: ConflictEntry, deleting: Bool, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        guard entry.isDeleteModify else { throw DeleteConflictFailure.unsupported }
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        // ConflictEdit uses ordinary add/rm: keep stages current working contents,
        // and Delete lets Git refuse removal instead of forcing local changes.
        return try run([deleting ? "rm" : "add", "--", entry.path], cancellation: cancellation, onOutput: onOutput).text
    }
    public func deleteConflictChanges(_ entry: ConflictEntry, cancellation: OperationCancellation? = nil) throws -> String {
        guard entry.isDeleteModify, entry.stages.contains(where: { $0.number == 1 }) else { throw DeleteConflictFailure.unsupported }
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        // --base compares the stage-1 blob with the surviving working contents.
        let text = try run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--base", "--", entry.path], cancellation: cancellation).text
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        return text
    }
}

/// Stage-1 base versus reviewed working contents, with a live editable destination
/// and no adjacent .BASE/.LOCAL/.REMOTE artifacts.
public struct ConflictBaseComparison: Sendable {
    public let entry: ConflictEntry
    public let snapshot: RevisionComparisonSnapshot
    public let document: FileComparisonDocument
}
extension GitRepository {
    public func conflictBaseComparison(_ entry: ConflictEntry, cancellation: OperationCancellation? = nil) throws -> ConflictBaseComparison {
        try cancellation?.check()
        guard !entry.isSubmodule, let base = entry.stages.first(where: { $0.number == 1 }), base.mode != "160000" else { throw DeleteConflictFailure.unsupported }
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        let bytes = try run(["cat-file", "blob", base.object], cancellation: cancellation).stdout
        let working = try WorkingFileComparison.workingContent(at: restoreLocation(entry.path))
        let destination = ComparisonFileContent(path: entry.path, revision: .workingTree, bytes: working.bytes, mode: working.mode, permissions: working.permissions)
        let content = ComparisonFileContent(path: entry.path, revision: .revision(base.object), bytes: bytes, mode: base.mode)
        let file = CommitFile(path: entry.path, oldPath: nil, action: "M", added: nil, removed: nil, hasStatistics: false, isSubmodule: false)
        let snapshot = RevisionComparisonSnapshot(root: root, from: content.revision, to: .workingTree, fromDetails: nil, toDetails: nil, files: [file], options: RevisionDiffOptions(), diffDetection: diffDetection)
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        try cancellation?.check()
        return ConflictBaseComparison(entry: entry, snapshot: snapshot, document: FileComparisonDocument(base: content, destination: destination))
    }
    public func saveConflictBaseComparison(_ entry: ConflictEntry, document: FileComparisonDocument, text: String, encoding: ComparisonTextEncoding? = nil, options: MergeFileSaveOptions = .init(),cancellation:OperationCancellation? = nil) throws -> FileComparisonDocument {
        try cancellation?.check()
        guard document.destination.path == entry.path,
              let base = entry.stages.first(where: { $0.number == 1 }), document.base.revision == .revision(base.object) else { throw ResolveFailure.stale }
        try validateConflicts([entry], using: .current)
        let destination = try FileComparisonEditing.saveWorkingContent(at: restoreLocation(entry.path), original: document.destination, text: text, encoding: encoding, options: options,cancellation:cancellation)
        return FileComparisonDocument(base: document.base, destination: destination)
    }
}
