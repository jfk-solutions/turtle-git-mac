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
    public func submoduleConflictDetails(path: String, identityOptions: ConflictIdentityOptions = .init(), cancellation: OperationCancellation? = nil, backend: GitLibGit2Configuration? = nil) async throws -> SubmoduleConflictDetails {
        try cancellation?.check()
        let selected = backend ?? libgit2Configuration ?? .load()
        guard let entry = try conflicts(paths: [path], cancellation: cancellation).first(where: { $0.path == path }) else { throw ResolveFailure.stale }
        guard entry.isSubmodule else { throw SubmoduleConflictFailure.unsupported }
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        let url = root.appendingPathComponent(path)
        let initialized = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
        if initialized {
            var bytes = try run(["-C", url.path, "rev-parse", "--show-toplevel"], cancellation: cancellation).stdout
            if bytes.last == 10 { bytes.removeLast() }
            guard URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.resolvingSymlinksInPath().path else { throw ResolveFailure.outsideWorkingTree }
        }
        let originalBase = entry.stages.first { $0.number == 1 }
        let local = entry.stages.first { $0.number == 2 }, remote = entry.stages.first { $0.number == 3 }
        // Upstream compares destinations to the initialized checkout's HEAD, while
        // retaining the original conflict stages for validation before resolving.
        var baseHash = initialized ? try run(["-C", url.path, "rev-parse", "--verify", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) : originalBase?.object
        if !initialized, baseHash == nil, local != nil, remote == nil { baseHash = local?.object }
        func metadata(_ hash: String?) -> (String, Bool, Int64) {
            guard let hash else { return (initialized ? "" : "no submodule", initialized, 0) }
            guard initialized else { return ("not initialized", false, 0) }
            do {
                let text = try run(["-C", url.path, "log", "--encoding=UTF-8", "-1", "--format=%ct %s", hash, "--"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
                let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let time = Int64(parts[0]) else { return ("Could not read commit", false, 0) }
                return (String(parts[1]), true, time)
            } catch { return (error.localizedDescription, false, 0) }
        }
        let addedBoth = !initialized && originalBase == nil && local != nil && remote != nil
        let baseInfo = addedBoth ? ("", true, Int64(0)) : metadata(baseHash)
        func side(_ stage: ConflictStage?, number: Int, title: String) async throws -> SubmoduleConflictSide {
            try cancellation?.check()
            var info = metadata(stage?.object), change = SubmoduleChangeType.unknown
            if let stage, stage.mode != "160000" { info = ("file, not a submodule", false, 0) }
            if initialized {
                if baseHash == nil { change = .newSubmodule }
                else if stage == nil { change = .deleteSubmodule }
                else if baseHash == stage?.object { change = .identical }
                else if baseInfo.1 && info.1, let baseHash, let hash = stage?.object {
                    let child = GitRepository(root: url, executable: executable, askpass: askpass, diffDetection: diffDetection, libgit2Configuration: selected)
                    if try await child.replayMergeBase(from: baseHash, to: hash, cancellation: cancellation).fastForward { change = .fastForward }
                    else if try await child.replayMergeBase(from: hash, to: baseHash, cancellation: cancellation).fastForward { change = .rewind }
                    else { change = info.2 > baseInfo.2 ? .newerTime : info.2 < baseInfo.2 ? .olderTime : .sameTime }
                }
                if !baseInfo.1 || !info.1 { change = .unknown }
            } else if addedBoth {
                // Upstream distinguishes file/submodule add-add conflicts from
                // uninitialized submodule/submodule additions.
                info = stage?.mode == "160000" ? ("not initialized", false, 0) : ("file, not a submodule", false, 0)
                let other = number == 2 ? remote : local
                if stage?.mode == "160000", other?.mode != "160000" { change = .newSubmodule }
            } else if originalBase == nil && local == nil && remote != nil {
                info = number == 2 ? ("no submodule", false, 0) : ("not initialized", false, 0)
                change = number == 2 ? .identical : .newSubmodule
            } else if baseHash != nil {
                info = ("not initialized", false, 0)
                if stage == nil { change = .deleteSubmodule }
                else if baseHash == stage?.object && (number == 2 || local == nil || remote == nil) { change = .identical }
            }
            return SubmoduleConflictSide(stage: number, title: title, revision: stage?.object, subject: info.0, available: info.1, change: change)
        }
        let titles = try conflictTitles(options: identityOptions, cancellation: cancellation), rebase = titles.rebase
        let mine = try await side(rebase ? remote : local, number: rebase ? 3 : 2, title: titles.mine.title)
        let theirs = try await side(rebase ? local : remote, number: rebase ? 2 : 3, title: titles.theirs.title)
        let base = SubmoduleConflictSide(stage: 1, title: "Base", revision: baseHash, subject: baseInfo.0, available: baseInfo.1, change: .identical)
        try cancellation?.check()
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        if initialized {
            let currentHead = try run(["-C", url.path, "rev-parse", "--verify", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            guard currentHead == baseHash else { throw ResolveFailure.stale }
        }
        return SubmoduleConflictDetails(entry: entry, checkout: initialized ? url : nil, base: base, mine: mine, theirs: theirs)
    }
}
