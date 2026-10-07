import Foundation
import CryptoKit
import Darwin

public enum CleanType: Int, CaseIterable, Sendable {
    case all = 0, nonIgnored = 1, ignored = 2
}

public struct CleanOptions: Equatable, Sendable {
    public var type: CleanType
    public var directories: Bool { didSet { if !directories { unmanagedRepositories = false } } }
    public var unmanagedRepositories: Bool
    public init(type: CleanType = .all, directories: Bool = true, unmanagedRepositories: Bool = false) {
        self.type = type; self.directories = directories
        self.unmanagedRepositories = directories && unmanagedRepositories
    }
    var previewArguments: [String] {
        ["-c", "core.quotepath=true", "clean", "-n"] + (directories ? ["-d"] : []) +
            [type == .all ? "-fx" : type == .ignored ? "-fX" : "-f"] +
            (directories && unmanagedRepositories ? ["-f"] : [])
    }
}

public struct CleanPreview: Sendable {
    public let options: CleanOptions
    public let paths: [String]
    public let output: Data
    /// Literal root-relative candidates; trailing slash denotes a directory.
    public let candidates: [String]
    fileprivate let root: URL
    fileprivate let fingerprints: [String: Data]
}

public enum CleanFailure: LocalizedError {
    case bare, path, output, changed, locked
    public var errorDescription: String? {
        switch self {
        case .bare: return "Clean requires a working tree."
        case .path: return "Choose paths inside the working tree."
        case .output: return "Git returned an unrecognized cleanup path. No files were removed."
        case .changed: return "Cleanup candidates changed. Preview again before removing files."
        case .locked: return "Could not lock the Git index. No files were removed."
        }
    }
}

extension GitRepository {
    /// Read-only clean plan. Caller supplies literal scopes; Finder file requests
    /// must be converted to their containing directory by the dialog coordinator.
    public func cleanPreview(options: CleanOptions = CleanOptions(), paths: [String] = [], cancellation: OperationCancellation? = nil) throws -> CleanPreview {
        try cancellation?.check()
        let environment = ["GIT_OPTIONAL_LOCKS": "0"]
        guard try run(["rev-parse", "--is-bare-repository"], environmentOverrides: environment, cancellation: cancellation).text.trimmingCharacters(in: .newlines) != "true" else { throw CleanFailure.bare }
        guard paths.allSatisfy(Self.validCleanPath) else { throw CleanFailure.path }
        let output = try run(options.previewArguments + ["--"] + paths, environmentOverrides: environment, cancellation: cancellation).stdout
        var candidates: [String] = []
        for line in output.split(separator: 10) {
            let prefix = Array("Would remove ".utf8)
            guard line.starts(with: prefix) else { continue } // e.g. skipped nested repository
            let encoded = Array(line.dropFirst(prefix.count))
            let bytes: [UInt8]
            if encoded.first == 34 {
                guard encoded.count >= 2, encoded.last == 34 else { throw CleanFailure.output }
                var decoded: [UInt8] = [], index = 1
                while index < encoded.count - 1 {
                    let byte = encoded[index]; index += 1
                    if byte != 92 { decoded.append(byte); continue }
                    guard index < encoded.count - 1 else { throw CleanFailure.output }
                    let escaped = encoded[index]; index += 1
                    let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 34: 34, 92: 92]
                    if let value = escapes[escaped] { decoded.append(value) }
                    else if (48...55).contains(escaped) {
                        guard index + 1 < encoded.count - 1, (48...55).contains(encoded[index]), (48...55).contains(encoded[index + 1]) else { throw CleanFailure.output }
                        let value = Int(escaped - 48) * 64 + Int(encoded[index] - 48) * 8 + Int(encoded[index + 1] - 48)
                        guard value <= 255 else { throw CleanFailure.output }
                        decoded.append(UInt8(value)); index += 2
                    } else { throw CleanFailure.output }
                }
                bytes = decoded
            } else { bytes = encoded }
            guard let path = String(bytes: bytes, encoding: .utf8), Self.validCleanPath(path) else { throw CleanFailure.output }
            candidates.append(path)
        }
        try cancellation?.check()
        var fingerprints: [String: Data] = [:]
        for path in candidates {
            guard fingerprints[path] == nil else { throw CleanFailure.output }
            fingerprints[path] = try cleanFingerprint(restoreLocation(path), cancellation: cancellation)
        }
        return CleanPreview(options: options, paths: paths, output: output, candidates: candidates, root: root, fingerprints: fingerprints)
    }
    private static func validCleanPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") &&
            !path.split(separator: "/").contains(where: { $0 == ".." || $0 == ".git" })
    }
}

