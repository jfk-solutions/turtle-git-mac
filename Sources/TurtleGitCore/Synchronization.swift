// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// BranchCombox uses the pull tracking configuration, independently of Push's
/// pushRemote/pushDefault/pushbranch preferences.
public struct SynchronizationBranches: Sendable {
    public let localBranches: [String]
    public let currentBranch: String
    public let remotes: [String]
    public let trackedRemote: String
    public let trackedBranch: String
}

public enum SynchronizationDisposition: Equatable, Sendable {
    case unknownURL, unknownRemoteBranch, upToDate, needsForce, outgoing
}

/// A pinned, read-only projection of SyncDlg::FetchOutList. Transport commands
/// must refresh this projection after completion; this is not permission to push.
public struct SynchronizationOutgoing: Sendable {
    public let disposition: SynchronizationDisposition
    public let remoteReference: String
    public let localHash: String?
    public let remoteHash: String?
    public let mergeBase: String?
    public let fastForward: Bool
    public let commits: [LogEntry]
    public let comparison: RevisionComparisonSnapshot?
    public var canEmailPatch: Bool { disposition == .outgoing }
}

public enum SynchronizationFailure: LocalizedError {
    case invalidInput
    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "Choose valid synchronization branches and remote."
        }
    }
}

public enum SynchronizationTransportAction: Equatable, Sendable {
    case pull, fetch, fetchAndRebase, fetchAllBranches, remoteUpdate, prune
    case push, pushTags, pushNotes
}
public enum SynchronizationRebaseMode: Equatable, Sendable { case none, choose, rebase, preserveMerges }
public struct SynchronizationTransportOptions: Sendable {
    public var action: SynchronizationTransportAction
    public var localBranch = ""
    public var remote = ""
    public var remoteBranch = ""
    public var force = false
    public var fetchVerbose = true
    public init(action: SynchronizationTransportAction) { self.action = action }
}
/// Read-only preflight. Native tracking/hook/checkout questions must be settled
/// by the owner before it executes this immutable command selection.
public struct SynchronizationTransportPlan: Sendable {
    public let root: URL
    public let options: SynchronizationTransportOptions
    public let arguments: [String]
    public let transportRemotes: [String]
    public let oldHead: String?
    public let oldRemoteHash: String?
    public let checkoutBranch: String?
    public let checkoutArguments: [String]?
    public let rebaseMode: SynchronizationRebaseMode
    public let deletesDestination: Bool
    fileprivate let currentBranch: String
    fileprivate let rebaseReference: String?
}
public struct SynchronizationTransportResult: Sendable {
    public let command: GitResult
    public let rebaseTarget: String?
}
public enum SynchronizationTransportFailure: LocalizedError {
    case checkoutNotAuthorized, deletionNotAuthorized, repositoryChanged, rebaseBranchRequired
    public var errorDescription: String? {
        switch self {
        case .checkoutNotAuthorized: return "Confirm switching to the selected local branch before pulling."
        case .deletionNotAuthorized: return "Confirm deleting the destination branch before pushing an empty source."
        case .repositoryChanged: return "The repository changed. Refresh Synchronization before starting this operation."
        case .rebaseBranchRequired: return "Choose a remote branch before fetching for the configured Pull rebase."
        }
    }
}
/// Fetch completed, but its native Rebase handoff could not be pinned. Retain
/// the successful transport output independently of the failed follow-up read.
public struct SynchronizationTransportFollowUpFailure: LocalizedError {
    public let command: GitResult
    public let details: String
    public var errorDescription: String? { command.text + "\nPreparing Rebase failed.\n" + details }
}

