import Foundation

public enum SubmoduleChangeType: String, Sendable {
    case unknown = "Unknown", identical = "Identical", newSubmodule = "New submodule", deleteSubmodule = "Delete submodule"
    case fastForward = "Fast Forward", rewind = "Rewind", newerTime = "Newer commit time", olderTime = "Older commit time", sameTime = "Same commit time"
}
public struct SubmoduleConflictSide: Sendable {
    public let stage: Int
    public let title: String
    public let revision: String?
    public let subject: String
    public let available: Bool
    public let change: SubmoduleChangeType
    public var canShowLog: Bool { available && revision != nil && change != .deleteSubmodule }
    public var choice: ResolveChoice? { ResolveChoice(rawValue: stage) }
}
public struct SubmoduleConflictDetails: Sendable {
    public let entry: ConflictEntry
    public let checkout: URL?
    public let base: SubmoduleConflictSide
    public let mine: SubmoduleConflictSide
    public let theirs: SubmoduleConflictSide
}
public enum SubmoduleConflictFailure: LocalizedError {
    case unsupported
    public var errorDescription: String? { "Choose a conflicted submodule to open this dialog." }
}
extension GitRepository {
    public func submoduleConflictDetails(path: String) throws -> SubmoduleConflictDetails {
        guard let entry = try conflicts(paths: [path]).first(where: { $0.path == path }) else { throw ResolveFailure.stale }
        guard entry.isSubmodule else { throw SubmoduleConflictFailure.unsupported }
        try validateConflicts([entry], using: .current)
        let url = root.appendingPathComponent(path)
        let initialized = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
        if initialized {
            var bytes = try run(["-C", url.path, "rev-parse", "--show-toplevel"]).stdout
            if bytes.last == 10 { bytes.removeLast() }
            guard URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL == url.standardizedFileURL else { throw ResolveFailure.outsideWorkingTree }
        }
        let originalBase = entry.stages.first { $0.number == 1 }
        let local = entry.stages.first { $0.number == 2 }, remote = entry.stages.first { $0.number == 3 }
        // Upstream compares destinations to the initialized checkout's HEAD, while
        // retaining the original conflict stages for validation before resolving.
        var baseHash = initialized ? try run(["-C", url.path, "rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .newlines) : originalBase?.object
        if !initialized, baseHash == nil, local != nil, remote == nil { baseHash = local?.object }
        func metadata(_ hash: String?) -> (String, Bool, Int64) {
            guard let hash else { return (initialized ? "" : "no submodule", initialized, 0) }
            guard initialized else { return ("not initialized", false, 0) }
            do {
                let text = try run(["-C", url.path, "log", "-1", "--format=%ct %s", hash, "--"]).text.trimmingCharacters(in: .newlines)
                let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let time = Int64(parts[0]) else { return ("Could not read commit", false, 0) }
                return (String(parts[1]), true, time)
            } catch { return (error.localizedDescription, false, 0) }
        }
        let baseInfo = metadata(baseHash)
        func side(_ stage: ConflictStage?, number: Int, title: String) -> SubmoduleConflictSide {
            var info = metadata(stage?.object), change = SubmoduleChangeType.unknown
            if let stage, stage.mode != "160000" { info = ("file, not a submodule", false, 0) }
            if initialized {
                if baseHash == nil { change = .newSubmodule }
                else if stage == nil { change = .deleteSubmodule }
                else if baseHash == stage?.object { change = .identical }
                else if baseInfo.1 && info.1, let baseHash, let hash = stage?.object {
                    if (try? run(["-C", url.path, "merge-base", "--is-ancestor", baseHash, hash])) != nil { change = .fastForward }
                    else if (try? run(["-C", url.path, "merge-base", "--is-ancestor", hash, baseHash])) != nil { change = .rewind }
                    else { change = info.2 > baseInfo.2 ? .newerTime : info.2 < baseInfo.2 ? .olderTime : .sameTime }
                }
                if !baseInfo.1 || !info.1 { change = .unknown }
            } else if stage == nil {
                change = baseHash == nil ? .identical : .deleteSubmodule
                if baseHash != nil { info = ("not initialized", false, 0) }
            } else if baseHash == stage?.object { change = .identical }
            else if baseHash == nil, (local == nil || remote == nil || local?.mode != remote?.mode), stage?.mode == "160000" { change = .newSubmodule }
            return SubmoduleConflictSide(stage: number, title: title, revision: stage?.object, subject: info.0, available: info.1, change: change)
        }
        let rebase = try conflictIsRebase()
        var incomingTitle = "changes to-be-integrated"
        for reference in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"] {
            if let hash = try? run(["rev-parse", "--verify", reference + "^{commit}"]).text.trimmingCharacters(in: .newlines) {
                var identity = String(hash.prefix(7))
                if reference == "MERGE_HEAD", let refs = try? run(["for-each-ref", "--points-at", hash, "--format=%(refname:short)", "refs/heads", "refs/remotes"]).text.split(separator: "\n"), let first = refs.first { identity = String(first) + ", " + identity }
                incomingTitle = reference == "REVERT_HEAD" ? "Parent of " + identity : reference + " (" + identity + ")"
                break
            }
        }
        let mine = side(rebase ? remote : local, number: rebase ? 3 : 2, title: rebase ? "Branch being rebased" : "HEAD")
        let theirs = side(rebase ? local : remote, number: rebase ? 2 : 3, title: rebase ? "Branch being rebased onto" : incomingTitle)
        let base = SubmoduleConflictSide(stage: 1, title: "Base", revision: baseHash, subject: baseInfo.0, available: baseInfo.1, change: .identical)
        return SubmoduleConflictDetails(entry: entry, checkout: initialized ? url : nil, base: base, mine: mine, theirs: theirs)
    }
}
