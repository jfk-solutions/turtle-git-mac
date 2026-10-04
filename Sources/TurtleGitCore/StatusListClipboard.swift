import Foundation

public enum StatusListColumn: String, CaseIterable, Sendable {
    case path = "Path", fileExtension = "Extension", status = "Status", added = "Lines added", removed = "Lines removed"
    /// The native list has a leading checkbox column, which carries no text.
    public static func nativeColumn(_ index: Int) -> StatusListColumn? {
        let columns = allCases
        return (1...columns.count).contains(index) ? columns[index - 1] : nil
    }
}

public enum StatusListCopy: Sendable {
    case fullPaths, relativePaths, names, all, column(StatusListColumn), pathsAndStatus
}

public enum StatusListClipboard {
    public static func fileExtension(_ path: String, isDirectory: Bool = false) -> String {
        guard !isDirectory, !path.hasSuffix("/") else { return "" }
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[dot...])
    }
    public static func displayedPath(_ entry: StatusEntry) -> String {
        if let old = entry.originalPath, !old.isEmpty, [entry.index, entry.worktree].contains(where: { $0 == "R" || $0 == "C" }) {
            return entry.path + " (from " + old + ")"
        }
        return entry.path
    }

    /// Copy the displayed row order. Single-column output has no heading;
    /// multi-column output uses headings and tabs, with macOS LF line endings.
    public static func text(_ entries: [StatusEntry], root: URL, statistics: [String: CommitFile], copy: StatusListCopy, visibleColumns: [StatusListColumn] = StatusListColumn.allCases) -> String {
        guard !entries.isEmpty else { return "" }
        func cell(_ entry: StatusEntry, _ column: StatusListColumn) -> String {
            let stats = statistics[entry.path]
            switch column {
            case .path: return displayedPath(entry)
            case .fileExtension: return fileExtension(entry.path, isDirectory: stats?.isSubmodule == true)
            case .status: return entry.index == "R" || entry.worktree == "R" ? "Renamed" : stats?.status ?? entry.state.rawValue.capitalized
            case .added: return stats?.added.map(String.init) ?? "–"
            case .removed: return stats?.removed.map(String.init) ?? "–"
            }
        }
        var columns: [StatusListColumn] = []
        switch copy {
        case .all:
            guard !visibleColumns.isEmpty else { return "" }
            columns = visibleColumns
        case .column(let column): columns = [column]
        case .pathsAndStatus: columns = [.path, .status]
        default: break
        }
        let heading = columns.count > 1 ? columns.map(\.rawValue).joined(separator: "\t") + "\n" : ""
        return heading + entries.map { entry in
            switch copy {
            case .fullPaths: return root.appendingPathComponent(entry.path).path
            case .relativePaths: return entry.path
            case .names: return (entry.path as NSString).lastPathComponent
            case .pathsAndStatus: return [entry.path, cell(entry, .status)].joined(separator: "\t")
            default: return columns.map { cell(entry, $0) }.joined(separator: "\t")
            }
        }.joined(separator: "\n") + "\n"
    }
}
