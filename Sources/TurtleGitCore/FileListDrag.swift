// SPDX-License-Identifier: GPL-2.0-or-later
// Adapts GitDataObject.cpp and GitStatusListCtrl::OnBeginDrag, TortoiseGit.
import Foundation
import Darwin

/// One occurrence in the displayed selection. Equal paths and equal leaf names
/// remain separate items; the receiving application chooses their final names.
public struct FileListDragItem: Identifiable, Sendable {
    public let id: Int
    public let path: String
    public let name: String
}

/// A gesture captures an already-resolved revision, never a mutable reference.
/// This value carries no filesystem authority; native providers retain the
/// originating repository's access lease independently of their source window.
public struct FileListDragPlan: Sendable {
    public let root: URL
    public let revision: ComparisonRevision
    public let backend: GitLibGit2Configuration
    public let items: [FileListDragItem]

    public init(root: URL, revision: ComparisonRevision, files: [CommitFile], backend: GitLibGit2Configuration) throws {
        guard root.isFileURL else { throw RevisionComparisonFailure.selection }
        switch revision {
        case .revision(let hash):
            guard [40, 64].contains(hash.utf8.count), hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw RepositoryBrowserFailure.revision
            }
        case .workingTree: break
        case .emptyTree: throw RepositoryBrowserFailure.revision
        }
        var items: [FileListDragItem] = []
        for (index, file) in files.enumerated() {
            // GitDataObject offers names as text, but no file contents for
            // missing/deleted rows or directories (including gitlinks).
            guard !file.isSubmodule, file.action.first != "D", file.action.first != "!",
                  file.newMode != 0o040000, file.newMode != 0o160000 else { continue }
            guard RepositoryBrowserListing.validPath(file.path, allowRoot: false),
                  !file.path.split(separator: "/").contains(where: { String($0).caseInsensitiveCompare(".git") == .orderedSame }),
                  let name = file.path.split(separator: "/").last else { throw RevisionComparisonFailure.selection }
            // The source's default stripLength=-1 uses the leaf name, not a
            // directory hierarchy and not the old side of a rename/copy.
            items.append(FileListDragItem(id: index, path: file.path, name: String(name)))
        }
        self.root = root.standardizedFileURL
        self.revision = revision
        self.backend = backend
        self.items = items
    }

    /// AppKit needs a synchronous NSURL writer at gesture time. Validate the
    /// actual parent boundary and leaf kind here as well as during deferred load.
    /// The leaf may itself be a symlink; its target is never exported instead.
    public func validatedWorkingURL(itemAt index: Int) throws -> URL {
        guard case .workingTree = revision, items.indices.contains(index) else { throw RevisionComparisonFailure.selection }
        let location = root.appendingPathComponent(items[index].path).standardizedFileURL
        guard location.path.hasPrefix(root.path + "/"),
              RepositoryAccessLease.pathIsContained(location.deletingLastPathComponent(), by: root) else {
            throw WorkingFileRestoreFailure.location
        }
        var info = stat()
        guard lstat(location.path, &info) == 0 else { throw RevisionComparisonFailure.selection }
        let kind = info.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK) else { throw RevisionComparisonFailure.selection }
        return location
    }
}

public enum FileListDragMaterialization: Sendable {
    /// A live working-tree drag offers its actual URL, never an index copy.
    case workingURL(URL)
    /// A historical drag owns a separate private leaf copy for this occurrence.
    /// Providers retain it until delivery and call discard on every exit path.
    case historical(RepositoryBrowserExport)
}

extension GitRepository {
    public func materializeFileListDrag(_ plan: FileListDragPlan, itemAt index: Int, cancellation: OperationCancellation? = nil) throws -> FileListDragMaterialization {
        try cancellation?.check()
        guard root.path.utf8.elementsEqual(plan.root.path.utf8), plan.items.indices.contains(index) else {
            throw RevisionComparisonFailure.selection
        }
        let item = plan.items[index]
        switch plan.revision {
        case .workingTree:
            let location = try plan.validatedWorkingURL(itemAt: index)
            try cancellation?.check()
            return .workingURL(location)
        case .revision(let hash):
            // GetOneFile applies the captured backend's checkout filters. Raw
            // comparison blobs and the current working tree are not substitutes.
            let content = try materializedHistoricalFile(revision: hash, path: item.path, cancellation: cancellation, backend: plan.backend)
            try cancellation?.check()
            guard let mode = content.mode, ["100644", "100755", "120000"].contains(mode) else {
                throw RevisionComparisonFailure.selection
            }
            let manager = FileManager.default
            let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitFileDrag-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                let destination = directory.appendingPathComponent(item.name)
                // Historical symlinks are their link text, matching GetOneFile
                // and the existing Repository Browser materialization policy.
                try content.bytes.write(to: destination, options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: mode == "100755" ? 0o755 : 0o644], ofItemAtPath: destination.path)
                try cancellation?.check()
                return .historical(RepositoryBrowserExport(directory: directory, item: destination, fileCount: 1))
            } catch {
                try? manager.removeItem(at: directory)
                throw error
            }
        case .emptyTree: throw RepositoryBrowserFailure.revision
        }
    }
}
