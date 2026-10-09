// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct SubmoduleSyncCommand: Sendable {
    public let scope: String
    public var arguments: [String] { scope == "." ? ["submodule", "sync"] : ["submodule", "sync", "--", scope] }
    public var display: String { "git " + arguments.map { $0.contains(where: { $0.isWhitespace || $0 == "'" }) ? "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" : $0 }.joined(separator: " ") }
}
public struct SubmoduleSyncResult: Sendable {
    public struct Entry: Sendable {
        public let command: SubmoduleSyncCommand
        public let exitCode: Int32
        public let output: String
    }
    public let entries: [Entry]
    public var exitCode: Int32 { entries.isEmpty ? -1 : entries.reduce(0) { $0 | $1.exitCode } }
    public var success: Bool { exitCode == 0 }
}
public enum SubmoduleSyncFailure: LocalizedError {
    case selection
    public var errorDescription: String? { "Choose existing directories inside the superproject to synchronize." }
}

extension GitRepository {
    public func submoduleSyncPlan(scope: [String], cancellation: OperationCancellation? = nil) throws -> [SubmoduleSyncCommand] {
        try cancellation?.check(); guard try !isBare(cancellation: cancellation) else { throw SubmoduleSyncFailure.selection }
        var commands: [SubmoduleSyncCommand] = []
        for path in scope.isEmpty ? ["."] : scope {
            try cancellation?.check()
            let location = path == "." ? root : try restoreLocation(path)
            guard let type = try? FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType else { throw SubmoduleSyncFailure.selection }
            if type == .typeSymbolicLink { throw SubmoduleSyncFailure.selection }
            // Source SubmoduleCommand includes directories only; files are skipped.
            if type == .typeDirectory { commands.append(SubmoduleSyncCommand(scope: path)) }
        }
        // Validate configured gitlinks before allowing Git to change child configs.
        let paths = try submoduleUpdatePaths(cancellation: cancellation)
        for path in paths where commands.contains(where: { $0.scope == "." || path == $0.scope || path.hasPrefix($0.scope + "/") }) {
            let location = try restoreLocation(path)
            if let type = try? FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType, type != .typeDirectory { throw SubmoduleSyncFailure.selection }
        }
        return commands
    }
    /// Source RunCmdList continues after ordinary command exit errors and ORs status.
    /// Process launch/validation failures and cancellation stop the sequence.
    public func syncSubmodules(scope: [String] = [], cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> SubmoduleSyncResult {
        let token = cancellation ?? OperationCancellation()
        let commands = try submoduleSyncPlan(scope: scope, cancellation: token)
        var entries: [SubmoduleSyncResult.Entry] = []
        for command in commands {
            try token.check(); _ = try submoduleSyncPlan(scope: [command.scope], cancellation: token)
            onOutput?(GitOutputChunk(stream: .stdout, data: Data(((entries.isEmpty ? "" : "\n") + command.display + "\n").utf8)))
            let result = try run(command.arguments, successfulExitCodes: 0...255, cancellation: token, onOutput: onOutput)
            entries.append(.init(command: command, exitCode: result.exitCode, output: result.text))
        }
        return SubmoduleSyncResult(entries: entries)
    }
}
