// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum FileMoveFailure: LocalizedError {
    case selection, destination, name, occupied, unchanged, changed
    public var errorDescription: String? {
        switch self {
        case .selection: return "Select existing versioned files or folders in this working tree."
        case .destination: return "Choose an existing destination folder in the same working tree, outside Git’s administrative directories."
        case .name: return "Enter a file or folder name without folder separators."
        case .occupied: return "An item already exists with this name. Choose a new name before moving."
        case .unchanged: return "Choose a different name or destination folder."
        case .changed: return "The selected file, index entries or repository changed. Refresh before moving."
        }
    }
}
public struct FileMovePlan: Sendable {
    public let source: String
    public let destination: String
    public let folder: URL
    public let caseOnly: Bool
    let index: Data
    public let head: Data
    let fingerprint: FileMoveFingerprint
}
struct FileMoveFingerprint: Equatable, Sendable {
    let type: String
    let inode: UInt64
    let device: UInt64
    let size: UInt64
    let modified: Date?
    let permissions: UInt64
    init(_ attributes: [FileAttributeKey: Any]) throws {
        guard let type = attributes[.type] as? FileAttributeType,
              [.typeRegular, .typeDirectory, .typeSymbolicLink].contains(type) else { throw FileMoveFailure.selection }
        self.type = type.rawValue
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = attributes[.modificationDate] as? Date
        permissions = (attributes[.posixPermissions] as? NSNumber)?.uint64Value ?? 0
    }
}
extension GitRepository {
    public func fileMoveDestination(_ folder: URL, cancellation: OperationCancellation? = nil) throws -> URL {
        try cancellation?.check()
        guard folder.isFileURL, !folder.path.contains("\0"), try !isBare(cancellation: cancellation),
              RepositoryAccessLease.pathIsContained(folder, by: root) else { throw FileMoveFailure.destination }
        let canonical = folder.standardizedFileURL.resolvingSymlinksInPath(), canonicalRoot = root.resolvingSymlinksInPath()
        guard canonical.path == canonicalRoot.path || canonical.path.hasPrefix(canonicalRoot.path + "/"),
              try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw FileMoveFailure.destination }
        let relative = canonical.path == canonicalRoot.path ? "" : String(canonical.path.dropFirst(canonicalRoot.path.count + 1))
        guard !relative.components(separatedBy: "/").contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw FileMoveFailure.destination }
        let top = try run(["-C", canonical.path, "rev-parse", "--show-toplevel"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == canonicalRoot.path else { throw FileMoveFailure.destination }
        try cancellation?.check(); return relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
    }
    public func prepareFileMove(source: String, to folder: URL, name: String? = nil, cancellation: OperationCancellation? = nil) throws -> FileMovePlan {
        try cancellation?.check(); _ = try RemovalRequest(paths: [source], keepLocal: true)
        let folder = try fileMoveDestination(folder, cancellation: cancellation), sourceURL = try restoreLocation(source)
        let owner = try CloneOptions.workingDirectory(for: sourceURL.deletingLastPathComponent())
        let top = try run(["-C", owner.path, "rev-parse", "--show-toplevel"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { throw FileMoveFailure.selection }
        let proposed = name ?? sourceURL.lastPathComponent
        guard !proposed.isEmpty, name == nil || !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposed != ".", proposed != "..", !proposed.contains("/"), !proposed.contains("\0"), proposed.caseInsensitiveCompare(".git") != .orderedSame else { throw FileMoveFailure.name }
        let destinationURL = folder.appendingPathComponent(proposed).standardizedFileURL
        guard destinationURL.path != sourceURL.path else { throw FileMoveFailure.unchanged }
        guard destinationURL.path.hasPrefix(root.path + "/"), !destinationURL.path.hasPrefix(sourceURL.path + "/") else { throw FileMoveFailure.destination }
        let destination = String(destinationURL.path.dropFirst(root.path.count + 1))
        _ = try RemovalRequest(paths: [destination], keepLocal: true)
        let caseOnly = source.caseInsensitiveCompare(destination) == .orderedSame
        if (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)) != nil {
            let siblings = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            guard caseOnly && !siblings.contains(proposed) else { throw FileMoveFailure.occupied }
        }
        let index = try run(["ls-files", "--stage", "-z", "--", source], cancellation: cancellation).stdout
        guard !index.isEmpty else { throw FileMoveFailure.selection }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path) } catch { throw FileMoveFailure.selection }
        let fingerprint = try FileMoveFingerprint(attributes)
        let head = try run(["rev-parse", "--verify", "--quiet", "HEAD"], successfulExitCodes: 0...1, cancellation: cancellation).stdout
        try cancellation?.check()
        return FileMovePlan(source: source, destination: destination, folder: folder, caseOnly: caseOnly, index: index, head: head, fingerprint: fingerprint)
    }
    public func executeFileMove(_ plan: FileMovePlan, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try cancellation?.check()
        let fresh = try prepareFileMove(source: plan.source, to: plan.folder, name: (plan.destination as NSString).lastPathComponent, cancellation: cancellation)
        guard fresh.destination == plan.destination, fresh.index == plan.index, fresh.head == plan.head, fresh.fingerprint == plan.fingerprint else { throw FileMoveFailure.changed }
        try cancellation?.check()
        return try run(["mv"] + (fresh.caseOnly ? ["-f"] : []) + ["--", plan.source, plan.destination], cancellation: cancellation, onOutput: onOutput).text
    }
}
