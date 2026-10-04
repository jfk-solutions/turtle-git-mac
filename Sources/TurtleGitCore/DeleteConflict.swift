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
    public func deleteConflictDetails(path: String) throws -> DeleteConflictDetails {
        guard let entry = try conflicts(paths: [path]).first(where: { $0.path == path }) else { throw ResolveFailure.stale }
        guard entry.isDeleteModify else { throw DeleteConflictFailure.unsupported }
        try validateConflicts([entry], using: .current)
        func hash(_ reference: String) -> String? { try? run(["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"]).text.trimmingCharacters(in: .newlines) }
        let rebase = try conflictIsRebase(), head = hash("HEAD")
        var incoming: String?, incomingName = "Ref to be merged"
        for name in rebase ? ["REBASE_HEAD"] : ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"] {
            if let resolved = hash(name) { incoming = resolved; incomingName = name + " (" + resolved.prefix(7) + ")"; break }
        }
        if !rebase, incomingName.hasPrefix("MERGE_HEAD"), let incoming {
            let refs = try run(["for-each-ref", "--points-at", incoming, "--format=%(refname:short)", "refs/heads", "refs/remotes"]).text.split(separator: "\n")
            if let reference = refs.first { incomingName = "MERGE_HEAD (" + reference + ", " + incoming.prefix(7) + ")" }
        }
        func side(_ stage: Int, reference: String, commit: String?) -> ConflictSide {
            let present = entry.stages.contains { $0.number == stage }
            return ConflictSide(stage: stage, reference: reference, commit: commit, status: present ? (entry.stages.contains { $0.number == 1 } ? "Modified" : "Created") : "Deleted")
        }
        let stage2 = side(2, reference: rebase ? "Branch being rebased onto" : "HEAD", commit: head)
        let stage3 = side(3, reference: rebase ? "Commit being replayed" : incomingName, commit: incoming)
        return DeleteConflictDetails(entry: entry, first: rebase ? stage3 : stage2, second: rebase ? stage2 : stage3)
    }
    public func resolveDeleteConflict(_ entry: ConflictEntry, deleting: Bool) throws -> String {
        guard entry.isDeleteModify else { throw DeleteConflictFailure.unsupported }
        try validateConflicts([entry], using: .current)
        // ConflictEdit uses ordinary add/rm: keep stages current working contents,
        // and Delete lets Git refuse removal instead of forcing local changes.
        return try run([deleting ? "rm" : "add", "--", entry.path]).text
    }
    public func deleteConflictChanges(_ entry: ConflictEntry) throws -> String {
        guard entry.isDeleteModify, entry.stages.contains(where: { $0.number == 1 }) else { throw DeleteConflictFailure.unsupported }
        try validateConflicts([entry], using: .current)
        // --base compares the stage-1 blob with the surviving working contents.
        return try run(["diff", "--no-ext-diff", "--no-color", "--base", "--", entry.path]).text
    }
}
