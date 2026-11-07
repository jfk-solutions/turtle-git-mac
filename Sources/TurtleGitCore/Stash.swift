import Foundation

public struct StashSaveOptions: Sendable {
    public var message = ""
    public var includeUntracked = false
    public var all = false
    /// User Stash Save has CheckUserData preflight; internal replay saves do not.
    public var requireIdentity = false
    public init() {}
}
public struct StashSaveResult: Sendable {
    public let output: String
    public let previous: String?
    public let current: String?
    public var created: Bool { current != nil && current != previous }
}
/// The requested stash-push process has drained, before reading its resulting
/// stash reference. Validation/reference preflight reads never emit this receipt.
public struct StashSaveCommandCompletion:Sendable {
    public let success:Bool
    public let cancelled:Bool
    public let exitCode:Int32?
    public let finished:Date
    public let elapsed:TimeInterval
    public init(success:Bool,cancelled:Bool,exitCode:Int32?,finished:Date=Date(),elapsed:TimeInterval) {
        self.success=success;self.cancelled=cancelled;self.exitCode=exitCode;self.finished=finished;self.elapsed=max(0,elapsed)
    }
}
/// Stash push completed, but its resulting identity could not be inspected.
/// The actual command receipt/output remains distinct from this later read.
public struct StashSaveReferenceReadFailure:LocalizedError,Sendable {
    public let command:GitResult
    public let previous:String?
    public let details:String
    public init(command:GitResult,previous:String?,details:String) {self.command=command;self.previous=previous;self.details=details}
    public var errorDescription:String? {"The stash command completed, but its resulting reference could not be read.\n"+details}
}
public struct StashRestoreResult: Sendable {
    public let output: String
    public let conflicted: Bool
    public init(output: String, conflicted: Bool) { self.output = output; self.conflicted = conflicted }
}
public enum StashFailure: LocalizedError {
    case combination, message, identity
    public var errorDescription: String? {
        switch self {
        case .combination: return "Include untracked and --all cannot be combined."
        case .message: return "The stash message cannot contain a NUL character."
        case .identity: return "Configure your Git user name and email before saving a stash."
        }
    }
}
extension GitRepository {
    /// TortoiseGit checks tracked index/worktree changes before replay; untracked
    /// files alone do not trigger its Stash/Abort question.
    public func replayStashCondition(cherryPick: Bool, cancellation: OperationCancellation? = nil) throws -> (dirty: Bool, automatic: Bool) {
        try cancellation?.check()
        let dirty = try !replayWorktreeIsClean(cancellation:cancellation)
        let automatic=try replayAutomaticStash(cherryPick:cherryPick,cancellation:cancellation)
        try cancellation?.check()
        return (dirty, automatic)
    }

    /// Source re-reads this setting when restoring, rather than keeping its Save-time value.
    public func replayAutomaticStash(cherryPick:Bool,cancellation:OperationCancellation?=nil) throws -> Bool {
        try cancellation?.check();guard !cherryPick else { return false }
        let config=try run(["config","--bool","--get","rebase.autostash"],successfulExitCodes:0...1,cancellation:cancellation)
        try cancellation?.check();return config.exitCode==0 && config.text.trimmingCharacters(in:.whitespacesAndNewlines)=="true"
    }

