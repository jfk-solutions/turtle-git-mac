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
public struct FetchRebaseResult: Sendable {
    public let output: String
    /// Immutable target from this fetch, independent of later FETCH_HEAD updates.
    public let upstream: String
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
    public func fetchForRebase(_ options: FetchOptions) throws -> FetchRebaseResult {
        guard !(try rebaseState()).active else { throw FetchRebaseFailure.active }
        guard !options.allRemotes, !options.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FetchRebaseFailure.destination }
        // Fetch exactly the selected branch even when ordinary Fetch uses all
        // configured refspecs. FETCH_HEAD then identifies that branch, including
        // remotes whose refspecs do not map to refs/remotes/<name>/<branch>.
        var selected = options; selected.namedRemoteFetchAll = false
        let output = try fetch(selected)
        let upstream = try run(["rev-parse", "--verify", "FETCH_HEAD^{commit}"]).text.trimmingCharacters(in: .newlines)
        return FetchRebaseResult(output: output, upstream: upstream)
    }
    private func fetchConfig(_ key: String) -> String { ((try? run(["config", "--get", key]).text) ?? "").trimmingCharacters(in: .newlines) }
    public func fetchDefaults(remote selected: String? = nil) throws -> FetchDefaults {
        let names = try remoteNames(), current = try branch()
        let tracked = current.isEmpty ? "" : fetchConfig("branch." + current + ".remote")
        let remote = selected ?? (names.contains(tracked) ? tracked : (names.count == 1 ? names[0] : ""))
        let merge = current.isEmpty ? "" : fetchConfig("branch." + current + ".merge")
        let submoduleBranch = merge.isEmpty ? ((try? fetchSubmoduleBranch()) ?? "") : ""
        let branchName = merge.hasPrefix("refs/heads/") ? String(merge.dropFirst(11)) : (merge.isEmpty ? (submoduleBranch.isEmpty ? current : submoduleBranch) : merge)
        let tagopt = fetchConfig("remote." + remote + ".tagopt")
        let remotePrune = fetchConfig("remote." + remote + ".prune")
        return FetchDefaults(remote: remote, branch: branchName, tags: tagopt == "--no-tags" ? "None" : tagopt == "--tags" ? "All" : "Reachable",
                             prune: remotePrune.isEmpty ? fetchConfig("fetch.prune") : remotePrune,
                             shallow: try run(["rev-parse", "--is-shallow-repository"]).text.trimmingCharacters(in: .newlines) == "true",
                             bare: try run(["rev-parse", "--is-bare-repository"]).text.trimmingCharacters(in: .newlines) == "true")
    }
    /// PullFetchDlg asks libgit2 for the registered parent's .gitmodules branch.
    /// This display default does not use Git's submodule-update config override
    /// or expand the special dot value to the parent's current branch.
    private func fetchSubmoduleBranch() throws -> String {
        guard let parent = try registeredSubmoduleParent() else { return "" }
        let modules = parent.appendingPathComponent(".gitmodules")
        let relative = String(root.path.dropFirst(parent.path.count + 1))
        let names = try run(["config", "--no-includes", "--null", "--file", modules.path, "--name-only", "--get-regexp", "^submodule\\..*\\.path$"], successfulExitCodes: 0...1).stdout.split(separator: 0)
        for rawName in names {
            let name = String(decoding: rawName, as: UTF8.self)
            let paths = try run(["config", "--no-includes", "--null", "--file", modules.path, "--get-all", name], successfulExitCodes: 0...1).stdout.split(separator: 0)
            guard paths.contains(where: { $0.elementsEqual(relative.utf8) }) else { continue }
            let key = String(name.dropLast(4)) + "branch"
            var bytes = try run(["config", "--no-includes", "--null", "--file", modules.path, "--get", key], successfulExitCodes: 0...1).stdout
            if bytes.last == 0 { bytes.removeLast() }
            return String(decoding: bytes, as: UTF8.self)
        }
        return ""
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
