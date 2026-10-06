import Foundation
import Darwin

public enum WorkingFileExportFailure: LocalizedError {
    case location, source, unsupported
    public var errorDescription: String? {
        switch self {
        case .location: return "Export paths must stay inside the chosen folder and outside Git metadata."
        case .source: return "Choose another export folder. Export would overwrite a selected working file."
        case .unsupported: return "Only regular files can be exported."
        }
    }
}

extension GitRepository {
    /// Working-tree Save As copies current disk bytes, following file symlinks,
    /// without reading or changing the Git index.
    public func saveWorkingFile(path: String, to destination: URL, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        let source = try restoreLocation(path).resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        guard destination.isFileURL, try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              !destination.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }),
              !parent.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw WorkingFileExportFailure.location }
        guard source.path != destination.resolvingSymlinksInPath().path else { throw WorkingFileExportFailure.source }
        guard try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeRegular else { throw WorkingFileExportFailure.unsupported }
        let temporary = parent.appendingPathComponent(".TurtleGitSaveAs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try cancellation?.check()
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw GitFailure(arguments: ["save as", path], code: 1, message: String(cString: strerror(errno)))
        }
    }
    /// Export working contents, including untracked files, without consulting or
    /// updating the index. Like upstream FilesExport, directories are skipped,
    /// symlinks supply their target's contents, and existing copies are replaced.
    @discardableResult public func exportWorkingFiles(paths: [String], to folder: URL, cancellation: OperationCancellation? = nil) throws -> Int {
        try cancellation?.check()
        let manager = FileManager.default
        let destinationRoot = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard !destinationRoot.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }),
              try destinationRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw WorkingFileExportFailure.location }
        let sources = try Array(Set(paths)).sorted().map { try restoreLocation($0) }
        let resolvedSources = Set(sources.map { $0.resolvingSymlinksInPath().path })
        let destinations = sources.map { destinationRoot.appendingPathComponent(String($0.path.dropFirst(root.path.count + 1))).standardizedFileURL }
        // Preflight the whole selection before replacing any existing copy.
        for destination in destinations {
            try cancellation?.check()
            guard RepositoryAccessLease.pathIsContained(destination.deletingLastPathComponent(), by: destinationRoot),
                  !destination.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }),
                  !destination.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw WorkingFileExportFailure.location }
            guard !resolvedSources.contains(destination.resolvingSymlinksInPath().path) else { throw WorkingFileExportFailure.source }
        }
        var count = 0
        for (source, destination) in zip(sources, destinations) {
            try cancellation?.check()
            let resolved = source.resolvingSymlinksInPath()
            let attributes = try manager.attributesOfItem(atPath: resolved.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory { continue }
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw WorkingFileExportFailure.unsupported }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard RepositoryAccessLease.pathIsContained(destination.deletingLastPathComponent(), by: destinationRoot),
                  !destination.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw WorkingFileExportFailure.location }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".TurtleGitExport-" + UUID().uuidString)
            defer { try? manager.removeItem(at: temporary) }
            try manager.copyItem(at: resolved, to: temporary)
            try cancellation?.check()
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw GitFailure(arguments: ["export", source.lastPathComponent], code: 1, message: String(cString: strerror(errno)))
            }
            count += 1
        }
        return count
    }
}

/// Pinned, preflighted historical export. Each file is written separately so the
/// native dialog can offer upstream's Ignore/Abort choice after a failure.
public struct HistoricalFileExport: Sendable {
    public let revision: String
    public let paths: [String]
    fileprivate let root: URL
    fileprivate let folder: URL
}

extension GitRepository {
    public func prepareHistoricalExport(revision: String, files: [CommitFile], to folder: URL) throws -> HistoricalFileExport {
        let destinationRoot = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard try destinationRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              !destinationRoot.pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw WorkingFileExportFailure.location }
        let hash = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        var seen = Set<String>()
        let paths = files.filter { !$0.isSubmodule && !$0.action.hasPrefix("D") && seen.insert($0.path).inserted }.map(\.path)
        let sources = try paths.map { try restoreLocation($0).resolvingSymlinksInPath().path }
        for path in paths {
            let destination = destinationRoot.appendingPathComponent(path).standardizedFileURL
            guard RepositoryAccessLease.pathIsContained(destination.deletingLastPathComponent(), by: destinationRoot),
                  !destination.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw WorkingFileExportFailure.location }
            guard !sources.contains(destination.resolvingSymlinksInPath().path) else { throw WorkingFileExportFailure.source }
        }
        return HistoricalFileExport(revision: hash, paths: paths, root: root, folder: destinationRoot)
    }
    public func exportHistoricalFile(_ export: HistoricalFileExport, path: String) throws {
        guard export.root == root, export.paths.contains(path) else { throw RevisionComparisonFailure.selection }
        let content = try historicalFile(revision: export.revision, path: path)
        let destination = export.folder.appendingPathComponent(path).standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        guard RepositoryAccessLease.pathIsContained(parent, by: export.folder),
              !parent.resolvingSymlinksInPath().pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw WorkingFileExportFailure.location }
        let sources = try export.paths.map { try restoreLocation($0).resolvingSymlinksInPath().path }
        guard !sources.contains(destination.resolvingSymlinksInPath().path) else { throw WorkingFileExportFailure.source }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard RepositoryAccessLease.pathIsContained(parent, by: export.folder),
              !parent.resolvingSymlinksInPath().pathComponents.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw WorkingFileExportFailure.location }
        let temporary = parent.appendingPathComponent(".TurtleGitExport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try content.bytes.write(to: temporary, options: .withoutOverwriting)
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw GitFailure(arguments: ["export", path], code: 1, message: String(cString: strerror(errno)))
        }
    }
}
