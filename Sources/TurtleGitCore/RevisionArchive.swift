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
        case .destination: return "Choose a ZIP file outside Git metadata in an existing folder."
        }
    }
}

extension GitRepository {
    /// Export committed contents using Git's ZIP writer, including its archive
    /// attributes, executable modes and symlink handling. The native caller owns
    /// destination access and overwrite confirmation. Failure or cancellation
    /// leaves an existing destination intact; no index or working files change.
    @discardableResult public func archiveRevision(_ revision: String = "HEAD", directory: String = "", to destination: URL, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
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
            guard try !isBare(), RepositoryAccessLease.pathIsContained(folder, by: root),
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
        let temporary = parent.appendingPathComponent(".TurtleGitArchive-" + UUID().uuidString + ".zip")
        defer { try? manager.removeItem(at: temporary) }
        let result = try run(arguments + ["archive", "--format=zip", "--output=" + temporary.path, "--verbose", "--end-of-options", object], cancellation: cancellation, onOutput: onOutput)
        try cancellation?.check()
        guard Darwin.rename(temporary.path, target.path) == 0 else {
            throw GitFailure(arguments: ["archive", revision], code: 1, message: String(cString: strerror(errno)))
        }
        return result.text
    }
}
