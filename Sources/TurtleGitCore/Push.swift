import Foundation

public enum PushSubmodules: String, CaseIterable, Sendable { case none = "no", check, onDemand = "on-demand" }
public struct PushOptions: Sendable {
    public var source = ""
    public var destination = ""
    public var remote = ""
    public var arbitraryURL = false
    public var allRemotes = false
    public var allBranches = false
    public var force = false
    public var forceWithLease = false
    public var includeTags = false
    public var setUpstream = false
    public var savePushRemote = false
    public var savePushBranch = false
    public var submodules = PushSubmodules.none
    public var pushOption = ""
    public var showBranchRevisionNumber = false
    public init() {}
}
public struct PushDefaults: Sendable {
    public let remote: String
    public let destination: String
    public let setUpstream: Bool
    public let localBranch: String?
}
public struct PushExecutionFailure: LocalizedError {
    public let completed: [String]
    public let failedRemote: String
    public let details: String
    public let output: String
    public let commandFailure: GitFailure?
    public init(completed: [String], failedRemote: String, details: String, output: String = "", commandFailure: GitFailure? = nil) {
        self.completed = completed; self.failedRemote = failedRemote; self.details = details; self.output = output; self.commandFailure = commandFailure
    }
    public var errorDescription: String? {
        output + (completed.isEmpty ? "" : "Completed: " + completed.joined(separator: ", ") + ".\n") + "Push to \(failedRemote) failed.\n" + details
    }
}
public enum PushValidationFailure: LocalizedError {
    case remote, source, destination, combination, pushOption
    public var errorDescription: String? {
        switch self {
        case .remote: return "Choose a configured remote or enter a destination URL."
        case .source: return "Choose an unambiguous local reference or revision."
        case .destination: return "Enter a valid remote branch or tag name."
        case .combination: return "These push options cannot be combined."
        case .pushOption: return "Push options cannot contain NUL or newlines."
        }
    }
}
extension GitRepository {
    public func remoteURLs(name: String) throws -> (fetch: String, push: String) {
        let fetch = try run(["remote", "get-url", "--", name]).text.trimmingCharacters(in: .newlines)
        return (fetch, pushConfig("remote." + name + ".pushurl"))
    }
    public func saveRemote(name: String, fetchURL: String, pushURL: String, existing: Bool) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("/"), !fetchURL.isEmpty, !fetchURL.contains("\0"), !pushURL.contains("\0"), (try? run(["check-ref-format", "refs/remotes/" + name + "/test"])) != nil else { throw PushValidationFailure.remote }
        if existing { _ = try run(["remote", "set-url", "--", name, fetchURL]) }
        else { _ = try run(["remote", "add", "--", name, fetchURL]) }
        if pushURL.isEmpty { if !pushConfig("remote." + name + ".pushurl").isEmpty { _ = try run(["config", "--local", "--unset-all", "remote." + name + ".pushurl"]) } }
        else { _ = try run(["config", "--local", "remote." + name + ".pushurl", pushURL]) }
    }
    public func remoteNames() throws -> [String] { try run(["remote"]).text.split(separator: "\n").map(String.init) }
    private func pushConfig(_ key: String) -> String { ((try? run(["config", "--get", key]).text) ?? "").trimmingCharacters(in: .newlines) }
    public func pushDefaults(source: String) throws -> PushDefaults {
        let names = try remoteNames()
        let symbolic = ((try? run(["rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", source]).text) ?? "").trimmingCharacters(in: .newlines)
        let candidate: String? = source.hasPrefix("refs/heads/") ? String(source.dropFirst(11)) : (!source.hasPrefix("refs/") && !source.hasPrefix("remotes/") ? source : nil)
        let exactBranch = candidate.flatMap { name in (try? run(["show-ref", "--verify", "--quiet", "--", "refs/heads/" + name])) != nil ? name : nil }
        let branch = exactBranch ?? (symbolic.hasPrefix("refs/heads/") ? String(symbolic.dropFirst(11)) : nil)
        var remote = branch.map { pushConfig("branch." + $0 + ".pushRemote") } ?? ""
        if remote.isEmpty { remote = pushConfig("remote.pushDefault") }
        if remote.isEmpty, let branch { remote = pushConfig("branch." + branch + ".remote") }
        if !names.contains(remote) { remote = names.count == 1 ? names[0] : "" }
        let destination = branch.map { pushConfig("branch." + $0 + ".pushbranch") } ?? ""
        var merge = branch.map { pushConfig("branch." + $0 + ".merge") } ?? ""
        if merge.hasPrefix("refs/heads/") { merge = String(merge.dropFirst(11)) }
        else if merge.hasPrefix("refs/") { merge = String(merge.dropFirst(5)) }
        return PushDefaults(remote: remote, destination: destination.isEmpty ? merge : destination,
                            setUpstream: branch != nil && merge.isEmpty, localBranch: branch)
    }
    public func pushSubmoduleDefault() -> PushSubmodules { PushSubmodules(rawValue: pushConfig("push.recurseSubmodules")) ?? .none }
    private func pushSourceIsUnique(_ source: String) -> Bool {
        // CGit::IsBranchTagNameUnique checks exact refs formed from the supplied
        // name. Fully qualified refs/revision expressions retain their source behavior.
        let branch = (try? run(["show-ref", "--verify", "--quiet", "--", "refs/heads/" + source])) != nil
        let tag = (try? run(["show-ref", "--verify", "--quiet", "--", "refs/tags/" + source])) != nil
        return !(branch && tag)
    }
    private func validatedPush(_ options: PushOptions, cancellation: OperationCancellation?) throws -> (source: String, destination: String, remotes: [String], localBranch: String?, destinationRef: String) {
        try cancellation?.check()
        let names = try remoteNames(), source = options.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = options.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let remotes = options.allRemotes ? names : [options.remote]
        guard !remotes.isEmpty, remotes.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }), options.arbitraryURL || remotes.allSatisfy(names.contains) else { throw PushValidationFailure.remote }
        guard !(options.force && options.forceWithLease), !(options.includeTags && options.forceWithLease), !(options.arbitraryURL && options.allRemotes) else { throw PushValidationFailure.combination }
        guard !options.pushOption.contains("\0"), !options.pushOption.contains("\n") else { throw PushValidationFailure.pushOption }
        if !options.allBranches, !source.isEmpty {
            // Verify before passing the original ref to push, retaining branch/tag identity.
            guard !source.contains(":"), !source.hasPrefix("+"), pushSourceIsUnique(source), (try? run(["rev-parse", "--verify", "--end-of-options", source + "^{object}"])) != nil else { throw PushValidationFailure.source }
        }
        if !options.allBranches, !destination.isEmpty {
            let full = destination.hasPrefix("refs/") ? destination : "refs/heads/" + destination
            guard (try? run(["check-ref-format", full])) != nil else { throw PushValidationFailure.destination }
        }
        let defaults = try pushDefaults(source: source)
        let symbolic = ((try? run(["rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", source]).text) ?? "").trimmingCharacters(in: .newlines)
        let destinationRef = destination.isEmpty || destination.hasPrefix("refs/") ? destination : (symbolic.hasPrefix("refs/tags/") ? "refs/tags/" : "refs/heads/") + destination
        try cancellation?.check()
        if options.savePushRemote || options.savePushBranch {
            guard !options.arbitraryURL, !options.allRemotes, !options.allBranches, !options.setUpstream, defaults.localBranch != nil else { throw PushValidationFailure.combination }
        }
        return (source, destination, remotes, defaults.localBranch, destinationRef)
    }
    /// Read-only submission validation, shared by the native history gate and transport.
    public func validatePushOptions(_ options: PushOptions, cancellation: OperationCancellation? = nil) throws {
        _ = try validatedPush(options, cancellation: cancellation)
    }
    /// The upstream first-parent counter is a display value, not a unique revision ID.
    public func branchRevisionNumber(_ revision: String, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try run(["rev-list", "--count", "--first-parent", "--end-of-options", revision, "--"], cancellation: cancellation, onOutput: onOutput).text.trimmingCharacters(in: .newlines)
    }
    public func push(_ options: PushOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        let plan = try validatedPush(options, cancellation: cancellation)
        let source = plan.source, destination = plan.destination, remotes = plan.remotes, destinationRef = plan.destinationRef
        if options.savePushRemote || options.savePushBranch {
            guard !options.arbitraryURL, !options.allRemotes, !options.allBranches, !options.setUpstream, let branch = plan.localBranch else { throw PushValidationFailure.combination }
            if options.savePushRemote { _ = try run(["config", "--local", "branch." + branch + ".pushRemote", options.remote]) }
            if options.savePushBranch {
                let key = "branch." + branch + ".pushbranch"
                if destination.isEmpty { if !pushConfig(key).isEmpty { _ = try run(["config", "--local", "--unset-all", key]) } }
                else { _ = try run(["config", "--local", key, destination]) }
            }
        }
        var flags = ["--porcelain", "--progress", "--recurse-submodules=" + options.submodules.rawValue]
        if options.force { flags.append("--force") }
        if options.forceWithLease { flags.append("--force-with-lease") }
        if options.setUpstream { flags.append("--set-upstream") }
        if !options.pushOption.isEmpty { flags.append("--push-option=" + options.pushOption) }
        var output = "", completed: [String] = []
        for remote in remotes {
            do {
                try cancellation?.check()
                if options.allBranches {
                    output += try run(["push", "--all"] + flags + ["--", remote], cancellation: cancellation, onOutput: onOutput).text
                    completed.append(remote + " (branches)")
                    if options.includeTags { output += try run(["push", "--tags"] + flags + ["--", remote], cancellation: cancellation, onOutput: onOutput).text; completed.append(remote + " (tags)") }
                } else {
                    var args = ["push"] + flags
                    if options.includeTags { args.append("--tags") }
                    args += ["--", remote]
                    if !source.isEmpty || !destination.isEmpty { args.append(source + (destinationRef.isEmpty ? "" : ":" + destinationRef)) }
                    output += try run(args, cancellation: cancellation, onOutput: onOutput).text; completed.append(remote)
                    if options.showBranchRevisionNumber { output += try branchRevisionNumber(source, cancellation: cancellation, onOutput: onOutput) + "\n" }
                }
            } catch { throw PushExecutionFailure(completed: completed, failedRemote: remote, details: error.localizedDescription, output: output, commandFailure: error as? GitFailure) }
        }
        return output
    }
}
