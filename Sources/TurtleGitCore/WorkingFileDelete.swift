import Foundation
import Darwin

extension StatusEntry {
    public var canDeleteFromStatusList: Bool { state == .untracked || state == .ignored || worktree == "D" }
}

public struct WorkingFileDeleteResult: Sendable {
    public let removedPaths: [String]
    public let trashedFiles: [URL]
    public let removedIndexPaths: [String]
}

public struct WorkingFileDeleteFailure: LocalizedError, Sendable {
    public let message: String
    public let removedPaths: [String]
    public let trashedFiles: [URL]
    public var errorDescription: String? {
        message + (trashedFiles.isEmpty ? "" : "\n\nFiles moved to Trash remain recoverable:\n" + trashedFiles.map(\.path).joined(separator: "\n"))
            + (removedPaths.isEmpty || !trashedFiles.isEmpty ? "" : "\n\nCompleted deletions:\n" + removedPaths.joined(separator: "\n"))
    }
}

extension GitRepository {
    /// Delete status-list selections, removing their exact index entries only
    /// after file operations succeed. Trash failure never falls back to unlink.
    public func deleteWorkingFiles(_ selected: [StatusEntry], permanently: Bool = false, cancellation: OperationCancellation? = nil) throws -> WorkingFileDeleteResult {
        try cancellation?.check()
        guard !selected.isEmpty, Set(selected.map(\.path)).count == selected.count,
              selected.contains(where: \.canDeleteFromStatusList) else {
            throw GitFailure(arguments: ["delete"], code: 1, message: "Select unversioned, ignored or missing paths to delete.")
        }
        let current = Dictionary(try status(refreshIndex: false).map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        guard selected.allSatisfy({ current[$0.path] == $0 }) else {
            throw GitFailure(arguments: ["delete"], code: 1, message: "The selected files changed. Refresh before deleting.")
        }
        let manager = FileManager.default
        let paths = selected.map(\.path)
        let locations = try paths.map { try restoreLocation($0) }
        var existing: [URL] = []
        for location in locations {
            try cancellation?.check()
            if let attributes = try? manager.attributesOfItem(atPath: location.path) {
                guard [.typeRegular, .typeDirectory, .typeSymbolicLink].contains(attributes[.type] as? FileAttributeType) else { throw GitFailure(arguments: ["delete"], code: 1, message: "Only regular files, directories and symbolic links can be deleted from this list.") }
                existing.append(location)
            } else if manager.fileExists(atPath: location.path) {
                throw GitFailure(arguments: ["delete"], code: 1, message: "Could not inspect " + location.path)
            }
        }
        var indexBytes = try run(["rev-parse", "--git-path", "index"]).stdout
        if indexBytes.last == 10 { indexBytes.removeLast() }
        let indexPath = String(decoding: indexBytes, as: UTF8.self)
        let index = indexPath.hasPrefix("/") ? URL(fileURLWithPath: indexPath) : root.appendingPathComponent(indexPath)
        let lock = URL(fileURLWithPath: index.path + ".lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw GitFailure(arguments: ["delete"], code: 1, message: "Could not lock the Git index: " + String(cString: strerror(errno))) }
        var ownsLock = true
        defer { if ownsLock { try? manager.removeItem(at: lock) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var indexed = Set<String>()
        for offset in stride(from: 0, to: paths.count, by: 64) {
            let batch = Array(paths[offset..<min(offset + 64, paths.count)])
            for record in try run(["ls-files", "--stage", "-z", "--"] + batch).stdout.split(separator: 0) {
                guard let tab = record.firstIndex(of: 9) else { continue }
                indexed.insert(String(decoding: record[record.index(after: tab)...], as: UTF8.self))
            }
        }
        let removing = Set(paths).intersection(indexed).sorted()
        let directory = manager.temporaryDirectory.appendingPathComponent("TurtleGitDelete-" + UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let privateIndex = directory.appendingPathComponent("index")
        if !removing.isEmpty {
            try manager.copyItem(at: index, to: privateIndex)
            for offset in stride(from: 0, to: removing.count, by: 64) {
                _ = try run(["update-index", "--force-remove", "--"] + Array(removing[offset..<min(offset + 64, removing.count)]), environmentOverrides: ["GIT_INDEX_FILE": privateIndex.path])
            }
        }
        var removed: [String] = [], trash: [URL] = []
        do {
            for location in existing {
                try cancellation?.check()
                if permanently { try manager.removeItem(at: location) }
                else {
                    var trashed: NSURL?
                    try manager.trashItem(at: location, resultingItemURL: &trashed)
                    if let trashed { trash.append(trashed as URL) }
                }
                removed.append(String(location.path.dropFirst(root.path.count + 1)))
            }
            try cancellation?.check()
            if !removing.isEmpty {
                try handle.write(contentsOf: Data(contentsOf: privateIndex)); try handle.close()
                if let permissions = (try? manager.attributesOfItem(atPath: index.path))?[.posixPermissions] { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: lock.path) }
                guard Darwin.rename(lock.path, index.path) == 0 else { throw GitFailure(arguments: ["delete"], code: 1, message: "Could not replace the Git index: " + String(cString: strerror(errno))) }
                ownsLock = false
            }
        } catch { throw WorkingFileDeleteFailure(message: error.localizedDescription, removedPaths: removed, trashedFiles: trash) }
        return WorkingFileDeleteResult(removedPaths: removed, trashedFiles: trash, removedIndexPaths: removing)
    }
}
