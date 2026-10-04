import Foundation
import Darwin

public enum WorkingFileRestoreFailure: LocalizedError {
    case selection, location, changed, unsupported
    public var errorDescription: String? {
        switch self {
        case .selection: return "Select existing versioned files to mark for restoration."
        case .location: return "The saved copy belongs to another working tree or its destination is outside this working tree."
        case .changed: return "The file changed while its restoration copy was being created. Try again."
        case .unsupported: return "Only regular files and symbolic links can be saved or restored."
        }
    }
}

/// An immutable, disk-backed copy owned by a Commit dialog. It preserves binary
/// contents and symlink targets without reading the link's destination.
public final class WorkingFileRestoreCopy: @unchecked Sendable {
    public let path: String
    fileprivate let root: URL
    fileprivate let directory: URL
    fileprivate let permissions: Int
    fileprivate let linkTarget: String?
    fileprivate init(path: String, root: URL, directory: URL, permissions: Int, linkTarget: String?) {
        self.path = path; self.root = root; self.directory = directory
        self.permissions = permissions; self.linkTarget = linkTarget
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension GitRepository {
    public func captureWorkingFileRestoreCopy(path: String) throws -> WorkingFileRestoreCopy {
        guard try trackedPaths().contains(path) else { throw WorkingFileRestoreFailure.selection }
        let location = try restoreLocation(path)
        let manager = FileManager.default
        let before = try manager.attributesOfItem(atPath: location.path)
        let type = before[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { throw WorkingFileRestoreFailure.unsupported }
        let directory = manager.temporaryDirectory.appendingPathComponent("TurtleGitRestore-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let target: String?
            if type == .typeSymbolicLink { target = try manager.destinationOfSymbolicLink(atPath: location.path) }
            else { target = nil; try manager.copyItem(at: location, to: directory.appendingPathComponent("contents")) }
            let after = try manager.attributesOfItem(atPath: location.path)
            for key in [FileAttributeKey.type, .systemFileNumber, .size, .modificationDate, .posixPermissions] {
                guard (before[key] as? NSObject) == (after[key] as? NSObject) else { throw WorkingFileRestoreFailure.changed }
            }
            if let target, target != (try manager.destinationOfSymbolicLink(atPath: location.path)) { throw WorkingFileRestoreFailure.changed }
            return WorkingFileRestoreCopy(path: path, root: root, directory: directory,
                permissions: (before[.posixPermissions] as? NSNumber)?.intValue ?? 0o644, linkTarget: target)
        } catch { try? manager.removeItem(at: directory); throw error }
    }
    public func restoreWorkingFile(_ copy: WorkingFileRestoreCopy) throws {
        guard copy.root == root else { throw WorkingFileRestoreFailure.location }
        let location = try restoreLocation(copy.path), manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: location.path) {
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeSymbolicLink else { throw WorkingFileRestoreFailure.unsupported }
        }
        let temporary = location.deletingLastPathComponent().appendingPathComponent(".TurtleGitRestore-" + UUID().uuidString)
        defer { try? manager.removeItem(at: temporary) }
        if let target = copy.linkTarget { try manager.createSymbolicLink(atPath: temporary.path, withDestinationPath: target) }
        else {
            try manager.copyItem(at: copy.directory.appendingPathComponent("contents"), to: temporary)
            try manager.setAttributes([.posixPermissions: copy.permissions, .modificationDate: Date()], ofItemAtPath: temporary.path)
        }
        guard Darwin.rename(temporary.path, location.path) == 0 else {
            throw GitFailure(arguments: ["restore working copy"], code: 1, message: String(cString: strerror(errno)))
        }
    }
    private func restoreLocation(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.components(separatedBy: "/").contains(where: { $0 == ".." || $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw WorkingFileRestoreFailure.location }
        let location = root.appendingPathComponent(path).standardizedFileURL
        guard location.path.hasPrefix(root.path + "/"), RepositoryAccessLease.pathIsContained(location.deletingLastPathComponent(), by: root) else { throw WorkingFileRestoreFailure.location }
        return location
    }
}
