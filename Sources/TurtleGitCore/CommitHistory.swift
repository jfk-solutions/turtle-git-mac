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

public struct HistorySearchFields: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let messages = Self(rawValue: 1 << 0)
    public static let authors = Self(rawValue: 1 << 1)
    public static let emails = Self(rawValue: 1 << 2)
    public static let revisions = Self(rawValue: 1 << 3)
    public static let subject = Self(rawValue: 1 << 4)
    public static let referenceNames = Self(rawValue: 1 << 5)
    public static let notes = Self(rawValue: 1 << 6)
    public static let tagInfo = Self(rawValue: 1 << 7)
    public static let paths = Self(rawValue: 1 << 8)
}

public struct HistoryOptions: Sendable {
    public var allBranches = false
    public var endRevision: String?
    public var limit = 200
    public var search = ""
    public var searchFields: HistorySearchFields = .messages
    public var searchCaseSensitive = false
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
    public let hasStatistics: Bool
    public let isSubmodule: Bool
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
    public static func parse(names: Data, statistics: Data, raw: Data = Data()) -> [CommitFile] {
        let rawRecords = raw.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var gitlinks = Set<String>(), cursor = 0
        while cursor + 1 < rawRecords.count {
            let header = rawRecords[cursor].split(separator: " "); cursor += 1
            guard header.count == 5, header[0].hasPrefix(":") else { break }
            var path = rawRecords[cursor]; cursor += 1
            if header[4].hasPrefix("R") || header[4].hasPrefix("C") {
                guard cursor < rawRecords.count else { break }; path = rawRecords[cursor]; cursor += 1
            }
            if header[1] == "160000" || (header[1] == "000000" && header[0] == ":160000") { gitlinks.insert(path) }
        }
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
                                    added: stats[path]?.0, removed: stats[path]?.1, hasStatistics: stats[path] != nil, isSubmodule: gitlinks.contains(path)))
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
        if options.limit == 0 { return [] }
        // An unborn HEAD is valid; --all may still have commits in other branches.
        if !options.allBranches && options.endRevision == nil {
            do { _ = try run(["rev-parse", "--verify", "--quiet", "HEAD"]) }
            catch let failure as GitFailure where failure.code == 1 { return [] }
        }
        let filtering = !options.search.isEmpty
        let filterInMemory = filtering && options.searchFields != .messages
        if filtering && options.searchFields.isEmpty { return [] }
        var args = ["log", "--topo-order", "--no-notes", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00%cn%x00%ce%x00"]
        if !filterInMemory { args.append("-\(options.limit)") }
        if let revision = options.endRevision {
            let hash = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
            args.append(hash)
        } else if options.allBranches { args.append("--all") }
        if filtering && !filterInMemory {
            args.append("--fixed-strings")
            if !options.searchCaseSensitive { args.append("--regexp-ignore-case") }
            args.append("--grep=" + options.search)
        }
        if let since = options.since { args.append("--since=@\(Int(since.timeIntervalSince1970))") }
        if let until = options.until { args.append("--until=@\(Int(until.timeIntervalSince1970))") }
        args.append("--")
        if let path = options.path, !path.isEmpty { args.append(path) }
        args += options.paths
        let refs = try run(["for-each-ref", "--format=%(objectname)%00%(*objectname)%00%(refname)%00"]).stdout
        let fields = String(decoding: refs, as: UTF8.self).components(separatedBy: "\0")
        var references: [String: [RevisionReference]] = [:]
        var peeledReferenceNames: [String: [String]] = [:]
        var annotatedObjects: [String: [String]] = [:]
        var i = 0
        while i + 2 < fields.count {
            let hash = (fields[i + 1].isEmpty ? fields[i] : fields[i + 1]).trimmingCharacters(in: .whitespacesAndNewlines)
            references[hash, default: []].append(RevisionReference(name: fields[i + 2]))
            if !fields[i + 1].isEmpty {
                peeledReferenceNames[hash, default: []].append(fields[i + 2] + "^{}")
                if fields[i + 2].hasPrefix("refs/tags/") { annotatedObjects[hash, default: []].append(fields[i].trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            i += 3
        }
        // Notes are separate payloads: their text can contain NUL bytes, unlike
        // the fields in the commit record. Avoid per-commit work in repositories
        // with no notes refs or notes configuration.
        let notesConfigured = try run(["config", "--get-regexp", "^(core[.]notesref|notes[.]displayref)$"], successfulExitCodes: 0...1).exitCode == 0
        let hasNotes = references.values.contains { $0.contains { $0.name.hasPrefix("refs/notes/") } }
            || notesConfigured || ProcessInfo.processInfo.environment["GIT_NOTES_REF"] != nil
        var notesCache: [String: String] = [:]
        func notes(_ hash: String) throws -> String {
            guard hasNotes else { return "" }
            if let cached = notesCache[hash] { return cached }
            let value = try run(["show", "-s", "--notes", "--format=%N", hash, "--"]).text.trimmingCharacters(in: .newlines)
            notesCache[hash] = value; return value
        }
        var tagCache: [String: String] = [:]
        func tagInfo(_ hash: String) throws -> String {
            try (annotatedObjects[hash] ?? []).map { object in
                if let cached = tagCache[object] { return cached }
                var value = try run(["cat-file", "tag", object]).text
                if value.hasPrefix("object "), let newline = value.firstIndex(of: "\n") {
                    value = String(value[value.index(after: newline)...])
                    if value.hasPrefix("type commit\n") { value.removeFirst("type commit\n".count) }
                }
                value = value.trimmingCharacters(in: .newlines)
                tagCache[object] = value; return value
            }.joined(separator: "\n")
        }
        func changedPaths(_ hash: String, parents: [String]) throws -> [String] {
            var paths = Set<String>()
            for parent in parents.isEmpty ? [""] : parents {
                var arguments = ["diff-tree", "--root", "--no-commit-id", "--name-status", "-z", "-r", "-M", "--no-ext-diff", "--no-color"]
                if !parent.isEmpty { arguments.append(parent) }
                arguments += [hash, "--"]
                for file in CommitFile.parse(names: try run(arguments).stdout, statistics: Data()) {
                    paths.insert(file.path)
                    if let old = file.oldPath { paths.insert(old) }
                }
            }
            return paths.sorted()
        }
        let fieldsInHistory = String(decoding: try run(args).stdout, as: UTF8.self).components(separatedBy: "\0")
        var entries: [LogEntry] = []
        var record = 0
        while record + 8 < fieldsInHistory.count {
            let fields = Array(fieldsInHistory[record..<(record + 9)])
            record += 9
            if filterInMemory {
                var searchable: [String] = []
                if options.searchFields.contains(.paths) { searchable += try changedPaths(fields[0].trimmingCharacters(in: .whitespacesAndNewlines), parents: fields[1].split(separator: " ").map(String.init)) }
                if options.searchFields.contains(.tagInfo) { searchable.append(try tagInfo(fields[0].trimmingCharacters(in: .whitespacesAndNewlines))) }
                if options.searchFields.contains(.notes) { searchable.append(try notes(fields[0].trimmingCharacters(in: .whitespacesAndNewlines))) }
                if options.searchFields.contains(.subject) { searchable.append(fields[5]) }
                if options.searchFields.contains(.messages) { searchable.append(fields[6]) }
                if options.searchFields.contains(.authors) { searchable += [fields[2], fields[7]] }
                if options.searchFields.contains(.emails) { searchable += [fields[3], fields[8]] }
                if options.searchFields.contains(.revisions) { searchable.append(fields[0].trimmingCharacters(in: .newlines)) }
                if options.searchFields.contains(.referenceNames) {
                    let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    searchable += (references[hash] ?? []).map(\.name) + (peeledReferenceNames[hash] ?? [])
                }
                guard searchable.contains(where: { $0.range(of: options.search, options: options.searchCaseSensitive ? [] : .caseInsensitive) != nil }) else { continue }
            }
            let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { continue }
            var entry = LogEntry(hash: hash, author: fields[2], date: fields[4], subject: fields[5],
                parents: fields[1].split(separator: " ").map(String.init), email: fields[3], message: fields[6],
                committer: fields[7], committerEmail: fields[8])
            entry.notes = try notes(hash); entry.tagInfo = try tagInfo(hash); entries.append(entry)
            if filtering && options.limit > 0 && entries.count >= options.limit { break }
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
    /// Full log clipboard details for a pinned commit, including every parent's
    /// changed paths, Git notes and annotated tags. Use native LF line endings.
    public func commitLogText(revision: String, includePaths: Bool = true) throws -> String {
        let hash = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        let data = try run(["show", "-s", "--no-notes", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00", hash, "--"]).stdout
        guard let entry = LogEntry.parseHistory(data).first, entry.hash == hash else { throw RevisionComparisonFailure.range }
        var text = "Revision: \(hash)\nAuthor: \(entry.author) <\(entry.email)>\nDate: \(entry.date)\nMessage:\n\(entry.message)"
        if !text.hasSuffix("\n") { text += "\n" }
        let notes = try run(["show", "-s", "--format=%N", hash, "--"]).text.trimmingCharacters(in: .newlines)
        if !notes.isEmpty { text += "----\nNotes:\n\(notes)\n" }
        let refs = try run(["for-each-ref", "--format=%(objectname)%00%(*objectname)%00%(refname)%00", "refs/tags/"]).text.components(separatedBy: "\0")
        var index = 0
        while index + 2 < refs.count {
            let object = refs[index].trimmingCharacters(in: .newlines), peeled = refs[index + 1], name = refs[index + 2]
            if peeled == hash {
                let tag = try run(["cat-file", "tag", object]).text
                text += "----\nTag info: \(name)\n\(tag)"
                if !text.hasSuffix("\n") { text += "\n" }
            }
            index += 3
        }
        guard includePaths else { return text + "\n" }
        text += "----\n"
        // Upstream's full clipboard includes paths against each merge parent.
        for parent in entry.parents.isEmpty ? [nil] : entry.parents.map({ Optional($0) }) {
            var side = entry; side.parents = parent.map { [$0] } ?? []
            for file in try files(in: side) {
                text += "\(file.status): \(file.path)"
                if let old = file.oldPath { text += " (from \(old))" }
                text += "\n"
            }
        }
        return text + "\n"
    }
    public func files(in entry: LogEntry) throws -> [CommitFile] {
        var args = ["diff-tree", "--root", "--no-commit-id", "-r", "-M", "--no-ext-diff", "--no-color"]
        if let parent = entry.parents.first { args.append(parent) }
        args += [entry.hash, "--"]
        var names = args; names.insert(contentsOf: ["--name-status", "-z"], at: 1)
        var numbers = args; numbers.insert(contentsOf: ["--numstat", "-z"], at: 1)
        var raw = args; raw.insert(contentsOf: ["--raw", "-z"], at: 1)
        return CommitFile.parse(names: try run(names).stdout, statistics: try run(numbers).stdout, raw: try run(raw).stdout)
    }
    /// Upstream status-list unified diff concatenates each selected file's
    /// patch in visible list order, without including unselected changes.
    public func revisionFileDiff(_ entry: LogEntry, files: [CommitFile], workingTree: Bool = false) throws -> String {
        String(decoding: try revisionFileDiffData(entry, files: files, workingTree: workingTree), as: UTF8.self)
    }
    /// Preserve Git's patch bytes for external unified-diff viewers.
    public func revisionFileDiffData(_ entry: LogEntry, files: [CommitFile], workingTree: Bool = false) throws -> Data {
        guard !files.isEmpty else { throw RevisionComparisonFailure.selection }
        var seen = Set<String>(), patch = Data()
        for file in files where seen.insert(file.path).inserted {
            guard !file.path.isEmpty, !file.path.contains("\0") else { throw RevisionComparisonFailure.selection }
            if let oldPath = file.oldPath {
                var args: [String]
                if workingTree { args = ["diff", "--no-ext-diff", "--no-color", entry.hash] }
                else if let parent = entry.parents.first { args = ["diff", "--no-ext-diff", "--no-color", parent, entry.hash] }
                else { args = ["show", "--format=", "--no-ext-diff", "--no-color", entry.hash] }
                args += ["--", oldPath, file.path]
                patch.append(try run(args).stdout)
            } else { patch.append(try revisionDiffData(entry, path: file.path, workingTree: workingTree)) }
        }
        return patch
    }
    public func revisionDiff(_ entry: LogEntry, path: String? = nil, workingTree: Bool = false) throws -> String {
        String(decoding: try revisionDiffData(entry, path: path, workingTree: workingTree), as: UTF8.self)
    }
    public func revisionDiffData(_ entry: LogEntry, path: String? = nil, workingTree: Bool = false) throws -> Data {
        var args: [String]
        if workingTree { args = ["diff", "--no-ext-diff", "--no-color", entry.hash] }
        else if let parent = entry.parents.first { args = ["diff", "--no-ext-diff", "--no-color", parent, entry.hash] }
        else { args = ["show", "--format=", "--no-ext-diff", "--no-color", entry.hash] }
        args.append("--"); if let path { args.append(path) }
        return try run(args).stdout
    }
}
