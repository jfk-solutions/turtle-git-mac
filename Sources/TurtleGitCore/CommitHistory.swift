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

public enum HistoryLabelCommand: String, CaseIterable, Sendable {
    case tags = "Tags", localBranches = "Local branches", remoteBranches = "Remote branches", otherRefs = "Other refs"
    public var flag: HistoryReferenceVisibility {
        switch self {
        case .tags: return .tags
        case .localBranches: return .localBranches
        case .remoteBranches: return .remoteBranches
        case .otherRefs: return .otherRefs
        }
    }
}

/// The six LOGLIST_SHOW flags. Stash and Bisect have no View menu switch upstream.
public struct HistoryReferenceVisibility: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let localBranches = Self(rawValue: 0x01)
    public static let remoteBranches = Self(rawValue: 0x02)
    public static let tags = Self(rawValue: 0x04)
    public static let stash = Self(rawValue: 0x08)
    public static let bisect = Self(rawValue: 0x10)
    public static let otherRefs = Self(rawValue: 0x20)
    public static let all: Self = [.localBranches, .remoteBranches, .tags, .stash, .bisect, .otherRefs]
    private func category(_ reference: RevisionReference) -> Self {
        if reference.name.hasPrefix("refs/heads/") { return .localBranches }
        if reference.name.hasPrefix("refs/remotes/") { return .remoteBranches }
        if reference.name.hasPrefix("refs/tags/") { return .tags }
        if reference.name.hasPrefix("refs/stash") { return .stash }
        if reference.name.hasPrefix("refs/bisect/") { return .bisect }
        return .otherRefs
    }
    public func shows(_ reference: RevisionReference) -> Bool { contains(category(reference)) }
    /// ShouldShowRefsFilter retains only these five kinds; Other refs paints labels only.
    public func keepsCommit(_ reference: RevisionReference) -> Bool {
        category(reference) != .otherRefs && shows(reference)
    }
}

public enum HistoryUnrelatedPathMode: Int, Sendable {
    case all = 0, hide = 1, gray = 2
    public mutating func toggle(_ mode: Self) { self = self == mode ? .all : mode }
}

public struct HistoryPathScope: Sendable, Equatable {
    public let path: String
    public let isDirectory: Bool
    public init(path: String, isDirectory: Bool) { self.path = path; self.isDirectory = isDirectory }
    /// Match FillLogMessageCtrl's literal prefix and directory/gitlink boundary rules.
    public func contains(_ file: CommitFile) -> Bool {
        if path.isEmpty || path == "." { return true }
        let directoryPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        let prefix = isDirectory ? directoryPath + "/" : path
        func matches(_ candidate: String) -> Bool {
            if isDirectory && file.isSubmodule && candidate.utf8.elementsEqual(directoryPath.utf8) { return true }
            return candidate.utf8.starts(with: prefix.utf8)
        }
        return matches(file.path) || ((file.action.hasPrefix("R") || file.action.hasPrefix("C")) && file.oldPath.map(matches) == true)
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
    public static let bugIDs = Self(rawValue: 1 << 9)
}

/// Fixed action slots from the upstream Log list: copied files share Added.
public struct LogRevisionActions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let modified = Self(rawValue: 1 << 0)
    public static let added = Self(rawValue: 1 << 1)
    public static let deleted = Self(rawValue: 1 << 2)
    public static let replaced = Self(rawValue: 1 << 3)
    public static let conflicted = Self(rawValue: 1 << 4)
    public static func classify(_ files: [CommitFile]) -> Self {
        var actions = Self()
        for file in files {
            switch file.action.first {
            case "M", "T": actions.insert(.modified)
            case "A", "C": actions.insert(.added)
            case "D": actions.insert(.deleted)
            case "R": actions.insert(.replaced)
            case "U": actions.insert(.conflicted)
            default: break
            }
        }
        return actions
    }
}

/// Jump order and selection-history behavior from LogDlg.cpp/GitLogListBase.h.
public enum HistoryJumpKind: String, CaseIterable, Sendable {
    case authorEmail = "Author Email", committerEmail = "Committer Email", mergePoint = "Merge Point"
    case parent1 = "Parent 1", parent2 = "Parent 2", tag = "Tag", tagFF = "Tag (FF)"
    case branch = "Branch", branchFF = "Branch (FF)", selectionHistory = "Selection History"
    public var requiresAncestry: Bool { self == .tagFF || self == .branchFF }
    /// nil means the source handler returns without changing selection.
    public func candidates(entries: [LogEntry], selected: Set<String>, up: Bool) -> [Int]? {
        let indices = entries.indices.filter { selected.contains(entries[$0].hash) }
        guard self != .selectionHistory, let first = indices.first, let last = indices.last, first != 0 else { return nil }
        let origin = entries[first]
        let parentIndex = self == .parent2 ? 1 : 0
        if !up && (self == .parent1 || self == .parent2) && origin.parents.count <= parentIndex { return nil }
        let rows = up ? Array((0..<last).reversed()) : Array((last + 1)..<entries.count)
        return rows.filter { index in
            let entry = entries[index]
            switch self {
            case .authorEmail: return entry.email == origin.email
            case .committerEmail: return entry.committerEmail == origin.committerEmail
            case .mergePoint: return entry.parents.count > 1
            case .parent1, .parent2:
                return up ? (entry.parents.count > parentIndex && entry.parents[parentIndex] == origin.hash) : entry.hash == origin.parents[parentIndex]
            case .tag, .tagFF: return entry.references.contains { $0.name.hasPrefix("refs/tags/") }
            case .branch, .branchFF: return entry.references.contains { $0.name.hasPrefix("refs/heads/") || $0.name.hasPrefix("refs/remotes/") }
            case .selectionHistory: return false
            }
        }
    }
}
public struct HistorySelectionNavigation: Sendable {
    public private(set) var hashes: [String] = []
    public private(set) var location = 0
    public init() {}
    public mutating func add(_ hash: String) {
        guard !hash.isEmpty else { return }
        if hashes.last == hash { location = hashes.count - 1; return }
        if !hashes.isEmpty && location != hashes.count - 1 {
            if hashes[location] == hash { return }
            hashes.removeSubrange((location + 1)..<hashes.count)
        }
        if hashes.count >= 50 { hashes.removeFirst() }
        hashes.append(hash); location = hashes.count - 1
    }
    public mutating func move(up: Bool) -> String? {
        guard !hashes.isEmpty, up ? location > 0 : location + 1 < hashes.count else { return nil }
        location += up ? -1 : 1
        return hashes[location]
    }
}

