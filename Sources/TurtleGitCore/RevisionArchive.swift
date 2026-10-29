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
        return try writeRevisionArchive(object:object,revisionCaption:revision,arguments:arguments,pathspec:nil,to:destination,
            protectDestination:false,cancellation:cancellation,onOutput:onOutput,onCommand:onCommand,
            onCommandFinished:onCommandFinished,beforeFinalization:beforeFinalization)
    }

    /// Export a captured historical Browser directory without consulting its
    /// working-tree spelling. Full original Git-relative member prefixes are
    /// retained; the commit itself remains the archive tree-ish so export-subst
    /// and committed export-ignore attributes retain their ordinary Git meaning.
    @discardableResult public func archiveRepositoryBrowser(_ snapshot:RepositoryBrowserSnapshot,directory:String?=nil,to destination:URL,
        cancellation:OperationCancellation?=nil,onOutput:(@Sendable(GitOutputChunk)->Void)?=nil,
        onCommand:(@Sendable(GitCommandInvocation)->Void)?=nil,onCommandFinished:(@Sendable(RevisionArchiveCommandCompletion)->Void)?=nil,
        beforeFinalization:(@Sendable()throws->Void)?=nil)throws->String {
        try cancellation?.check()
        guard snapshot.root==root,let object=snapshot.objectID,let tree=snapshot.treeID,
              [40,64].contains(object.utf8.count),object.utf8.allSatisfy({$0>=48 && $0<=57 || $0>=97 && $0<=102}),
              [40,64].contains(tree.utf8.count),tree.utf8.allSatisfy({$0>=48 && $0<=57 || $0>=97 && $0<=102}) else {throw RevisionArchiveFailure.revision}
        let scope=try RepositoryBrowserGitPath(key:directory ?? snapshot.directory)
        guard scope.rawData.isEmpty || RepositoryBrowserPathIdentity.equal(scope.key,snapshot.directory) ||
              snapshot.entries.contains(where:{$0.kind == .directory && RepositoryBrowserPathIdentity.equal($0.path,scope.key)}),
              !scope.rawData.split(separator:47).contains(where:{component in
                  component.map{($0>=65 && $0<=90) ? $0+32:$0} == Array(".git".utf8)
              }) else {throw RevisionArchiveFailure.directory}
        let actualTree=try run(["rev-parse","--verify","--end-of-options",object+"^{tree}"],cancellation:cancellation).text.trimmingCharacters(in:.newlines)
        guard GitReferenceName.equal(actualTree,tree) else {throw RevisionArchiveFailure.revision}
        if !scope.rawData.isEmpty {
            guard let record=try historicalTreeRecord(revision:object,path:scope.key,cancellation:cancellation),record.mode == "040000" else {throw RevisionArchiveFailure.directory}
        }
        return try writeRevisionArchive(object:object,revisionCaption:object,arguments:[],pathspec:scope.rawData.isEmpty ? nil:scope,
            to:destination,protectDestination:true,cancellation:cancellation,onOutput:onOutput,onCommand:onCommand,
            onCommandFinished:onCommandFinished,beforeFinalization:beforeFinalization)
    }

    private func writeRevisionArchive(object:String,revisionCaption:String,arguments:[String],pathspec:RepositoryBrowserGitPath?,to destination:URL,
        protectDestination:Bool,cancellation:OperationCancellation?,onOutput:(@Sendable(GitOutputChunk)->Void)?,
        onCommand:(@Sendable(GitCommandInvocation)->Void)?,onCommandFinished:(@Sendable(RevisionArchiveCommandCompletion)->Void)?,
        beforeFinalization:(@Sendable()throws->Void)?)throws->String {
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
        let destinationReceipt:MergeToolOutputTarget?
        if protectDestination {destinationReceipt=try MergeToolOutputTarget(capturing:target)} else {destinationReceipt=nil}
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
        var command=arguments+["archive","--output="+temporary.path,"--verbose","--end-of-options",object]
        var argumentBytes:[Int:Data]=[:]
        if let pathspec {
            // archive consumes positional pathspecs after its tree-ish. A
            // second '--' here is itself a filename, not another delimiter.
            // The global literal-pathspec policy and preceding end-of-options
            // already protect the pinned object and original path bytes.
            command.append(pathspec.display)
            argumentBytes[command.count-1]=pathspec.rawData
        }
        try cancellation?.check()
        onCommand?(commandInvocation(command))
        let started=ProcessInfo.processInfo.systemUptime,result:GitResult
        do{
            result=try run(command,argumentBytes:argumentBytes,cancellation:cancellation,onOutput:onOutput)
            onCommandFinished?(.init(success:true,cancelled:false,exitCode:result.exitCode,elapsed:ProcessInfo.processInfo.systemUptime-started))
        }catch{
            let cancelled=cancellation?.isCancelled==true || error is OperationCancellationFailure || error is GitCommandCancellationFailure
            let code=(error as? GitCommandCancellationFailure)?.result.exitCode ?? (error as? GitFailure)?.code
            onCommandFinished?(.init(success:false,cancelled:cancelled,exitCode:code,elapsed:ProcessInfo.processInfo.systemUptime-started))
            throw error
        }
        try beforeFinalization?()
        try cancellation?.check()
        try destinationReceipt?.validate()
        if protectDestination {
            var currentParent=stat()
            guard GitReferenceName.equal(target.deletingLastPathComponent().resolvingSymlinksInPath().path,parent.path),
                  stat(parent.path,&currentParent)==0,currentParent.st_dev==parentInfo.st_dev,currentParent.st_ino==parentInfo.st_ino else {throw RevisionArchiveFailure.destination}
        }
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            throw GitFailure(arguments: ["archive", revisionCaption], code: 1, message: String(cString: strerror(errno)))
        }
        return result.text
    }
}
