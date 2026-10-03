import Foundation

public struct PullOptions: Sendable {
    public var fetch = FetchOptions()
    public var squash = false
    public var noCommit = false
    public var noFastForward = false
    public var fastForwardOnly = false
    public init() {}
}
public struct PullDefaults: Sendable {
    public let trackedRemote: String
    public let trackedBranch: String
    public let rebase: Bool
}
public enum PullFailure: LocalizedError {
    case combination, rebaseWorkflow
    public var errorDescription: String? {
        switch self {
        case .combination: return "No Fast Forward and Fast Forward Only cannot be combined."
        case .rebaseWorkflow: return "This branch is configured to rebase on pull. The interactive Fetch and Rebase workflow is still being ported."
        }
    }
}
extension GitRepository {
    public func pullDefaults() throws -> PullDefaults {
        let current = try branch()
        func config(_ key: String) -> String { ((try? run(["config", "--get", key]).text) ?? "").trimmingCharacters(in: .newlines) }
        let remote = current.isEmpty ? "" : config("branch." + current + ".remote")
        let merge = current.isEmpty ? "" : config("branch." + current + ".merge")
        let branchRebase = current.isEmpty ? "" : config("branch." + current + ".rebase")
        let rebase = current.isEmpty ? "false" : (branchRebase.isEmpty ? config("pull.rebase") : branchRebase).lowercased()
        return PullDefaults(trackedRemote: remote, trackedBranch: merge.hasPrefix("refs/heads/") ? String(merge.dropFirst(11)) : merge,
                            rebase: ["true", "yes", "on", "1", "merges", "interactive", "preserve"].contains(rebase))
    }
    public func pull(_ options: PullOptions) throws -> String {
        guard !(options.noFastForward && options.fastForwardOnly) else { throw PullFailure.combination }
        let defaults = try pullDefaults()
        // Upstream routes configured rebase through Fetch + its interactive Rebase dialog.
        guard !defaults.rebase || options.fetch.arbitraryURL else { throw PullFailure.rebaseWorkflow }
        let fetch = options.fetch, names = try remoteNames()
        guard !fetch.allRemotes, !fetch.remote.isEmpty, !fetch.remote.contains("\0"), fetch.arbitraryURL || names.contains(fetch.remote) else { throw FetchFailure.remote }
        if let depth = fetch.depth, depth <= 0 { throw FetchFailure.depth }
        let branch = fetch.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty {
            let full = branch.hasPrefix("refs/heads/") ? branch : "refs/heads/" + branch
            guard (try? run(["check-ref-format", full])) != nil else { throw FetchFailure.branch }
        }
        var args = ["pull", "--progress", "--verbose", "--no-rebase", "--no-edit"]
        if options.noFastForward { args.append("--no-ff") }
        if options.fastForwardOnly { args.append("--ff-only") }
        if options.squash { args.append("--squash") }
        if options.noCommit { args.append("--no-commit") }
        if fetch.tags != .configured { args.append(fetch.tags == .enabled ? "--tags" : "--no-tags") }
        if fetch.prune != .configured { args.append(fetch.prune == .enabled ? "--prune" : "--no-prune") }
        if let depth = fetch.depth { args.append("--depth=" + String(depth)) }
        args += ["--", fetch.remote]
        let configuredTracking = !fetch.arbitraryURL && fetch.namedRemoteFetchAll && fetch.remote == defaults.trackedRemote && branch == defaults.trackedBranch
        if !branch.isEmpty && !configuredTracking { args.append(branch) }
        return try run(args).text
    }
}
