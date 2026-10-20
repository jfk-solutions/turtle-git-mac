// Adapts ImportPatchDlg.cpp's git am flags and recovery commands (see NOTICE).
import Foundation
import Darwin

public struct MailPatchOptions: Sendable {
    public var threeWay = true
    public var ignoreSpaceChange = true
    public var signOff = false
    public var keepCR = true
    public init() {}
}
public enum MailPatchSession: Equatable, Sendable { case none, applying, rebase }
public enum MailPatchRecovery: String, CaseIterable, Sendable { case abort, skip, resolved }
/// A reviewed am operation, not an index/worktree snapshot: resolving conflicts
/// and staging files must remain possible while the recovery question is open.
public struct MailPatchRecoverySession: Equatable, Sendable {
    public let metadataPath: String
    public let currentItem: Int
    public let totalItems: Int
    fileprivate let directory: MailPatchDirectoryIdentity
    fileprivate let fields: [String: Data]
    fileprivate let head: Data
}
fileprivate struct MailPatchDirectoryIdentity: Equatable, Sendable {
    let device: Int32, inode: UInt64, birthSeconds: Int64, birthNanoseconds: Int64
    init(_ value: stat) {
        device=value.st_dev;inode=value.st_ino
        birthSeconds=Int64(value.st_birthtimespec.tv_sec);birthNanoseconds=Int64(value.st_birthtimespec.tv_nsec)
    }
}
public enum MailPatchFailure: LocalizedError {
    case file, activeSession, rebase, noSession, changedSession
    public var errorDescription: String? {
        switch self {
        case .file: return "Choose an existing readable patch file."
        case .activeSession: return "A patch import is already active. Abort, skip or resolve it before importing another file."
        case .rebase: return "A rebase is active. Finish or abort it in the Rebase dialog before importing patches."
        case .noSession: return "No active patch import was found."
        case .changedSession: return "The patch import changed while recovery was being reviewed. Review its current state before choosing Abort, Skip or Resolved again."
        }
    }
}
extension GitRepository {
    private func mailPatchMetadataPath(_ name: String, cancellation: OperationCancellation?) throws -> URL {
        var bytes = try run(["rev-parse", "--path-format=absolute", "--git-path", name], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        guard let path=String(data:bytes,encoding:.utf8),path.hasPrefix("/"),!path.contains("\0") else{throw MailPatchFailure.changedSession}
        return FileTransferPaths.fileURL(path)
    }
    /// Checks this worktree's Git paths, including linked worktrees and external git directories.
    public func mailPatchSession(cancellation: OperationCancellation? = nil) throws -> MailPatchSession {
        let manager = FileManager.default
        if manager.fileExists(atPath: try mailPatchMetadataPath("rebase-apply/applying",cancellation:cancellation).path) { return .applying }
        let apply = try mailPatchMetadataPath("rebase-apply",cancellation:cancellation), merge = try mailPatchMetadataPath("rebase-merge",cancellation:cancellation)
        if manager.fileExists(atPath: apply.path) || manager.fileExists(atPath: merge.path) { return .rebase }
        return .none
    }
    /// Source ImportPatchDlg.cpp:379–420 asks repeatedly until am recovery ends.
    /// Capture its current incarnation/item before asking, then revalidate before
    /// every explicit recovery command. This is a race guard, not a Git lock.
    public func mailPatchRecoverySession(cancellation: OperationCancellation? = nil) throws -> MailPatchRecoverySession? {
        try cancellation?.check()
        switch try mailPatchSession(cancellation:cancellation) {
        case .none:return nil
        case .rebase:throw MailPatchFailure.rebase
        case .applying:break
        }
        let path=try mailPatchMetadataPath("rebase-apply",cancellation:cancellation)
        let descriptor=open(path.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor>=0 else{try cancellation?.check();throw MailPatchFailure.changedSession}
        defer{close(descriptor)}
        func directoryIdentity()throws->MailPatchDirectoryIdentity {
            var value=stat();guard fstat(descriptor,&value)==0,value.st_mode & S_IFMT == S_IFDIR else{throw MailPatchFailure.changedSession}
            return MailPatchDirectoryIdentity(value)
        }
        func fields()throws->[String:Data] {
            var result:[String:Data]=[:]
            for name in ["applying","next","last","orig-head","abort-safety","head-name","onto","original-commit"] {
                try cancellation?.check()
                do{result[name]=try HistoryFileCache.readFile(name,directory:descriptor,limit:65536,noFollow:true,cancellation:cancellation)}
                catch let error as POSIXError where error.code == .ENOENT {continue}
            }
            guard result["applying"] != nil,result["next"] != nil,result["last"] != nil else{throw MailPatchFailure.changedSession}
            return result
        }
        let identity=try directoryIdentity()
        let head=try run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:cancellation).stdout
        let contents=try fields()
        let finalHead=try run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:cancellation).stdout
        var currentPath=stat()
        guard try fields()==contents,try directoryIdentity()==identity,head==finalHead,
              lstat(path.path,&currentPath)==0,currentPath.st_mode & S_IFMT == S_IFDIR,MailPatchDirectoryIdentity(currentPath)==identity,
              let next=contents["next"].flatMap({Int(String(decoding:$0,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines))}),
              let last=contents["last"].flatMap({Int(String(decoding:$0,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines))}),next>0,last>=next else{throw MailPatchFailure.changedSession}
        try cancellation?.check()
        return MailPatchRecoverySession(metadataPath:path.path,currentItem:next,totalItems:last,directory:identity,fields:contents,head:head)
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
    public func recoverMailPatch(_ action: MailPatchRecovery, reviewed: MailPatchRecoverySession? = nil, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try cancellation?.check()
        guard let current=try mailPatchRecoverySession(cancellation:cancellation) else{throw reviewed == nil ? MailPatchFailure.noSession:MailPatchFailure.changedSession}
        if let reviewed,reviewed != current {throw MailPatchFailure.changedSession}
        try cancellation?.check()
        return try run(["am", "--" + action.rawValue], cancellation: cancellation, onOutput: onOutput).text
    }
}
