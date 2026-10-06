import Foundation

public struct AddDialogEntry: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let state: FileState
    public let status: StatusEntry
    public let size: Int64?
    public let modified: Date?
}
public struct AddDialogSelection: Sendable {
    public let entries: [AddDialogEntry]
    public let initiallyChecked: Set<String>
}
public enum AddFailure: LocalizedError {
    case selection, outsideRepository
    public var errorDescription: String? {
        self == .selection ? "Select files or folders to add." : "The selected path belongs to a different repository."
    }
}
extension GitRepository {
    public func addSelectionIsFiles(_ paths: [String]) throws -> Bool {
        guard !paths.isEmpty else { return false }
        return try paths.allSatisfy { path in
            guard path != "." else { return false }
            let location = try restoreLocation(path)
            guard let type = try? FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType else { return false }
            return type != .typeDirectory
        }
    }
    public func addDialogSelection(paths: [String], includeIgnored: Bool, cancellation: OperationCancellation? = nil) throws -> AddDialogSelection {
        try cancellation?.check()
        let scope = paths.filter { $0 != "." && !$0.isEmpty }
        for path in scope { _ = try restoreLocation(path) }
        let direct = Set(scope.filter { path in
            (try? FileManager.default.attributesOfItem(atPath: restoreLocation(path).path)[.type] as? FileAttributeType).map { $0 != .typeDirectory } ?? false
        })
        let status = StatusEntry.parse(try run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored"], cancellation: cancellation).stdout)
        var rows: [String: AddDialogEntry] = [:]
        var checked = Set<String>()
        for row in status where scope.isEmpty || scope.contains(where: { row.path == $0 || row.path.hasPrefix($0 + "/") }) {
            guard row.state == .untracked || includeIgnored && row.state == .ignored || row.hasUnversionedCopy || direct.contains(row.path) else { continue }
            let location = try restoreLocation(row.path)
            let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
            guard attributes != nil else { continue }
            rows[row.path] = AddDialogEntry(path: row.path, state: row.state, status: row, size: (attributes?[.size] as? NSNumber)?.int64Value, modified: attributes?[.modificationDate] as? Date)
            if row.state == .untracked || row.hasUnversionedCopy || direct.contains(row.path) { checked.insert(row.path) }
        }
        for path in direct where rows[path] == nil {
            let attributes = try FileManager.default.attributesOfItem(atPath: restoreLocation(path).path)
            rows[path] = AddDialogEntry(path: path, state: .normal, status: StatusEntry(path: path, originalPath: nil, index: " ", worktree: " "), size: (attributes[.size] as? NSNumber)?.int64Value, modified: attributes[.modificationDate] as? Date)
            checked.insert(path)
        }
        return AddDialogSelection(entries: rows.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, initiallyChecked: checked)
    }
    /// Original CLI AddProgressCommand uses add -f for the explicitly reviewed list.
    public func addReviewedPaths(_ paths: [String], cancellation: OperationCancellation? = nil) async throws -> String {
        try cancellation?.check()
        guard !paths.isEmpty, Set(paths).count == paths.count, try !isBare() else { throw AddFailure.selection }
        var parents = Set<String>()
        for path in paths {
            try cancellation?.check()
            let location = try restoreLocation(path)
            guard parents.insert(location.deletingLastPathComponent().path).inserted else { continue }
            let parent = GitRepository(root: location.deletingLastPathComponent(), executable: executable)
            let owner = try await parent.discoverRoot()
            guard owner.path == root.path else { throw AddFailure.outsideRepository }
        }
        try addWorkingFiles(paths: paths, cancellation: cancellation)
        return ""
    }
}
