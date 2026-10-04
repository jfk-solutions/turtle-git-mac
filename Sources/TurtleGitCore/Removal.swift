import Foundation

public enum RemovalFailure: LocalizedError {
    case selection, outsideWorkingTree, unversioned
    public var errorDescription: String? {
        switch self {
        case .selection: return "Select versioned files or folders to remove."
        case .outsideWorkingTree: return "Removal must stay inside this working tree, outside Git’s administrative directories."
        case .unversioned: return "This path is no longer in the index. Refresh the file list before removing it."
        }
    }
}
public struct RemovalRequest: Sendable {
    public let paths: [String]
    public let keepLocal: Bool
    public init(paths: [String], keepLocal: Bool) throws {
        guard !paths.isEmpty else { throw RemovalFailure.selection }
        var seen = Set<String>()
        for path in paths {
            let components = path.components(separatedBy: "/")
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                  !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.caseInsensitiveCompare(".git") == .orderedSame }) else {
                throw RemovalFailure.outsideWorkingTree
            }
        }
        self.paths = paths.filter { seen.insert($0).inserted }; self.keepLocal = keepLocal
    }
    public var confirmation: String {
        if paths.count == 1 {
            return "Do you really want to remove “\(paths[0])”\(keepLocal ? " from the index" : "")?"
        }
        return "Do you really want to remove the \(paths.count) selected files/directories\(keepLocal ? " from the index" : "")?"
    }
}
extension GitRepository {
    /// RemoveCommand handles one selected path per invocation so its native
    /// Ignore/Abort prompt can decide whether to continue after a failure.
    public func removeVersionedPath(_ path: String, keepLocal: Bool) throws -> String {
        _ = try RemovalRequest(paths: [path], keepLocal: keepLocal)
        guard try !isBare() else { throw RemovalFailure.selection }
        let url = root.appendingPathComponent(path)
        guard RepositoryAccessLease.pathIsContained(url.deletingLastPathComponent(), by: root) else { throw RemovalFailure.outsideWorkingTree }
        let parent = try CloneOptions.workingDirectory(for: url.deletingLastPathComponent())
        var rootBytes = try run(["-C", parent.path, "rev-parse", "--show-toplevel"]).stdout
        if rootBytes.last == 10 { rootBytes.removeLast() }
        let selectedRoot = URL(fileURLWithPath: String(decoding: rootBytes, as: UTF8.self)).standardizedFileURL
        guard selectedRoot == root else { throw RemovalFailure.outsideWorkingTree }
        let tracked = try trackedPaths()
        guard tracked.contains(path) || tracked.contains(where: { $0.hasPrefix(path + "/") }) else { throw RemovalFailure.unversioned }
        // Preserve upstream forced/recursive semantics. --cached leaves working
        // files untouched, including their unstaged changes. No shell/path globbing.
        return try run(["rm", "-r", "-f"] + (keepLocal ? ["--cached"] : []) + ["--", path]).text
    }
}
