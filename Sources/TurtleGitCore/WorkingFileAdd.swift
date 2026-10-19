import Foundation
import Darwin

public enum WorkingFileAddMode: String, CaseIterable, Sendable {
    case normal = "Add", executable = "Add as Executable (+x)", symlink = "Add as Symlink"
    var indexMode: String? {
        switch self { case .normal: return nil; case .executable: return "100755"; case .symlink: return "120000" }
    }
    var helperName: String { switch self { case .normal: return "normal"; case .executable: return "executable"; case .symlink: return "symlink" } }
}

/// The helper's notification stream is not Git output or a shell command.
/// Exact path membership keeps arbitrary diagnostics from inventing added rows.
private final class AddNotificationReceiver: @unchecked Sendable {
    private let lock = NSLock(), paths: GitPathSet
    private let callback: (@Sendable (String) -> Void)?
    private var pending = Data(), delivered = GitPathSet()
    init(paths: [String], callback: (@Sendable (String) -> Void)?) { self.paths = GitPathSet(paths); self.callback = callback }
    func consume(_ chunk: GitOutputChunk) {
        guard case .stdout = chunk.stream else { return }
        lock.lock()
        pending.append(chunk.data)
        var notifications: [String] = []
        let prefix = Data("TurtleGit Add v1:".utf8)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            if line.starts(with: prefix), let bytes = Data(base64Encoded: Data(line.dropFirst(prefix.count))),
               let path = String(data: bytes, encoding: .utf8), paths.contains(path), delivered.insert(path).inserted { notifications.append(path) }
            pending.removeSubrange(...newline)
        }
        if pending.count > 1_048_576 { pending.removeAll(keepingCapacity: false) }
        lock.unlock()
        for path in notifications { callback?(path) }
    }
}