extension GitRepository {
    private func synchronizationHash(_ revision: String, cancellation: OperationCancellation?) throws -> String? {
        guard !revision.contains("\0") else { throw SynchronizationFailure.invalidInput }
        let result = try run(["rev-parse", "--verify", "--quiet", "--end-of-options", revision + "^{commit}"], successfulExitCodes: 0...1, cancellation: cancellation)
        return result.exitCode == 0 ? String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) : nil
    }
    /// FixBranchName(FETCH_HEAD): exactly one for-merge line, not the first line
    /// and not an arbitrary member of an octopus fetch.
    private func synchronizationFetchHead(cancellation: OperationCancellation?) throws -> String {
        let result = try run(["rev-parse", "--git-path", "FETCH_HEAD"], cancellation: cancellation)
        var bytes = result.stdout; if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let contents = (try? Data(contentsOf: url)) ?? Data()
        let mergeLines = String(decoding: contents, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            return fields.count >= 3 && fields[1].isEmpty ? String(fields[0]) : nil
        }
        try cancellation?.check()
        return mergeLines.count == 1 ? mergeLines[0] : ""
    }
    public func synchronizationTransportPlan(_ input: SynchronizationTransportOptions, cancellation: OperationCancellation? = nil) throws -> SynchronizationTransportPlan {
        try cancellation?.check()
        guard ![input.localBranch, input.remote, input.remoteBranch].contains(where: { $0.contains("\0") }), !input.remote.isEmpty else { throw SynchronizationFailure.invalidInput }
        var options = input
        options.remoteBranch = options.remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = try synchronizationBranches(localBranch: options.localBranch, cancellation: cancellation)
        let head = try synchronizationHash("HEAD", cancellation: cancellation)
        let pushing = [.push, .pushTags, .pushNotes].contains(options.action)
        guard pushing || head != nil else { throw SynchronizationFailure.invalidInput }
        let url = options.remote.contains("/") || options.remote.contains("\\")
        var source = options.localBranch
        if GitReferenceName.equal(source, "FETCH_HEAD") { source = try synchronizationFetchHead(cancellation: cancellation) }
        var checkout: String?
        var mode = options.action == .fetchAndRebase ? SynchronizationRebaseMode.choose : .none
        if options.action == .pull {
            guard let localHash = try synchronizationHash(source, cancellation: cancellation) else { throw SynchronizationFailure.invalidInput }
            if localHash != head || !GitReferenceName.equal(options.localBranch, catalog.currentBranch) { checkout = options.localBranch }
            func configuration(_ key: String) throws -> String? {
                let value = try run(["config", "--get", key], successfulExitCodes: 0...1, cancellation: cancellation)
                return value.exitCode == 0 ? String(decoding: value.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) : nil
            }
            let branchKey = "branch." + options.localBranch + ".rebase"
            let branchValue = try configuration(branchKey)
            let key = branchValue == nil ? "pull.rebase" : branchKey
            let rebase = try branchValue ?? configuration(key) ?? "false"
            if rebase == "merges" { mode = .preserveMerges }
            else {
                do {
                    let value = try run(["config", "--bool", "--get", key], successfulExitCodes: 0...1, cancellation: cancellation)
                    if String(decoding: value.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) == "true" { mode = .rebase }
                } catch let error as GitFailure {
                    // Source GetBOOL leaves its zero default for a non-boolean
                    // string. The CLI Pull still receives its configured value.
                    guard error.code == 128 else { throw error }
                }
            }
            if mode != .none && options.remoteBranch.isEmpty { throw SynchronizationTransportFailure.rebaseBranchRequired }
        }
        let fetching = [.fetch, .fetchAndRebase, .fetchAllBranches].contains(options.action) || options.action == .pull && mode != .none
        var oldRemote: String?, args: [String], reference: String?
        if fetching {
            var refspec = options.action == .fetchAllBranches ? "" : options.remoteBranch
            if !url && !refspec.isEmpty {
                let tracking = "remotes/" + options.remote + "/" + refspec
                oldRemote = try synchronizationHash(tracking, cancellation: cancellation)
                if oldRemote != nil { refspec += ":" + tracking }
            }
            args = ["fetch", "--progress"]
            if options.fetchVerbose { args.append("-v") }
            if options.force { args.append("--force") }
            args += ["--", options.remote]
            if !refspec.isEmpty { args.append(refspec) }
            if mode != .none {
                let named = catalog.remotes.contains { GitReferenceName.equal($0, options.remote) }
                reference = named && !options.remoteBranch.isEmpty ? "remotes/" + options.remote + "/" + options.remoteBranch : "FETCH_HEAD"
            }
        } else {
            switch options.action {
            case .pull:
                args = ["pull", "-v", "--progress"]
                if options.force { args.append("--force") }
                args += ["--", options.remote]
                let tracked = !url && GitReferenceName.equal(catalog.trackedRemote, options.remote) && GitReferenceName.equal(catalog.trackedBranch, options.remoteBranch)
                if !tracked && !options.remoteBranch.isEmpty { args.append(options.remoteBranch) }
            case .remoteUpdate: args = ["remote", "update"]
            case .prune: args = ["remote", "prune", "--", options.remote]
            case .push, .pushTags, .pushNotes:
                args = ["push", "-v", "--progress"]
                if options.action == .pushTags { args.append("--tags") }
                if options.force { args.append("--force") }
                if options.action == .pushNotes {
                    source = String(decoding: try run(["notes", "get-ref"], cancellation: cancellation).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
                } else if !options.remoteBranch.isEmpty { source += ":" + options.remoteBranch }
                args += ["--", options.remote]
                if !source.isEmpty { args.append(source) }
            default: throw SynchronizationFailure.invalidInput
            }
        }
        guard !args.contains(where: { $0.contains("\0") }) else { throw SynchronizationFailure.invalidInput }
        try cancellation?.check()
        return SynchronizationTransportPlan(root: root, options: options, arguments: args,
            transportRemotes: options.action == .remoteUpdate ? catalog.remotes : [options.remote], oldHead: head,
            oldRemoteHash: oldRemote, checkoutBranch: checkout,
            checkoutArguments: checkout.map { branch in
                // Git 2.39 checkout lacks --end-of-options. switch's -- fence
                // preserves local-branch attachment and explicit revision detachment.
                let local = catalog.localBranches.contains { GitReferenceName.equal($0, branch) }
                return ["switch", local ? "--no-guess" : "--detach", "--", branch]
            }, rebaseMode: mode,
            deletesDestination: pushing && options.action != .pushNotes && source.hasPrefix(":"),
            currentBranch: catalog.currentBranch, rebaseReference: reference)
    }
    /// Executes the source CLI command. Project hooks, tracking questions and
    /// native post-fetch Rebase choices remain the caller's owned workflow.
    public func synchronize(_ plan: SynchronizationTransportPlan, checkoutAuthorized: Bool = false, deletionAuthorized: Bool = false,
                            cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil,
                            prepareTransport: SSHTransportPreparation? = nil) async throws -> SynchronizationTransportResult {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard plan.root == root else { throw SynchronizationTransportFailure.repositoryChanged }
        guard !plan.deletesDestination || deletionAuthorized else { throw SynchronizationTransportFailure.deletionNotAuthorized }
        guard plan.checkoutBranch == nil || checkoutAuthorized else { throw SynchronizationTransportFailure.checkoutNotAuthorized }
        if plan.options.action == .pull {
            guard try synchronizationHash("HEAD", cancellation: token) == plan.oldHead,
                  GitReferenceName.equal(try branch(cancellation: token), plan.currentBranch) else { throw SynchronizationTransportFailure.repositoryChanged }
        }
        if let arguments = plan.checkoutArguments {
            _ = try run(arguments, cancellation: token, onOutput: onOutput)
        }
        let readyHead = plan.options.action == .pull ? try synchronizationHash("HEAD", cancellation: token) : nil
        let readyBranch = plan.options.action == .pull ? try branch(cancellation: token) : ""
        let session = try await prepareSSHTransport(plan.transportRemotes, cancellation: token, preparation: prepareTransport)
        defer { withExtendedLifetime(session) {} }
        if plan.options.action == .pull {
            guard try synchronizationHash("HEAD", cancellation: token) == readyHead,
                  GitReferenceName.equal(try branch(cancellation: token), readyBranch) else { throw SynchronizationTransportFailure.repositoryChanged }
        }
        let result = try run(plan.arguments, environmentOverrides: session?.transportEnvironment ?? [:], cancellation: token, onOutput: onOutput)
        var target: String?
        if let reference = plan.rebaseReference {
            do {
                let revision = reference == "FETCH_HEAD" ? try synchronizationFetchHead(cancellation: token) : reference
                guard !revision.isEmpty, let resolved = try synchronizationHash(revision, cancellation: token) else { throw SynchronizationFailure.invalidInput }
                target = resolved
            } catch {
                try token.check()
                throw SynchronizationTransportFollowUpFailure(command: result, details: error.localizedDescription)
            }
        }
        return SynchronizationTransportResult(command: result, rebaseTarget: target)
    }

    public func synchronizationBranches(localBranch: String? = nil, cancellation: OperationCancellation? = nil) throws -> SynchronizationBranches {
        try cancellation?.check()
        guard localBranch?.contains("\0") != true else { throw SynchronizationFailure.invalidInput }
        let refs = try checkoutReferences(cancellation: cancellation)
        let locals = refs.compactMap { GitReferenceName.removingPrefix("refs/heads/", from: $0.name) }
        let current = try branch(cancellation: cancellation)
        let selected = localBranch ?? current
        func configuration(_ key: String) throws -> String {
            let result = try run(["config", "--get", key], successfulExitCodes: 0...1, cancellation: cancellation)
            return result.exitCode == 0 ? String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) : ""
        }
        let remote = selected.isEmpty ? "" : try configuration("branch." + selected + ".remote")
        var tracked = selected.isEmpty ? "" : try configuration("branch." + selected + ".merge")
        // CGit::StripRefName strips heads specially, otherwise only refs/.
        if let short = GitReferenceName.removingPrefix("refs/heads/", from: tracked) { tracked = short }
        else if let short = GitReferenceName.removingPrefix("refs/", from: tracked) { tracked = short }
        while tracked.last?.isWhitespace == true { tracked.removeLast() }
        let remotes = try run(["remote"], cancellation: cancellation).stdout
        try cancellation?.check()
        return SynchronizationBranches(localBranches: locals, currentBranch: current,
            remotes: String(decoding: remotes, as: UTF8.self).split(separator: "\n").map(String.init),
            trackedRemote: remote, trackedBranch: tracked)
    }

    public func synchronizationOutgoing(localBranch: String, remote: String, remoteBranch: String, force: Bool = false, cancellation: OperationCancellation? = nil) throws -> SynchronizationOutgoing {
        let token = cancellation ?? OperationCancellation()
        try token.check()
        guard ![localBranch, remote, remoteBranch].contains(where: { $0.contains("\0") }) else { throw SynchronizationFailure.invalidInput }
        let reference = remote + "/" + remoteBranch
        func snapshot(_ state: SynchronizationDisposition, local: String? = nil, tracking: String? = nil, base: String? = nil, fastForward: Bool = false, commits: [LogEntry] = [], comparison: RevisionComparisonSnapshot? = nil) -> SynchronizationOutgoing {
            SynchronizationOutgoing(disposition: state, remoteReference: reference, localHash: local, remoteHash: tracking, mergeBase: base, fastForward: fastForward, commits: commits, comparison: comparison)
        }
        // Preserve the source's URL/path heuristic; it intentionally does not
        // contact the server to discover commits for a typed URL.
        if remote.contains("/") || remote.contains("\\") { return snapshot(.unknownURL) }
        let remoteResult = try run(["rev-parse", "--verify", "--quiet", "--end-of-options", reference + "^{commit}"], successfulExitCodes: 0...1, cancellation: token)
        guard remoteResult.exitCode == 0 else { return snapshot(.unknownRemoteBranch) }
        guard !localBranch.isEmpty else { throw SynchronizationFailure.invalidInput }
        let remoteHash = String(decoding: remoteResult.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let localResult = try run(["rev-parse", "--verify", "--end-of-options", localBranch + "^{commit}"], cancellation: token)
        let localHash = String(decoding: localResult.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        if localHash == remoteHash { return snapshot(.upToDate, local: localHash, tracking: remoteHash, base: localHash, fastForward: true) }
        let result = try run(["merge-base", remoteHash, localHash], successfulExitCodes: 0...1, cancellation: token)
        let base = result.exitCode == 0 ? String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) : nil
        let fastForward = base == remoteHash
        guard fastForward || force else { return snapshot(.needsForce, local: localHash, tracking: remoteHash, base: base) }
        var options = HistoryOptions(); options.limit = -1
        options.revisionRange = HistoryRevisionRange(from: remoteHash, to: localHash, kind: .difference)
        let commits = try history(options: options, cancellation: token)
        // An absent common ancestor leaves upstream CGitHash zero. Its diff
        // helper treats zero as the working-copy revision, including -R.
        let from: ComparisonRevision = fastForward ? .revision(remoteHash) : base.map(ComparisonRevision.revision) ?? .workingTree
        var diffOptions = RevisionDiffOptions(); diffOptions.detectCopies = true
        let comparison = try revisionComparison(from: from, to: .revision(localHash), options: diffOptions, cancellation: token)
        try token.check()
        return snapshot(.outgoing, local: localHash, tracking: remoteHash, base: base, fastForward: fastForward, commits: commits, comparison: comparison)
    }

    /// Incoming tabs compare the captured pre-operation revision with the actual
    /// completed revision (HEAD for Pull, fetched upstream for Fetch).
    public func synchronizationIncoming(from oldRevision: String, to newRevision: String, cancellation: OperationCancellation? = nil) throws -> (commits: [LogEntry], comparison: RevisionComparisonSnapshot) {
        let token = cancellation ?? OperationCancellation()
        func resolve(_ revision: String) throws -> String {
            guard !revision.isEmpty, !revision.contains("\0") else { throw SynchronizationFailure.invalidInput }
            return String(decoding: try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], cancellation: token).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        }
        var diffOptions = RevisionDiffOptions(); diffOptions.detectCopies = true
        let comparison = try revisionComparison(from: .revision(resolve(oldRevision)), to: .revision(resolve(newRevision)), options: diffOptions, cancellation: token)
        guard case .revision(let oldHash) = comparison.from, case .revision(let newHash) = comparison.to else { throw SynchronizationFailure.invalidInput }
        var options = HistoryOptions(); options.limit = -1
        options.revisionRange = HistoryRevisionRange(from: oldHash, to: newHash, kind: .difference)
        let commits = try history(options: options, cancellation: token)
        try token.check()
        return (commits, comparison)
    }
}
