// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum GitSVNOperation: String, Hashable, Sendable { case dcommit, fetch, rebase, ignore }
public enum GitSVNIgnoreDestination: Hashable, Sendable { case exclude, gitignore }
public struct GitSVNFetchResult: Sendable {
    public let reference: String
    public let oldHash: String
    public let newHash: String
    public let output: String
    public var changed: Bool { oldHash != newHash }
    public var range: String { oldHash + ".." + newHash }
}
public enum GitSVNRebasePlan: Equatable, Sendable { case upToDate, fastForward(String), rebase(String) }
public enum GitSVNFailure: LocalizedError {
    case runtime, remote, reference, stashChanged, changed
    public var errorDescription: String? {
        switch self {
        case .runtime: return "This Git executable does not provide a working git-svn runtime. Use a Git with Perl and Subversion bindings, or the bundled TurtleGit SVN runtime when available."
        case .remote: return "Found no SVN remote (svn-remote.svn.fetch)."
        case .reference: return "The SVN fetch mapping does not name a valid Git reference."
        case .stashChanged: return "The stash list changed. Your created stash was retained; restore it from Stash List."
        case .changed: return "The working tree or HEAD changed during SVN fetch. Review the repository before continuing."
        }
    }
}

extension GitRepository {
    public func checkGitSVNRuntime(cancellation: OperationCancellation? = nil) throws {
        do { _ = try run(["svn", "--version"], cancellation: cancellation) }
        catch let failure as GitCommandCancellationFailure { throw failure }
        catch is OperationCancellationFailure { throw OperationCancellationFailure.cancelled }
        catch { throw GitSVNFailure.runtime }
    }
    public func svnUpstream(cancellation: OperationCancellation? = nil) throws -> String {
        let result = try run(["config", "--get-all", "svn-remote.svn.fetch"], successfulExitCodes: 0...1, cancellation: cancellation)
        guard result.exitCode == 0, let line = result.text.split(separator: "\n").first, let colon = line.firstIndex(of: ":") else { throw GitSVNFailure.remote }
        let reference = String(line[line.index(after: colon)...])
        guard reference.hasPrefix("refs/"), !reference.contains("\0") else { throw GitSVNFailure.reference }
        do { _ = try run(["check-ref-format", reference], cancellation: cancellation) }
        catch is GitFailure { throw GitSVNFailure.reference }
        return reference
    }
    public func svnCommitType(cancellation: OperationCancellation? = nil) throws -> Bool? {
        let result = try run(["config", "--bool", "--get", "svn.rmdir"], successfulExitCodes: 0...1, cancellation: cancellation)
        return result.exitCode == 1 ? nil : result.text.trimmingCharacters(in: .newlines) == "true"
    }
    public func rememberSVNCommitType(removeEmptyDirectories: Bool, cancellation: OperationCancellation? = nil) throws {
        _ = try run(["config", "--local", "svn.rmdir", removeEmptyDirectories ? "true" : "false"], cancellation: cancellation)
    }
    public func svnTrackedChanges(cancellation: OperationCancellation? = nil) throws -> Bool {
        try !run(["status", "--porcelain=v1", "-z", "--untracked-files=no"], cancellation: cancellation).stdout.isEmpty
    }
    public func svnFetch(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> GitSVNFetchResult {
        try checkGitSVNRuntime(cancellation: cancellation)
        let reference = try svnUpstream(cancellation: cancellation)
        let old = try svnHash(reference, cancellation: cancellation)
        let result = try run(["svn", "fetch"], cancellation: cancellation, onOutput: onOutput)
        let new = try svnHash(reference, cancellation: cancellation)
        return GitSVNFetchResult(reference: reference, oldHash: old, newHash: new, output: result.text)
    }
    public func svnDCommit(removeEmptyDirectories: Bool, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try checkGitSVNRuntime(cancellation: cancellation)
        return try run(["svn", "dcommit"] + (removeEmptyDirectories ? ["--rmdir"] : []), cancellation: cancellation, onOutput: onOutput).text
    }
    public func svnRebasePlan(_ fetch: GitSVNFetchResult, cancellation: OperationCancellation? = nil) throws -> GitSVNRebasePlan {
        let head = try svnHash("HEAD", cancellation: cancellation)
        if head == fetch.newHash { return .upToDate }
        let ancestor = try run(["merge-base", "--is-ancestor", head, fetch.newHash], successfulExitCodes: 0...1, cancellation: cancellation)
        return ancestor.exitCode == 0 ? .fastForward(fetch.newHash) : .rebase(fetch.reference)
    }
    public func svnFastForward(to hash: String, expectedHead: String, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        guard try svnHash("HEAD", cancellation: cancellation) == expectedHead, try !svnTrackedChanges(cancellation: cancellation),
              hash.count == 40 || hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw GitSVNFailure.changed }
        // The target is an already validated full object ID. Reset's option
        // parser differs across Git versions; no revision disambiguator is
        // needed here, and older versions reject --end-of-options in this form.
        return try run(["reset", "--hard", hash, "--"], cancellation: cancellation, onOutput: onOutput).text
    }
    public func svnStash(cancellation: OperationCancellation? = nil) throws -> StashSaveResult {
        let previous = try run(["rev-parse", "--verify", "--quiet", "refs/stash"], successfulExitCodes: 0...1, cancellation: cancellation)
        let result = try run(["stash", "push"], cancellation: cancellation)
        let current = try run(["rev-parse", "--verify", "--quiet", "refs/stash"], successfulExitCodes: 0...1, cancellation: cancellation)
        return StashSaveResult(output: result.text, previous: previous.exitCode == 0 ? previous.text.trimmingCharacters(in: .newlines) : nil,
            current: current.exitCode == 0 ? current.text.trimmingCharacters(in: .newlines) : nil)
    }
    public func svnPopCreatedStash(_ hash: String, cancellation: OperationCancellation? = nil) throws -> String {
        guard try svnHash("refs/stash", cancellation: cancellation) == hash else { throw GitSVNFailure.stashChanged }
        return try run(["stash", "pop"], cancellation: cancellation).text
    }
    public func svnIgnoreExcludeURL(cancellation: OperationCancellation? = nil) throws -> URL {
        var bytes = try run(["rev-parse", "--git-path", "info/exclude"], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        return (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
    }
    public func svnImportIgnore(_ destination: GitSVNIgnoreDestination, excludeAccess: RepositoryAccessLease? = nil, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try checkGitSVNRuntime(cancellation: cancellation)
        switch destination {
        case .gitignore: return try run(["svn", "create-ignore"], cancellation: cancellation, onOutput: onOutput).text
        case .exclude:
            let file = try svnIgnoreExcludeURL(cancellation: cancellation)
            if GitRuntime.isAppStoreBuild && (excludeAccess?.hasSecurityScope != true || excludeAccess?.contains(file) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let result = try run(["svn", "show-ignore"], cancellation: cancellation, onOutput: onOutput)
            try cancellation?.check()
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try result.stdout.write(to: file, options: .atomic)
            return "Imported SVN ignore patterns to " + file.path + "\n" + String(decoding: result.stderr, as: UTF8.self)
        }
    }
    private func svnHash(_ reference: String, cancellation: OperationCancellation?) throws -> String {
        try run(["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
    }
}
