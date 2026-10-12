import Foundation

public struct StashSaveOptions: Sendable {
    public var message = ""
    public var includeUntracked = false
    public var all = false
    public init() {}
}
public struct StashSaveResult: Sendable {
    public let output: String
    public let previous: String?
    public let current: String?
    public var created: Bool { current != nil && current != previous }
}
public struct StashRestoreResult: Sendable {
    public let output: String
    public let conflicted: Bool
    public init(output: String, conflicted: Bool) { self.output = output; self.conflicted = conflicted }
}
public enum StashFailure: LocalizedError {
    case combination, message
    public var errorDescription: String? {
        switch self {
        case .combination: return "Include untracked and --all cannot be combined."
        case .message: return "The stash message cannot contain a NUL character."
        }
    }
}
extension GitRepository {
    /// TortoiseGit checks tracked index/worktree changes before replay; untracked
    /// files alone do not trigger its Stash/Abort question.
    public func replayStashCondition(cherryPick: Bool, cancellation: OperationCancellation? = nil) throws -> (dirty: Bool, automatic: Bool) {
        try cancellation?.check()
        let staged = try run(["diff", "--cached", "--quiet", "HEAD", "--"], successfulExitCodes: 0...1, cancellation: cancellation).exitCode != 0
        let working = try run(["diff", "--quiet", "--"], successfulExitCodes: 0...1, cancellation: cancellation).exitCode != 0
        let automatic: Bool
        if cherryPick { automatic = false }
        else {
            let config = try run(["config", "--bool", "--get", "rebase.autostash"], successfulExitCodes: 0...1, cancellation: cancellation)
            automatic = config.exitCode == 0 && config.text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
        try cancellation?.check()
        return (staged || working, automatic)
    }

    /// Apply retains the stash; Pop lets Git drop it only after successful application.
    /// Neither operation requests --index, matching TortoiseGit's default workflow.
    public func restoreStash(pop: Bool, reference: String? = nil, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> StashRestoreResult {
        try cancellation?.check()
        var args = ["stash", pop ? "pop" : "apply"]
        if let reference, !reference.isEmpty {
            guard !reference.contains("\0") else { throw GitFailure(arguments: args, code: 1, message: "The stash reference cannot contain a NUL character.") }
            guard !pop else { throw GitFailure(arguments: args, code: 1, message: "Pop restores the latest stash.") }
            var ref = reference
            if ref.hasPrefix("refs/") { ref.removeFirst(5) }
            if ref.hasPrefix("stash{") { ref = "stash@" + ref.dropFirst(5) }
            // Resolve separately so a selected reference cannot become a Git option.
            let hash = try run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            try cancellation?.check()
            args.append(hash)
        }
        do {
            return StashRestoreResult(output: try run(args, cancellation: cancellation, onOutput: onOutput).text, conflicted: false)
        } catch let failure as GitFailure {
            // A merge conflict is a recoverable result, not a completed clean apply.
            // Confirm actual unmerged entries rather than trusting output text alone.
            if failure.code == 1 && failure.message.contains("CONFLICT") {
                try cancellation?.check()
                if try status(cancellation: cancellation).contains(where: { $0.state == .conflicted }) {
                    return StashRestoreResult(output: failure.message, conflicted: true)
                }
            }
            throw failure
        }
    }
    public func saveStash(_ options: StashSaveOptions, cancellation: OperationCancellation? = nil) throws -> StashSaveResult {
        try cancellation?.check()
        guard !(options.includeUntracked && options.all) else { throw StashFailure.combination }
        guard !options.message.contains("\0") else { throw StashFailure.message }
        let previous = (try? run(["rev-parse", "--verify", "refs/stash"], cancellation: cancellation).text.trimmingCharacters(in: .newlines))
        // An absent stash is expected; cancellation must not be swallowed by
        // the optional reference read or continue into a write.
        try cancellation?.check()
        var args = ["stash", "push"]
        if options.includeUntracked { args.append("--include-untracked") }
        else if options.all { args.append("--all") }
        if !options.message.isEmpty { args += ["-m", options.message] }
        // Stash uses the magic pathspec :/ in its internal clean subprocess.
        // Whole-repository save accepts no user paths, so preserve Git's own
        // pathspec semantics here; literal mode would silently skip cleanup.
        let output = try run(args, literalPathspecs: false, cancellation: cancellation).text
        let current = (try? run(["rev-parse", "--verify", "refs/stash"], cancellation: cancellation).text.trimmingCharacters(in: .newlines))
        try cancellation?.check()
        return StashSaveResult(output: output, previous: previous, current: current)
    }
}