public struct CleanExecutionResult: Sendable {
    public let removedPaths: [String]
    public let trashedFiles: [URL]
}
public struct CleanExecutionFailure: LocalizedError, Sendable {
    public let message: String
    public let failedPath: String?
    public let cancelled: Bool
    public let result: CleanExecutionResult
    public var errorDescription: String? {
        message + (failedPath.map { "\n\nCleanup stopped at: " + $0 } ?? "") +
            (result.removedPaths.isEmpty ? "" : "\n\nCompleted removals:\n" + result.removedPaths.joined(separator: "\n")) +
            (result.trashedFiles.isEmpty ? "" : "\n\nRecoverable Trash items:\n" + result.trashedFiles.map(\.path).joined(separator: "\n"))
    }
}

extension GitRepository {
    /// Execute only an accepted preview. Native callers must confirm the chosen
    /// Trash/permanent action and hold repository access for this operation.
    public func executeClean(_ preview: CleanPreview, permanently: Bool = false, cancellation: OperationCancellation? = nil) throws -> CleanExecutionResult {
        try executeClean(preview, permanently: permanently, cancellation: cancellation) { location, permanent in
            if permanent { try FileManager.default.removeItem(at: location); return nil }
            var trashed: NSURL?
            try FileManager.default.trashItem(at: location, resultingItemURL: &trashed)
            return trashed.map { $0 as URL }
        }
    }
    func executeClean(_ preview: CleanPreview, permanently: Bool, cancellation: OperationCancellation?, removal: @Sendable (URL, Bool) throws -> URL?) throws -> CleanExecutionResult {
        try cancellation?.check()
        guard preview.root == root else { throw CleanFailure.changed }
        var indexPath = try run(["rev-parse", "--git-path", "index"]).stdout
        if indexPath.last == 10 { indexPath.removeLast() }
        let indexName = String(decoding: indexPath, as: UTF8.self)
        let index = indexName.hasPrefix("/") ? URL(fileURLWithPath: indexName) : root.appendingPathComponent(indexName)
        let lock = URL(fileURLWithPath: index.path + ".lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CleanFailure.locked }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: lock) }
        // Recheck the index-derived candidate set while competing index writers
        // are excluded. Content fingerprints cover edits within candidate folders.
        let fresh = try cleanPreview(options: preview.options, paths: preview.paths, cancellation: cancellation)
        guard fresh.candidates == preview.candidates, fresh.fingerprints == preview.fingerprints else { throw CleanFailure.changed }
        let locations = try preview.candidates.map { try restoreLocation($0) }
        var removed: [String] = [], trash: [URL] = [], current: String?
        do {
            for (path, location) in zip(preview.candidates, locations) {
                current = path
                try cancellation?.check()
                guard try cleanFingerprint(location, cancellation: cancellation) == preview.fingerprints[path] else { throw CleanFailure.changed }
                if let recovered = try removal(location, permanently) { trash.append(recovered) }
                removed.append(path); current = nil
            }
            try cancellation?.check()
        } catch {
            throw CleanExecutionFailure(message: error.localizedDescription, failedPath: current, cancelled: cancellation?.isCancelled == true,
                                        result: CleanExecutionResult(removedPaths: removed, trashedFiles: trash))
        }
        return CleanExecutionResult(removedPaths: removed, trashedFiles: trash)
    }
    private func cleanFingerprint(_ location: URL, cancellation: OperationCancellation?) throws -> Data {
        var hash = SHA256()
        func append(_ bytes: Data) { hash.update(data: Data((String(bytes.count) + ":").utf8)); hash.update(data: bytes) }
        func visit(_ url: URL) throws {
            try cancellation?.check()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else { throw CleanFailure.output }
            append(Data(type.rawValue.utf8))
            for key: FileAttributeKey in [.systemNumber, .systemFileNumber, .posixPermissions, .size, .modificationDate] {
                append(Data(String(describing: attributes[key]).utf8))
            }
            switch type {
            case .typeSymbolicLink:
                append(Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
            case .typeRegular:
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                while true {
                    try cancellation?.check()
                    guard let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty else { break }
                    hash.update(data: bytes)
                }
            case .typeDirectory:
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    append(Data(name.utf8)); try visit(url.appendingPathComponent(name))
                }
            default: throw CleanFailure.output
            }
        }
        try visit(location)
        return Data(hash.finalize())
    }
}

public struct CleanRepositoryPreview: Sendable {
    public let repository: URL
    /// Native sandbox callers must retain grants covering all these locations.
    public let requiredAccess: [URL]
    public let preview: CleanPreview
}
public struct CleanBatchPreview: Sendable {
    public let repositories: [CleanRepositoryPreview]
    public let options: CleanOptions
    public let paths: [String]
    public let includesSubmodules: Bool
    fileprivate let root: URL
}
public struct CleanRepositoryResult: Sendable {
    public let repository: URL
    public let result: CleanExecutionResult
}
public struct CleanBatchExecutionFailure: LocalizedError, Sendable {
    public let message: String
    public let failedRepository: URL
    public let cancelled: Bool
    public let completed: [CleanRepositoryResult]
    public let partial: CleanExecutionResult?
    public var errorDescription: String? {
        message + "\n\nCleanup stopped in: " + failedRepository.path +
            completed.filter { !$0.result.removedPaths.isEmpty }.map { entry in
                "\n\nCompleted in " + entry.repository.path + ":\n" + entry.result.removedPaths.joined(separator: "\n") +
                    (entry.result.trashedFiles.isEmpty ? "" : "\nRecoverable Trash items:\n" + entry.result.trashedFiles.map(\.path).joined(separator: "\n"))
            }.joined()
    }
}

extension GitRepository {
    /// Preview the parent scope followed by selected initialized submodule trees.
    /// A selected containing folder includes its child submodules; once selected,
    /// each initialized child is cleaned as a complete working tree recursively.
    public func cleanBatchPreview(options: CleanOptions = CleanOptions(), paths: [String] = [], includeSubmodules: Bool = false, cancellation: OperationCancellation? = nil) async throws -> CleanBatchPreview {
        let parent = try cleanPreview(options: options, paths: paths, cancellation: cancellation)
        var children: [URL] = [], seen = Set([root.resolvingSymlinksInPath().path])
        func visit(_ repository: GitRepository, scope: [String]) async throws {
            let names = try await repository.submoduleUpdatePaths(scope: scope, cancellation: cancellation)
            for name in names {
                try cancellation?.check()
                let location = try await repository.restoreLocation(name)
                guard let type = try? FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType else { continue }
                guard type == .typeDirectory else { throw SubmoduleComparisonFailure.unsafeCheckout }
                guard FileManager.default.fileExists(atPath: location.appendingPathComponent(".git").path) else { continue }
                let child = GitRepository(root: location, executable: executable)
                var top = try await child.run(["rev-parse", "--show-toplevel"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout
                if top.last == 10 { top.removeLast() }
                let canonical = location.resolvingSymlinksInPath().standardizedFileURL
                guard let topPath = String(data: top, encoding: .utf8) else { throw CleanFailure.output }
                guard URL(fileURLWithPath: topPath).resolvingSymlinksInPath().standardizedFileURL.path == canonical.path else { throw SubmoduleComparisonFailure.unsafeCheckout }
                guard seen.insert(canonical.path).inserted else { continue }
                children.append(location)
                try await visit(child, scope: [])
            }
        }
        if includeSubmodules {
            let normalized = paths.map { $0.split(separator: "/").filter { $0 != "." }.joined(separator: "/") }.filter { !$0.isEmpty }
            try await visit(self, scope: normalized)
        }
        var repositories = [CleanRepositoryPreview(repository: root, requiredAccess: try cleanRequiredAccess(cancellation: cancellation), preview: parent)]
        for location in children.sorted(by: { $0.path < $1.path }) {
            let child = GitRepository(root: location, executable: executable)
            let preview = try await child.cleanPreview(options: options, cancellation: cancellation)
            repositories.append(CleanRepositoryPreview(repository: location, requiredAccess: try await child.cleanRequiredAccess(cancellation: cancellation), preview: preview))
        }
        var separate: [CleanRepositoryPreview] = []
        for entry in repositories {
            let checkout = entry.repository.resolvingSymlinksInPath().path
            let covered = separate.contains { ancestor in
                ancestor.preview.candidates.contains { path in
                    guard path.hasSuffix("/") else { return false }
                    let candidate = ancestor.repository.appendingPathComponent(path).resolvingSymlinksInPath().path
                    return checkout == candidate || checkout.hasPrefix(candidate + "/")
                }
            }
            if !covered { separate.append(entry) }
        }
        return CleanBatchPreview(repositories: separate, options: options, paths: paths, includesSubmodules: includeSubmodules, root: root)
    }
    public func executeCleanBatch(_ batch: CleanBatchPreview, permanently: Bool = false, cancellation: OperationCancellation? = nil) async throws -> [CleanRepositoryResult] {
        try cancellation?.check()
        guard batch.root == root else { throw CleanFailure.changed }
        // Check every child before the first removal, including initialization,
        // registration, Git administrative paths and candidate content changes.
        let fresh = try await cleanBatchPreview(options: batch.options, paths: batch.paths, includeSubmodules: batch.includesSubmodules, cancellation: cancellation)
        guard fresh.repositories.count == batch.repositories.count,
              zip(fresh.repositories, batch.repositories).allSatisfy({ current, accepted in
                  current.repository == accepted.repository && current.requiredAccess == accepted.requiredAccess &&
                  current.preview.candidates == accepted.preview.candidates && current.preview.fingerprints == accepted.preview.fingerprints
              }) else { throw CleanFailure.changed }
        var completed: [CleanRepositoryResult] = []
        for accepted in batch.repositories {
            do {
                try cancellation?.check()
                let repository = GitRepository(root: accepted.repository, executable: executable)
                let result = try await repository.executeClean(accepted.preview, permanently: permanently, cancellation: cancellation)
                completed.append(CleanRepositoryResult(repository: accepted.repository, result: result))
            } catch {
                let partial = error as? CleanExecutionFailure
                throw CleanBatchExecutionFailure(message: error.localizedDescription, failedRepository: accepted.repository,
                                                 cancelled: cancellation?.isCancelled == true, completed: completed, partial: partial?.result)
            }
        }
        return completed
    }
    private func cleanRequiredAccess(cancellation: OperationCancellation?) throws -> [URL] {
        var result = [root.resolvingSymlinksInPath().standardizedFileURL]
        for argument in ["--absolute-git-dir", "--git-common-dir"] {
            var bytes = try run(["rev-parse", argument], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout
            if bytes.last == 10 { bytes.removeLast() }
            guard let path = String(data: bytes, encoding: .utf8), !path.isEmpty else { throw CleanFailure.path }
            let location = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).resolvingSymlinksInPath().standardizedFileURL
            if !result.contains(where: { $0.path == location.path }) { result.append(location) }
        }
        return result
    }
}
