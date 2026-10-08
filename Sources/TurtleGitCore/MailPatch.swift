// Adapts ImportPatchDlg.cpp's git am flags and recovery commands (see NOTICE).
import Foundation

public struct MailPatchOptions: Sendable {
    public var threeWay = true
    public var ignoreSpaceChange = true
    public var signOff = false
    public var keepCR = true
    public init() {}
}
public enum MailPatchSession: Equatable, Sendable { case none, applying, rebase }
public enum MailPatchRecovery: String, CaseIterable, Sendable { case abort, skip, resolved }
public enum MailPatchFailure: LocalizedError {
    case file, activeSession, rebase, noSession
    public var errorDescription: String? {
        switch self {
        case .file: return "Choose an existing readable patch file."
        case .activeSession: return "A patch import is already active. Abort, skip or resolve it before importing another file."
        case .rebase: return "A rebase is active. Finish or abort it in the Rebase dialog before importing patches."
        case .noSession: return "No active patch import was found."
        }
    }
}
extension GitRepository {
    /// Checks this worktree's Git paths, including linked worktrees and external git directories.
    public func mailPatchSession(cancellation: OperationCancellation? = nil) throws -> MailPatchSession {
        func path(_ name: String) throws -> URL {
            var bytes = try run(["rev-parse", "--path-format=absolute", "--git-path", name], cancellation: cancellation).stdout
            if bytes.last == 10 { bytes.removeLast() }
            return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: try path("rebase-apply/applying").path) { return .applying }
        let apply = try path("rebase-apply"), merge = try path("rebase-merge")
        if manager.fileExists(atPath: apply.path) || manager.fileExists(atPath: merge.path) { return .rebase }
        return .none
    }
    public func importMailPatch(_ file: URL, options: MailPatchOptions = .init(), cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try cancellation?.check()
        guard file.isFileURL, !file.path.contains("\0") else { throw MailPatchFailure.file }
        let file = file.standardizedFileURL
        var directory: ObjCBool = false
        guard file.isFileURL, !file.path.contains("\0"), FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue, FileManager.default.isReadableFile(atPath: file.path) else { throw MailPatchFailure.file }
        switch try mailPatchSession(cancellation: cancellation) {
        case .applying: throw MailPatchFailure.activeSession
        case .rebase: throw MailPatchFailure.rebase
        case .none: break
        }
        var arguments = ["am"]
        if options.signOff { arguments.append("--signoff") }
        if options.threeWay { arguments.append("--3way") }
        if options.ignoreSpaceChange { arguments.append("--ignore-space-change") }
        if options.keepCR { arguments.append("--keep-cr") }
        arguments += ["--", file.path]
        return try run(arguments, cancellation: cancellation, onOutput: onOutput).text
    }
    public func recoverMailPatch(_ action: MailPatchRecovery, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try cancellation?.check()
        switch try mailPatchSession(cancellation: cancellation) {
        case .none: throw MailPatchFailure.noSession
        case .rebase: throw MailPatchFailure.rebase
        case .applying: break
        }
        return try run(["am", "--" + action.rawValue], cancellation: cancellation, onOutput: onOutput).text
    }
}
