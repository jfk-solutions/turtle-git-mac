import Foundation
import Darwin

/// Pinned RevertProgressCommand's independent master and renamed-file policies.
/// Capture once for an owned operation; a retry must not acquire new disposal
/// behavior merely because Settings changed while its result was open.
public struct WorkingFileRevertPolicy: Equatable, Sendable {
    public let recycle: Bool
    public let recycleRenamedFiles: Bool
    public init(recycle: Bool = true, recycleRenamedFiles: Bool = true) {
        self.recycle = recycle; self.recycleRenamedFiles = recycleRenamedFiles
    }
    public static func load(from preferences: UserDefaults = .standard) -> Self {
        func enabled(_ key: String) -> Bool { preferences.object(forKey: key) == nil || preferences.bool(forKey: key) }
        return .init(recycle: enabled("RevertWithRecycleBin"), recycleRenamedFiles: enabled("RevertRenamedFilesWithRecycleBin"))
    }
    public func shouldRecycle(_ entry: StatusEntry) -> Bool {
        recycle && entry.state != .added && (recycleRenamedFiles || (entry.index != "R" && entry.worktree != "R"))
    }
}

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
    /// Read ignored metadata only for requested names omitted by the Commit
    /// projection. Revert must neither inventory unrelated ignored trees nor
    /// silently turn an ignored item in a mixed request into an omitted item.
    private func workingFileRevertStatus(_ requested: GitPathSet, amendToParent: Bool, cancellation: OperationCancellation?) throws -> [StatusEntry] {
        var current = try commitDialogStatus(amendToParent: amendToParent, cancellation: cancellation)
        let represented = GitPathSet(current.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
        let missing = GitPathOperationOrder.sorted(requested.subtracting(represented))
        for offset in stride(from: 0, to: missing.count, by: 64) {
            try cancellation?.check()
            let batch = Array(missing[offset..<min(offset + 64, missing.count)])
            let rows = StatusEntry.parse(try run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored", diffDetection.statusArgument, "--"] + batch,
                                               environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout)
            // A directory pathspec may also report descendants. Only exact
            // requested names supplement this captured file selection.
            current += rows.filter { requested.contains($0.path) && !represented.contains($0.path) }
        }
        let latest = GitPathMap(current.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var seen = GitPathSet()
        return current.compactMap { seen.insert($0.path).inserted ? latest[$0.path] : nil }
    }
    private func workingFileRevertTrackedPaths(_ requested: GitPathSet, cancellation: OperationCancellation?) throws -> GitPathSet {
        let paths = GitPathOperationOrder.sorted(requested)
        var tracked = GitPathSet()
        for offset in stride(from: 0, to: paths.count, by: 64) {
            try cancellation?.check()
            let batch = Array(paths[offset..<min(offset + 64, paths.count)])
            for path in try run(["ls-files", "-z", "--"] + batch, cancellation: cancellation).stdout.split(separator: 0) {
                tracked.insert(String(decoding: path, as: UTF8.self))
            }
        }
        return tracked
    }
    private func workingFileRevertAbsent(_ entry: StatusEntry, tracked: GitPathSet) throws -> Bool {
        guard [FileState.untracked, .ignored].contains(entry.state), entry.originalPath == nil,
              !entry.hasUnversionedCopy, !tracked.contains(entry.path) else { return false }
        let location = try restoreLocation(entry.path)
        var info = stat()
        if lstat(location.path, &info) == 0 { return false }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return true
    }
    /// A retry reads current selected-path status without narrowing the captured
    /// request. A former unknown/ignored file moved to Trash is still a requested
    /// Git pathspec; retain it while absent so Git reports its actual disposition.
    /// Clean tracked paths remain eligible; any other lost identity fails closed.
    public func workingFileRevertSelection(_ selected: [StatusEntry], amend: Bool = false, againstHead: Bool = false, cancellation: OperationCancellation? = nil) throws -> [StatusEntry] {
        try cancellation?.check()
        let requested = GitPathSet(selected.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
        _ = try RemovalRequest(paths: Array(requested), keepLocal: true)
        let current = try workingFileRevertStatus(requested, amendToParent: amend && !againstHead, cancellation: cancellation)
        let explicitlySelected = GitPathSet(selected.map(\.path))
        // Rename counterparts belong to that captured rename, not to an
        // additional unknown-file selection. An old-name obstruction must keep
        // the rename's captured recycling policy unless explicitly selected too.
        var result = current.filter {
            (requested.contains($0.path) || $0.originalPath.map { requested.contains($0) } == true) &&
            (![FileState.untracked, .ignored].contains($0.state) || explicitlySelected.contains($0.path))
        }
        let represented = GitPathSet(result.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
        let missing = requested.subtracting(represented)
        let tracked = try workingFileRevertTrackedPaths(missing, cancellation: cancellation)
        for path in GitPathOperationOrder.sorted(missing) {
            try cancellation?.check()
            if tracked.contains(path) { result.append(StatusEntry(path: path, originalPath: nil, index: " ", worktree: " ")) }
            else if let previous = selected.first(where: { GitReferenceName.equal($0.path, path) }), try workingFileRevertAbsent(previous, tracked: tracked) { result.append(previous) }
            else { throw GitFailure(arguments: ["revert"], code: 1, message: "The requested path is no longer available. Refresh before retrying Revert: " + path) }
        }
        try cancellation?.check(); return result
    }
    /// Revert selected status rows, preserving added working files and recycling
    /// replaced contents according to the captured policy. With recycling off,
    /// Git replaces those contents directly. The index stays private until all
    /// Git steps pass; working-file effects are not rolled back on failure.
    public func revertWorkingFiles(_ selected: [StatusEntry], amend: Bool = false, amendDiffToLastCommit: Bool = false, policy: WorkingFileRevertPolicy = .init(), cancellation: OperationCancellation? = nil, progress: @Sendable (WorkingFileRevertProgress) -> Void = { _ in }, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> WorkingFileRevertResult {
        try cancellation?.check()
        guard !selected.isEmpty, GitPathSet(selected.map(\.path)).count == selected.count else {
            throw GitFailure(arguments: ["revert"], code: 1, message: "Select files to revert.")
        }
        let requested = GitPathSet(selected.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
        _ = try RemovalRequest(paths: Array(requested), keepLocal: true)
        var current = GitPathMap(try workingFileRevertStatus(requested, amendToParent: amend && !amendDiffToLastCommit, cancellation: cancellation).map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        let clean = selected.filter { current[$0.path] == nil && $0.index == " " && $0.worktree == " " && $0.originalPath == nil && !$0.hasUnversionedCopy }
        let absent = selected.filter { current[$0.path] == nil && [FileState.untracked, .ignored].contains($0.state) }
        if !clean.isEmpty || !absent.isEmpty {
            let tracked = try workingFileRevertTrackedPaths(GitPathSet((clean + absent).map(\.path)), cancellation: cancellation)
            for entry in clean where tracked.contains(entry.path) { current[entry.path] = entry }
            for entry in absent where try workingFileRevertAbsent(entry, tracked: tracked) { current[entry.path] = entry }
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
                    if !sameFile && policy.shouldRecycle(entry) { recycle.append(oldLocation) }
                }
                if directory { submoduleRenames.append((entry.path, old)); restore.insert(old) }
                else { restore.formUnion([entry.path, old]) }
            } else if entry.state == .added { unstage.insert(entry.path) }
            else { restore.insert(entry.path) }
            if entry.state != .added, !directory, attributes != nil {
                guard [.typeRegular, .typeSymbolicLink].contains(attributes?[.type] as? FileAttributeType) else { throw WorkingFileRestoreFailure.unsupported }
                if policy.shouldRecycle(entry) { recycle.append(location) }
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
        var recycledNames = GitPathSet()
        let recycling = recycle.filter { recycledNames.insert($0.path).inserted }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let total = unstage.count + recycling.count + submoduleRenames.count + restore.count
        var completed = 0
        func notify(_ step: WorkingFileRevertProgress.Step, _ path: String, finished: Bool) {
            if finished { completed += 1 }
            progress(WorkingFileRevertProgress(step: step, path: path, finished: finished, completed: completed, total: total))
        }
        // Bounded batches preserve Git startup performance and provide boundaries
        // at which cancellation can stop before another group changes files.
        func runBatches(_ paths: [String], step: WorkingFileRevertProgress.Step, arguments: [String], wholeCohort: Bool = false) throws {
            guard !paths.isEmpty else { return }
            let batchSize = wholeCohort ? paths.count : 64
            for offset in stride(from: 0, to: paths.count, by: batchSize) {
                try cancellation?.check()
                let batch = Array(paths[offset..<min(offset + batchSize, paths.count)])
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
            // The pinned massive checkout validates every pathspec before
            // restoring any matched path. Keep unknown/ignored requests in one
            // packet so an unknown name in a later batch cannot leave earlier
            // versioned batches restored before that same Git pathspec error.
            // Added preparation stays private: any failure retains our original
            // index, while completed filesystem/Trash effects remain explicit.
            let mixed = selected.contains { [FileState.untracked, .ignored].contains($0.state) }
            try runBatches(GitPathOperationOrder.sorted(restore), step: .restore, arguments: ["restore", "--source=" + source, "--staged", "--worktree"], wholeCohort: mixed)
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
