import Foundation
import Darwin

public struct WorkingFileRevertResult: Sendable {
    public let revertedPaths: [String]
    public let trashedFiles: [URL]
    /// Exact superproject tree used by this operation, for post-Revert comparison.
    public let comparisonRevision: String
    /// Submodule names after restoring any staged rename.
    public let submodulePaths: [String]
}

public struct WorkingFileRevertFailure: LocalizedError, Sendable {
    public let gitError: String
    public let wasCancelled: Bool
    public let trashedFiles: [URL]
    public var errorDescription: String? {
        gitError + (trashedFiles.isEmpty ? "" : "\n\nWorking files moved to Trash remain recoverable:\n" + trashedFiles.map(\.path).joined(separator: "\n"))
    }
}

extension GitRepository {
    /// A retry reads current selected-path status rather than reusing stale rows.
    /// Previously completed clean paths are included only while still tracked.
    public func workingFileRevertSelection(_ selected: [StatusEntry], amend: Bool = false, againstHead: Bool = false, cancellation: OperationCancellation? = nil) throws -> [StatusEntry] {
        try cancellation?.check()
        let requested = GitPathSet(selected.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
        _ = try RemovalRequest(paths: Array(requested), keepLocal: true)
        let current = try commitDialogStatus(amendToParent: amend && !againstHead, cancellation: cancellation)
        var result = current.filter { ![FileState.untracked, .ignored].contains($0.state) && (requested.contains($0.path) || $0.originalPath.map { requested.contains($0) } == true) }
        let represented = GitPathSet(result.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
        let tracked = GitPathSet(try trackedPaths(cancellation: cancellation))
        for path in GitPathOperationOrder.sorted(requested) where !represented.contains(path) && tracked.contains(path) { result.append(StatusEntry(path: path, originalPath: nil, index: " ", worktree: " ")) }
        try cancellation?.check(); return result
    }
    /// Revert selected status rows, preserving added working files and recycling
    /// replaced contents. The index is held privately until all Git steps pass.
    public func revertWorkingFiles(_ selected: [StatusEntry], amend: Bool = false, amendDiffToLastCommit: Bool = false, cancellation: OperationCancellation? = nil, progress: @Sendable (WorkingFileRevertProgress) -> Void = { _ in }, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> WorkingFileRevertResult {
        try cancellation?.check()
        guard !selected.isEmpty, GitPathSet(selected.map(\.path)).count == selected.count,
              selected.allSatisfy({ ![FileState.untracked, .ignored].contains($0.state) }) else {
            throw GitFailure(arguments: ["revert"], code: 1, message: "Select versioned files to revert.")
        }
        var current = GitPathMap(try commitDialogStatus(amendToParent: amend && !amendDiffToLastCommit, cancellation: cancellation).map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        let clean = selected.filter { current[$0.path] == nil && $0.index == " " && $0.worktree == " " && $0.originalPath == nil && !$0.hasUnversionedCopy }
        if !clean.isEmpty {
            let tracked = GitPathSet(try trackedPaths(cancellation: cancellation))
            for entry in clean where tracked.contains(entry.path) { current[entry.path] = entry }
        }
        guard selected.allSatisfy({ current[$0.path] == $0 }) else {
            throw GitFailure(arguments: ["revert"], code: 1, message: "The selected files changed. Refresh before reverting.")
        }
        let source: String
        if amend { source = try commitComparisonBase(amendToParent: true, cancellation: cancellation) }
        else if let head = try? run(["rev-parse", "--verify", "HEAD^{commit}"], cancellation: cancellation).text { source = head.trimmingCharacters(in: .newlines) }
        else { try cancellation?.check(); source = try run(["mktree"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) }
        let manager = FileManager.default
        var trash: [URL] = [], submoduleRenames: [(String, String)] = []
        var submodulePaths = GitPathSet()
        var restore = GitPathSet(), unstage = GitPathSet(), recycle: [URL] = []
        // Validate every destination before locking the index or moving anything.
        for entry in selected {
            try cancellation?.check()
            let location = try restoreLocation(entry.path)
            let attributes = try? manager.attributesOfItem(atPath: location.path)
            let directory = attributes?[.type] as? FileAttributeType == .typeDirectory
            let gitlink = try run(["-c","core.precomposeunicode=false","ls-files", "--stage", "--", entry.path], cancellation: cancellation).text.split(separator: "\n").contains { $0.hasPrefix("160000 ") }
            if gitlink { submodulePaths.insert((entry.index == "R" || entry.worktree == "R") ? entry.originalPath ?? entry.path : entry.path) }
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
        try cancellation?.check()
        var indexBytes = try run(["rev-parse", "--git-path", "index"], cancellation: cancellation).stdout
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
        let recycling = Set(recycle).sorted(by: { $0.path < $1.path })
        let total = unstage.count + recycling.count + submoduleRenames.count + restore.count
        var completed = 0
        func notify(_ step: WorkingFileRevertProgress.Step, _ path: String, finished: Bool) {
            if finished { completed += 1 }
            progress(WorkingFileRevertProgress(step: step, path: path, finished: finished, completed: completed, total: total))
        }
        // Bounded batches preserve Git startup performance and provide boundaries
        // at which cancellation can stop before another group changes files.
        func runBatches(_ paths: [String], step: WorkingFileRevertProgress.Step, arguments: [String]) throws {
            for offset in stride(from: 0, to: paths.count, by: 64) {
                try cancellation?.check()
                let batch = Array(paths[offset..<min(offset + 64, paths.count)])
                for path in batch { notify(step, path, finished: false) }
                try cancellation?.check()
                _ = try run(arguments + ["--pathspec-from-file=-","--pathspec-file-nul"],environmentOverrides:environment,input:literalPathPacket(batch),onOutput:onOutput)
                for path in batch { notify(step, path, finished: true) }
            }
        }
        do {
            try runBatches(GitPathOperationOrder.sorted(unstage), step: .unstage, arguments: ["rm", "-f", "--cached", "--ignore-unmatch"])
            for location in recycling {
                try cancellation?.check()
                let path = String(location.path.dropFirst(root.path.count + 1))
                notify(.recycle, path, finished: false)
                try cancellation?.check()
                var trashed: NSURL?
                try manager.trashItem(at: location, resultingItemURL: &trashed)
                if let trashed { trash.append(trashed as URL) }
                notify(.recycle, path, finished: true)
            }
            for (new, old) in submoduleRenames {
                try cancellation?.check(); notify(.move, new, finished: false)
                try cancellation?.check()
                _ = try run(["-c","core.precomposeunicode=false","mv", "-f", "--", new, old], environmentOverrides: environment, onOutput: onOutput)
                notify(.move, new, finished: true)
            }
            try runBatches(GitPathOperationOrder.sorted(restore), step: .restore, arguments: ["restore", "--source=" + source, "--staged", "--worktree"])
            try cancellation?.check()
            let permissions = try manager.attributesOfItem(atPath: index.path)[.posixPermissions]
            if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: lock.path) }
            guard Darwin.rename(lock.path, index.path) == 0 else { throw GitFailure(arguments: ["revert"], code: 1, message: String(cString: strerror(errno))) }
        } catch {
            throw WorkingFileRevertFailure(gitError: error.localizedDescription, wasCancelled: error is OperationCancellationFailure, trashedFiles: trash)
        }
        return WorkingFileRevertResult(revertedPaths: selected.map(\.path), trashedFiles: trash, comparisonRevision: source, submodulePaths: submodulePaths.sorted())
    }
}
