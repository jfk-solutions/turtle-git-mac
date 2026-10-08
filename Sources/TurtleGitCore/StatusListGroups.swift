import Foundation

public enum StatusListGroup: Hashable, Sendable {
    case modified, unversioned, ignored, localChangesIgnored, changelist(String)
    public var title: String {
        switch self {
        case .modified: return "Modified Files"
        case .unversioned: return "Not Versioned Files"
        case .ignored: return "Ignored Files"
        case .localChangesIgnored: return "Local changes ignored (assumed valid/unchanged or skip worktree flagged files)"
        case .changelist(let name): return name
        }
    }
    fileprivate var identity: String {
        switch self {
        case .modified: return "modified"
        case .unversioned: return "unversioned"
        case .ignored: return "ignored"
        case .localChangesIgnored: return "local-changes-ignored"
        case .changelist(let name): return "changelist:" + name
        }
    }
}

/// Headers have identities that cannot be Git paths. Index-based native table
/// interaction must retain their slots and skip them when resolving files.
public enum StatusListRow: Identifiable, Hashable, Sendable {
    case group(StatusListGroup), file(StatusEntry)
    public var id: String {
        switch self {
        case .group(let group): return "\0group:" + group.identity
        case .file(let entry): return entry.id
        }
    }
    public var entry: StatusEntry? { if case .file(let entry) = self { return entry }; return nil }
    public var group: StatusListGroup? { if case .group(let group) = self { return group }; return nil }
}

public enum StatusListGroups {
    /// Match PrepareGroups/SetItemGroup: explicit membership precedes flags and
    /// status categories; ordinary changelists precede ignore-on-commit.
    public static func rows(entries: [StatusEntry], changelists: GitChangelists, locallyIgnored: Set<String> = []) -> [StatusListRow] {
        let enabled = !changelists.assignments.isEmpty || entries.contains { [.untracked, .ignored].contains($0.state) || locallyIgnored.contains($0.path) }
        guard enabled else { return entries.map(StatusListRow.file) }
        var buckets: [StatusListGroup: [StatusEntry]] = [:]
        for entry in entries {
            let group: StatusListGroup
            if let name = changelists.assignments[entry.path] { group = .changelist(name) }
            else if locallyIgnored.contains(entry.path) { group = .localChangesIgnored }
            else if entry.state == .ignored { group = .ignored }
            else if entry.state == .untracked { group = .unversioned }
            else { group = .modified }
            buckets[group, default: []].append(entry)
        }
        let names = changelists.names.filter { $0 != GitChangelists.ignored }
        let ordered: [StatusListGroup] = [.modified, .unversioned, .ignored, .localChangesIgnored] + names.map(StatusListGroup.changelist) + [.changelist(GitChangelists.ignored)]
        return ordered.flatMap { group -> [StatusListRow] in
            guard let files = buckets[group], !files.isEmpty else { return [] }
            return [.group(group)] + files.map(StatusListRow.file)
        }
    }
    public static func nextFileRow(after index: Int?, forward: Bool, in rows: [StatusListRow]) -> Int? {
        var candidate = index.map { $0 + (forward ? 1 : -1) } ?? (forward ? 0 : rows.count - 1)
        while rows.indices.contains(candidate) {
            if rows[candidate].entry != nil { return candidate }
            candidate += forward ? 1 : -1
        }
        return nil
    }
    public static func files(at indexes: IndexSet, in rows: [StatusListRow]) -> [StatusEntry] {
        indexes.compactMap { rows.indices.contains($0) ? rows[$0].entry : nil }
    }
    public static func files(in group: StatusListGroup, rows: [StatusListRow]) -> [StatusEntry] {
        var current: StatusListGroup?, result: [StatusEntry] = []
        for row in rows {
            if let header = row.group { current = header }
            else if current == group, let entry = row.entry { result.append(entry) }
        }
        return result
    }
}

/// Port of CSorter for the five columns currently exposed in Commit. Foundation
/// numeric/case-insensitive collation replaces Windows StrCmpLogicalW.
public enum StatusListSorting {
    public static func compare(_ lhs: StatusEntry, _ rhs: StatusEntry, column: StatusListColumn,
                               lhsStatistics: CommitFile? = nil, rhsStatistics: CommitFile? = nil,
                               lhsDirectory: Bool = false, rhsDirectory: Bool = false) -> ComparisonResult {
        func text(_ a: String, _ b: String, numeric: Bool = true) -> ComparisonResult {
            a.compare(b, options: numeric ? [.caseInsensitive, .numeric] : [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        func status(_ entry: StatusEntry, _ statistics: CommitFile?) -> String {
            entry.index == "R" || entry.worktree == "R" ? "Renamed" : statistics?.status ?? entry.state.rawValue.capitalized
        }
        func count(_ statistics: CommitFile?, added: Bool) -> Int {
            guard let statistics, statistics.hasStatistics else { return -2 }
            return (added ? statistics.added : statistics.removed) ?? -1
        }
        var result: ComparisonResult
        switch column {
        case .path: result = text(lhs.path, rhs.path)
        case .fileExtension:
            result = text(StatusListClipboard.fileExtension(lhs.path, isDirectory: lhsDirectory), StatusListClipboard.fileExtension(rhs.path, isDirectory: rhsDirectory))
        case .status: result = text(status(lhs, lhsStatistics), status(rhs, rhsStatistics), numeric: false)
        case .added, .removed:
            let a = count(lhsStatistics, added: column == .added), b = count(rhsStatistics, added: column == .added)
            result = a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
        if result == .orderedSame { result = text(lhs.path, rhs.path) }
        // Git names retain byte identity on macOS; canonically equivalent and
        // case-only names need a deterministic tie without merging their rows.
        if result == .orderedSame, !lhs.path.utf8.elementsEqual(rhs.path.utf8) {
            result = lhs.path.utf8.lexicographicallyPrecedes(rhs.path.utf8) ? .orderedAscending : .orderedDescending
        }
        return result
    }
}
