import Foundation

public struct RevertDialogSelection: Sendable {
    public let entries: [StatusEntry]
    public let initiallyChecked: GitPathSet
    public let hasUnversionedItems: Bool
    public init(status: [StatusEntry], paths: [String], directFiles: some Sequence<String>) {
        let directFiles = GitPathSet(directFiles)
        let scope = paths.filter { $0 != "." }
        let scoped = status.filter { row in scope.isEmpty || scope.contains { GitReferenceName.equal(row.path,$0) || row.path.utf8.starts(with:($0 + "/").utf8) } }
        hasUnversionedItems = scoped.contains { $0.state == .untracked || $0.hasUnversionedCopy }
        entries = scoped.filter { ![FileState.untracked, .ignored].contains($0.state) }.sorted { let order = $0.path.localizedStandardCompare($1.path);return order == .orderedSame ? $0.path.utf8.lexicographicallyPrecedes($1.path.utf8):order == .orderedAscending }
        initiallyChecked = GitPathSet(entries.filter { directFiles.contains($0.path) || $0.state == .added }.map(\.path))
    }
}