    /// Apply retains the stash; Pop lets Git drop it only after successful application.
    /// Neither operation requests --index, matching TortoiseGit's default workflow.
    public func restoreStash(pop: Bool, reference: String? = nil, cancellation: OperationCancellation? = nil,
                             backend:GitLibGit2Configuration?=nil,onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil,
                             onCommandFinished:(@Sendable(StashSaveCommandCompletion)->Void)?=nil) throws -> StashRestoreResult {
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
        let acceptedBackend=backend ?? libgit2Configuration ?? .load()
        try cancellation?.check()
        let started=ProcessInfo.processInfo.systemUptime
        let command:GitResult
        do {
            command=try run(args,cancellation:cancellation,onOutput:onOutput)
            onCommandFinished?(.init(success:command.exitCode==0,cancelled:false,exitCode:command.exitCode,elapsed:ProcessInfo.processInfo.systemUptime-started))
        } catch {
            let killed=error as? GitCommandCancellationFailure
            onCommandFinished?(.init(success:false,cancelled:cancellation?.isCancelled==true || error is OperationCancellationFailure || error is CancellationError || killed != nil,
                exitCode:killed?.result.exitCode ?? (error as? GitFailure)?.code,elapsed:ProcessInfo.processInfo.systemUptime-started))
            guard let failure=error as? GitFailure else {throw error}
            // A merge conflict is a recoverable result, not a completed clean apply.
            // Confirm actual unmerged entries rather than trusting output text alone.
            if failure.code == 1 && failure.message.contains("CONFLICT") {
                try cancellation?.check()
                if try hasWorkingTreeConflicts(cancellation:cancellation,backend:acceptedBackend) {
                    return StashRestoreResult(output: failure.message, conflicted: true)
                }
            }
            throw failure
        }
        return StashRestoreResult(output:command.text,conflicted:false)
    }
    private func stashReference(cancellation:OperationCancellation?) throws -> String? {
        let value=try run(["rev-parse","--verify","--quiet","refs/stash"],successfulExitCodes:0...1,cancellation:cancellation)
        try cancellation?.check()
        guard value.exitCode==0 else {
            guard value.stdout.isEmpty,value.stderr.isEmpty else {
                throw GitFailure(arguments:["rev-parse","--verify","--quiet","refs/stash"],code:value.exitCode,message:value.text,standardError:value.stderr)
            }
            return nil
        }
        var bytes=value.stdout
        if bytes.last==10 {bytes.removeLast()}
        guard [40,64].contains(bytes.count),bytes.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else {
            throw GitFailure(arguments:["rev-parse","--verify","--quiet","refs/stash"],code:1,message:"Git returned an invalid stash reference.")
        }
        return String(decoding:bytes,as:UTF8.self)
    }
    public func saveStash(_ options: StashSaveOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil,
                          onCommand:(@Sendable(GitCommandInvocation)->Void)? = nil,
                          onCommandFinished:(@Sendable(StashSaveCommandCompletion)->Void)? = nil) throws -> StashSaveResult {
        try cancellation?.check()
        guard !(options.includeUntracked && options.all) else { throw StashFailure.combination }
        guard !options.message.contains("\0") else { throw StashFailure.message }
        // Only the explicit quiet missing-reference status is absence. A read
        // failure must never turn a no-op save into a supposedly new stash.
        let previous=try stashReference(cancellation:cancellation)
        var args = ["stash", "push"]
        if options.includeUntracked { args.append("--include-untracked") }
        else if options.all { args.append("--all") }
        if !options.message.isEmpty { args += ["-m", options.message] }
        if options.requireIdentity {
            let identity = try replayUserIdentity(cancellation: cancellation)
            guard identity.complete else { throw StashFailure.identity }
        }
        // Stash uses the magic pathspec :/ in its internal clean subprocess.
        // Whole-repository save accepts no user paths, so preserve Git's own
        // pathspec semantics here; literal mode would silently skip cleanup.
        try cancellation?.check()
        onCommand?(commandInvocation(args,literalPathspecs:false))
        let started=ProcessInfo.processInfo.systemUptime
        let command:GitResult
        do {
            command=try run(args,literalPathspecs:false,cancellation:cancellation,onOutput:onOutput)
            onCommandFinished?(.init(success:command.exitCode == 0,cancelled:false,exitCode:command.exitCode,elapsed:ProcessInfo.processInfo.systemUptime-started))
        } catch {
            let killed=error as? GitCommandCancellationFailure
            onCommandFinished?(.init(success:false,cancelled:cancellation?.isCancelled == true || error is OperationCancellationFailure || error is CancellationError || killed != nil,
                exitCode:killed?.result.exitCode ?? (error as? GitFailure)?.code,elapsed:ProcessInfo.processInfo.systemUptime-started))
            throw error
        }
        let output=command.text
        let current:String?
        do {current=try stashReference(cancellation:cancellation)}
        catch {
            // Preserve cancellation as cancellation, and never emit a second
            // command receipt for this follow-up metadata phase.
            try cancellation?.check()
            if error is OperationCancellationFailure || error is CancellationError || error is GitCommandCancellationFailure {throw error}
            throw StashSaveReferenceReadFailure(command:command,previous:previous,details:error.localizedDescription)
        }
        return StashSaveResult(output: output, previous: previous, current: current)
    }
}