/// Date preferences and relative thresholds from LoglistUtils.cpp.
/// macOS locale layout and timezone conversion use Foundation.
public struct HistoryDateSettings: Equatable, Sendable {
    public var shortDate: Bool
    public var relative: Bool
    public var useSystemLocale: Bool
    public init(shortDate: Bool = true, relative: Bool = false, useSystemLocale: Bool = true) {
        self.shortDate = shortDate; self.relative = relative; self.useSystemLocale = useSystemLocale
    }
    public static func load(defaults: UserDefaults = .standard) -> Self {
        Self(shortDate: (defaults.object(forKey: "LogDateFormat") as? NSNumber)?.boolValue ?? true,
             relative: (defaults.object(forKey: "RelativeTimes") as? NSNumber)?.boolValue ?? false,
             useSystemLocale: (defaults.object(forKey: "UseSystemLocaleForDates") as? NSNumber)?.boolValue ?? true)
    }
    public func format(_ timestamp: String, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current, absolute: Bool = false) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: timestamp) else { return timestamp }
        return format(date, now: now, locale: locale, timeZone: timeZone, absolute: absolute)
    }
    private func format(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone, absolute: Bool) -> String {
        if relative && !absolute {
            let elapsed = now.timeIntervalSince(date), magnitude = abs(elapsed)
            let units: [(Double, Double, String, String)] = [(1095 * 86400, 365 * 86400, "Year", "Years"), (60 * 86400, 30 * 86400, "Month", "Months"), (14 * 86400, 7 * 86400, "Week", "Weeks"), (2 * 86400, 86400, "Day", "Days"), (7200, 3600, "Hour", "Hours"), (120, 60, "Minute", "minutes"), (0, 1, "Second", "Seconds")]
            for (threshold, divisor, single, plural) in units where magnitude >= threshold {
                let count = Int(elapsed / divisor)
                return "\(count) \(count == 1 ? single : plural) ago"
            }
        }
        let formatter = DateFormatter(); formatter.timeZone = timeZone
        if useSystemLocale {
            formatter.locale = locale; formatter.dateStyle = shortDate ? .short : .long; formatter.timeStyle = .medium
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        }
        return formatter.string(from: date)
    }
    /// Format only a tagger header, leaving annotation text and malformed headers intact.
    /// Header stripping follows the CLI GetTagInfo path in Git.cpp.
    public func tagInfo(_ object: String, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var lines = object.components(separatedBy: "\n")
        if lines.first?.hasPrefix("object ") == true {
            lines.removeFirst()
            if lines.first == "type commit" { lines.removeFirst() }
        }
        for index in lines.indices {
            if lines[index].isEmpty { break }
            guard lines[index].hasPrefix("tagger "), let end = lines[index].lastIndex(of: ">") else { continue }
            let tail = lines[index][lines[index].index(after: end)...].split(separator: " ", omittingEmptySubsequences: true)
            guard tail.count == 2, let seconds = Int64(tail[0]), seconds >= 0 else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(seconds))
            lines[index] = String(lines[index][...end]) + " " + format(date, now: now, locale: locale, timeZone: timeZone, absolute: false)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }
}

/// Plain-text query rules ported from upstream FilterHelper.cpp (GPL-2.0-or-later).
/// Conditions operate on the combined selected-field text, not each field alone.
struct HistoryTextQuery {
    private enum Prefix { case and, andNot, or }
    private struct Condition { var text: String; var prefix: Prefix; var nextOr = 0 }
    private var conditions: [Condition] = []
    private let negated: Bool
    private let caseSensitive: Bool
    var isActive: Bool { !conditions.isEmpty }
    var simpleLiteral: String? {
        guard !negated, conditions.count == 1, conditions[0].prefix == .and else { return nil }
        return conditions[0].text
    }
    init(_ query: String, caseSensitive: Bool) {
        self.caseSensitive = caseSensitive
        var units = Array(query.utf16)
        negated = units.first == 33
        if negated { units.removeFirst() }
        var index = 0
        func add(_ token: [UInt16], _ prefix: Prefix) {
            guard !token.isEmpty else { return }
            let text = String(decoding: token, as: UTF16.self)
            conditions.append(Condition(text: caseSensitive ? text : text.lowercased(), prefix: prefix))
            let position = conditions.count - 1
            if prefix == .or, position > 0 {
                for previous in stride(from: position - 1, through: 0, by: -1) {
                    if conditions[previous].nextOr > 0 { break }
                    conditions[previous].nextOr = position
                }
            }
        }
        while index < units.count {
            while index < units.count && units[index] == 32 { index += 1 }
            var prefix = Prefix.and
            if index < units.count {
                if units[index] == 45 { prefix = .andNot; index += 1 }
                else if units[index] == 43 { prefix = .or; index += 1 }
            }
            if index < units.count && units[index] == 34 {
                var token: [UInt16] = []
                while true {
                    index += 1
                    guard index < units.count else { break }
                    if units[index] == 34 {
                        index += 1
                        if index < units.count && units[index] == 34 { token.append(34) }
                        else if index >= units.count || units[index] == 32 { break }
                        else { token += [34, units[index]] }
                    } else { token.append(units[index]) }
                }
                add(token, prefix); index += 1
            }
            // Upstream also tokenizes the word immediately after a quoted term
            // with the same prefix (rather than restarting prefix detection).
            while index < units.count && units[index] == 32 { index += 1 }
            guard index < units.count else { break }
            let start = index
            while index < units.count && units[index] != 32 { index += 1 }
            add(Array(units[start..<index]), prefix)
        }
    }
    func matches(_ value: String) -> Bool {
        if !isActive { return !negated }
        let text = caseSensitive ? value : value.lowercased()
        if text.isEmpty { return negated }
        var current = true, index = 0
        while index < conditions.count {
            let condition = conditions[index]
            var found = text.contains(condition.text)
            if condition.prefix == .andNot { found.toggle() }
            if condition.prefix == .or { current = current || found; found = current }
            if !found {
                guard condition.nextOr > 0 else { return negated }
                current = false; index = condition.nextOr
            } else { index += 1 }
        }
        return !negated
    }
}

