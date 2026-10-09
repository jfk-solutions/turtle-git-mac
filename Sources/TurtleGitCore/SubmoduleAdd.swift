// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct SubmoduleAddOptions: Sendable {
    public var source = ""
    public var path = ""
    public var branch: String?
    public var force = false
    public var sshKey: URL?
    public init() {}
    public func relativePath(root: URL) throws -> String {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let relative: String
        if value.hasPrefix(root.path + "/") { relative = String(value.dropFirst(root.path.count + 1)) }
        else { relative = value }
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
              !relative.components(separatedBy: "/").contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw SubmoduleAddFailure.path }
        return relative
    }
    public func arguments(root: URL) throws -> [String] {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.contains("\0") else { throw SubmoduleAddFailure.source }
        if let branch { guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !branch.contains("\0") else { throw SubmoduleAddFailure.branch } }
        if let key = sshKey { guard key.isFileURL, key.path.hasPrefix("/"), !key.path.contains("\0") else { throw SubmoduleAddFailure.key } }
        var args = ["submodule", "add"]
        // Pinned SubmoduleCommand replaces its branch arguments when Force is set.
        if force { args.append("--force") }
        else if let branch { args += ["-b", branch.trimmingCharacters(in: .whitespacesAndNewlines)] }
        return args + ["--", source, try relativePath(root: root)]
    }
}

public enum SubmoduleAddFailure: LocalizedError {
    case source, path, branch, key
    public var errorDescription: String? {
        switch self {
        case .source: return "Enter a repository URL or local repository path."
        case .path: return "Choose a submodule path inside this working tree."
        case .branch: return "Enter a branch name."
        case .key: return "Choose an OpenSSH private key."
        }
    }
}

extension GitRepository {
    public func addSubmodule(_ options: SubmoduleAddOptions, cancellation: OperationCancellation? = nil, prepareTransport: SSHTransportPreparation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) async throws -> String {
        let token = cancellation ?? OperationCancellation(); try token.check()
        let args = try options.arguments(root: root), path = try options.relativePath(root: root)
        guard try !isBare(cancellation: token) else { throw SubmoduleAddFailure.path }
        let location = try restoreLocation(path)
        if let type = try? FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType,
           type != .typeDirectory { throw SubmoduleAddFailure.path }
        let session = try await prepareSSHTransport([], cancellation: token, preparation: prepareTransport)
        defer { withExtendedLifetime(session) {} }
        if options.sshKey != nil && session == nil { throw CloneFailure.keyRuntime }
        // Recheck the destination after a suspended grant/passphrase response.
        _ = try restoreLocation(path)
        if let type = try? FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType,
           type != .typeDirectory { throw SubmoduleAddFailure.path }
        let output = try run(args, environmentOverrides: session?.transportEnvironment ?? [:], literalPathspecs: false, cancellation: token, onOutput: onOutput).text
        if let key = options.sshKey {
            _ = try run(["-C", location.path, "-c", "core.precomposeunicode=false", "config", "--local", "remote.origin.turtlegitsshkeyfile", key.path], cancellation: token, onOutput: onOutput)
        }
        return output
    }
}
