import Foundation

public struct RevertDialogSelection: Sendable {
    public let entries: [StatusEntry]
    public let initiallyChecked: Set<String>
    public let hasUnversionedItems: Bool
    public init(status: [StatusEntry], paths: [String], directFiles: Set<String>) {
        let scope = paths.filter { $0 != "." }
        let scoped = status.filter { row in scope.isEmpty || scope.contains { row.path == $0 || row.path.hasPrefix($0 + "/") } }
        hasUnversionedItems = scoped.contains { $0.state == .untracked || $0.hasUnversionedCopy }
        entries = scoped.filter { ![FileState.untracked, .ignored].contains($0.state) }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        initiallyChecked = Set(entries.filter { directFiles.contains($0.path) || $0.state == .added }.map(\.path))
    }
}
