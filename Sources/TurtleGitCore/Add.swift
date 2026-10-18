import Foundation

public struct AddDialogEntry: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let state: FileState
    public let status: StatusEntry
    /// Snapshot type for status-list menu eligibility, retained if the path disappears.
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?
}
public struct AddDialogSelection: Sendable {
    public let entries: [AddDialogEntry]
    public let initiallyChecked: GitPathSet
}
public enum AddFailure: LocalizedError {
    case selection, outsideRepository
    public var errorDescription: String? {
        self == .selection ? "Select files or folders to add." : "The selected path belongs to a different repository."
    }
}
extension GitRepository {
    public func addSelectionIsFiles(_ paths: [String], cancellation: OperationCancellation? = nil) throws -> Bool {
        try cancellation?.check()
        guard !paths.isEmpty else { return false }
        return try paths.allSatisfy { path in
            try cancellation?.check()
            guard path != "." else { return false }
            let location = try restoreLocation(path)
            // Upstream AreAllPathsFiles excludes directories, including when
            // an explicitly selected file has disappeared. Git stages tracked
            // deletions or reports a missing untracked path in progress.
            let type = try? FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
            return type != .typeDirectory
        }
    }
    public func addDialogSelection(paths: [String], includeIgnored: Bool, cancellation: OperationCancellation? = nil) throws -> AddDialogSelection {
        try cancellation?.check()
        let scope = paths.filter { $0 != "." && !$0.isEmpty }
        for path in scope { _ = try restoreLocation(path) }
        let direct = GitPathSet(scope.filter { path in
            (try? FileManager.default.attributesOfItem(atPath: restoreLocation(path).path)[.type] as? FileAttributeType).map { $0 != .typeDirectory } ?? false
        })
        let status = StatusEntry.parse(try run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored"], cancellation: cancellation).stdout)
        var rows: GitPathMap<AddDialogEntry> = [:]
        var checked = GitPathSet()
        for row in status where scope.isEmpty || scope.contains(where: { GitReferenceName.equal(row.path,$0) || row.path.utf8.starts(with:($0 + "/").utf8) }) {
            guard row.state == .untracked || includeIgnored && row.state == .ignored || row.hasUnversionedCopy || direct.contains(row.path) else { continue }
            let location = try restoreLocation(row.path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
            guard attributes != nil else { continue }
            rows[row.path] = AddDialogEntry(path: row.path, state: row.state, status: row, isDirectory: attributes?[.type] as? FileAttributeType == .typeDirectory, size: (attributes?[.size] as? NSNumber)?.int64Value, modified: attributes?[.modificationDate] as? Date)
            if row.state == .untracked || row.hasUnversionedCopy || direct.contains(row.path) { checked.insert(row.path) }
        }
        for path in direct where rows[path] == nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: restoreLocation(path).path)
            rows[path] = AddDialogEntry(path: path, state: .normal, status: StatusEntry(path: path, originalPath: nil, index: " ", worktree: " "), isDirectory: false, size: (attributes[.size] as? NSNumber)?.int64Value, modified: attributes[.modificationDate] as? Date)
            checked.insert(path)
        }
        return AddDialogSelection(entries: rows.values.sorted { let order = $0.path.localizedStandardCompare($1.path);return order == .orderedSame ? $0.path.utf8.lexicographicallyPrecedes($1.path.utf8):order == .orderedAscending }, initiallyChecked: checked)
    }
    /// Original CLI AddProgressCommand uses add -f for the explicitly reviewed list.
    public func addReviewedPaths(_ paths: [String], mode: WorkingFileAddMode = .normal, cancellation: OperationCancellation? = nil) async throws -> String {
        try cancellation?.check()
        guard !paths.isEmpty, GitPathSet(paths).count == paths.count, try !isBare() else { throw AddFailure.selection }
        var parents = GitPathSet()
        for path in paths {
            try cancellation?.check()
            let location = try restoreLocation(path)
            guard parents.insert(location.deletingLastPathComponent().path).inserted else { continue }
            let parent = GitRepository(root: location.deletingLastPathComponent(), executable: executable)
            let owner = try await parent.discoverRoot()
            guard owner.path == root.path else { throw AddFailure.outsideRepository }
        }
        try addWorkingFiles(paths: paths, mode: mode, cancellation: cancellation)
        return ""
    }
}
