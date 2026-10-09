import Foundation

public struct CloneOptions: Sendable {
    public var source = ""
    public var recursive = false
    public var bare = false
    public var noCheckout = false
    public var depth: Int?
    public var branch: String?
    public var origin: String?
    public var sshKey: URL?
    /// Native Pageant replacement; legacy sshCommand callers retain their mode.
    public var loadSSHKeyWithAgent = false
    public var svn = false
    public var trunk: String?
    public var tags: String?
    public var branches: String?
    public var fromRevision: Int?
    public var username: String?
    public init() {}

    /// Git runs from an existing ancestor without creating or clearing the destination.
    public static func workingDirectory(for destination: URL) throws -> URL {
        guard destination.isFileURL else { throw CloneFailure.destination }
        var parent = destination.standardizedFileURL
        var directory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory) {
            let next = parent.deletingLastPathComponent()
            guard next != parent else { throw CloneFailure.destination }
            parent = next
        }
        guard directory.boolValue else { throw CloneFailure.destination }
        return parent
    }

    public func arguments(destination: URL) throws -> [String] {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.contains("\0") else { throw CloneFailure.source }
        guard destination.isFileURL, destination.path != "/", !destination.path.contains("\0") else { throw CloneFailure.destination }
        let fields = [branch, origin, trunk, tags, branches, username].compactMap { $0 }
        guard fields.allSatisfy({ !$0.contains("\0") }) else { throw CloneFailure.value }
        guard depth.map({ $0 > 0 }) ?? true, fromRevision.map({ $0 >= 0 }) ?? true else { throw CloneFailure.number }
        guard !(bare && (recursive || noCheckout || origin != nil)), !(svn && (bare || recursive || noCheckout || depth != nil || branch != nil)) else { throw CloneFailure.combination }
        guard svn || (trunk == nil && tags == nil && branches == nil && fromRevision == nil && username == nil) else { throw CloneFailure.combination }
        if loadSSHKeyWithAgent { guard let key = sshKey, key.isFileURL, key.path.hasPrefix("/"), !key.path.utf8.contains(0) else { throw CloneFailure.value } }
        var args: [String]
        if svn {
            args = ["svn", "clone"]
            if let origin { args += ["--prefix", origin.isEmpty ? "" : origin + "/"] }
            if let trunk { args += ["-T", trunk] }
            if let branches { args += ["-b", branches] }
            if let tags { args += ["-t", tags] }
            if let fromRevision { args += ["-r", "\(fromRevision):HEAD"] }
            if let username { args += ["--username", username] }
        } else {
            args = ["clone", "--progress", "-v"]
            if recursive { args.append("--recursive") }
            if bare { args.append("--bare") }
            if noCheckout { args.append("--no-checkout") }
            if let branch { guard !branch.isEmpty else { throw CloneFailure.value }; args += ["--branch", branch] }
            if let origin { guard !origin.isEmpty else { throw CloneFailure.value }; args += ["--origin", origin] }
            if let depth { args += ["--depth", String(depth)] }
            if let command = try sshCommand() { args += ["--config", "core.sshCommand=" + command] }
        }
        let url = svn && source.hasPrefix("/") ? URL(fileURLWithPath: source, isDirectory: false).absoluteString : source
        return args + ["--", url, destination.standardizedFileURL.path]
    }

    public func sshCommand() throws -> String? {
        guard !loadSSHKeyWithAgent, let key = sshKey else { return nil }
        guard key.isFileURL, !key.path.contains("\0") else { throw CloneFailure.value }
        // Git interprets core.sshCommand through a shell. Quote the literal key path.
        return "ssh -i '" + key.path.replacingOccurrences(of: "'", with: "'\\''") + "' -o IdentitiesOnly=yes"
    }
}

public enum CloneFailure: LocalizedError {
    case source, destination, value, number, combination, keyRuntime
    public var errorDescription: String? {
        switch self {
        case .source: return "Enter a repository URL or local repository path."
        case .destination: return "Choose a local destination with an existing parent folder."
        case .value: return "A clone option contains an invalid or empty value."
        case .number: return "Depth must be positive; the starting SVN revision cannot be negative."
        case .keyRuntime: return "Native SSH key loading is unavailable. Choose a build with SSH helpers."
        case .combination: return "These clone options cannot be combined."
        }
    }
}

extension GitRepository {
    public func clone(_ options: CloneOptions, to destination: URL, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, prepareTransport: SSHTransportPreparation? = nil) async throws -> String {
        let token = cancellation ?? OperationCancellation(); try token.check()
        let args = try options.arguments(destination: destination)
        if let branch = options.branch {
            guard !branch.hasPrefix("-"), (try? run(["check-ref-format", "refs/heads/" + branch], cancellation: token)) != nil else { throw CloneFailure.value }
        }
        if !options.svn, let origin = options.origin {
            guard !origin.hasPrefix("-"), (try? run(["check-ref-format", "refs/remotes/" + origin + "/test"], cancellation: token)) != nil else { throw CloneFailure.value }
        }
        let session = try await prepareSSHTransport([], cancellation: token, preparation: prepareTransport)
        defer { withExtendedLifetime(session) {} }
        if options.loadSSHKeyWithAgent && session == nil { throw CloneFailure.keyRuntime }
        var environment = session?.transportEnvironment ?? [:]
        if let command = try options.sshCommand() { environment["GIT_SSH_COMMAND"] = command }
        let output = try run(args, environmentOverrides: environment, literalPathspecs: false, cancellation: token, onOutput: onOutput).text
        if options.svn, let command = try options.sshCommand() {
            _ = try run(["-C", destination.path, "config", "--local", "core.sshCommand", command], cancellation: token, onOutput: onOutput)
        }
        if options.loadSSHKeyWithAgent, let key = options.sshKey {
            let remote = options.origin.flatMap { $0.isEmpty ? nil : $0 } ?? "origin"
            _ = try run(["-C", destination.path, "-c", "core.precomposeunicode=false", "config", "--local", "remote." + remote + ".turtlegitsshkeyfile", key.path], cancellation: token, onOutput: onOutput)
        }
        return output
    }
}