public enum HistoryGraphMode: Equatable, Sendable { case all, compressed, labeled }
public enum HistoryWalkCommand: String, CaseIterable, Sendable {
    case firstParent = "First Parent", noMerges = "No merges", followRenames = "Follow renames", fullHistory = "Full history"
    case compressed = "Compressed Graph", labeled = "Show labeled commits only"
}
public struct HistoryWalkOptions: Sendable {
    public var firstParent = false, noMerges = false, followRenames = false, fullHistory = false
    public var graphMode: HistoryGraphMode = .all
    public init() {}
    public var isActive: Bool { firstParent || noMerges || followRenames || fullHistory || graphMode != .all }
    public func contains(_ command: HistoryWalkCommand) -> Bool {
        switch command {
        case .firstParent: return firstParent
        case .noMerges: return noMerges
        case .followRenames: return followRenames
        case .fullHistory: return fullHistory
        case .compressed: return graphMode == .compressed
        case .labeled: return graphMode == .labeled
        }
    }
    public mutating func toggle(_ command: HistoryWalkCommand) {
        switch command {
        case .firstParent: firstParent.toggle()
        case .noMerges: noMerges.toggle()
        case .followRenames: followRenames.toggle()
        case .fullHistory: fullHistory.toggle()
        case .compressed: graphMode = graphMode == .compressed ? .all : .compressed
        case .labeled: graphMode = graphMode == .labeled ? .all : .labeled
        }
    }
}
public enum HistoryWalkFailure: LocalizedError {
    case singleFile
    public var errorDescription: String? { "Follow renames requires one file path. Select a file's history instead of a folder or multiple paths." }
}
public struct HistoryRevisionRange: Equatable, Sendable {
    public enum Kind: Sendable { case difference, symmetricDifference }
    public let from: String
    public let to: String
    public let kind: Kind
    public init(from: String, to: String, kind: Kind = .difference) { self.from = from; self.to = to; self.kind = kind }
    public var separator: String { kind == .difference ? ".." : "..." }
    public var expression: String { from + separator + to }
}
public struct HistoryOptions: Sendable {
    public var walk = HistoryWalkOptions()
    public var allBranches = false
    public var endRevision: String?
    public var revisionRange: HistoryRevisionRange?
    public var limit = 200
    public var search = ""
    public var searchFields: HistorySearchFields = .messages
    public var searchCaseSensitive = false
    public var searchRegex = false
    public var regexExecutable: URL?
    public var path: String?
    public var paths: [String] = []
    public var since: Date?
    public var until: Date?
    public init() {}
}

