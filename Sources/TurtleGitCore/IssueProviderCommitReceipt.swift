// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Capture the revision while the synchronous repository actor operation still
/// owns the commit, before a provider callback can suspend the native workflow.
/// Failure to obtain a receipt after Git success must never retry the commit.
public struct IssueProviderCommitReceipt: Sendable {
    public let output: String
    public let revision: String?
    public let warning: String?
}

extension GitRepository {
    public func commitForIssueProvider(message: String, paths: GitPathSet, staging: Bool,
        options: CommitOptions, replaySplit: RebaseSplitState? = nil,
        backend: GitLibGit2Configuration? = nil, cancellation: OperationCancellation? = nil,
        onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> IssueProviderCommitReceipt {
        let output: String
        if let replaySplit {
            output = try commitRebaseSplit(message: message, paths: paths, staging: staging,
                options: options, expected: replaySplit, cancellation: cancellation, onOutput: onOutput)
        } else if staging {
            output = try commitIndex(message: message, options: options,
                cancellation: cancellation, onOutput: onOutput)
        } else {
            output = try commitSelected(message: message, paths: paths, options: options,
                cancellation: cancellation, onOutput: onOutput, backend: backend)
        }
        do {
            // Git has succeeded. A concurrently cancelled UI cannot turn that
            // success into an apparent failed commit by cancelling this read.
            let revision = try run(["rev-parse", "--verify", "HEAD^{commit}"]).text.trimmingCharacters(in: .newlines)
            guard [40,64].contains(revision.utf8.count), revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw GitFailure(arguments: ["rev-parse"], code: 1, message: "Git returned an invalid commit revision.")
            }
            return IssueProviderCommitReceipt(output: output, revision: revision, warning: nil)
        } catch {
            return IssueProviderCommitReceipt(output: output, revision: nil,
                warning: "The commit succeeded, but its issue-provider revision could not be captured.\n\n" + error.localizedDescription)
        }
    }
}
