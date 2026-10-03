import Foundation

public struct RevisionReference: Hashable, Sendable {
    public let name: String
    public var isCurrent = false
    public var label: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }
}

public struct HistoryOptions: Sendable {
    public var allBranches = false
    public var limit = 200
    public var search = ""
    public var path: String?
    public var paths: [String] = []
    public var since: Date?
    public var until: Date?
    public init() {}
}

public struct CommitFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let oldPath: String?
    public let action: String
    public let added: Int?
    public let removed: Int?
    public var status: String {
        switch action.first {
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type changed"
        default: return "Modified"
        }
    }
    public static func parse(names: Data, statistics: Data) -> [CommitFile] {
        let numbers = statistics.split(separator: 0, omittingEmptySubsequences: false)
        var stats: [String: (Int?, Int?)] = [:]
        var i = 0
        while i < numbers.count {
            let parts = String(decoding: numbers[i], as: UTF8.self).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            i += 1
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty, i + 1 < numbers.count {
                // In -z output a rename has an empty path, followed by old and new paths.
                path = String(decoding: numbers[i + 1], as: UTF8.self); i += 2
            }
            stats[path] = (Int(parts[0]), Int(parts[1]))
        }
        let records = names.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        i = 0
        var files: [CommitFile] = []
        while i + 1 < records.count {
            let action = records[i]; i += 1
            var oldPath: String?
            if action.hasPrefix("R") || action.hasPrefix("C") {
                oldPath = records[i]; i += 1
            }
            guard i < records.count else { break }
            let path = records[i]; i += 1
            files.append(CommitFile(path: path, oldPath: oldPath, action: action,
                                    added: stats[path]?.0, removed: stats[path]?.1))
        }
        return files
    }
}

/// A lane is a pending ancestor, not a branch name. Edges remain continuous across rows.
public struct CommitGraphRow: Sendable {
    public struct Edge: Sendable {
        public let from: Int
        public let to: Int
        public let color: Int
        public let startsAtNode: Bool
        public let endsAtNode: Bool
    }
    public let column: Int
    public let color: Int
    public let junction: Bool
    public let edges: [Edge]
    public let width: Int
}

public enum CommitGraph {
    private struct Lane { var hash: String; var color: Int }
    public static func layout(_ entries: [LogEntry]) -> [CommitGraphRow] {
        var lanes: [Lane] = []
        var nextColor = 0
        var childCounts: [String: Int] = [:]
        for entry in entries { for parent in entry.parents { childCounts[parent, default: 0] += 1 } }
        return entries.map { entry in
            let hasIncoming = lanes.contains(where: { $0.hash == entry.hash })
            if !hasIncoming {
                lanes.append(Lane(hash: entry.hash, color: nextColor)); nextColor += 1
            }
            let before = lanes
            let column = lanes.firstIndex { $0.hash == entry.hash }!
            let color = lanes[column].color
            lanes.remove(at: column)
            for (index, parent) in entry.parents.enumerated() where !lanes.contains(where: { $0.hash == parent }) {
                let lane = Lane(hash: parent, color: index == 0 ? color : nextColor)
                if index == 0 { lanes.insert(lane, at: min(column, lanes.count)) }
                else { lanes.append(lane); nextColor += 1 }
            }
            var edges: [CommitGraphRow.Edge] = []
            for (index, lane) in before.enumerated() {
                if lane.hash == entry.hash {
                    if hasIncoming { edges.append(.init(from: index, to: column, color: lane.color, startsAtNode: false, endsAtNode: true)) }
                } else if let destination = lanes.firstIndex(where: { $0.hash == lane.hash }) {
                    edges.append(.init(from: index, to: destination, color: lane.color, startsAtNode: false, endsAtNode: false))
                }
            }
            for parent in entry.parents {
                if let destination = lanes.firstIndex(where: { $0.hash == parent }) {
                    edges.append(.init(from: column, to: destination, color: lanes[destination].color, startsAtNode: true, endsAtNode: false))
                }
            }
            return CommitGraphRow(column: column, color: color,
                junction: entry.parents.count > 1 || childCounts[entry.hash, default: 0] > 1,
                edges: edges, width: max(before.count, lanes.count))
        }
    }
}

extension GitRepository {
    public func history(options: HistoryOptions = HistoryOptions()) throws -> [LogEntry] {
        // An unborn HEAD is valid; --all may still have commits in other branches.
        if !options.allBranches {
            do { _ = try run(["rev-parse", "--verify", "--quiet", "HEAD"]) }
            catch let failure as GitFailure where failure.code == 1 { return [] }
        }
        var args = ["log", "--topo-order", "-\(options.limit)", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00"]
        if options.allBranches { args.append("--all") }
        if !options.search.isEmpty { args += ["--fixed-strings", "--regexp-ignore-case", "--grep=" + options.search] }
        if let since = options.since { args.append("--since=@\(Int(since.timeIntervalSince1970))") }
        if let until = options.until { args.append("--until=@\(Int(until.timeIntervalSince1970))") }
        args.append("--")
        if let path = options.path, !path.isEmpty { args.append(path) }
        args += options.paths
        var entries = LogEntry.parseHistory(try run(args).stdout)
        let refs = try run(["for-each-ref", "--format=%(objectname)%00%(*objectname)%00%(refname)%00"]).stdout
        let fields = String(decoding: refs, as: UTF8.self).components(separatedBy: "\0")
        var references: [String: [RevisionReference]] = [:]
        var i = 0
        while i + 2 < fields.count {
            let hash = (fields[i + 1].isEmpty ? fields[i] : fields[i + 1]).trimmingCharacters(in: .whitespacesAndNewlines)
            references[hash, default: []].append(RevisionReference(name: fields[i + 2])); i += 3
        }
        let head = try? run(["rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentRef = try? run(["symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
        for index in entries.indices {
            entries[index].references = (references[entries[index].hash] ?? []).map { value in
                var reference = value; reference.isCurrent = value.name == currentRef; return reference
            }
            entries[index].isHead = entries[index].hash == head
        }
        return entries
    }
    public func files(in entry: LogEntry) throws -> [CommitFile] {
        var args = ["diff-tree", "--root", "--no-commit-id", "-r", "-M", "--no-ext-diff", "--no-color"]
        if let parent = entry.parents.first { args.append(parent) }
        args += [entry.hash, "--"]
        var names = args; names.insert(contentsOf: ["--name-status", "-z"], at: 1)
        var numbers = args; numbers.insert(contentsOf: ["--numstat", "-z"], at: 1)
        return CommitFile.parse(names: try run(names).stdout, statistics: try run(numbers).stdout)
    }
    public func revisionDiff(_ entry: LogEntry, path: String? = nil, workingTree: Bool = false) throws -> String {
        var args: [String]
        if workingTree { args = ["diff", "--no-ext-diff", "--no-color", entry.hash] }
        else if let parent = entry.parents.first { args = ["diff", "--no-ext-diff", "--no-color", parent, entry.hash] }
        else { args = ["show", "--format=", "--no-ext-diff", "--no-color", entry.hash] }
        args.append("--"); if let path { args.append(path) }
        return try run(args).text
    }
}
