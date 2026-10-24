import Foundation

public enum FetchOverride: Int, CaseIterable, Sendable { case disabled = 0, enabled = 1, configured = 2 }
public struct FetchOptions: Sendable {
    public var remote = ""
    public var arbitraryURL = false
    public var allRemotes = false
    public var branch = ""
    public var namedRemoteFetchAll = true
    public var verbose = true
    public var tags = FetchOverride.configured
    public var prune = FetchOverride.configured
    public var depth: Int?
    public init() {}
}
public struct FetchDefaults: Sendable {
    /// Raw branch.remote before catalog validation; a missing configured remote
    /// must not be confused with an unconfigured branch during dialog refresh.
    public let trackedRemote: String
    public let remote: String
    public let branch: String
    public let tags: String
    public let prune: String
    public let shallow: Bool
    public let bare: Bool
}
public enum FetchFailure: LocalizedError {
    case remote, branch, depth
    public var errorDescription: String? {
        switch self {
        case .remote: return "Choose a configured remote or enter a destination URL."
        case .branch: return "Choose a valid remote branch name."
        case .depth: return "Depth must be a positive number."
        }
    }
}
public struct FetchRebaseResult: Sendable {
    public let output: String
    /// Immutable resolved commit, or the editable source preset if unresolved.
    public let upstream: String
    /// Source spelling before resolution, including an empty default chooser.
    public let upstreamPreset: String
    public let upstreamResolved: Bool
    /// The conventional named-remote ref before transport, as in DoFetch.
    public let oldUpstream: String
    public let head: String
    public let currentIsUpToDate: Bool
    public let canFastForward: Bool
    public var unchangedAtHEAD: Bool { upstreamResolved && !oldUpstream.isEmpty && oldUpstream == upstream && upstream == head }
}
/// Transport succeeded, but preparing the immutable Rebase target failed.
public struct FetchRebaseExecutionFailure: LocalizedError {
    public let output: String
    public let details: String
    public let commandFailure: GitFailure?
    public var errorDescription: String? { output + "\nPreparing Rebase failed.\n" + details }
}
public enum FetchRebaseFailure: LocalizedError {
    case destination, active
    public var errorDescription: String? {
        switch self {
        case .destination: return "Choose one remote and a branch before fetching for Rebase."
        case .active: return "Finish or abort the active Rebase before fetching for another Rebase."
        }
    }
}
extension GitRepository {
    /// Preserve literal decomposed ref names even in repositories whose worktree
    /// filenames use precomposition. This override never changes stored config.
    func fetchLiteralCommand(_ arguments: [String], environment: [String: String] = [:], cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
        do { return try run(["-c", "core.precomposeunicode=false"] + arguments, environmentOverrides: environment, successfulExitCodes: successfulExitCodes, cancellation: cancellation, onOutput: onOutput) }
        catch let failure as GitFailure {
            throw GitFailure(arguments: arguments, code: failure.code, message: failure.message, outputWasDelivered: failure.outputWasDelivered, standardError: failure.standardError)
        }
    }
    public func fetchForRebase(_ options: FetchOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, prepareTransport: SSHTransportPreparation? = nil, onCommand: (@Sendable (GitCommandInvocation) -> Void)? = nil, backend: GitLibGit2Configuration? = nil,onNotification:(@Sendable(GitTransferNotification)->Void)? = nil, isPull: Bool = false) async throws -> FetchRebaseResult {
        let backend = backend ?? libgit2Configuration ?? .load()
        try cancellation?.check()
        guard !(try rebaseState()).active else { throw FetchRebaseFailure.active }
        guard !options.allRemotes else { throw FetchRebaseFailure.destination }
        let branch = options.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        // PullFetchDlg omits named-all Fetch's field, but Pull omits it only
        // for the exact configured tracking selection. Capture that decision
        // once and use the same effective field for transport and its preset.
        let tracking = try pullDefaults(cancellation: cancellation)
        let matchesTracking = GitReferenceName.equal(tracking.trackedRemote, options.remote) && GitReferenceName.equal(tracking.trackedBranch, branch)
        let effectiveBranch = options.arbitraryURL || !options.namedRemoteFetchAll || (isPull && !matchesTracking) ? branch : ""
        guard !options.remote.contains("\0") else { throw FetchFailure.remote }
        guard !effectiveBranch.contains("\0") else { throw FetchFailure.branch }
        let preset: String
        if options.arbitraryURL { preset = "FETCH_HEAD" }
        else if !effectiveBranch.isEmpty { preset = "remotes/" + options.remote + "/" + effectiveBranch }
        else {
            preset = GitReferenceName.equal(tracking.trackedRemote, options.remote) && !tracking.trackedBranch.isEmpty ? "remotes/" + options.remote + "/" + tracking.trackedBranch : ""
        }
        let oldUpstream = options.arbitraryURL ? "" : (try fetchRebaseCommit(preset, cancellation: cancellation) ?? "")
        var selected = options
        if !effectiveBranch.isEmpty { selected.namedRemoteFetchAll = false }
        let output = try await fetch(selected, cancellation: cancellation, onOutput: onOutput, prepareTransport: prepareTransport, onCommand:onCommand,backend:backend,onNotification:onNotification)
        do {
            let resolved = try fetchRebaseCommit(preset, cancellation: cancellation)
            try cancellation?.check()
            let head = try fetchRebaseCommit("HEAD", cancellation: cancellation) ?? ""
            func ancestor(_ from: String, _ to: String) throws -> Bool {
                guard !from.isEmpty, !to.isEmpty else { return false }
                return try replayMergeBase(from:from,to:to,cancellation:cancellation,backend:backend).fastForward
            }
            let currentIsUpToDate = try resolved.map { try ancestor($0, head) } ?? false
            let canFastForward = try resolved.map { try ancestor(head, $0) } ?? false
            try cancellation?.check()
            return FetchRebaseResult(output: output, upstream: resolved ?? preset, upstreamPreset: preset, upstreamResolved: resolved != nil, oldUpstream: oldUpstream, head: head, currentIsUpToDate: currentIsUpToDate, canFastForward: canFastForward)
        } catch {
            try cancellation?.check()
            throw FetchRebaseExecutionFailure(output: output, details: error.localizedDescription, commandFailure: error as? GitFailure)
        }
    }

