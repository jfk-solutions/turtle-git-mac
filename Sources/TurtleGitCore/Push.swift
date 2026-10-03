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
    public var errorDescription: String? {
        (completed.isEmpty ? "" : "Completed: " + completed.joined(separator: ", ") + ".\n") + "Push to \(failedRemote) failed.\n" + details
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
        let branch = symbolic.hasPrefix("refs/heads/") ? String(symbolic.dropFirst(11)) : nil
        var remote = branch.map { pushConfig("branch." + $0 + ".pushRemote") } ?? ""
        if remote.isEmpty { remote = pushConfig("remote.pushDefault") }
        if remote.isEmpty, let branch { remote = pushConfig("branch." + branch + ".remote") }
        if !names.contains(remote) { remote = names.count == 1 ? names[0] : "" }
        let destination = branch.map { pushConfig("branch." + $0 + ".pushbranch") } ?? ""
        let merge = branch.map { pushConfig("branch." + $0 + ".merge") } ?? ""
        return PushDefaults(remote: remote, destination: destination.isEmpty ? merge : destination,
                            setUpstream: branch != nil && merge.isEmpty, localBranch: branch)
    }
    public func pushSubmoduleDefault() -> PushSubmodules { PushSubmodules(rawValue: pushConfig("push.recurseSubmodules")) ?? .none }
    public func push(_ options: PushOptions) throws -> String {
        let names = try remoteNames(), source = options.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = options.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let remotes = options.allRemotes ? names : [options.remote]
        guard !remotes.isEmpty, remotes.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }), options.arbitraryURL || remotes.allSatisfy(names.contains) else { throw PushValidationFailure.remote }
        guard !(options.force && options.forceWithLease), !(options.includeTags && options.forceWithLease), !(options.arbitraryURL && options.allRemotes) else { throw PushValidationFailure.combination }
        guard !options.pushOption.contains("\0"), !options.pushOption.contains("\n") else { throw PushValidationFailure.pushOption }
        if !options.allBranches, !source.isEmpty {
            // Verify before passing the original ref to push, retaining branch/tag identity.
            guard !source.contains(":"), !source.hasPrefix("+"), (try? run(["rev-parse", "--verify", "--end-of-options", source + "^{object}"])) != nil else { throw PushValidationFailure.source }
        }
        if !options.allBranches, !destination.isEmpty {
            let full = destination.hasPrefix("refs/") ? destination : "refs/heads/" + destination
            guard (try? run(["check-ref-format", full])) != nil else { throw PushValidationFailure.destination }
        }
        let defaults = try pushDefaults(source: source)
        let symbolic = ((try? run(["rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", source]).text) ?? "").trimmingCharacters(in: .newlines)
        let destinationRef = destination.isEmpty || destination.hasPrefix("refs/") ? destination : (symbolic.hasPrefix("refs/tags/") ? "refs/tags/" : "refs/heads/") + destination
        if options.savePushRemote || options.savePushBranch {
            guard !options.arbitraryURL, !options.allRemotes, !options.allBranches, !options.setUpstream, let branch = defaults.localBranch else { throw PushValidationFailure.combination }
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
                if options.allBranches {
                    output += try run(["push", "--all"] + flags + ["--", remote]).text
                    completed.append(remote + " (branches)")
                    if options.includeTags { output += try run(["push", "--tags"] + flags + ["--", remote]).text; completed.append(remote + " (tags)") }
                } else {
                    var args = ["push"] + flags
                    if options.includeTags { args.append("--tags") }
                    args += ["--", remote]
                    if !source.isEmpty || !destination.isEmpty { args.append(source + (destinationRef.isEmpty ? "" : ":" + destinationRef)) }
                    output += try run(args).text; completed.append(remote)
                }
            } catch { throw PushExecutionFailure(completed: completed, failedRemote: remote, details: error.localizedDescription) }
        }
        return output
    }
}