public struct CommitFile: Identifiable, Hashable, Sendable {
    public var id: String { parentIndex.map { "\0parent\($0)\0" + path } ?? path }
    /// Present only for separate occurrences in a merge Log's parent groups.
    public let parentIndex: Int?
    public let path: String
    public let oldPath: String?
    public let action: String
    public let added: Int?
    public let removed: Int?
    public let hasStatistics: Bool
    public let isSubmodule: Bool
    public init(path: String, oldPath: String?, action: String, added: Int?, removed: Int?, hasStatistics: Bool, isSubmodule: Bool, parentIndex: Int? = nil) {
        self.path = path; self.oldPath = oldPath; self.action = action
        self.added = added; self.removed = removed; self.hasStatistics = hasStatistics
        self.isSubmodule = isSubmodule; self.parentIndex = parentIndex
    }
    public func inParentGroup(_ index: Int) -> Self {
        Self(path: path, oldPath: oldPath, action: action, added: added, removed: removed, hasStatistics: hasStatistics, isSubmodule: isSubmodule, parentIndex: index)
    }
    public var status: String {
        switch action.first {
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type changed"
        case "U": return "Conflicted"
        case "?": return "Unversioned"
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
public enum HistoryRollupChoice: Sendable { case expand, collapse }
public struct HistoryRollupInfo: Sendable {
    public let collapsed: Bool
    public let forced: Bool
    public func toggled(in states: inout [String: HistoryRollupChoice], hash: String) {
        if states[hash] != nil && forced { states.removeValue(forKey: hash) }
        else { states[hash] = collapsed ? .expand : .collapse }
    }
}

public enum HistorySearchActivity {
    public static func isActive(_ query: String, regex: Bool, caseSensitive: Bool, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> Bool {
        try cancellation?.check()
        if !regex { return HistoryTextQuery(query, caseSensitive: caseSensitive).isActive }
        let expression = query.hasPrefix("!") ? String(query.dropFirst()) : query
        if expression.isEmpty { return false }
        let bytes = try IssueRegexRuntime.capture(message: "", check: expression, extract: "", executable: executable,
            mode: [caseSensitive ? "--log-case" : "--log-insensitive"], messageUnits: [], cancellation: cancellation)
        let header = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard header == "log\tactive" || header == "log\tinactive" else { throw HistoryRegexFailure.failed("Invalid log filter activity output.") }
        return header == "log\tactive"
    }
}

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
    /// Authoritative source lane states for native drawing. Edges remain the
    /// existing abstract parent-connectivity API, not the rendered geometry.
    public let lanes: [HistoryLane]
    public let junction: Bool
    public let collapsed: Bool
    public let edges: [Edge]
    public let width: Int
}

public enum CommitGraph {
    private struct Lane { var hash: String; var color: Int }
    /// Compression changes only graph copies, never action/detail parent metadata.
    public static func project(_ entries: [LogEntry], walk: HistoryWalkOptions, references: HistoryReferenceVisibility = .all, rollupStates: [String: HistoryRollupChoice] = [:]) -> (entries: [LogEntry], graph: [CommitGraphRow], rollups: [String: HistoryRollupInfo]) {
        var children: [String: Set<String>] = [:]
        for entry in entries { for parent in entry.graphParents ?? entry.parents { children[parent, default: []].insert(entry.hash) } }
        var rollups: [String: HistoryRollupInfo] = [:]
        var expanded = Set<String>(), collapsed = Set<String>()
        let visible = entries.filter { entry in
            if entry.hash.isEmpty { return true }
            let labeled = entry.isHead || entry.references.contains { references.keepsCommit($0) }
            let descendants = children[entry.hash, default: []]
            let fork = descendants.count > 1
            let special = labeled || entry.parents.count > 1 || fork
            var show = walk.graphMode == .all || labeled || walk.graphMode == .compressed && special
            var defaultCollapse = walk.graphMode != .all
            var rolled = defaultCollapse
            if walk.graphMode == .compressed && !rollupStates.isEmpty {
                let child = descendants.count == 1 ? descendants.first : nil
                let childExpanded = child.map { expanded.contains($0) } ?? false
                let childCollapsed = !childExpanded && (child.map { collapsed.contains($0) } ?? false)
                show = special || childExpanded
                defaultCollapse = special || childCollapsed
                rolled = show ? rollupStates[entry.hash].map { $0 == .collapse } ?? defaultCollapse : defaultCollapse
                if rolled { collapsed.insert(entry.hash) } else { expanded.insert(entry.hash) }
            }
            rollups[entry.hash] = HistoryRollupInfo(collapsed: rolled, forced: rolled != defaultCollapse)
            return show
        }
        let visibleHashes = Set(visible.map(\.hash))
        let records = Dictionary(uniqueKeysWithValues: entries.map { ($0.hash, $0) })
        func graphParents(_ entry: LogEntry) -> [String] {
            let parents = entry.graphParents ?? entry.parents
            return walk.firstParent ? Array(parents.prefix(1)) : parents
        }
        func nearestVisible(_ origin: String) -> [String] {
            var pending = [origin], seen = Set<String>(), result: [String] = []
            while let hash = pending.popLast() {
                guard seen.insert(hash).inserted else { continue }
                if visibleHashes.contains(hash) || records[hash] == nil { result.append(hash) }
                else if let entry = records[hash] { pending += graphParents(entry).reversed() }
            }
            return result
        }
        let graphEntries = visible.map { entry -> LogEntry in
            var copy = entry, seen = Set<String>()
            copy.parents = graphParents(entry).flatMap(nearestVisible).filter { seen.insert($0).inserted }
            copy.graphParents = nil
            return copy
        }
        let graph = zip(visible, layout(graphEntries, mergeCommits: visible.map { $0.parents.count > 1 }, firstParent: walk.firstParent)).map { entry, row in
            CommitGraphRow(column: row.column, color: row.color, lanes: row.lanes,
                junction: entry.parents.count > 1 || children[entry.hash, default: []].count > 1,
                collapsed: rollups[entry.hash]?.collapsed ?? false, edges: row.edges, width: row.width)
        }
        return (visible, graph, rollups)
    }
    public static func layout(_ entries: [LogEntry]) -> [CommitGraphRow] { layout(entries, mergeCommits: entries.map { $0.parents.count > 1 }, firstParent: false) }
    private static func layout(_ entries: [LogEntry], mergeCommits: [Bool], firstParent: Bool) -> [CommitGraphRow] {
        var source = HistoryLanes()
        var rowIndex = 0
        var lanes: [Lane] = []
        var nextColor = 0
        var childCounts: [String: Int] = [:]
        for entry in entries { for parent in entry.graphParents ?? entry.parents { childCounts[parent, default: 0] += 1 } }
        return entries.map { entry in
            let parents = entry.graphParents ?? entry.parents
            let sourceLanes = source.consume(hash: entry.hash, parents: parents, mergeCommit: mergeCommits[rowIndex], firstParent: firstParent)
            let sourceColumn = source.activeLane
            rowIndex += 1
            let hasIncoming = lanes.contains(where: { $0.hash == entry.hash })
            if !hasIncoming {
                lanes.append(Lane(hash: entry.hash, color: nextColor)); nextColor += 1
            }
            let before = lanes
            let column = lanes.firstIndex { $0.hash == entry.hash }!
            let color = lanes[column].color
            lanes.remove(at: column)
            for (index, parent) in parents.enumerated() where !lanes.contains(where: { $0.hash == parent }) {
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
            for parent in parents {
                if let destination = lanes.firstIndex(where: { $0.hash == parent }) {
                    edges.append(.init(from: column, to: destination, color: lanes[destination].color, startsAtNode: true, endsAtNode: false))
                }
            }
            return CommitGraphRow(column: sourceColumn, color: sourceColumn, lanes: sourceLanes,
                junction: entry.parents.count > 1 || childCounts[entry.hash, default: 0] > 1,
                collapsed: false, edges: edges, width: sourceLanes.count)
        }
    }
}

/// Parent labels from GitLogListBase.cpp: 1-based number, 20 UTF-16 units and 8 hex digits.
public struct LogParentChoice: Sendable, Equatable {
    public let number: Int
    public let hash: String
    public let subject: String?
    public init(number: Int, hash: String, subject: String? = nil) { self.number = number; self.hash = hash; self.subject = subject }
    public var title: String {
        let prefix = "Parent \(number)"
        guard let subject else { return prefix + " (" + hash.prefix(8) + ")" }
        let short = subject.utf16.count > 20 ? String(decoding: Array(subject.utf16.prefix(20)), as: UTF16.self) + "..." : subject
        return prefix + ": \"" + short + "\" (" + hash.prefix(8) + ")"
    }
}
/// A Log merge may list the same path once for each parent. Keep those
/// occurrences separate instead of unioning their actions/statistics by path.
public struct LogFileGroup: Identifiable, Sendable {
    /// Zero-based parent order, or zero for a root commit's empty-tree comparison.
    public let id: Int
    public let parent: String?
    /// This entry scopes existing file patch readers to this group's parent.
    public let entry: LogEntry
    public let files: [CommitFile]
}
public struct LogFileRevertTarget: Sendable {
    public let path: String
    public let revision: String
    public let unstageOnly: Bool
    fileprivate let root: URL
    fileprivate let mode: String?
}

public enum LogRevertFailure: LocalizedError {
    case parent, root, bare, mergeActive
    public var errorDescription: String? {
        switch self {
        case .parent: return "Choose a valid parent of this merge commit."
        case .root: return "Select a non-root commit to revert."
        case .bare: return "This operation requires a working tree."
        case .mergeActive: return "Finish the active merge before reverting a commit."
        }
    }
}

public struct CommitNoteSnapshot: Identifiable, Sendable {
    public let revision: String
    public let notesRef: String
    public let text: String
    public let minimumLength: Int
    public var id: String { revision }
    public func accepts(_ text: String) -> Bool { text.utf16.count >= minimumLength && !text.contains("\0") }
}
public enum CommitNoteFailure: LocalizedError {
    case invalidText, minimumLength(Int), savedButRefreshFailed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidText: return "The note is not valid UTF-8 text or contains a NUL character."
        case .minimumLength(let size): return "The note must contain at least \(size) characters."
        case .savedButRefreshFailed(let message): return "Notes saved, but the displayed notes could not be refreshed: " + message
        }
    }
}

extension GitRepository {
    public func logMergeActive(cancellation: OperationCancellation? = nil) throws -> Bool {
        let path = try run(["rev-parse", "--git-path", "MERGE_HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        try cancellation?.check()
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path)
    }
    public func logParentChoices(_ entry: LogEntry, cancellation: OperationCancellation? = nil) throws -> [LogParentChoice] {
        var choices: [LogParentChoice] = []
        for (index, parent) in entry.parents.enumerated() {
            try cancellation?.check()
            guard (parent.count == 40 || parent.count == 64) && parent.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw LogRevertFailure.parent }
            do {
                let result = try run(["show", "--encoding=UTF-8", "-s", "--no-notes", "--format=%s", parent, "--"], cancellation: cancellation)
                var subject = String(decoding: result.stdout, as: UTF8.self)
                if subject.hasSuffix("\n") { subject.removeLast() }
                choices.append(LogParentChoice(number: index + 1, hash: parent, subject: subject))
            } catch is GitFailure { choices.append(LogParentChoice(number: index + 1, hash: parent)) }
        }
        try cancellation?.check()
        return choices
    }
    /// Source GitRevert: reverse the chosen mainline into index/worktree without committing.
    public func revertLogRevision(revision: String, mainline: Int? = nil) throws -> GitResult {
        guard try run(["rev-parse", "--is-bare-repository"]).text.trimmingCharacters(in: .newlines) != "true" else { throw LogRevertFailure.bare }
        guard try !logMergeActive() else { throw LogRevertFailure.mergeActive }
        let hash = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        let parents = try run(["show", "-s", "--no-notes", "--format=%P", hash, "--"]).text.split(whereSeparator: \.isWhitespace)
        guard !parents.isEmpty else { throw LogRevertFailure.root }
        if parents.count > 1 { guard let mainline, (1...parents.count).contains(mainline) else { throw LogRevertFailure.parent } }
        else if mainline != nil { throw LogRevertFailure.parent }
        var arguments = ["revert", "--no-edit", "--no-commit"]
        if let mainline { arguments += ["--mainline", String(mainline)] }
        arguments.append(hash)
        return try run(arguments)
    }
    /// Read the active notes ref, independently of additional log display refs.
    public func editableCommitNote(revision: String, cancellation: OperationCancellation? = nil) throws -> CommitNoteSnapshot {
        try cancellation?.check()
        _ = try run(["var", "GIT_AUTHOR_IDENT"], cancellation: cancellation)
        _ = try run(["var", "GIT_COMMITTER_IDENT"], cancellation: cancellation)
        let hash = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        let ref = try run(["notes", "get-ref"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        let note = try run(["notes", "--ref=" + ref, "list", hash], successfulExitCodes: 0...1, cancellation: cancellation)
        var text = ""
        if note.exitCode == 0 {
            let blob = note.text.trimmingCharacters(in: .newlines)
            let data = try run(["cat-file", "blob", blob], cancellation: cancellation).stdout
            guard let value = String(data: data, encoding: .utf8), !value.contains("\0") else { throw CommitNoteFailure.invalidText }
            text = value
        }
        let properties = try projectConfiguration(pattern: "^tgit[.]logminsize$", cancellation: cancellation)
        let minimum = max(0, (properties["tgit.logminsize"] as NSString?)?.integerValue ?? 0)
        try cancellation?.check()
        return CommitNoteSnapshot(revision: hash, notesRef: ref, text: text, minimumLength: minimum)
    }
    /// The synchronous mutation is not interruptible; callers keep its dialog open until completion.
    /// Reusing a blob preserves exact text, including empty notes, on older Git versions too.
    public func saveCommitNote(_ note: CommitNoteSnapshot, text: String) throws -> String {
        guard !text.contains("\0") else { throw CommitNoteFailure.invalidText }
        guard note.accepts(text) else { throw CommitNoteFailure.minimumLength(note.minimumLength) }
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitNote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try Data(text.utf8).write(to: file)
        let blob = try run(["hash-object", "-w", "--", file.path]).text.trimmingCharacters(in: .newlines)
        _ = try run(["notes", "--ref=" + note.notesRef, "add", "--force", "--allow-empty", "--reuse-message", blob, note.revision])
        // Refresh the display-ref aggregate used by the existing Log message pane.
        do { return try run(["show", "--encoding=UTF-8", "-s", "--notes", "--format=%N", note.revision, "--"]).text.trimmingCharacters(in: .newlines) }
        catch { throw CommitNoteFailure.savedButRefreshFailed(error.localizedDescription) }
    }
    /// FF jumps inspect the actual graph, including ancestors omitted by filters/limits.
    public func historyJump(entries: [LogEntry], selected: Set<String>, kind: HistoryJumpKind, up: Bool, cancellation: OperationCancellation? = nil) throws -> Int? {
        try cancellation?.check()
        guard let candidates = kind.candidates(entries: entries, selected: selected, up: up) else { return nil }
        guard kind.requiresAncestry else { return candidates.first }
        guard let origin = entries.first(where: { selected.contains($0.hash) }) else { return nil }
        for index in candidates {
            try cancellation?.check()
            let ancestor = up ? origin.hash : entries[index].hash
            let descendant = up ? entries[index].hash : origin.hash
            guard [ancestor, descendant].allSatisfy({ ($0.count == 40 || $0.count == 64) && $0.allSatisfy { $0.isHexDigit && $0.isASCII } }) else { throw RevisionComparisonFailure.range }
            if try run(["merge-base", "--is-ancestor", ancestor, descendant], successfulExitCodes: 0...1, cancellation: cancellation).exitCode == 0 { return index }
        }
        try cancellation?.check()
        return nil
    }
    public func history(options: HistoryOptions = HistoryOptions(), cancellation: OperationCancellation? = nil, issueProperties: IssueTrackerProperties? = nil, dateSettings: HistoryDateSettings = .load()) throws -> [LogEntry] {
        try cancellation?.check()
        func historyRun(_ arguments: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(arguments, successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }
        if options.limit == 0 { return [] }
        // An unborn HEAD is valid; --all may still have commits in other branches.
        if !options.allBranches && options.endRevision == nil && options.revisionRange == nil {
            do { _ = try historyRun(["rev-parse", "--verify", "--quiet", "HEAD"]) }
            catch let failure as GitFailure where failure.code == 1 { return [] }
        }
        if options.walk.followRenames {
            let paths = (options.path.map { $0.isEmpty ? [] : [$0] } ?? []) + options.paths
            guard !options.allBranches, try canFollowHistory(paths: paths, revision: options.revisionRange?.to ?? options.endRevision, cancellation: cancellation) else { throw HistoryWalkFailure.singleFile }
        }
        let issueProperties = try issueProperties ?? issueTrackerProperties(cancellation: cancellation)
        var issueCache: [String: String] = [:]
        func issueIDs(_ hash: String, message: String) throws -> String {
            if let value = issueCache[hash] { return value }
            let value = try issueProperties.logIssueIDs(in: message, executable: options.regexExecutable, cancellation: cancellation)
            issueCache[hash] = value; return value
        }
        let filtering = !options.search.isEmpty
        let query = HistoryTextQuery(options.search, caseSensitive: options.searchCaseSensitive)
        // Git fixed-string grep is equivalent only for one positive message term.
        let filterInMemory = filtering && (options.searchRegex || options.searchFields != .messages || query.simpleLiteral == nil)
        var args = ["log", "--encoding=UTF-8", "--topo-order", "--no-notes", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00%cn%x00%ce%x00%cI%x00"]
        // Match GetLogCmd: parent rewriting for normal walks, raw full history.
        let rewritesParents = !options.walk.fullHistory
        if rewritesParents { args.append("--parents") }
        if options.walk.firstParent { args.append("--first-parent") }
        if options.walk.noMerges { args.append("--no-merges") }
        if options.walk.followRenames { args.append("--follow") }
        if options.walk.fullHistory { args.append("--full-history") }
        if !filterInMemory { args.append("-\(options.limit)") }
        if let range = options.revisionRange {
            let from = try historyRun(["rev-parse", "--verify", "--end-of-options", range.from + "^{commit}"]).text.trimmingCharacters(in: .newlines)
            let to = try historyRun(["rev-parse", "--verify", "--end-of-options", range.to + "^{commit}"]).text.trimmingCharacters(in: .newlines)
            args.append(from + range.separator + to)
        } else if let revision = options.endRevision {
            let hash = try historyRun(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
            args.append(hash)
        } else if options.allBranches { args.append("--all") }
        if filtering && !filterInMemory {
            args.append("--fixed-strings")
            if !options.searchCaseSensitive { args.append("--regexp-ignore-case") }
            args.append("--grep=" + (query.simpleLiteral ?? options.search))
        }
        if let since = options.since { args.append("--since=@\(Int(since.timeIntervalSince1970))") }
        if let until = options.until { args.append("--until=@\(Int(until.timeIntervalSince1970))") }
        args.append("--")
        if let path = options.path, !path.isEmpty { args.append(path) }
        args += options.paths
        let refs = try historyRun(["for-each-ref", "--format=%(objectname)%00%(*objectname)%00%(refname)%00"]).stdout
        let fields = String(decoding: refs, as: UTF8.self).components(separatedBy: "\0")
        var references: [String: [RevisionReference]] = [:]
        var peeledReferenceNames: [String: [String]] = [:]
        var annotatedObjects: [String: [String]] = [:]
        var i = 0
        while i + 2 < fields.count {
            try cancellation?.check()
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
        let notesConfigured = try historyRun(["config", "--get-regexp", "^(core[.]notesref|notes[.]displayref)$"], successfulExitCodes: 0...1).exitCode == 0
        let hasNotes = references.values.contains { $0.contains { $0.name.hasPrefix("refs/notes/") } }
            || notesConfigured || ProcessInfo.processInfo.environment["GIT_NOTES_REF"] != nil
        var notesCache: [String: String] = [:]
        func notes(_ hash: String) throws -> String {
            guard hasNotes else { return "" }
            if let cached = notesCache[hash] { return cached }
            let value = try historyRun(["show", "--encoding=UTF-8", "-s", "--notes", "--format=%N", hash, "--"]).text.trimmingCharacters(in: .newlines)
            notesCache[hash] = value; return value
        }
        var tagCache: [String: String] = [:]
        func tagInfo(_ hash: String) throws -> String {
            try (annotatedObjects[hash] ?? []).map { object in
                if let cached = tagCache[object] { return cached }
                var value = try historyRun(["cat-file", "tag", object]).text
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
                try cancellation?.check()
                var arguments = ["diff-tree", "--root", "--no-commit-id", "--name-status", "-z", "-r", "-M", "--no-ext-diff", "--no-color"]
                if !parent.isEmpty { arguments.append(parent) }
                arguments += [hash, "--"]
                for file in CommitFile.parse(names: try historyRun(arguments).stdout, statistics: Data()) {
                    paths.insert(file.path)
                    if let old = file.oldPath { paths.insert(old) }
                }
            }
            return paths.sorted()
        }
        let fieldsInHistory = String(decoding: try historyRun(args).stdout, as: UTF8.self).components(separatedBy: "\0")
        var actualParents: [String: [String]] = [:]
        if rewritesParents {
            let hashes = stride(from: 0, to: max(0, fieldsInHistory.count - 9), by: 10).map {
                fieldsInHistory[$0].trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            guard hashes.allSatisfy({ ($0.count == 40 || $0.count == 64) && $0.allSatisfy { $0.isASCII && $0.isHexDigit } }) else { throw RevisionComparisonFailure.range }
            // Bound argv size even when in-memory searching scans a large history.
            for start in stride(from: 0, to: hashes.count, by: 128) {
                let batch = Array(hashes[start..<min(start + 128, hashes.count)])
                let fields = String(decoding: try historyRun(["show", "--no-patch", "--no-notes", "--format=%H%x00%P%x00"] + batch + ["--"]).stdout, as: UTF8.self).components(separatedBy: "\0")
                var index = 0
                while index + 1 < fields.count {
                    let hash = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    actualParents[hash] = fields[index + 1].split(whereSeparator: \.isWhitespace).map(String.init)
                    index += 2
                }
                guard batch.allSatisfy({ actualParents[$0] != nil }) else { throw RevisionComparisonFailure.range }
            }
        }
        var entries: [LogEntry] = []
        var regexTexts: [String] = []
        var record = 0
        while record + 9 < fieldsInHistory.count {
            try cancellation?.check()
            let fields = Array(fieldsInHistory[record..<(record + 10)])
            record += 10
            let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { continue }
            let walkedParents = fields[1].split(separator: " ").map(String.init)
            let parents = actualParents[hash] ?? walkedParents
            if filterInMemory {
                var searchable: [String] = []
                if !options.searchFields.intersection([.subject, .messages]).isEmpty { searchable.append(fields[5]) }
                if options.searchFields.contains(.messages) {
                    let message = fields[6]
                    searchable.append(message.firstIndex(of: "\n").map { String(message[message.index(after: $0)...]) } ?? "")
                }
                if options.searchFields.contains(.bugIDs) { searchable.append(try issueIDs(fields[0].trimmingCharacters(in: .whitespacesAndNewlines), message: fields[6])) }
                if options.searchFields.contains(.authors) { searchable += [fields[2], fields[7]] }
                if options.searchFields.contains(.emails) { searchable += [fields[3], fields[8]] }
                if options.searchFields.contains(.revisions) { searchable.append(fields[0].trimmingCharacters(in: .newlines)) }
                if options.searchFields.contains(.notes) { searchable.append(try notes(fields[0].trimmingCharacters(in: .whitespacesAndNewlines))) }
                if options.searchFields.contains(.referenceNames) {
                    let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    searchable += (references[hash] ?? []).map(\.name) + (peeledReferenceNames[hash] ?? [])
                }
                if options.searchFields.contains(.tagInfo) { searchable.append(dateSettings.tagInfo(try tagInfo(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)))) }
                if options.searchFields.contains(.paths) { searchable += try changedPaths(hash, parents: parents) }
                let text = searchable.isEmpty ? "" : searchable.joined(separator: "\n") + "\n"
                if options.searchRegex { regexTexts.append(text) }
                else { guard query.matches(text) else { continue } }
            }
            var entry = LogEntry(hash: hash, author: fields[2], date: fields[4], subject: fields[5],
                parents: parents, email: fields[3], message: fields[6],
                committer: fields[7], committerEmail: fields[8], committerDate: fields[9])
            if rewritesParents { entry.graphParents = walkedParents }
            entry.issueIDs = try issueIDs(hash, message: fields[6])
            entry.notes = try notes(hash); entry.tagInfo = try tagInfo(hash); entries.append(entry)
            if filtering && !options.searchRegex && options.limit > 0 && entries.count >= options.limit { break }
        }
        if filtering && options.searchRegex {
            let matches = try IssueRegexRuntime.logMatches(regexTexts, pattern: options.search, caseSensitive: options.searchCaseSensitive, executable: options.regexExecutable, cancellation: cancellation)
            entries = zip(entries, matches).filter { $0.1 }.map { $0.0 }
            if options.limit > 0 { entries = Array(entries.prefix(options.limit)) }
        }
        let head = try? historyRun(["rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentRef = try? historyRun(["symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
        for index in entries.indices {
            entries[index].references = (references[entries[index].hash] ?? []).map { value in
                var reference = value; reference.isCurrent = value.name == currentRef; return reference
            }
            entries[index].isHead = entries[index].hash == head
        }
        try cancellation?.check()
        return entries
    }
    public func canFollowHistory(paths: [String], revision: String? = nil, cancellation: OperationCancellation? = nil) throws -> Bool {
        try cancellation?.check()
        guard paths.count == 1, let path = paths.first, !path.isEmpty, path != ".", !path.hasSuffix("/") else { return false }
        let bare = try run(["rev-parse", "--is-bare-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true"
        if !bare, (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.type] as? FileAttributeType) == .typeDirectory { return false }
        let pinned = try run(["rev-parse", "--verify", "--quiet", "--end-of-options", (revision ?? "HEAD") + "^{commit}"], successfulExitCodes: 0...1, cancellation: cancellation)
        if pinned.exitCode == 1 { return true }
        let hash = pinned.text.trimmingCharacters(in: .newlines)
        let tree = try run(["ls-tree", "-z", hash, "--", path], cancellation: cancellation).stdout
        let record = String(decoding: tree, as: UTF8.self)
        return !record.hasPrefix("040000 ") && !record.hasPrefix("160000 ")
    }
    public func historyPathScopes(paths: [String], revision: String? = nil, cancellation: OperationCancellation? = nil) throws -> [HistoryPathScope] {
        guard !paths.isEmpty else { return [] }
        let bare = try run(["rev-parse", "--is-bare-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true"
        let pinned = try run(["rev-parse", "--verify", "--quiet", "--end-of-options", (revision ?? "HEAD") + "^{commit}"], successfulExitCodes: 0...1, cancellation: cancellation)
        let hash = pinned.text.trimmingCharacters(in: .newlines)
        return try paths.map { path in
            try cancellation?.check()
            var directory = path == "." || path.hasSuffix("/")
            if !bare, (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.type] as? FileAttributeType) == .typeDirectory { directory = true }
            if !directory, pinned.exitCode == 0 {
                let record = String(decoding: try run(["ls-tree", "-z", hash, "--", path], cancellation: cancellation).stdout, as: UTF8.self)
                directory = record.hasPrefix("040000 ") || record.hasPrefix("160000 ")
            }
            return HistoryPathScope(path: path, isDirectory: directory)
        }
    }
    /// Full log clipboard details for a pinned commit, including every parent's
    /// changed paths, Git notes and annotated tags. Use native LF line endings.
    public func commitLogText(revision: String, includePaths: Bool = true, cancellation: OperationCancellation? = nil, dateSettings: HistoryDateSettings = .load()) throws -> String {
        try cancellation?.check()
        func clipboardRun(_ arguments: [String]) throws -> GitResult {
            try cancellation?.check()
            return try run(arguments, cancellation: cancellation)
        }
        let hash = try clipboardRun(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        let data = try clipboardRun(["show", "--encoding=UTF-8", "-s", "--no-notes", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00", hash, "--"]).stdout
        guard let entry = LogEntry.parseHistory(data).first, entry.hash == hash else { throw RevisionComparisonFailure.range }
        var text = "Revision: \(hash)\nAuthor: \(entry.author) <\(entry.email)>\nDate: \(dateSettings.format(entry.date))\nMessage:\n\(entry.message)"
        if !text.hasSuffix("\n") { text += "\n" }
        let notes = try clipboardRun(["show", "--encoding=UTF-8", "-s", "--format=%N", hash, "--"]).text.trimmingCharacters(in: .newlines)
        if !notes.isEmpty { text += "----\nNotes:\n\(notes)\n" }
        let refs = try clipboardRun(["for-each-ref", "--format=%(objectname)%00%(*objectname)%00%(refname)%00", "refs/tags/"]).text.components(separatedBy: "\0")
        var index = 0
        while index + 2 < refs.count {
            try cancellation?.check()
            let object = refs[index].trimmingCharacters(in: .newlines), peeled = refs[index + 1], name = refs[index + 2]
            if peeled == hash {
                let tag = try clipboardRun(["cat-file", "tag", object]).text
                text += "----\nTag info: \(name)\n\(dateSettings.tagInfo(tag))"
                if !text.hasSuffix("\n") { text += "\n" }
            }
            index += 3
        }
        try cancellation?.check()
        guard includePaths else { return text + "\n" }
        text += "----\n"
        // Upstream's full clipboard includes paths against each merge parent.
        for parent in entry.parents.isEmpty ? [nil] : entry.parents.map({ Optional($0) }) {
            try cancellation?.check()
            var side = entry; side.parents = parent.map { [$0] } ?? []
            for file in try files(in: side, cancellation: cancellation) {
                try cancellation?.check()
                text += "\(file.status): \(file.path)"
                if let old = file.oldPath { text += " (from \(old))" }
                text += "\n"
            }
        }
        try cancellation?.check()
        return text + "\n"
    }
    /// Lightweight name-status union across all parents for the lazy Log Actions column.
    public func revisionActions(in entry: LogEntry, cancellation: OperationCancellation? = nil) throws -> LogRevisionActions {
        try cancellation?.check()
        var actions = LogRevisionActions()
        for parent in entry.parents.isEmpty ? [nil] : entry.parents.map({ Optional($0) }) {
            try cancellation?.check()
            var args = ["diff-tree", "--root", "--no-commit-id", "--name-status", "-z", "-r", "-M", "--no-ext-diff", "--no-color"]
            if let parent { args.append(parent) }
            args += [entry.hash, "--"]
            let names = try run(args, cancellation: cancellation).stdout
            try cancellation?.check()
            actions.formUnion(LogRevisionActions.classify(CommitFile.parse(names: names, statistics: Data())))
        }
        try cancellation?.check()
        return actions
    }
    public func files(in entry: LogEntry, cancellation: OperationCancellation? = nil) throws -> [CommitFile] {
        try cancellation?.check()
        var args = ["diff-tree", "--root", "--no-commit-id", "-r", "-M", "--no-ext-diff", "--no-color"]
        if let parent = entry.parents.first { args.append(parent) }
        args += [entry.hash, "--"]
        var names = args; names.insert(contentsOf: ["--name-status", "-z"], at: 1)
        var numbers = args; numbers.insert(contentsOf: ["--numstat", "-z"], at: 1)
        var raw = args; raw.insert(contentsOf: ["--raw", "-z"], at: 1)
        let nameData = try run(names, cancellation: cancellation).stdout
        try cancellation?.check()
        let numberData = try run(numbers, cancellation: cancellation).stdout
        try cancellation?.check()
        let rawData = try run(raw, cancellation: cancellation).stdout
        try cancellation?.check()
        let files = CommitFile.parse(names: nameData, statistics: numberData, raw: rawData)
        try cancellation?.check()
        return files
    }
    /// GitRevLoglist::GetFiles reads every actual parent in commit order.
    /// Resolve metadata from the pinned commit rather than a caller's cached
    /// parent list; preserve empty groups and duplicate paths across groups.
    public func logFileGroups(in entry: LogEntry, cancellation: OperationCancellation? = nil) throws -> [LogFileGroup] {
        try cancellation?.check()
        guard (entry.hash.count == 40 || entry.hash.count == 64), entry.hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw RevisionComparisonFailure.range }
        let metadata = try run(["show", "-s", "--no-notes", "--format=%H%x00%P", entry.hash, "--"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout
        let fields = metadata.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count == 2, String(decoding: fields[0], as: UTF8.self) == entry.hash else { throw RevisionComparisonFailure.range }
        let parents = String(decoding: fields[1], as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        var groups: [LogFileGroup] = []
        for (index, parent) in (parents.isEmpty ? [nil] : parents.map(Optional.some)).enumerated() {
            try cancellation?.check()
            var scoped = entry; scoped.parents = parent.map { [$0] } ?? []
            let changed = try files(in: scoped, cancellation: cancellation)
            try cancellation?.check()
            groups.append(LogFileGroup(id: index, parent: parent, entry: scoped, files: changed))
        }
        return groups
    }
    /// Pin each selected occurrence's actual revision/parent and validate its
    /// old-name target before any working file is recycled.
    public func prepareLogFileRevert(_ entry: LogEntry, files: [CommitFile], parent: Bool) throws -> [LogFileRevertTarget] {
        guard !files.isEmpty, try !isBare() else { throw RevisionComparisonFailure.selection }
        let groups = try logFileGroups(in: entry)
        var targets: [LogFileRevertTarget] = []
        for file in files {
            let index = file.parentIndex ?? 0
            guard let group = groups.first(where: { $0.id == index }),
                  group.files.contains(where: { $0.path == file.path && $0.oldPath == file.oldPath && $0.action == file.action }) else { throw RevisionComparisonFailure.selection }
            let path = file.oldPath ?? file.path
            _ = try restoreLocation(path)
            let revision: String
            if parent { guard let hash = group.parent else { throw RevisionComparisonFailure.range }; revision = hash }
            else { revision = entry.hash }
            let unstage = parent && file.action.hasPrefix("A")
            var mode: String?
            if !unstage {
                for record in try run(["ls-tree", "-z", revision, "--", path]).stdout.split(separator: 0) {
                    guard let tab = record.firstIndex(of: 9), Data(record[record.index(after: tab)...]) == Data(path.utf8) else { continue }
                    mode = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ").first.map(String.init)
                }
                guard let mode, ["100644", "100755", "120000", "160000"].contains(mode) else { throw RevisionComparisonFailure.selection }
            }
            targets.append(LogFileRevertTarget(path: path, revision: revision, unstageOnly: unstage, root: root, mode: mode))
        }
        return targets
    }
    /// Checkout changes index/worktree but never moves HEAD. Parent-added paths
    /// use upstream's rm --cached workaround and retain their working contents.
    public func revertLogFile(_ target: LogFileRevertTarget, recycle: Bool = true) throws -> [URL] {
        guard target.root == root, try !isBare() else { throw RevisionComparisonFailure.selection }
        let location = try restoreLocation(target.path)
        if target.unstageOnly {
            _ = try run(["rm", "--cached", "--ignore-unmatch", "--", target.path])
            return []
        }
        let manager = FileManager.default
        let attributes = try? manager.attributesOfItem(atPath: location.path)
        let type = attributes?[.type] as? FileAttributeType
        guard type == nil || [.typeRegular, .typeSymbolicLink].contains(type!) || target.mode == "160000" && type == .typeDirectory else { throw WorkingFileRestoreFailure.unsupported }
        var trash: [URL] = []
        do {
            if recycle, let type, type != .typeDirectory {
                var moved: NSURL?
                try manager.trashItem(at: location, resultingItemURL: &moved)
                if let moved { trash.append(moved as URL) }
            }
            // The factory pins a hexadecimal commit ID, so it cannot be an
            // option. Older supported Git versions lack checkout's delimiter.
            _ = try run(["checkout", target.revision, "--", target.path])
            return trash
        } catch { throw WorkingFileRevertFailure(gitError: error.localizedDescription, wasCancelled: false, trashedFiles: trash) }
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
        for file in files where seen.insert(file.id).inserted {
            guard !file.path.isEmpty, !file.path.contains("\0") else { throw RevisionComparisonFailure.selection }
            var scoped = entry
            if let index = file.parentIndex {
                guard entry.parents.indices.contains(index) else { throw RevisionComparisonFailure.selection }
                scoped.parents = [entry.parents[index]]
            }
            if let oldPath = file.oldPath {
                var args: [String]
                if workingTree { args = ["diff", "--no-ext-diff", "--no-color", entry.hash] }
                else if let parent = scoped.parents.first { args = ["diff", "--no-ext-diff", "--no-color", parent, entry.hash] }
                else { args = ["show", "--format=", "--no-ext-diff", "--no-color", entry.hash] }
                args += ["--", oldPath, file.path]
                patch.append(try run(args).stdout)
            } else { patch.append(try revisionDiffData(scoped, path: file.path, workingTree: workingTree)) }
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
    /// FillPatchView: whole changes with stats, or selected versioned rows in list order.
    public func logPatchPreviewData(_ entry: LogEntry, files: [CommitFile]? = nil, cancellation: OperationCancellation? = nil) throws -> Data {
        func read(_ args: [String], codes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(args, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], successfulExitCodes: codes, cancellation: cancellation)
        }
        func validHash(_ value: String) -> Bool { (value.count == 40 || value.count == 64) && value.allSatisfy { $0.isASCII && $0.isHexDigit } }
        let working = entry.hash.isEmpty
        let hash: String
        let parents: [String]
        if working {
            guard try read(["rev-parse", "--is-bare-repository"]).text.trimmingCharacters(in: .newlines) != "true" else { throw RevisionComparisonFailure.range }
            let head = try read(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], codes: 0...1)
            if head.exitCode == 1 { return Data() }
            hash = head.text.trimmingCharacters(in: .newlines); parents = []
        } else {
            hash = entry.hash
            guard validHash(hash) else { throw RevisionComparisonFailure.range }
            parents = try read(["show", "--no-patch", "--format=%P", hash, "--"]).text.split(whereSeparator: \.isWhitespace).map(String.init)
            // Upstream's root~1 comparison produces no preview for a root commit.
            if parents.isEmpty { return Data() }
        }
        guard validHash(hash), parents.allSatisfy(validHash) else { throw RevisionComparisonFailure.range }
        let flags = ["--no-ext-diff", "--no-textconv", "--no-color"]
        if let files {
            var output = Data()
            func validPath(_ path: String) -> Bool { !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && !path.split(separator: "/").contains("..") }
            for file in files where file.action != "?" {
                try cancellation?.check()
                guard validPath(file.path), file.oldPath.map(validPath) != false else { throw RevisionComparisonFailure.selection }
                let args: [String]
                if working { args = ["diff"] + flags + [hash, "--"] }
                else {
                    let parent = file.parentIndex ?? 0
                    guard parents.indices.contains(parent) else { throw RevisionComparisonFailure.selection }
                    args = ["diff"] + flags + [parents[parent], hash, "--"]
                }
                output.append(try read(args + (file.oldPath.map { [$0, file.path] } ?? [file.path])).stdout)
            }
            return output
        }
        if working { return try read(["diff", "--stat", "-p"] + flags + [hash, "--"]).stdout }
        return try read(["diff-tree", "-r", "-p", "--stat"] + flags + [parents[0], hash, "--"]).stdout
    }
}
