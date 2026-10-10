// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

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

extension GitRepository {
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
