import Foundation

public enum FetchOverride: Int, CaseIterable, Sendable { case disabled = 0, enabled = 1, configured = 2 }
public struct FetchOptions: Sendable {
    public var remote = ""
    public var arbitraryURL = false
    public var allRemotes = false
    public var branch = ""
    public var namedRemoteFetchAll = true
    public var tags = FetchOverride.configured
    public var prune = FetchOverride.configured
    public var depth: Int?
    public init() {}
}
public struct FetchDefaults: Sendable {
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
extension GitRepository {
    private func fetchConfig(_ key: String) -> String { ((try? run(["config", "--get", key]).text) ?? "").trimmingCharacters(in: .newlines) }
    public func fetchDefaults(remote selected: String? = nil) throws -> FetchDefaults {
        let names = try remoteNames(), current = try branch()
        let tracked = current.isEmpty ? "" : fetchConfig("branch." + current + ".remote")
        let remote = selected ?? (names.contains(tracked) ? tracked : (names.count == 1 ? names[0] : ""))
        let merge = current.isEmpty ? "" : fetchConfig("branch." + current + ".merge")
        let branchName = merge.hasPrefix("refs/heads/") ? String(merge.dropFirst(11)) : (merge.isEmpty ? current : merge)
        let tagopt = fetchConfig("remote." + remote + ".tagopt")
        let remotePrune = fetchConfig("remote." + remote + ".prune")
        return FetchDefaults(remote: remote, branch: branchName, tags: tagopt == "--no-tags" ? "None" : tagopt == "--tags" ? "All" : "Reachable",
                             prune: remotePrune.isEmpty ? fetchConfig("fetch.prune") : remotePrune,
                             shallow: try run(["rev-parse", "--is-shallow-repository"]).text.trimmingCharacters(in: .newlines) == "true",
                             bare: try run(["rev-parse", "--is-bare-repository"]).text.trimmingCharacters(in: .newlines) == "true")
    }
    public func remoteBranches(remote: String) throws -> [String] {
        guard !remote.isEmpty, !remote.contains("\0") else { throw FetchFailure.remote }
        return try run(["ls-remote", "--heads", "--", remote]).text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].hasPrefix("refs/heads/") else { return nil }
            return String(fields[1].dropFirst(11))
        }.sorted()
    }
    public func fetch(_ options: FetchOptions) throws -> String {
        let names = try remoteNames()
        guard !(options.allRemotes && options.arbitraryURL), options.allRemotes ? !names.isEmpty : (!options.remote.isEmpty && !options.remote.contains("\0") && (options.arbitraryURL || names.contains(options.remote))) else { throw FetchFailure.remote }
        if let depth = options.depth, depth <= 0 { throw FetchFailure.depth }
        let branch = options.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let useBranch = !options.allRemotes && (options.arbitraryURL || !options.namedRemoteFetchAll) && !branch.isEmpty
        if useBranch {
            let full = branch.hasPrefix("refs/heads/") ? branch : "refs/heads/" + branch
            guard (try? run(["check-ref-format", full])) != nil else { throw FetchFailure.branch }
        }
        var args = ["fetch", "--progress", "--verbose"]
        if let depth = options.depth { args.append("--depth=" + String(depth)) }
        if options.tags != .configured { args.append(options.tags == .enabled ? "--tags" : "--no-tags") }
        if options.prune != .configured { args.append(options.prune == .enabled ? "--prune" : "--no-prune") }
        if options.allRemotes { args.append("--all") }
        else { args += ["--", options.remote]; if useBranch { args.append(branch) } }
        return try run(args).text
    }
}
