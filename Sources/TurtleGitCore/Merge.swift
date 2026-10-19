import Foundation

public struct MergeOptions: Sendable {
    public var revision = ""
    public var squash = false
    public var noCommit = false
    public var allowUnrelatedHistories = false
    public var noFastForward = false
    public var fastForwardOnly = false
    public var logCount: Int?
    public var strategy = ""
    public var strategyOption = ""
    public var strategyParameter = ""
    public var message = ""
    public var stripComments = false
    public var sanitizeMessage = true
    /// User-invoked Merge checks configured identity even for a fast-forward.
    /// Fetch's internal fast-forward deliberately retains Git's own requirements.
    public var requireIdentity = false
    public init() {}
    public static let strategies = ["resolve", "recursive", "ours", "subtree"]
    public static let strategyOptions = ["ours", "theirs", "patience", "ignore-space-change", "ignore-all-space", "ignore-space-at-eol", "renormalize", "no-renormalize", "rename-threshold", "subtree"]
}
public struct MergePreparation: Sendable {
    public let identity: ReplayUserIdentity
    public let replayActive: Bool
    public let hasGitSVN: Bool
    public init(identity: ReplayUserIdentity, replayActive: Bool, hasGitSVN: Bool) {
        self.identity = identity; self.replayActive = replayActive; self.hasGitSVN = hasGitSVN
    }
}
public enum MergeFailure: LocalizedError {
    case revision, combination, strategy, parameter, logCount, identity, activeReplay
    public var errorDescription: String? {
        switch self {
        case .revision: return "Choose a branch, tag or commit that exists in this repository."
        case .combination: return "No Fast Forward cannot be combined with Fast Forward Only or Squash."
        case .strategy: return "Choose a supported merge strategy and strategy option."
        case .parameter: return "Enter a valid strategy parameter."
        case .logCount: return "Enter a nonnegative number of commit messages."
        case .identity: return "Configure your Git user name and email before merging."
        case .activeReplay: return "Finish or abort the active TurtleGit rebase or cherry-pick before merging."
        }
    }
}
extension GitRepository {
    private func mergeRepositoryPath(_ name: String, cancellation: OperationCancellation?) throws -> URL {
        var bytes = try run(["rev-parse", "--git-path", name], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }
    /// Read ownership markers without invoking rebaseState's transaction recovery:
    /// this preflight must not edit an in-progress replay merely to reject Merge.
    private func mergeHasOwnedReplay(cancellation: OperationCancellation?) throws -> Bool {
        let manager = FileManager.default
        for name in ["rebase-merge", "rebase-apply"] {
            let directory = try mergeRepositoryPath(name, cancellation: cancellation)
            for marker in ["turtlegit-session.json", "turtlegit-replay-identities.json", "turtlegit-cherry-pick.json"] {
                try cancellation?.check()
                if manager.fileExists(atPath: directory.appendingPathComponent(marker).path) { return true }
            }
        }
        return false
    }
    public func prepareMerge(cancellation: OperationCancellation? = nil) throws -> MergePreparation {
        let identity = try replayUserIdentity(cancellation: cancellation)
        let active = try mergeHasOwnedReplay(cancellation: cancellation)
        var bytes = try run(["rev-parse", "--git-common-dir"], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        let common = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        try cancellation?.check()
        return MergePreparation(identity: identity, replayActive: active, hasGitSVN: FileManager.default.fileExists(atPath: common.appendingPathComponent("svn/.metadata").path))
    }
    public func mergeMessageCount() -> Int {
        (try? mergeMessageCount(cancellation: OperationCancellation())) ?? 20
    }
    public func mergeMessageCount(cancellation: OperationCancellation) throws -> Int {
        let value: String
        do { value = try run(["config", "--get", "merge.log"], successfulExitCodes: 0...1, cancellation: cancellation).text.trimmingCharacters(in: .newlines) }
        catch { try cancellation.check(); return 20 }
        return Int(value).flatMap { $0 > 0 ? $0 : nil } ?? 20
    }
    public func merge(_ options: MergeOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onCommand: (@Sendable (GitCommandInvocation) -> Void)? = nil) throws -> String {
        try cancellation?.check()
        guard !(options.noFastForward && (options.fastForwardOnly || options.squash)) else { throw MergeFailure.combination }
        if let count = options.logCount, count < 0 { throw MergeFailure.logCount }
        guard options.strategy.isEmpty || MergeOptions.strategies.contains(options.strategy),
              options.strategyOption.isEmpty || MergeOptions.strategyOptions.contains(options.strategyOption) else { throw MergeFailure.strategy }
        guard !options.revision.isEmpty, !options.revision.contains("\0") else { throw MergeFailure.revision }
        do { _ = try run(["rev-parse", "--verify", "--end-of-options", options.revision + "^{commit}"], cancellation: cancellation) }
        catch { try cancellation?.check(); throw MergeFailure.revision }
        var args = ["merge", "--no-edit"]
        if options.noFastForward { args.append("--no-ff") }
        if options.fastForwardOnly { args.append("--ff-only") }
        if options.squash { args.append("--squash") }
        if options.noCommit { args.append("--no-commit") }
        if options.allowUnrelatedHistories { args.append("--allow-unrelated-histories") }
        if let count = options.logCount { args.append("--log=\(count)") }
        if !options.strategy.isEmpty { args.append("--strategy=" + options.strategy) }
        // Upstream ignores hidden option/parameter values when the strategy changes.
        if options.strategy == "recursive", !options.strategyOption.isEmpty {
            var option = options.strategyOption
            if ["rename-threshold", "subtree"].contains(option), !options.strategyParameter.isEmpty {
                guard !options.strategyParameter.contains("\0") else { throw MergeFailure.parameter }
                if option == "rename-threshold" {
                    let value = options.strategyParameter.hasSuffix("%") ? String(options.strategyParameter.dropLast()) : options.strategyParameter
                    guard let percentage = Int(value), (0...100).contains(percentage) else { throw MergeFailure.parameter }
                }
                option += "=" + options.strategyParameter
            }
            args.append("--strategy-option=" + option)
        }
        var messageFile: EncodedCommitMessageFile?
        defer { messageFile?.remove() }
        if !options.squash, !options.message.isEmpty {
            guard !options.message.contains("\0") else { throw MergeFailure.parameter }
            let prepared = try prepareCommitMessageFile(options.message, stripComments: options.stripComments, sanitize: options.sanitizeMessage, cancellation: cancellation)
            let file = try makeCommitMessageFile(prepared.contents, appendFinalNewline: false, cancellation: cancellation)
            messageFile = file
            args += ["-F", file.url.path]
        }
        // Keep the selected ref name for Git's generated message; -- prevents options.
        args += ["--", options.revision]
        // Recheck after all preparation, immediately before Git can mutate refs or
        // the index. Match the source's identity-before-replay refusal order.
        if options.requireIdentity {
            let identity = try replayUserIdentity(cancellation: cancellation)
            guard identity.complete else { throw MergeFailure.identity }
        }
        if try mergeHasOwnedReplay(cancellation: cancellation) { throw MergeFailure.activeReplay }
        try cancellation?.check()
        onCommand?(commandInvocation(args))
        return try run(args, cancellation: cancellation, onOutput: onOutput).text
    }
}
