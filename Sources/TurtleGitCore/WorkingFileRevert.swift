import Foundation
import Darwin

public struct WorkingFileRevertResult: Sendable {
    public let revertedPaths: [String]
    public let trashedFiles: [URL]
}

public struct WorkingFileRevertFailure: LocalizedError, Sendable {
    public let gitError: String
    public let trashedFiles: [URL]
    public var errorDescription: String? {
        gitError + (trashedFiles.isEmpty ? "" : "\n\nWorking files moved to Trash remain recoverable:\n" + trashedFiles.map(\.path).joined(separator: "\n"))
    }
}

extension GitRepository {
    /// Revert selected status rows, preserving added working files and recycling
    /// replaced contents. The index is held privately until all Git steps pass.
    public func revertWorkingFiles(_ selected: [StatusEntry], amend: Bool = false, amendDiffToLastCommit: Bool = false) throws -> WorkingFileRevertResult {
        guard !selected.isEmpty, Set(selected.map(\.path)).count == selected.count,
              selected.allSatisfy({ ![FileState.untracked, .ignored].contains($0.state) }) else {
            throw GitFailure(arguments: ["revert"], code: 1, message: "Select versioned files to revert.")
        }
        let current = Dictionary(try commitDialogStatus(amendToParent: amend && !amendDiffToLastCommit).map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        guard selected.allSatisfy({ current[$0.path] == $0 }) else {
            throw GitFailure(arguments: ["revert"], code: 1, message: "The selected files changed. Refresh before reverting.")
        }
        let source: String
        if amend { source = try commitComparisonBase(amendToParent: true) }
        else if let head = try? run(["rev-parse", "--verify", "HEAD^{commit}"]).text { source = head.trimmingCharacters(in: .newlines) }
        else { source = try run(["mktree"]).text.trimmingCharacters(in: .newlines) }
        let manager = FileManager.default
        var trash: [URL] = [], submoduleRenames: [(String, String)] = []
        var restore = Set<String>(), unstage = Set<String>(), recycle: [URL] = []
        // Validate every destination before locking the index or moving anything.
        for entry in selected {
            let location = try restoreLocation(entry.path)
            let attributes = try? manager.attributesOfItem(atPath: location.path)
            let directory = attributes?[.type] as? FileAttributeType == .typeDirectory
            let gitlink = try run(["ls-files", "--stage", "--", entry.path]).text.split(separator: "\n").contains { $0.hasPrefix("160000 ") }
            if directory && !gitlink { throw WorkingFileRestoreFailure.unsupported }
            if let old = entry.originalPath, entry.index == "R" || entry.worktree == "R" {
                let oldLocation = try restoreLocation(old)
                if let oldAttributes = try? manager.attributesOfItem(atPath: oldLocation.path), oldAttributes[.type] as? FileAttributeType == .typeDirectory {
                    throw GitFailure(arguments: ["revert"], code: 1, message: "Cannot restore the old name because a directory already exists: " + old)
                }
                if let oldAttributes = try? manager.attributesOfItem(atPath: oldLocation.path) {
                    guard !directory else { throw WorkingFileRestoreFailure.unsupported }
                    let type = oldAttributes[.type] as? FileAttributeType
                    guard type == .typeRegular || type == .typeSymbolicLink else { throw WorkingFileRestoreFailure.unsupported }
                    let oldInode = oldAttributes[.systemFileNumber] as? NSNumber, inode = attributes?[.systemFileNumber] as? NSNumber
                    let oldDevice = oldAttributes[.systemNumber] as? NSNumber, device = attributes?[.systemNumber] as? NSNumber
                    let sameFile = oldInode != nil && inode != nil && oldDevice != nil && device != nil && oldInode == inode && oldDevice == device
                    if !sameFile { recycle.append(oldLocation) }
                }
                if directory { submoduleRenames.append((entry.path, old)); restore.insert(old) }
                else { restore.formUnion([entry.path, old]) }
            } else if entry.state == .added { unstage.insert(entry.path) }
            else { restore.insert(entry.path) }
            if entry.state != .added, !directory, attributes != nil {
                guard [.typeRegular, .typeSymbolicLink].contains(attributes?[.type] as? FileAttributeType) else { throw WorkingFileRestoreFailure.unsupported }
                recycle.append(location)
            }
        }
        var indexBytes = try run(["rev-parse", "--git-path", "index"]).stdout
        if indexBytes.last == 10 { indexBytes.removeLast() }
        let indexPath = String(decoding: indexBytes, as: UTF8.self)
        let index = indexPath.hasPrefix("/") ? URL(fileURLWithPath: indexPath) : root.appendingPathComponent(indexPath)
        let lock = URL(fileURLWithPath: index.path + ".lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw GitFailure(arguments: ["revert"], code: 1, message: "Could not lock the Git index: " + String(cString: strerror(errno))) }
        defer { try? manager.removeItem(at: lock) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: Data(contentsOf: index)); try handle.close() }
        catch { try? handle.close(); throw error }
        let environment = ["GIT_INDEX_FILE": lock.path]
        do {
            if !unstage.isEmpty { _ = try run(["rm", "-f", "--cached", "--ignore-unmatch", "--"] + unstage.sorted(), environmentOverrides: environment) }
            for location in Set(recycle).sorted(by: { $0.path < $1.path }) {
                var trashed: NSURL?
                try manager.trashItem(at: location, resultingItemURL: &trashed)
                if let trashed { trash.append(trashed as URL) }
            }
            for (new, old) in submoduleRenames {
                _ = try run(["mv", "-f", "--", new, old], environmentOverrides: environment)
            }
            if !restore.isEmpty { _ = try run(["restore", "--source=" + source, "--staged", "--worktree", "--"] + restore.sorted(), environmentOverrides: environment) }
            let permissions = try manager.attributesOfItem(atPath: index.path)[.posixPermissions]
            if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: lock.path) }
            guard Darwin.rename(lock.path, index.path) == 0 else { throw GitFailure(arguments: ["revert"], code: 1, message: String(cString: strerror(errno))) }
        } catch {
            throw WorkingFileRevertFailure(gitError: error.localizedDescription, trashedFiles: trash)
        }
        return WorkingFileRevertResult(revertedPaths: selected.map(\.path), trashedFiles: trash)
    }
}
