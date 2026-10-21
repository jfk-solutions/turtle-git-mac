// Native adaptation of TortoiseGit AppUtils.cpp CAppUtils::Export.
// TortoiseGit is licensed under GPL-2.0-or-later; see NOTICE.
import Foundation
import Darwin

public enum RevisionArchiveFailure: LocalizedError {
    case revision, directory, destination
    public var errorDescription: String? {
        switch self {
        case .revision: return "Choose a revision containing a commit or tree."
        case .directory: return "Choose an existing repository directory, or export the whole project."
        case .destination: return "Choose an archive file outside Git metadata in an existing folder."
        }
    }
}

/// Actual archive-process settlement, before the atomic destination replacement.
public struct RevisionArchiveCommandCompletion:Sendable {
    public let success:Bool
    public let cancelled:Bool
    public let exitCode:Int32?
    public let elapsed:TimeInterval
    public let finished:Date
    public init(success:Bool,cancelled:Bool,exitCode:Int32?,elapsed:TimeInterval,finished:Date=Date()){
        self.success=success;self.cancelled=cancelled;self.exitCode=exitCode;self.elapsed=elapsed;self.finished=finished
    }
}

extension GitRepository {
    /// Export committed contents using Git's filename-selected writer, including its archive
    /// attributes, executable modes and symlink handling. The native caller owns
    /// destination access and overwrite confirmation. Failure or cancellation
    /// leaves an existing destination intact; no index or working files change.
    @discardableResult public func archiveRevision(_ revision: String = "HEAD", directory: String = "", to destination: URL, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil,
        onCommand:(@Sendable(GitCommandInvocation)->Void)?=nil,onCommandFinished:(@Sendable(RevisionArchiveCommandCompletion)->Void)?=nil,beforeFinalization:(@Sendable()throws->Void)?=nil) throws -> String {
        try cancellation?.check()
        guard !revision.isEmpty, !revision.utf8.contains(0) else { throw RevisionArchiveFailure.revision }
        let object: String
        do {
            object = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            _ = try run(["rev-parse", "--verify", "--end-of-options", object + "^{tree}"], cancellation: cancellation)
        } catch {
            if cancellation?.isCancelled == true { throw error }
            throw RevisionArchiveFailure.revision
        }
        guard RepositoryBrowserListing.validPath(directory, allowRoot: true),
              !directory.split(separator: "/").contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw RevisionArchiveFailure.directory }
        var arguments: [String] = []
        if !directory.isEmpty {
            let folder = root.appendingPathComponent(directory).resolvingSymlinksInPath()
            guard try !isBare(cancellation:cancellation), RepositoryAccessLease.pathIsContained(folder, by: root),
                  !folder.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }),
                  try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw RevisionArchiveFailure.directory }
            // Upstream runs archive from the selected directory. Git strips that
            // directory prefix while retaining commit-based export-subst values.
            arguments = ["-C", folder.path]
        }
        let manager = FileManager.default
        let target = destination.standardizedFileURL
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        guard target.isFileURL, !target.lastPathComponent.isEmpty,
              try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              !target.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }),
              !parent.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw RevisionArchiveFailure.destination }
        // Bare repositories and linked worktrees need their actual metadata
        // paths checked as well as ordinary .git directories.
        for option in ["--absolute-git-dir", "--git-common-dir"] {
            let path = try run(["rev-parse", option], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            let metadata = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).resolvingSymlinksInPath()
            guard !RepositoryAccessLease.pathIsContained(parent, by: metadata) else { throw RevisionArchiveFailure.destination }
        }
        if let type = try? manager.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType {
            guard type == .typeRegular else { throw RevisionArchiveFailure.destination }
        }
        // Ask Foundation for a private workspace on the target's volume rather
        // than assuming a file-scoped Save grant authorizes arbitrary siblings.
        // Execution with a signed sandbox grant remains a deployment check.
        let replacement = try manager.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:target,create:true)
        defer { try? manager.removeItem(at:replacement) }
        var parentInfo=stat(),replacementInfo=stat()
        guard stat(parent.path,&parentInfo)==0,lstat(replacement.path,&replacementInfo)==0,
              replacementInfo.st_mode & S_IFMT == S_IFDIR,parentInfo.st_dev==replacementInfo.st_dev else {
            throw RevisionArchiveFailure.destination
        }
        // Preserve the complete basename: Git recognizes configured multi-part
        // suffixes as well as zip/tar/tar.gz. Unknown or absent suffixes retain
        // Git's default TAR behavior; defaulting to .zip belongs to the form.
        let temporary=replacement.appendingPathComponent(target.lastPathComponent,isDirectory:false)
        let command=arguments+["archive","--output="+temporary.path,"--verbose","--end-of-options",object]
        try cancellation?.check()
        onCommand?(commandInvocation(command))
        let started=ProcessInfo.processInfo.systemUptime,result:GitResult
        do{
            result=try run(command,cancellation:cancellation,onOutput:onOutput)
            onCommandFinished?(.init(success:true,cancelled:false,exitCode:result.exitCode,elapsed:ProcessInfo.processInfo.systemUptime-started))
        }catch{
            let cancelled=cancellation?.isCancelled==true || error is OperationCancellationFailure || error is GitCommandCancellationFailure
            let code=(error as? GitCommandCancellationFailure)?.result.exitCode ?? (error as? GitFailure)?.code
            onCommandFinished?(.init(success:false,cancelled:cancelled,exitCode:code,elapsed:ProcessInfo.processInfo.systemUptime-started))
            throw error
        }
        try beforeFinalization?()
        try cancellation?.check()
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            throw GitFailure(arguments: ["archive", revision], code: 1, message: String(cString: strerror(errno)))
        }
        return result.text
    }
}