    private func fetchRebaseCommit(_ reference: String, cancellation: OperationCancellation?) throws -> String? {
        guard !reference.isEmpty else { return nil }
        let arguments = ["rev-parse", "--verify", "--quiet", "--end-of-options", reference + "^{commit}"]
        let result = try fetchLiteralCommand(arguments, cancellation: cancellation, successfulExitCodes: 0...1)
        guard result.exitCode == 0 else { return nil }
        let object = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard [40, 64].contains(object.utf8.count), object.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GitFailure(arguments: arguments, code: 1, message: "Git returned an invalid commit object ID.")
        }
        return object
    }

    private func fetchConfig(_ key: String, cancellation: OperationCancellation?) throws -> String {
        do { return try run(["config", "--get", key], cancellation: cancellation).text.trimmingCharacters(in: .newlines) }
        catch { try cancellation?.check(); return "" }
    }
    public func fetchDefaults(remote selected: String? = nil, cancellation: OperationCancellation? = nil) throws -> FetchDefaults {
        let names = try remoteNames(cancellation: cancellation), current = try branch(cancellation: cancellation)
        let tracked = current.isEmpty ? "" : try fetchConfig("branch." + current + ".remote", cancellation: cancellation)
        let remote = selected ?? (names.contains(where:{GitReferenceName.equal($0,tracked)}) ? tracked : (names.count == 1 ? names[0] : ""))
        let merge = current.isEmpty ? "" : try fetchConfig("branch." + current + ".merge", cancellation: cancellation)
        let submoduleBranch: String
        do { submoduleBranch = merge.isEmpty ? try fetchSubmoduleBranch(cancellation: cancellation) : "" }
        catch { try cancellation?.check(); submoduleBranch = "" }
        let branchName = merge.hasPrefix("refs/heads/") ? String(merge.dropFirst(11)) : (merge.isEmpty ? (submoduleBranch.isEmpty ? current : submoduleBranch) : merge)
        let tagopt = try fetchConfig("remote." + remote + ".tagopt", cancellation: cancellation)
        let remotePrune = try fetchConfig("remote." + remote + ".prune", cancellation: cancellation)
        return FetchDefaults(trackedRemote: tracked, remote: remote, branch: branchName, tags: tagopt == "--no-tags" ? "None" : tagopt == "--tags" ? "All" : "Reachable",
                             prune: remotePrune.isEmpty ? try fetchConfig("fetch.prune", cancellation: cancellation) : remotePrune,
                             shallow: try run(["rev-parse", "--is-shallow-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true",
                             bare: try run(["rev-parse", "--is-bare-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true")
    }
    /// PullFetchDlg asks libgit2 for the registered parent's .gitmodules branch.
    /// This display default does not use Git's submodule-update config override
    /// or expand the special dot value to the parent's current branch.
    private func fetchSubmoduleBranch(cancellation: OperationCancellation?) throws -> String {
        guard let parent = try registeredSubmoduleParent(cancellation: cancellation) else { return "" }
        let modules = parent.appendingPathComponent(".gitmodules")
        let relative = String(root.path.dropFirst(parent.path.count + 1))
        let names = try run(["config", "--no-includes", "--null", "--file", modules.path, "--name-only", "--get-regexp", "^submodule\\..*\\.path$"], successfulExitCodes: 0...1, cancellation: cancellation).stdout.split(separator: 0)
        for rawName in names {
            let name = String(decoding: rawName, as: UTF8.self)
            let paths = try run(["config", "--no-includes", "--null", "--file", modules.path, "--get-all", name], successfulExitCodes: 0...1, cancellation: cancellation).stdout.split(separator: 0)
            guard paths.contains(where: { $0.elementsEqual(relative.utf8) }) else { continue }
            let key = String(name.dropLast(4)) + "branch"
            var bytes = try run(["config", "--no-includes", "--null", "--file", modules.path, "--get", key], successfulExitCodes: 0...1, cancellation: cancellation).stdout
            if bytes.last == 0 { bytes.removeLast() }
            return String(decoding: bytes, as: UTF8.self)
        }
        return ""
    }
    public func remoteBranches(remote: String, cancellation: OperationCancellation? = nil, prepareTransport: SSHTransportPreparation? = nil) async throws -> [String] {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard !remote.isEmpty, !remote.contains("\0") else { throw FetchFailure.remote }
        let session = try await prepareSSHTransport([remote], cancellation: token, preparation: prepareTransport)
        defer { withExtendedLifetime(session) {} }
        return try run(["ls-remote", "--heads", "--", remote], environmentOverrides: session?.transportEnvironment ?? [:], cancellation: token).text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].hasPrefix("refs/heads/") else { return nil }
            return String(fields[1].dropFirst(11))
        }.sorted()
    }
    public func fetch(_ options: FetchOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, prepareTransport: SSHTransportPreparation? = nil, onCommand: (@Sendable (GitCommandInvocation) -> Void)? = nil, backend: GitLibGit2Configuration? = nil,onNotification:(@Sendable(GitTransferNotification)->Void)? = nil) async throws -> String {
        let backend = backend ?? libgit2Configuration ?? .load()
        let token = cancellation ?? OperationCancellation(); try token.check()
        let names = try remoteNames(cancellation: cancellation)
        guard !(options.allRemotes && options.arbitraryURL), options.allRemotes ? !names.isEmpty : (!options.remote.isEmpty && !options.remote.contains("\0") && (options.arbitraryURL || names.contains(where:{GitReferenceName.equal($0,options.remote)}))) else { throw FetchFailure.remote }
        if let depth = options.depth, depth <= 0 { throw FetchFailure.depth }
        let branch = options.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let useBranch = !options.allRemotes && (options.arbitraryURL || !options.namedRemoteFetchAll) && !branch.isEmpty
        // PullFetchDlg forwards one literal refspec, not necessarily a branch
        // name. Let the captured Git engine validate mappings, force, wildcard
        // and negative syntax; argv transport still forbids embedded NUL.
        if useBranch && branch.contains("\0") { throw FetchFailure.branch }
        var args = ["fetch", "--progress"]
        if options.verbose { args.append("--verbose") }
        if let depth = options.depth { args.append("--depth=" + String(depth)) }
        if options.tags != .configured { args.append(options.tags == .enabled ? "--tags" : "--no-tags") }
        if options.prune != .configured { args.append(options.prune == .enabled ? "--prune" : "--no-prune") }
        if options.allRemotes { args.append("--all") }
        else { args += ["--", options.remote]; if useBranch { args.append(branch) } }
        let executor = try backend.executor(for: .fetch)
        let session = try await prepareSSHTransport(options.allRemotes ? names : [options.remote], cancellation: token, preparation: prepareTransport)
        defer { withExtendedLifetime(session) {} }
        let executionArguments = ["-c", "core.precomposeunicode=false"] + args
        try token.check();onCommand?(commandInvocation(executionArguments,executorOverride:executor))
        do { return try runTransfer(executionArguments,environment:session?.transportEnvironment ?? [:],cancellation:token,onOutput:onOutput,executor:executor,onNotification:onNotification,sourceFetch:executor != nil).text }
        catch let failure as GitFailure {
            throw GitFailure(arguments: args, code: failure.code, message: failure.message, outputWasDelivered: failure.outputWasDelivered, standardError: failure.standardError)
        }
    }
}

/// AppUtils::GetClipboardLink and PullFetchDlg's literal-space field split.
/// POSIX absolute paths and file URLs supplement Windows drive paths on macOS.
public enum FetchClipboardInput {
    private static let whitespace = CharacterSet(charactersIn: " \t\r\n\u{0B}\u{0C}")
    static func link(_ raw: String, prefix: String) -> String? {
        var input = Array(raw.utf16)
        if let nul = input.firstIndex(of: 0) { input = Array(input[..<nul]) }
        guard !input.isEmpty else { return nil }
        if input.first == 34 && input.last == 34 { input = Array(input.dropFirst().dropLast()) }
        if let newline = input.firstIndex(of: 10) {
            input = Array(input[..<newline])
            while let last = input.last, [9, 10, 11, 12, 13, 32].contains(last) { input.removeLast() }
        }
        var text = String(decoding: input, as: UTF16.self)
        guard !text.isEmpty else { return nil }
        for scheme in ["http://", "https://", "git://", "ssh://", "git@", "file://"] {
            if text.utf16.starts(with: scheme.utf16), text.utf16.count != scheme.utf16.count { return text }
        }
        let units = Array(text.utf16)
        if units.count >= 2, units[1] == 58, (65...90).contains(units[0]) || (97...122).contains(units[0]) { return text }
        if units.first == 47 { return text }
        guard text.utf16.starts(with: prefix.utf16) else { return nil }
        text = String(decoding: units.dropFirst(prefix.utf16.count), as: UTF16.self).trimmingCharacters(in: whitespace)
        let remaining = Array(text.utf16), spaces = remaining.indices.filter { remaining[$0] == 32 }
        if spaces.count >= 2, spaces[1] > 0 { text = String(decoding: remaining[..<spaces[1]], as: UTF16.self) }
        return text.isEmpty ? nil : text
    }
    /// CloneDlg/SubmoduleAddDlg use the common link probe, then remove one
    /// matching quote pair. This is a field default, never a command execution.
    public static func cloneSource(_ text:String) -> String? {
        guard var value=link(text,prefix:"git clone ")?.trimmingCharacters(in:whitespace),!value.isEmpty else {return nil}
        let units=Array(value.utf16)
        if units.count>2,let first=units.first,first==units.last,first==34 || first==39 {
            value=String(decoding:units.dropFirst().dropLast(),as:UTF16.self)
        }
        return value.isEmpty ? nil:value
    }
    public static func selection(_ text: String, isPull: Bool) -> (url: String, branch: String?)? {
        guard let value = link(text, prefix: isPull ? "git pull" : "git fetch") ?? link(text, prefix: isPull ? "git fetch" : "git pull") else { return nil }
        let units = Array(value.utf16)
        guard let separator = units.firstIndex(of: 32), separator > 1, units.count > separator + 2 else { return (value, nil) }
        func unquote(_ units: ArraySlice<UInt16>) -> String {
            if units.count > 2, let first = units.first, first == units.last, first == 34 || first == 39 {
                return String(decoding: units.dropFirst().dropLast(), as: UTF16.self)
            }
            return String(decoding: units, as: UTF16.self)
        }
        return (unquote(units[..<separator]), unquote(units[(separator + 1)...]))
    }
}
