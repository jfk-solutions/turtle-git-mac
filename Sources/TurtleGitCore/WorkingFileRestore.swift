import Foundation
import Darwin

public enum WorkingFileRestoreFailure: LocalizedError {
    case selection, location, changed, unsupported
    public var errorDescription: String? {
        switch self {
        case .selection: return "Select existing files to mark for restoration."
        case .location: return "The saved copy belongs to another working tree or its destination is outside this working tree."
        case .changed: return "The file changed while its restoration copy was being created. Try again."
        case .unsupported: return "Only regular files and symbolic links can be saved or restored."
        }
    }
}

/// An immutable, disk-backed copy owned by a status-list dialog. It preserves binary
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
    public func captureWorkingFileRestoreCopy(path: String, allowUnversioned: Bool = false) throws -> WorkingFileRestoreCopy {
        if !allowUnversioned { guard try trackedPaths().contains(path) else { throw WorkingFileRestoreFailure.selection } }
        let location = try restoreLocation(path)
        if allowUnversioned { try validateRestoreOwner(location) }
        let manager = FileManager.default
        let before = try manager.attributesOfItem(atPath: location.path)
        let type = before[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { throw WorkingFileRestoreFailure.unsupported }
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitRestore-" + UUID().uuidString)
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
        try validateRestoreOwner(location)
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
    private func validateRestoreOwner(_ location: URL) throws {
        var owner = try run(["-C", location.deletingLastPathComponent().path, "rev-parse", "--show-toplevel"]).stdout
        if owner.last == 10 { owner.removeLast() }
        guard URL(fileURLWithPath: String(decoding: owner, as: UTF8.self)).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { throw WorkingFileRestoreFailure.location }
    }
    func restoreLocation(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.components(separatedBy: "/").contains(where: { $0 == ".." || $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw WorkingFileRestoreFailure.location }
        let location = root.appendingPathComponent(path).standardizedFileURL
        guard location.path.hasPrefix(root.path + "/"), RepositoryAccessLease.pathIsContained(location.deletingLastPathComponent(), by: root) else { throw WorkingFileRestoreFailure.location }
        return location
    }
}

public enum FileRevealDestination: Equatable, Sendable {
    case select(URL)
    case openDirectory(URL)
}

extension GitRepository {
    /// Historical Explore selects the current disk item, or opens the nearest
    /// existing parent when that item has since disappeared. No checkout occurs.
    public func fileRevealDestination(path: String) throws -> FileRevealDestination {
        guard try !isBare() else { throw RevisionComparisonFailure.selection }
        let location = try restoreLocation(path)
        let manager = FileManager.default
        if (try? manager.attributesOfItem(atPath: location.path)) != nil { return .select(location) }
        var parent = location.deletingLastPathComponent()
        while parent.path == root.path || parent.path.hasPrefix(root.path + "/") {
            if (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .openDirectory(parent) }
            if parent == root { break }
            parent.deleteLastPathComponent()
        }
        throw WorkingFileRestoreFailure.location
    }
}
