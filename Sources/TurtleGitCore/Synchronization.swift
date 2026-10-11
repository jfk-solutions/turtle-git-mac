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

/// Source GitRefCompareList ordering, including unchanged references.
public enum SynchronizationReferenceChangeKind: Int, Sendable {
    case unknown, new, deleted, forward, newerTime, rewind, olderTime, sameTime, same
}
public struct SynchronizationReferenceSnapshot: Sendable {
    public let root: URL
    public let references: [GitReferenceName: String]
}
public struct SynchronizationReferenceChange: Sendable, Identifiable {
    public let name: GitReferenceName
    public var id: GitReferenceName { name }
    public let oldHash: String?
    public let newHash: String?
    public let oldMessage: String
    public let newMessage: String
    public let kind: SynchronizationReferenceChangeKind
    public let count: Int
    public var shortName: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/", "refs/notes/", "refs/"] {
            if let short = GitReferenceName.removingPrefix(prefix, from: name.rawValue) {
                return short.hasSuffix("^{}") ? String(short.dropLast(3)) : short
            }
        }
        return name.rawValue
    }
    public var typeName: String {
        if name.rawValue.hasPrefix("refs/heads/") { return "Branch" }
        if name.rawValue.hasPrefix("refs/remotes/") { return "Remote branch" }
        if name.rawValue.hasPrefix("refs/tags/") { return "Tag" }
        return ""
    }
    public var change: String {
        switch kind {
        case .unknown: return ""
        case .new: return "New"
        case .deleted: return "Deleted"
        case .forward: return "Forward \(count)"
        case .newerTime: return "Newer commit time"
        case .rewind: return "Rewind \(count)"
        case .olderTime: return "Older commit time"
        case .sameTime: return "Same commit time"
        case .same: return "Same"
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
    fileprivate let optionsOnly: Bool
}
public struct SynchronizationTransportResult: Sendable {
    public let command: GitResult
    public let rebaseTarget: String?
    public let rebaseMode: SynchronizationRebaseMode
    public let executedArguments: [String]
}
/// A completed, separately presented Pull checkout. The original plan keeps
/// the incoming-list baseline; the private fingerprint guards the next step.
/// Only the repository that performed checkout can resume this checkpoint.
public struct SynchronizationPullCheckout: Sendable {
    public let plan: SynchronizationTransportPlan
    public let command: GitResult?
    fileprivate let repository: GitRepository
    fileprivate let readyHead: String?
    fileprivate let readyBranch: String
}
/// Captures the actual branch attachment for SyncDlg's post-fetch choices.
/// The pinned target is independent of subsequent remote-ref/FETCH_HEAD writes.
public struct SynchronizationRebaseState: Sendable {
    public let target: String
    public let head: String
    public let branch: String
    public let canFastForward: Bool
    fileprivate let repository: GitRepository
}
public enum SynchronizationTransportFailure: LocalizedError {
    case checkoutNotAuthorized, deletionNotAuthorized, repositoryChanged, rebaseBranchRequired, fastForwardRequired
    public var errorDescription: String? {
        switch self {
        case .checkoutNotAuthorized: return "Confirm switching to the selected local branch before pulling."
        case .deletionNotAuthorized: return "Confirm deleting the destination branch before pushing an empty source."
        case .repositoryChanged: return "The repository changed. Refresh Synchronization before starting this operation."
        case .rebaseBranchRequired: return "Choose a remote branch before fetching for the configured Pull rebase."
        case .fastForwardRequired: return "The fetched revision cannot fast-forward the current branch."
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
    public func synchronizationRebaseState(target: String, cancellation: OperationCancellation? = nil) throws -> SynchronizationRebaseState {
        try cancellation?.check()
        guard !target.isEmpty, !target.contains("\0"),
              let targetHash = try synchronizationHash(target, cancellation: cancellation),
              let head = try synchronizationHash("HEAD", cancellation: cancellation) else { throw SynchronizationFailure.invalidInput }
        let branch = try self.branch(cancellation: cancellation)
        let forward = try run(["merge-base", "--is-ancestor", head, targetHash], successfulExitCodes: 0...1, cancellation: cancellation).exitCode == 0
        try cancellation?.check()
        return SynchronizationRebaseState(target: targetHash, head: head, branch: branch, canFastForward: forward, repository: self)
    }
    public func validateSynchronizationRebaseState(_ state: SynchronizationRebaseState, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard state.repository === self,
              try synchronizationHash("HEAD", cancellation: cancellation) == state.head,
              GitReferenceName.equal(try branch(cancellation: cancellation), state.branch) else { throw SynchronizationTransportFailure.repositoryChanged }
    }
    /// Source SyncDlg runs this separate progress command after Merge is chosen.
    public func synchronizationFastForward(_ state: SynchronizationRebaseState, cancellation: OperationCancellation? = nil,
                                            onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> GitResult {
        try validateSynchronizationRebaseState(state, cancellation: cancellation)
        guard state.canFastForward else { throw SynchronizationTransportFailure.fastForwardRequired }
        return try run(["merge", "--ff-only", "--", state.target], cancellation: cancellation, onOutput: onOutput)
    }
    public func synchronizationReferenceSnapshot(cancellation: OperationCancellation? = nil) throws -> SynchronizationReferenceSnapshot {
        try cancellation?.check()
        let output = try run(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(object)%00"], cancellation: cancellation).stdout
        var refs = [GitReferenceName: String]()
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 5 else { throw SynchronizationFailure.invalidInput }
            let tag = fields[2] == "tag"
            let name = String(fields[0]) + (tag ? "^{}" : "")
            let hash = String(tag ? fields[3] : fields[1])
            guard !hash.isEmpty else { throw SynchronizationFailure.invalidInput }
            refs[GitReferenceName(name)] = hash
        }
        try cancellation?.check()
        return SynchronizationReferenceSnapshot(root: root, references: refs)
    }
    /// Compare pinned all-ref maps, preserving source tag-target identity. Full
    /// hashes stay in the model so menu actions do not resolve moving ref names.
    public func synchronizationReferenceChanges(from old: SynchronizationReferenceSnapshot, to new: SynchronizationReferenceSnapshot,
                                                cancellation: OperationCancellation? = nil) throws -> [SynchronizationReferenceChange] {
        try cancellation?.check()
        guard old.root == root, new.root == root else { throw SynchronizationTransportFailure.repositoryChanged }
        var metadata = [String: (String, Int64?)]()
        func commit(_ hash: String?) throws -> (String, Int64?) {
            guard let hash else { return ("", nil) }
            if let cached = metadata[hash] { return cached }
            var result: (String, Int64?) = ("", nil)
            do {
                let type = try run(["cat-file", "-t", hash], cancellation: cancellation).stdout
                if String(decoding: type, as: UTF8.self).trimmingCharacters(in: .newlines) == "commit" {
                    let bytes = try run(["show", "--no-patch", "--no-show-signature", "--encoding=UTF-8", "--format=%ct%x00%B", hash, "--"], cancellation: cancellation).stdout
                    let fields = String(decoding: bytes, as: UTF8.self).split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
                    if fields.count == 2 {
                        result = (fields[1].split(separator: "\n").first.map(String.init) ?? "", Int64(fields[0]))
                    }
                }
            } catch is GitFailure { try cancellation?.check() }
            metadata[hash] = result; return result
        }
        let names = Set(old.references.keys).union(new.references.keys)
        var changes = [SynchronizationReferenceChange]()
        for name in names {
            try cancellation?.check()
            let before = old.references[name], after = new.references[name]
            let oldCommit = try commit(before), newCommit = try commit(after)
            var kind: SynchronizationReferenceChangeKind = .unknown, count = 0
            if before == nil { kind = .new }
            else if after == nil { kind = .deleted }
            else if before == after { kind = .same }
            else if let before, let after, let oldTime = oldCommit.1, let newTime = newCommit.1 {
                do {
                    let value = try run(["rev-list", "--left-right", "--count", before + "..." + after, "--"], cancellation: cancellation).stdout
                    let counts = String(decoding: value, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
                    if counts.count == 2 {
                        if counts[0] == 0 && counts[1] > 0 { kind = .forward; count = counts[1] }
                        else if counts[1] == 0 && counts[0] > 0 { kind = .rewind; count = counts[0] }
                        else { kind = oldTime < newTime ? .newerTime : oldTime > newTime ? .olderTime : .sameTime }
                    }
                } catch is GitFailure { try cancellation?.check() }
            }
            changes.append(SynchronizationReferenceChange(name: name, oldHash: before, newHash: after, oldMessage: oldCommit.0, newMessage: newCommit.0, kind: kind, count: count))
        }
        try cancellation?.check()
        return changes.sorted { a, b in a.kind.rawValue == b.kind.rawValue ? a.name.rawValue.utf16.lexicographicallyPrecedes(b.name.rawValue.utf16) : a.kind.rawValue < b.kind.rawValue }
    }
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
        try buildSynchronizationTransportPlan(input, cancellation: cancellation, checkoutCompleted: false)
    }
    /// Shift options preflight retains the approved checkout and old HEAD, but
    /// cannot execute transport: the full native options dialog selects it.
    public func synchronizationOptionsPlan(_ input: SynchronizationTransportOptions, cancellation: OperationCancellation? = nil) throws -> SynchronizationTransportPlan {
        guard input.action == .pull || input.action == .fetch else { throw SynchronizationFailure.invalidInput }
        return try buildSynchronizationTransportPlan(input, cancellation: cancellation, checkoutCompleted: false, optionsOnly: true)
    }
    private func buildSynchronizationTransportPlan(_ input: SynchronizationTransportOptions, cancellation: OperationCancellation?, checkoutCompleted: Bool, optionsOnly: Bool = false) throws -> SynchronizationTransportPlan {
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
        if pushing && GitReferenceName.equal(source, "FETCH_HEAD") { source = try synchronizationFetchHead(cancellation: cancellation) }
        var checkout: String?
        var mode = options.action == .fetchAndRebase ? SynchronizationRebaseMode.choose : .none
        if options.action == .pull {
            if !checkoutCompleted {
                guard let localHash = try synchronizationHash(source, cancellation: cancellation) else { throw SynchronizationFailure.invalidInput }
                if localHash != head || !GitReferenceName.equal(options.localBranch, catalog.currentBranch) { checkout = options.localBranch }
            }
            // Before checkout, predict whether the selected short local branch
            // stays attached. After checkout/authentication, use the actual HEAD
            // branch: post-checkout hooks may change configuration or attachment.
            let rebaseBranch = checkout.map { target in catalog.localBranches.contains { GitReferenceName.equal($0, target) } ? target : "" } ?? catalog.currentBranch
            if !optionsOnly, !rebaseBranch.isEmpty {
                func configuration(_ key: String) throws -> String? {
                    let value = try run(["config", "--get", key], successfulExitCodes: 0...1, cancellation: cancellation)
                    return value.exitCode == 0 ? String(decoding: value.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) : nil
                }
                let branchKey = "branch." + rebaseBranch + ".rebase"
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
            }
            // Source validates this after the separate checkout step. Do not
            // reject before a planned checkout whose hook can change the mode.
            if !optionsOnly && checkout == nil && mode != .none && options.remoteBranch.isEmpty { throw SynchronizationTransportFailure.rebaseBranchRequired }
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
        return SynchronizationTransportPlan(root: root, options: options, arguments: optionsOnly ? [] : args,
            transportRemotes: options.action == .remoteUpdate ? catalog.remotes : [options.remote], oldHead: head,
            oldRemoteHash: oldRemote, checkoutBranch: checkout,
            checkoutArguments: checkout.map { branch in
                // Git 2.39 checkout lacks --end-of-options. switch's -- fence
                // preserves local-branch attachment and explicit revision detachment.
                let local = catalog.localBranches.contains { GitReferenceName.equal($0, branch) }
                return ["switch", local ? "--no-guess" : "--detach", "--", branch]
            }, rebaseMode: mode,
            deletesDestination: pushing && options.action != .pushNotes && source.hasPrefix(":"),
            currentBranch: catalog.currentBranch, rebaseReference: reference, optionsOnly: optionsOnly)
    }
    /// Executes the source CLI command. Project hooks, tracking questions and
    /// native post-fetch Rebase choices remain the caller's owned workflow.
    public func synchronize(_ plan: SynchronizationTransportPlan, checkoutAuthorized: Bool = false, deletionAuthorized: Bool = false,
                            cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil,
                            prepareTransport: SSHTransportPreparation? = nil) async throws -> SynchronizationTransportResult {
        try await executeSynchronization(plan, checkout: nil, checkoutAuthorized: checkoutAuthorized, deletionAuthorized: deletionAuthorized,
                                         cancellation: cancellation, onOutput: onOutput, prepareTransport: prepareTransport)
    }
    /// Runs only the approved checkout, allowing the native owner to present
    /// source-style separate progress before tracking and transport questions.
    public func synchronizationPullCheckout(_ plan: SynchronizationTransportPlan, checkoutAuthorized: Bool = false,
                                            cancellation: OperationCancellation? = nil,
                                            onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> SynchronizationPullCheckout {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard plan.options.action == .pull else { throw SynchronizationFailure.invalidInput }
        guard plan.root == root,
              try synchronizationHash("HEAD", cancellation: token) == plan.oldHead,
              GitReferenceName.equal(try branch(cancellation: token), plan.currentBranch) else { throw SynchronizationTransportFailure.repositoryChanged }
        guard plan.checkoutBranch == nil || checkoutAuthorized else { throw SynchronizationTransportFailure.checkoutNotAuthorized }
        let command = try plan.checkoutArguments.map { try run($0, cancellation: token, onOutput: onOutput) }
        let head = try synchronizationHash("HEAD", cancellation: token)
        let branch = try self.branch(cancellation: token)
        try token.check()
        return SynchronizationPullCheckout(plan: plan, command: command, repository: self, readyHead: head, readyBranch: branch)
    }
    /// Continues after the owned checkout without switching a second time,
    /// even when a post-checkout hook changed the actual branch attachment.
    public func synchronize(_ checkout: SynchronizationPullCheckout, cancellation: OperationCancellation? = nil,
                            onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil,
                            prepareTransport: SSHTransportPreparation? = nil) async throws -> SynchronizationTransportResult {
        try await executeSynchronization(checkout.plan, checkout: checkout, checkoutAuthorized: true, deletionAuthorized: false,
                                         cancellation: cancellation, onOutput: onOutput, prepareTransport: prepareTransport)
    }
    private func executeSynchronization(_ plan: SynchronizationTransportPlan, checkout: SynchronizationPullCheckout?,
                                        checkoutAuthorized: Bool, deletionAuthorized: Bool, cancellation: OperationCancellation?,
                                        onOutput: (@Sendable (GitOutputChunk) -> Void)?, prepareTransport: SSHTransportPreparation?) async throws -> SynchronizationTransportResult {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard !plan.optionsOnly else { throw SynchronizationFailure.invalidInput }
        guard plan.root == root else { throw SynchronizationTransportFailure.repositoryChanged }
        guard !plan.deletesDestination || deletionAuthorized else { throw SynchronizationTransportFailure.deletionNotAuthorized }
        guard plan.checkoutBranch == nil || checkoutAuthorized else { throw SynchronizationTransportFailure.checkoutNotAuthorized }
        if plan.options.action == .pull {
            let expectedHead: String?
            if let checkout { expectedHead = checkout.readyHead } else { expectedHead = plan.oldHead }
            guard checkout == nil || checkout?.repository === self,
                  try synchronizationHash("HEAD", cancellation: token) == expectedHead,
                  GitReferenceName.equal(try branch(cancellation: token), checkout?.readyBranch ?? plan.currentBranch) else { throw SynchronizationTransportFailure.repositoryChanged }
        }
        if checkout == nil, let arguments = plan.checkoutArguments {
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
        // Source evaluates Pull rebase settings only after checkout and key
        // preparation. Rebuild its command from the same selected fields then;
        // the original plan still owns the pre-checkout HEAD for incoming tabs.
        let execution = plan.options.action == .pull ? try buildSynchronizationTransportPlan(plan.options, cancellation: token, checkoutCompleted: true) : plan
        let result = try run(execution.arguments, environmentOverrides: session?.transportEnvironment ?? [:], cancellation: token, onOutput: onOutput)
        var target: String?
        if let reference = execution.rebaseReference {
            do {
                let revision = reference == "FETCH_HEAD" ? try synchronizationFetchHead(cancellation: token) : reference
                guard !revision.isEmpty, let resolved = try synchronizationHash(revision, cancellation: token) else { throw SynchronizationFailure.invalidInput }
                target = resolved
            } catch {
                try token.check()
                throw SynchronizationTransportFollowUpFailure(command: result, details: error.localizedDescription)
            }
        }
        return SynchronizationTransportResult(command: result, rebaseTarget: target, rebaseMode: execution.rebaseMode, executedArguments: execution.arguments)
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

// Source: CGitTagCompareList. Compare annotated objects and friendly target rows
// separately; remote metadata is looked up only in the local object database.
public enum SynchronizationTagKind: String, Sendable { case same, differ, onlyLocal, onlyRemote }
public enum SynchronizationTagAction: Sendable { case fetch, push, deleteLocal, deleteRemote }
public struct SynchronizationTagRow: Hashable, Sendable, Identifiable {
    public let name: GitReferenceName
    public var id: GitReferenceName { name }
    public let localHash: String?
    public let remoteHash: String?
    public let localMessage: String
    public let remoteMessage: String
    public var kind: SynchronizationTagKind {
        if let localHash, let remoteHash { return localHash == remoteHash ? .same : .differ }
        return localHash != nil ? .onlyLocal : .onlyRemote
    }
    public var tag: GitReferenceName {
        GitReferenceName(name.rawValue.hasSuffix("^{}") ? String(name.rawValue.dropLast(3)) : name.rawValue)
    }
    public func allows(_ action: SynchronizationTagAction) -> Bool {
        switch action {
        case .fetch: return remoteHash != nil && kind != .same
        case .push: return localHash != nil && kind != .same
        case .deleteLocal: return localHash != nil
        case .deleteRemote: return remoteHash != nil
        }
    }
}
public struct SynchronizationTagSnapshot: Sendable {
    public let root: URL
    public let remote: String
    public let rows: [SynchronizationTagRow]
    fileprivate let localObjects: [GitReferenceName: String]
    fileprivate let repository: GitRepository
}
extension GitRepository {
    public func synchronizationTags(remote: String, cancellation: OperationCancellation? = nil,
                                    prepareTransport: SSHTransportPreparation? = nil) async throws -> SynchronizationTagSnapshot {
        let token = cancellation ?? OperationCancellation(); try token.check()
        let remoteRows = try await remoteTags(remote: remote, includingPeeled: true, cancellation: token, prepareTransport: prepareTransport)
        let advertised = Dictionary(uniqueKeysWithValues: remoteRows.map { ($0.name, $0.hash) })
        let bytes = try run(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(object)%00", "refs/tags/"], cancellation: token).stdout
        var local = [GitReferenceName: String](), objects = [GitReferenceName: String]()
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
            try token.check()
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 5, let short = GitReferenceName.removingPrefix("refs/tags/", from: String(fields[0])) else { throw SynchronizationFailure.invalidInput }
            let name = GitReferenceName(short), hash = String(fields[1])
            objects[name] = hash; local[name] = hash
            if fields[2] == "tag" {
                // Source libgit2's git_tag_target is one level, not recursive.
                guard !fields[3].isEmpty else { throw SynchronizationFailure.invalidInput }
                local[GitReferenceName(short + "^{}")] = String(fields[3])
            }
        }
        var messages = [String: String]()
        func message(_ hash: String?) throws -> String {
            guard let hash else { return "" }
            if let cached = messages[hash] { return cached }
            var result = ""
            do {
                let type = try run(["cat-file", "-t", hash], cancellation: token).stdout
                if String(decoding: type, as: UTF8.self).trimmingCharacters(in: .newlines) == "commit" {
                    let body = try run(["show", "--no-patch", "--no-show-signature", "--encoding=UTF-8", "--format=%B", hash, "--"], cancellation: token).stdout
                    result = String(decoding: body, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
                }
            } catch is GitFailure { try token.check() }
            messages[hash] = result; return result
        }
        let names = Set(local.keys).union(advertised.keys).sorted { $0.rawValue.utf16.lexicographicallyPrecedes($1.rawValue.utf16) }
        var rows = [SynchronizationTagRow]()
        for name in names {
            try token.check()
            let mine = local[name], theirs = advertised[name]
            rows.append(SynchronizationTagRow(name: name, localHash: mine, remoteHash: theirs, localMessage: try message(mine), remoteMessage: try message(theirs)))
        }
        try token.check()
        return SynchronizationTagSnapshot(root: root, remote: remote, rows: rows, localObjects: objects, repository: self)
    }
    /// Menus normalize a friendly ^{} row to the underlying tag. Force Push and
    /// non-force Fetch retain upstream behavior; deletions require confirmation.
    public func synchronizeTag(_ action: SynchronizationTagAction, row: SynchronizationTagRow, snapshot: SynchronizationTagSnapshot,
                               deletionAuthorized: Bool = false, cancellation: OperationCancellation? = nil,
                               onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil,
                               prepareTransport: SSHTransportPreparation? = nil) async throws -> GitResult {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard snapshot.repository === self, snapshot.root == root else { throw SynchronizationTransportFailure.repositoryChanged }
        guard snapshot.rows.contains(row), row.allows(action) else { throw SynchronizationFailure.invalidInput }
        let reference = "refs/tags/" + row.tag.rawValue
        _ = try run(["-c", "core.precomposeunicode=false", "check-ref-format", reference], cancellation: token)
        if action == .deleteLocal || action == .deleteRemote {
            guard deletionAuthorized else { throw SynchronizationTransportFailure.deletionNotAuthorized }
        }
        func checkLocal() throws {
            let current = try run(["-c", "core.precomposeunicode=false", "rev-parse", "--verify", "--quiet", "--end-of-options", reference], successfulExitCodes: 0...1, cancellation: token)
            let hash = current.exitCode == 0 ? String(decoding: current.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) : nil
            guard hash == snapshot.localObjects[row.tag] else { throw SynchronizationTransportFailure.repositoryChanged }
        }
        if action == .deleteLocal {
            try checkLocal()
            guard let expected = snapshot.localObjects[row.tag] else { throw SynchronizationFailure.invalidInput }
            return try run(["-c", "core.precomposeunicode=false", "update-ref", "--no-deref", "-d", reference, expected], cancellation: token, onOutput: onOutput)
        }
        if action != .deleteRemote { try checkLocal() }
        let session = try await prepareSSHTransport([snapshot.remote], cancellation: token, preparation: prepareTransport)
        defer { withExtendedLifetime(session) {} }
        if action != .deleteRemote { try checkLocal() }
        let args: [String]
        switch action {
        case .fetch: args = ["fetch", "--", snapshot.remote, reference + ":" + reference]
        case .push: args = ["push", "--force", "--", snapshot.remote, reference]
        case .deleteRemote: args = ["push", "--", snapshot.remote, ":" + reference]
        case .deleteLocal: throw SynchronizationFailure.invalidInput
        }
        return try run(["-c", "core.precomposeunicode=false"] + args, environmentOverrides: session?.transportEnvironment ?? [:], cancellation: token, onOutput: onOutput)
    }
}