extension GitRepository {
    /// Source AddProgressCommand uses per-path libgit2 adds or CLI add -f, then
    /// overrides selected non-directory modes. Disk files retain their type/mode.
    public func addWorkingFiles(paths: [String], mode: WorkingFileAddMode = .normal, cancellation: OperationCancellation? = nil, onAdded: (@Sendable (String) -> Void)? = nil, backend: GitLibGit2Configuration? = nil, preservePathOrder: Bool = false) throws {
        let backend = backend ?? libgit2Configuration ?? .load()
        try cancellation?.check()
        func ordered(_ paths: [String]) -> [String] {
            guard preservePathOrder else { return GitPathOperationOrder.sorted(paths) }
            var seen = GitPathSet()
            return paths.filter { seen.insert($0).inserted }
        }
        let paths = ordered(paths)
        guard !paths.isEmpty else { throw GitFailure(arguments: ["add"], code: 1, message: "Select files to add.") }
        for path in paths { _ = try restoreLocation(path) }
        let executor = try backend.executor(for: .add)
        var helperPaths = paths, modePaths = paths, directoryPaths: [String] = []
        var expandedDirectory = false
        if executor != nil {
            var expanded: [String] = [], explicitFiles: [String] = []
            func visit(_ path: String) throws {
                try cancellation?.check()
                let location = try restoreLocation(path)
                let type = (try? FileManager.default.attributesOfItem(atPath: location.path)[.type]) as? FileAttributeType
                guard type == .typeDirectory else { expanded.append(path); return }
                // Nested repositories are single Git entries, never a request
                // to descend into their metadata or stage their individual files.
                if (try? FileManager.default.attributesOfItem(atPath: location.appendingPathComponent(".git").path)) != nil { expanded.append(path); return }
                let children = try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }
                for child in children {
                    try cancellation?.check()
                    guard child.lastPathComponent.caseInsensitiveCompare(".git") != .orderedSame else { continue }
                    try visit(path + "/" + child.lastPathComponent)
                }
            }
            for path in paths {
                let location = try restoreLocation(path)
                if (try? FileManager.default.attributesOfItem(atPath: location.path)[.type]) as? FileAttributeType == .typeDirectory { expandedDirectory = true; directoryPaths.append(path) }
                else { explicitFiles.append(path) }
                try visit(path)
            }
            helperPaths = ordered(expanded); modePaths = explicitFiles
        }
        try withPrivateAddIndex(cancellation: cancellation) { environment in
            if let executor {
                if expandedDirectory {
                    let bytes = try run(["-c", "core.precomposeunicode=false", "ls-files", "--cached", "-z"], environmentOverrides: environment, cancellation: cancellation).stdout
                    let indexed = try bytes.split(separator: 0).map { record -> String in
                        guard let path = String(data: Data(record), encoding: .utf8) else { throw FileMoveFailure.selection }; return path
                    }
                    let index = FileTransferIndex(paths: indexed, caseSensitive: (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true)
                    let explicit = GitPathSet(modePaths)
                    helperPaths = try helperPaths.map { explicit.contains($0) ? $0 : try index.resolvingForIndex($0) }
                    for directory in directoryPaths {
                        let exact = try index.resolvingForIndex(directory)
                        // Existing tracked spellings (including canonical peers)
                        // belong to a whole-folder Add independently of the one
                        // spelling Foundation returns for its filesystem entry.
                        helperPaths += indexed.filter { FileTransferPaths.contains($0, in: exact) }
                    }
                    helperPaths = ordered(helperPaths)
                }
                if helperPaths.isEmpty { return }
                // libgit2 doesn't consume Git's split-index link extension. Flatten
                // only this private copy; the original index stays locked/unchanged.
                _ = try run(["update-index", "--no-split-index"], environmentOverrides: environment, cancellation: cancellation)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: environment["GIT_INDEX_FILE"]!)
                let receiver = AddNotificationReceiver(paths: helperPaths, callback: onAdded)
                let helperMode = expandedDirectory ? WorkingFileAddMode.normal : mode
                let arguments = ["-c", "core.precomposeunicode=false", "add", "--turtlegit-index=" + environment["GIT_INDEX_FILE"]!]
                _ = try run(arguments + ["--turtlegit-mode=" + helperMode.helperName, "--stdin"], cancellation: cancellation, input: literalPathPacket(helperPaths), retainStandardOutput: false, onOutput: receiver.consume, executorOverride: executor)
                // The existing native directory extension expands file rows as
                // the source Add dialog does. Its explicit mode applies only to
                // selected file leaves, never all children of a selected folder.
                if expandedDirectory, mode.indexMode != nil, !modePaths.isEmpty {
                    _ = try run(arguments + ["--turtlegit-mode=" + mode.helperName, "--turtlegit-mode-only", "--stdin"], cancellation: cancellation, input: literalPathPacket(modePaths), retainStandardOutput: false, onOutput: { _ in }, executorOverride: executor)
                }
                return
            }
            for offset in stride(from: 0, to: paths.count, by: 64) {
                _ = try run(["add","-f","--pathspec-from-file=-","--pathspec-file-nul"],environmentOverrides:environment,cancellation:cancellation,input:literalPathPacket(Array(paths[offset..<min(offset + 64, paths.count)])))
            }
            if let indexMode = mode.indexMode {
                for path in paths {
                    let location = root.appendingPathComponent(path)
                    let type = try FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
                    if type == .typeDirectory { continue }
                    let records = try run(["-c","core.precomposeunicode=false","ls-files", "--stage", "-z", "--", path], environmentOverrides: environment, cancellation: cancellation).stdout.split(separator: 0)
                    guard let record = records.first, records.count == 1, let tab = record.firstIndex(of: 9) else {
                        throw GitFailure(arguments: ["add"], code: 1, message: "Could not read the staged file mode for " + path)
                    }
                    let header = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                    guard header.count == 3, header[2] == "0" else { throw GitFailure(arguments: ["add"], code: 1, message: "The file has unresolved index entries: " + path) }
                    _ = try run(["update-index","-z","--index-info"],environmentOverrides:environment,cancellation:cancellation,input:Data((indexMode + " " + String(header[1]) + "\t" + path + "\0").utf8))
                }
            }
        }
        if executor == nil { for path in paths { onAdded?(path) } }
    }

    /// Progress post-actions update the current index blobs without re-adding disk contents.
    public func setAddedFileMode(paths: [String], mode: WorkingFileAddMode, cancellation: OperationCancellation? = nil, backend: GitLibGit2Configuration? = nil) throws {
        let captured = backend ?? libgit2Configuration ?? .load()
        try cancellation?.check()
        guard mode.indexMode != nil, !paths.isEmpty else { throw AddFailure.selection }
        let paths = GitPathOperationOrder.sorted(paths)
        for path in paths { _ = try restoreLocation(path) }
        // Source Add progress post-actions always use the library, independently
        // of the Add operation's engine preference. Only the staged mode changes.
        guard let executor = try GitLibGit2Configuration(mask: GitLibGit2Operation.add.mask, helperURL: captured.helperURL).executor(for: .add) else { throw GitLibGit2Failure.runtimeMissing }
        try withPrivateAddIndex(cancellation: cancellation) { environment in
            _ = try run(["update-index", "--no-split-index"], environmentOverrides: environment, cancellation: cancellation)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: environment["GIT_INDEX_FILE"]!)
            _ = try run(["-c", "core.precomposeunicode=false", "add", "--turtlegit-index=" + environment["GIT_INDEX_FILE"]!, "--turtlegit-mode=" + mode.helperName, "--turtlegit-mode-only", "--stdin"], cancellation: cancellation, input: literalPathPacket(paths), retainStandardOutput: false, onOutput: { _ in }, executorOverride: executor)
        }
    }

    private func withPrivateAddIndex(cancellation: OperationCancellation?, operation: ([String: String]) throws -> Void) throws {
        var indexBytes = try run(["rev-parse", "--git-path", "index"], cancellation: cancellation).stdout
        if indexBytes.last == 10 { indexBytes.removeLast() }
        let indexPath = String(decoding: indexBytes, as: UTF8.self)
        let index = indexPath.hasPrefix("/") ? URL(fileURLWithPath: indexPath) : root.appendingPathComponent(indexPath)
        let lock = URL(fileURLWithPath: index.path + ".lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw GitFailure(arguments: ["add"], code: 1, message: "Could not lock the Git index: " + String(cString: strerror(errno))) }
        var ownsLock = true
        defer { if ownsLock { try? FileManager.default.removeItem(at: lock) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitAdd-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateIndex = directory.appendingPathComponent("index")
        let environment = ["GIT_INDEX_FILE": privateIndex.path]
        if FileManager.default.fileExists(atPath: index.path) { try FileManager.default.copyItem(at: index, to: privateIndex) }
        else { _ = try run(["read-tree", "--empty"], environmentOverrides: environment, cancellation: cancellation) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateIndex.path)
        try operation(environment)
        try cancellation?.check()
        try handle.write(contentsOf: Data(contentsOf: privateIndex)); try handle.close()
        if let permissions = (try? FileManager.default.attributesOfItem(atPath: index.path))?[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: lock.path)
        }
        guard Darwin.rename(lock.path, index.path) == 0 else { throw GitFailure(arguments: ["add"], code: 1, message: "Could not replace the Git index: " + String(cString: strerror(errno))) }
        ownsLock = false
    }
}
