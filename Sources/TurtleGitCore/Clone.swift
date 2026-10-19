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

public struct CloneOutcome: Sendable {
    public let output:String
    public let warnings:[String]
    public init(output:String,warnings:[String]) {self.output=output;self.warnings=warnings}
    public var summary:String {output + (warnings.isEmpty ? "" : (output.hasSuffix("\n") ? "" : "\n") + warnings.joined(separator:"\n"))}
}
/// The clone subprocess has drained, before saving post-clone SSH settings.
/// Transport preparation and validation failures do not emit this receipt.
public struct CloneCommandCompletion:Sendable {
    public let success:Bool,cancelled:Bool
    public let exitCode:Int32?
    public let finished:Date
    public let elapsed:TimeInterval
    public init(success:Bool,cancelled:Bool,exitCode:Int32?,finished:Date=Date(),elapsed:TimeInterval) {
        self.success=success;self.cancelled=cancelled;self.exitCode=exitCode;self.finished=finished;self.elapsed=max(0,elapsed)
    }
}

extension GitRepository {
    public func validateClone(_ options: CloneOptions, to destination: URL, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        _ = try options.arguments(destination: destination)
        if let branch = options.branch {
            let valid = !branch.hasPrefix("-") && (try? run(["check-ref-format", "refs/heads/" + branch], cancellation: cancellation)) != nil
            try cancellation?.check();guard valid else {throw CloneFailure.value}
        }
        if !options.svn, let origin = options.origin {
            let valid = !origin.hasPrefix("-") && (try? run(["check-ref-format", "refs/remotes/" + origin + "/test"], cancellation: cancellation)) != nil
            try cancellation?.check();guard valid else {throw CloneFailure.value}
        }
    }
    public func clone(_ options: CloneOptions, to destination: URL, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, prepareTransport: SSHTransportPreparation? = nil,
                      onCommand:(@Sendable(GitCommandInvocation)->Void)? = nil,onCommandFinished:(@Sendable(CloneCommandCompletion)->Void)? = nil, backend: GitLibGit2Configuration? = nil) async throws -> String {
        try await cloneOutcome(options,to:destination,cancellation:cancellation,onOutput:onOutput,prepareTransport:prepareTransport,onCommand:onCommand,onCommandFinished:onCommandFinished,backend:backend).summary
    }
    /// Git command failure throws; post-clone configuration failure is retained
    /// separately, matching CloneCommand's StorePuttyKey acknowledgment.
    public func cloneOutcome(_ options: CloneOptions, to destination: URL, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, prepareTransport: SSHTransportPreparation? = nil,
                             onCommand:(@Sendable(GitCommandInvocation)->Void)? = nil,onCommandFinished:(@Sendable(CloneCommandCompletion)->Void)? = nil, backend: GitLibGit2Configuration? = nil) async throws -> CloneOutcome {
        let backend = backend ?? libgit2Configuration ?? .load()
        let token=cancellation ?? OperationCancellation();try token.check()
        try validateClone(options,to:destination,cancellation:token)
        let args=try options.arguments(destination:destination)
        let executor = options.svn ? nil : try backend.executor(for: .clone)
        let session = try await prepareSSHTransport([], cancellation: token, preparation: prepareTransport)
        defer { withExtendedLifetime(session) {} }
        if options.loadSSHKeyWithAgent && session == nil { throw CloneFailure.keyRuntime }
        var environment = session?.transportEnvironment ?? [:]
        if let command = try options.sshCommand() { environment["GIT_SSH_COMMAND"] = command }
        try token.check()
        onCommand?(commandInvocation(args,literalPathspecs:false,executorOverride:executor))
        let started=ProcessInfo.processInfo.systemUptime
        let command:GitResult
        do {
            command=try run(args,environmentOverrides:environment,literalPathspecs:false,cancellation:token,onOutput:onOutput,executorOverride:executor)
            onCommandFinished?(.init(success:command.exitCode == 0,cancelled:false,exitCode:command.exitCode,elapsed:ProcessInfo.processInfo.systemUptime-started))
        } catch {
            let killed=error as? GitCommandCancellationFailure
            onCommandFinished?(.init(success:false,cancelled:token.isCancelled || error is OperationCancellationFailure || error is CancellationError || killed != nil,
                exitCode:killed?.result.exitCode ?? (error as? GitFailure)?.code,elapsed:ProcessInfo.processInfo.systemUptime-started))
            throw error
        }
        let output=command.text
        var warnings:[String]=[]
        do {
        if options.svn, let command = try options.sshCommand() {
            _ = try run(["-C", destination.path, "config", "--local", "core.sshCommand", command], cancellation: token)
        }
        if options.loadSSHKeyWithAgent, let key = options.sshKey {
            let remote = options.origin.flatMap { $0.isEmpty ? nil : $0 } ?? "origin"
            _ = try run(["-C", destination.path, "-c", "core.precomposeunicode=false", "config", "--local", "remote." + remote + ".turtlegitsshkeyfile", key.path], cancellation: token)
        }
        } catch {
            warnings.append("Clone completed, but its SSH setting could not be saved.\n" + error.localizedDescription)
        }
        return CloneOutcome(output:output,warnings:warnings)
    }
}
