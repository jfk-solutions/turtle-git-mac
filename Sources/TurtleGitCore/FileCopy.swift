// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin

public enum FileCopyCollision: Sendable { case overwrite, keep, cancel }
public enum CopiedRepositoryChoice: Sendable { case deleteMetadata, ignore, abort }
public struct FileCopyPlan: Sendable {
    public let source: URL
    public let destination: String
    public let folder: URL
    public let occupied: Bool
    public let targetDirectory: Bool
    public let sourceDirectory: Bool
    let sourceStamp: FileMoveFingerprint
    let sourceTree: [String: FileMoveFingerprint]
    let targetStamp: FileMoveFingerprint?
}
public struct CopiedRepository: Sendable {
    public let path: String
    public let gitFile: Bool
}
public struct FileCopyResult: Sendable {
    public let destination: String
    public let repositories: [CopiedRepository]
}
extension GitRepository {
    public func prepareFileCopy(source: URL, to folder: URL, name: String? = nil, cancellation: OperationCancellation? = nil) throws -> FileCopyPlan {
        try cancellation?.check()
        guard source.isFileURL, !source.path.contains("\0"), !source.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw FileMoveFailure.selection }
        let folder = try fileMoveDestination(folder, cancellation: cancellation)
        let source = source.standardizedFileURL
        let proposed = name ?? source.lastPathComponent
        guard !proposed.isEmpty, proposed != ".", proposed != "..", !proposed.contains("/"), !proposed.contains("\0"), proposed.caseInsensitiveCompare(".git") != .orderedSame else { throw FileMoveFailure.name }
        let target = folder.appendingPathComponent(proposed)
        let sourcePhysical = source.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(source.lastPathComponent)
        let targetPhysical = folder.resolvingSymlinksInPath().appendingPathComponent(proposed)
        guard sourcePhysical.path != targetPhysical.path else { throw FileMoveFailure.unchanged }
        let stamp = try FileMoveFingerprint(FileManager.default.attributesOfItem(atPath: source.path))
        guard stamp.type != FileAttributeType.typeDirectory.rawValue || !targetPhysical.path.hasPrefix(sourcePhysical.path + "/") else { throw FileMoveFailure.destination }
        let destination = String(target.path.dropFirst(root.path.count + 1))
        _ = try RemovalRequest(paths: [destination], keepLocal: true)
        let targetStamp = try (try? FileManager.default.attributesOfItem(atPath: target.path)).map(FileMoveFingerprint.init)
        if let targetStamp, targetStamp.inode == stamp.inode && targetStamp.device == stamp.device { throw FileMoveFailure.unchanged }
        let sourceTree = try copyTreeSnapshot(source, cancellation: cancellation)
        try cancellation?.check()
        return FileCopyPlan(source: source, destination: destination, folder: folder, occupied: targetStamp != nil, targetDirectory: targetStamp?.type == FileAttributeType.typeDirectory.rawValue, sourceDirectory: stamp.type == FileAttributeType.typeDirectory.rawValue, sourceStamp: stamp, sourceTree: sourceTree, targetStamp: targetStamp)
    }
    /// Copy first, add second. Failed/cancelled add leaves copied files for recovery.
    /// Metadata choices affect only the new destination, never the original tree.
    public func copyWorkingItem(_ plan: FileCopyPlan, overwrite: Bool, cancellation: OperationCancellation? = nil) throws -> FileCopyResult {
        let fresh = try prepareFileCopy(source: plan.source, to: plan.folder, name: (plan.destination as NSString).lastPathComponent, cancellation: cancellation)
        guard fresh.sourceTree == plan.sourceTree, fresh.sourceStamp == plan.sourceStamp, fresh.targetStamp == plan.targetStamp, fresh.destination == plan.destination else { throw FileMoveFailure.changed }
        guard !fresh.targetDirectory, !fresh.occupied || overwrite else { throw FileMoveFailure.occupied }
        let target = root.appendingPathComponent(plan.destination), temporary = plan.folder.appendingPathComponent(".TurtleGit-copy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try cancellation?.check(); try copyTree(plan.source, to: temporary, cancellation: cancellation); try cancellation?.check()
        let last = try prepareFileCopy(source: plan.source, to: plan.folder, name: target.lastPathComponent, cancellation: cancellation)
        guard last.sourceTree == plan.sourceTree, last.sourceStamp == plan.sourceStamp, last.targetStamp == plan.targetStamp else { throw FileMoveFailure.changed }
        if fresh.occupied {
            guard Darwin.rename(temporary.path, target.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } else { try FileManager.default.moveItem(at: temporary, to: target) }
        return FileCopyResult(destination: plan.destination, repositories: try copiedRepositories(plan.destination, cancellation: cancellation))
    }
    private func copyTreeSnapshot(_ source: URL, cancellation: OperationCancellation?) throws -> [String: FileMoveFingerprint] {
        var result: [String: FileMoveFingerprint] = [:]
        func visit(_ url: URL, relative: String) throws {
            try cancellation?.check(); let stamp = try FileMoveFingerprint(FileManager.default.attributesOfItem(atPath: url.path)); result[relative] = stamp
            if stamp.type == FileAttributeType.typeDirectory.rawValue {
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() { try visit(url.appendingPathComponent(name), relative: relative + "/" + name) }
            }
        }
        try visit(source, relative: ""); return result
    }
    private func copyTree(_ source: URL, to target: URL, cancellation: OperationCancellation?) throws {
        try cancellation?.check(); let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() { try copyTree(source.appendingPathComponent(name), to: target.appendingPathComponent(name), cancellation: cancellation) }
            let preserved = attributes.filter { [.posixPermissions, .modificationDate, .creationDate].contains($0.key) }
            try FileManager.default.setAttributes(preserved, ofItemAtPath: target.path)
        } else { try FileManager.default.copyItem(at: source, to: target) }
        try cancellation?.check()
    }
    public func copiedRepositories(_ destination: String, cancellation: OperationCancellation? = nil) throws -> [CopiedRepository] {
        _ = try RemovalRequest(paths: [destination], keepLocal: true)
        var result: [CopiedRepository] = []
        func visit(_ relative: String) throws {
            try cancellation?.check()
            let url = try restoreLocation(relative), attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { return }
            let children = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            if let admin = children.first(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) {
                let type = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(admin).path)[.type] as? FileAttributeType
                result.append(CopiedRepository(path: relative, gitFile: type != .typeDirectory)); return
            }
            for name in children { try visit(relative + "/" + name) }
        }
        try visit(destination); return result
    }
    public func removeCopiedGitMetadata(_ item: CopiedRepository, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check(); let location = try restoreLocation(item.path)
        guard try copiedRepositories(item.path, cancellation: cancellation).contains(where: { $0.path == item.path && $0.gitFile == item.gitFile }),
              try run(["ls-files", "--stage", "-z", "--", item.path], cancellation: cancellation).stdout.isEmpty else { throw FileMoveFailure.changed }
        let names = try FileManager.default.contentsOfDirectory(atPath: location.path).filter { $0.caseInsensitiveCompare(".git") == .orderedSame }
        try cancellation?.check(); for name in names { try FileManager.default.removeItem(at: location.appendingPathComponent(name)) }
    }
    public func stageCopiedItem(_ destination: String, ignoredRepositories: [String], cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        _ = try RemovalRequest(paths: [destination], keepLocal: true)
        let remaining = try copiedRepositories(destination, cancellation: cancellation).map(\.path)
        guard Set(remaining) == Set(ignoredRepositories) else { throw FileMoveFailure.changed }
        var paths: [String] = []
        func visit(_ relative: String) throws {
            try cancellation?.check()
            guard !ignoredRepositories.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) else { return }
            let url = try restoreLocation(relative), type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeDirectory {
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    guard name.caseInsensitiveCompare(".git") != .orderedSame else { throw FileMoveFailure.changed }
                    try visit(relative + "/" + name)
                }
            } else { paths.append(relative) }
        }
        try visit(destination)
        var output = ""
        for start in stride(from: 0, to: paths.count, by: 128) {
            try cancellation?.check()
            output += try run(["add", "--"] + Array(paths[start..<min(start + 128, paths.count)]), cancellation: cancellation, onOutput: onOutput).text
        }
        return output
    }
    public func clipboardMovePaths(_ urls: [URL], cancellation: OperationCancellation? = nil) throws -> [String] {
        var result: [String] = [], seen = Set<String>()
        for url in urls {
            try cancellation?.check()
            guard url.isFileURL else { throw FileMoveFailure.selection }
            let parent = try fileMoveDestination(url.deletingLastPathComponent(), cancellation: cancellation)
            let path = String(parent.appendingPathComponent(url.lastPathComponent).path.dropFirst(root.path.count + 1))
            _ = try RemovalRequest(paths: [path], keepLocal: true)
            guard try !run(["ls-files", "--stage", "-z", "--", path], cancellation: cancellation).stdout.isEmpty else { throw FileMoveFailure.selection }
            if seen.insert(path).inserted { result.append(path) }
        }
        return result
    }
}
