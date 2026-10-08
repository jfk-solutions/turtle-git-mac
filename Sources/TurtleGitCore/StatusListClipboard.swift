import Foundation

public enum StatusListColumn: String, CaseIterable, Sendable {
    case path = "Path", fileName = "Filename", fileExtension = "Extension", status = "Status", added = "Lines added", removed = "Lines removed", lastModified = "Last modified", fileSize = "File size", lfsOwner = "LFS Lock"
    public static let defaultColumns: [StatusListColumn] = [.path, .fileExtension, .status, .added, .removed]
    /// The native list has a leading checkbox column, which carries no text.
    public static func nativeColumn(_ index: Int, columns: [StatusListColumn] = defaultColumns) -> StatusListColumn? {
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

    public static func displayedPath(_ file: CommitFile) -> String {
        if let old = file.oldPath, !old.isEmpty, file.action.hasPrefix("R") || file.action.hasPrefix("C") {
            return file.path + " (from " + old + ")"
        }
        return file.path
    }

    /// Log merge parents can contain different occurrences of the same path.
    /// Read each occurrence's own statistics and use its ID for displayed statuses.
    public static func text(_ files: [CommitFile], root: URL, statuses: [String: String], copy: StatusListCopy, visibleColumns: [StatusListColumn] = StatusListColumn.defaultColumns) -> String {
        func cell(_ file: CommitFile, _ column: StatusListColumn) -> String {
            switch column {
            case .path: return displayedPath(file)
            case .fileName: return (file.path as NSString).lastPathComponent
            case .lastModified, .fileSize: return "–"
            case .lfsOwner: return ""
            case .fileExtension: return fileExtension(file.path, isDirectory: file.isSubmodule)
            case .status: return statuses[file.id] ?? file.status
            case .added: return file.addedText
            case .removed: return file.removedText
            }
        }
        return format(files, root: root, copy: copy, visibleColumns: visibleColumns, path: { $0.path }, cell: cell)
    }

    /// Copy the displayed row order. Single-column output has no heading;
    /// multi-column output uses headings and tabs, with macOS LF line endings.
    public static func text(_ entries: [StatusEntry], root: URL, statistics: [String: CommitFile], copy: StatusListCopy, metadata: [String: StatusListMetadata] = [:], lfsOwners: [String: String] = [:], visibleColumns: [StatusListColumn] = StatusListColumn.defaultColumns) -> String {
        func cell(_ entry: StatusEntry, _ column: StatusListColumn) -> String {
            let stats = statistics[entry.path]
            switch column {
            case .path: return displayedPath(entry)
            case .fileName: return (entry.path as NSString).lastPathComponent
            case .lastModified: return metadata[entry.path]?.dateText ?? "–"
            case .fileSize: return metadata[entry.path]?.sizeText ?? "–"
            case .lfsOwner: return lfsOwners[entry.path] ?? ""
            case .fileExtension: return fileExtension(entry.path, isDirectory: stats?.isSubmodule == true || metadata[entry.path]?.isDirectory == true)
            case .status: return entry.index == "R" || entry.worktree == "R" ? "Renamed" : stats?.status ?? entry.state.rawValue.capitalized
            case .added: return stats?.added.map(String.init) ?? "–"
            case .removed: return stats?.removed.map(String.init) ?? "–"
            }
        }
        return format(entries, root: root, copy: copy, visibleColumns: visibleColumns, path: { $0.path }, cell: cell)
    }

    private static func format<Row>(_ rows: [Row], root: URL, copy: StatusListCopy, visibleColumns: [StatusListColumn], path: (Row) -> String, cell: (Row, StatusListColumn) -> String) -> String {
        guard !rows.isEmpty else { return "" }
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
        return heading + rows.map { entry in
            switch copy {
            case .fullPaths: return root.appendingPathComponent(path(entry)).path
            case .relativePaths: return path(entry)
            case .names: return (path(entry) as NSString).lastPathComponent
            case .pathsAndStatus: return [path(entry), cell(entry, .status)].joined(separator: "\t")
            default: return columns.map { cell(entry, $0) }.joined(separator: "\t")
            }
        }.joined(separator: "\n") + "\n"
    }
}

/// Versioned native equivalent of CommitDlg's default/selected column mask.
public struct StatusListColumnSettings: Equatable, Sendable {
    public var visible: Set<StatusListColumn>
    public var order: [StatusListColumn]
    /// Only user-adjusted widths are persisted; other columns keep native defaults.
    public var widths: [StatusListColumn: Double]
    public init(visible: Set<StatusListColumn> = Set(StatusListColumn.defaultColumns), order: [StatusListColumn] = StatusListColumn.allCases, widths: [StatusListColumn: Double] = [:]) {
        self.visible = visible.union([.path])
        var seen = Set<StatusListColumn>()
        self.order = (order + StatusListColumn.allCases).filter { seen.insert($0).inserted }
        self.widths = widths.filter { $0.value.isFinite && $0.value > 0 }.mapValues { min(10000, $0) }
    }
    public static func load(from defaults: UserDefaults, key: String = "Commit.FileColumns") -> Self {
        guard defaults.integer(forKey: key + ".Version") == 1,
              let names = defaults.stringArray(forKey: key) else { return Self() }
        let order = (defaults.stringArray(forKey: key + ".Order") ?? []).compactMap(StatusListColumn.init(rawValue:))
        let saved = defaults.dictionary(forKey: key + ".Widths") ?? [:]
        var widths: [StatusListColumn: Double] = [:]
        for (name, value) in saved {
            guard let column = StatusListColumn(rawValue: name), let number = value as? NSNumber else { continue }
            widths[column] = number.doubleValue
        }
        return Self(visible: Set(names.compactMap(StatusListColumn.init(rawValue:))), order: order, widths: widths)
    }
    public func save(to defaults: UserDefaults, key: String = "Commit.FileColumns") {
        defaults.set(1, forKey: key + ".Version")
        defaults.set(StatusListColumn.allCases.filter { visible.contains($0) || $0 == .path }.map(\.rawValue), forKey: key)
        let normalized = Self(visible: visible, order: order, widths: widths)
        defaults.set(normalized.order.map(\.rawValue), forKey: key + ".Order")
        defaults.set(Dictionary(uniqueKeysWithValues: normalized.widths.map { ($0.key.rawValue, $0.value) }), forKey: key + ".Widths")
    }
}
