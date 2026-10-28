import Foundation

/// Original tag objects and recursively peeled targets are distinct metadata.
struct HistoryReferenceObject: Sendable {
    let name: String
    let object: String
    let peeled: String?
    var target: String { peeled ?? object }
}

extension GitRepository {
    /// GetMapHashToFriendName's CLI route uses show-ref -d. Unlike older Git's
    /// for-each-ref *objectname, this peels nested tags all the way to the target.
    func historyReferenceObjects(cancellation: OperationCancellation?) throws -> [HistoryReferenceObject] {
        if let backend=masterReferenceBackend() {
            return try localReferenceCatalog(scope:"labels",backend:backend,cancellation:cancellation).map {HistoryReferenceObject(name:$0.name,object:$0.oid,peeled:$0.peeledOID)}
        }
        let arguments = ["show-ref", "--dereference"]
        let result = try run(arguments, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], successfulExitCodes: 0...1, cancellation: cancellation)
        var objects: [(String, String)] = []
        var peeled: [GitReferenceName: String] = [:]
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
            try cancellation?.check()
            guard let space = line.firstIndex(of: " ") else { throw GitFailure(arguments: arguments, code: -1, message: "Malformed reference output.") }
            let hash = String(line[..<space]), name = String(line[line.index(after: space)...])
            guard (hash.count == 40 || hash.count == 64), hash.allSatisfy({ $0.isASCII && $0.isHexDigit }), name.hasPrefix("refs/") else {
                throw GitFailure(arguments: arguments, code: -1, message: "Malformed reference output.")
            }
            if let plain = GitReferenceName.removingSuffix("^{}", from: name) { peeled[GitReferenceName(plain)] = hash }
            else { objects.append((name, hash)) }
        }
        return objects.map { HistoryReferenceObject(name: $0.0, object: $0.1, peeled: peeled[GitReferenceName($0.0)]) }
    }
}

public struct RevisionReference: Hashable, Sendable {
    public let name: String
    public var isCurrent = false
    public var kind: HistoryReferenceKind?
    public var displayName: String?
    public init(name: String, isCurrent: Bool = false, kind: HistoryReferenceKind? = nil, displayName: String? = nil) { self.name = name; self.isCurrent = isCurrent; self.kind = kind; self.displayName = displayName }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        GitReferenceName.equal(lhs.name, rhs.name) && lhs.isCurrent == rhs.isCurrent && lhs.kind == rhs.kind
            && lhs.displayName.map { GitReferenceName($0) } == rhs.displayName.map { GitReferenceName($0) }
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(GitReferenceName(name)); hasher.combine(isCurrent); hasher.combine(kind)
        hasher.combine(displayName.map { GitReferenceName($0) })
    }
    public var label: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] {
            if let short = GitReferenceName.removingPrefix(prefix, from: name) { return short }
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
        switch reference.kind ?? HistoryReferenceLabel.shortName(reference.name).kind {
        case .localBranch: return .localBranches
        case .remoteBranch: return .remoteBranches
        case .tag, .annotatedTag: return .tags
        case .stash: return .stash
        case .bisectGood, .bisectBad, .bisectSkip: return .bisect
        case .notes, .unknown: return .otherRefs
        }
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
        let raw=(try? HistoricalGitPath.argument(path).bytes) ?? Data(path.utf8)
        let directoryPath = raw.last == 47 ? Data(raw.dropLast()) : raw
        let prefix = isDirectory ? directoryPath + Data([47]) : raw
        func matches(_ candidate: String) -> Bool {
            if isDirectory && file.isSubmodule && ((try? HistoricalGitPath.argument(candidate).bytes) ?? Data(candidate.utf8)) == directoryPath { return true }
            return ((try? HistoricalGitPath.argument(candidate).bytes) ?? Data(candidate.utf8)).starts(with:prefix)
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
/// LogDlgFileFilter matches the current and old Git names as one text record.
public struct HistoryFileFilter {
    private let query: HistoryTextQuery
    public init(_ text: String) { query = HistoryTextQuery(text, caseSensitive: false) }
    public func matches(_ file: CommitFile) -> Bool {
        query.matches(file.displayPath + (file.displayOldPath.map { "\n" + $0 } ?? ""))
    }
}

/// UpdateLogInfoLabel and GetStatisticsString(simple), projected without Git I/O.
public struct HistoryInformation: Equatable, Sendable {
    public let revisionCount: Int, selectedRevisionCount: Int, selectedFileCount: Int
    public let oldest: String, newest: String
    public let addedLines: Int, removedLines: Int, modified: Int, added: Int, deleted: Int, renamed: Int
    public init(entries: [LogEntry], selected: Set<String>, files: [CommitFile], selectedFiles: some Sequence<String>, visibleFileIDs: some Sequence<String>) {
        let start = entries.count > 1 && entries.first?.hash.isEmpty == true ? 1 : 0
        revisionCount = entries.count - start
        newest = entries.indices.contains(start) ? String(entries[start].hash.prefix(8)) : ""
        oldest = entries.last.map { String($0.hash.prefix(8)) } ?? ""
        selectedRevisionCount = entries.filter { selected.contains($0.hash) }.count
        selectedFileCount = selectedRevisionCount > 0 ? GitPathSet(selectedFiles).intersection(visibleFileIDs).count : 0
        func total(_ key: KeyPath<CommitFile, Int?>) -> Int {
            files.reduce(0) { partial, file in
                let value = max(0, file[keyPath: key] ?? 0), next = partial.addingReportingOverflow(value)
                return next.overflow ? Int.max : next.partialValue
            }
        }
        addedLines = total(\.added); removedLines = total(\.removed)
        modified = files.filter { ["M", "R", "T"].contains($0.action.first.map(String.init) ?? "") }.count
        added = files.filter { ["A", "C"].contains($0.action.first.map(String.init) ?? "") }.count
        deleted = files.filter { ["D", "K"].contains($0.action.first.map(String.init) ?? "") }.count
        renamed = files.filter { $0.action.hasPrefix("R") }.count
    }
    public var text: String {
        var value = "Showing \(revisionCount) revision(s), from revision \(oldest) to revision \(newest) - \(selectedRevisionCount) revision(s) selected, \(selectedFileCount) file(s) selected"
        if selectedRevisionCount == 1 {
            value += "; line: \(addedLines)(+) \(removedLines)(-) files: Modified = \(modified) Added = \(added) Deleted = \(deleted) Renamed = \(renamed)"
        }
        return value
    }
}

public enum HistoryWholeProjectPreference {
    public static func key(root: URL) -> String { "LogDialog.ShowWholeProject." + root.standardizedFileURL.path }
    public static func load(root: URL, defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key(root: root)) }
    public static func save(_ value: Bool, root: URL, defaults: UserDefaults = .standard) { defaults.set(value, forKey: key(root: root)) }
}

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
    func matchRanges(in value: String) -> [NSRange] {
        let text = (caseSensitive ? value : value.lowercased()) as NSString
        var ranges: [NSRange] = []
        for condition in conditions where condition.prefix != .andNot {
            var offset = 0
            while offset <= text.length {
                let found = text.range(of: condition.text, options: .literal, range: NSRange(location: offset, length: text.length - offset))
                guard found.location != NSNotFound else { break }
                ranges.append(found); offset = found.location + 1
            }
        }
        return HistoryHighlighting.merge(ranges)
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
/// CFilterData's six stored scales, preserving source order and fixed-day units.
public enum HistoryLimitScale: Int, CaseIterable, Sendable {
    case noLimit, selectedDate, commits, years, months, weeks
    public var requiresNumber: Bool { rawValue >= Self.commits.rawValue }
    public var title: String {
        switch self {
        case .noLimit: return "No limitation"
        case .selectedDate: return "Last selected date"
        case .commits: return "Last N commit(s)"
        case .years: return "Last N year(s)"
        case .months: return "Last N month(s)"
        case .weeks: return "Last N week(s)"
        }
    }
    public func title(number: UInt32) -> String { requiresNumber ? title.replacingOccurrences(of: "N", with: String(Int32(bitPattern: number))) : title }
}
public struct HistoryLimitDefaults: Equatable, Sendable {
    public var scale: HistoryLimitScale = .noLimit
    public var number: UInt32 = 1
    public init(scale: HistoryLimitScale = .noLimit, number: UInt32 = 1) { self.scale = scale; self.number = number }
    public static func load(defaults: UserDefaults = .standard) -> Self {
        Self(scale: HistoryLimitScale(rawValue: defaults.integer(forKey: "LogDialog.NumberOfLogsScale")) ?? .noLimit,
             number: (defaults.object(forKey: "LogDialog.NumberOfLogs") as? NSNumber)?.uint32Value ?? 1)
    }
    /// SetDialogs::OnApply saves the scale, and only a positive _wtol number.
    public static func apply(scale: HistoryLimitScale, numberText: String, defaults: UserDefaults = .standard) {
        defaults.set(scale.rawValue, forKey: "LogDialog.NumberOfLogsScale")
        let number = signedNumber(numberText)
        if scale.requiresNumber && number > 0 { defaults.set(number, forKey: "LogDialog.NumberOfLogs") }
    }
    public static func signedNumber(_ text: String) -> Int32 {
        let units = Array(text.utf8.drop(while: { [9,10,11,12,13,32].contains($0) }))
        var i = 0, negative = false, magnitude: Int64 = 0
        if units.first == 45 || units.first == 43 { negative = units.first == 45; i = 1 }
        let limit = Int64(Int32.max) + (negative ? 1 : 0)
        while i < units.count, (48...57).contains(units[i]) { magnitude = min(limit, magnitude * 10 + Int64(units[i] - 48)); i += 1 }
        return Int32(negative ? -magnitude : magnitude)
    }
    public static func fromDateKey(root: URL) -> String { "History.LogDlg_Limits." + root.standardizedFileURL.path + ".FromDate" }
    private static func dateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter(); var gregorian = Calendar(identifier: .gregorian); gregorian.timeZone = calendar.timeZone
        formatter.calendar = gregorian; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false; return formatter
    }
    public static func savedFrom(root: URL, defaults: UserDefaults = .standard, calendar: Calendar = .current) -> Date? {
        guard let text = defaults.string(forKey: fromDateKey(root: root)), text.count == 10 else { return nil }
        let formatter = dateFormatter(calendar: calendar)
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }; return date
    }
    public static func saveFrom(_ date: Date, root: URL, defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        defaults.set(dateFormatter(calendar: calendar).string(from: date), forKey: fromDateKey(root: root))
    }
}
public struct HistoryLimitScope: Equatable, Sendable {
    public var scale: HistoryLimitScale
    public var number: UInt32
    public var from: Date?
    public var until: Date?
    public init(defaults: HistoryLimitDefaults = HistoryLimitDefaults(), from: Date? = nil, until: Date? = nil) {
        scale = defaults.scale; number = defaults.number; self.from = from; self.until = until
    }
    public func since(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let timestamp: Int64
        switch scale {
        case .noLimit, .commits: return nil
        case .selectedDate: return from.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        case .years, .months, .weeks:
            let days: Int64 = scale == .years ? 365 : scale == .months ? 30 : 7
            // The source casts local midnight to DWORD before signed 64-bit subtraction.
            let midnight = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
            timestamp = Int64(UInt32(truncatingIfNeeded: midnight)) - Int64(number) * days * 86400
        }
        return timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
    }
    public func apply(to options: inout HistoryOptions, now: Date = Date(), calendar: Calendar = .current) {
        options.limit = scale == .commits ? Int(number) : -1
        options.since = since(now: now, calendar: calendar); options.until = until
    }
    public static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date { max(Date(timeIntervalSince1970: 0), calendar.startOfDay(for: date)) }
    public static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        guard date.timeIntervalSince1970 >= 0 else { return Date(timeIntervalSince1970: 0) }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!.addingTimeInterval(-1)
    }
}

/// GetLogCmd's three reference-set masks are distinct from label visibility.
public enum HistoryReferenceScope: String, CaseIterable, Sendable {
    case current, all, basic, local
    public var title: String {
        switch self { case .current: return "HEAD"; case .all: return "All branches"; case .basic: return "All basic refs"; case .local: return "All local branches" }
    }
    public var arguments: [String] {
        switch self {
        case .current: return []
        case .all: return ["--all"]
        case .basic: return ["--branches", "--tags", "--remotes", "--glob=stas[h]", "--glob=bisect"]
        case .local: return ["--branches"]
        }
    }
}

/// LogDlg's per-repository AllBranch setting uses 0/1/2/3 for
/// current/all/local/basic. Keep it independent from reference-label visibility.
public enum HistoryReferenceScopePreference {
    public static func key(root: URL) -> String { "LogDialog.AllBranch." + root.standardizedFileURL.path }
    public static func load(root: URL, defaults: UserDefaults = .standard) -> HistoryReferenceScope {
        switch defaults.integer(forKey: key(root: root)) {
        case 1: return .all
        case 2: return .local
        case 3: return .basic
        default: return .current
        }
    }
    public static func save(_ scope: HistoryReferenceScope, root: URL, defaults: UserDefaults = .standard) {
        let value: Int
        switch scope { case .current: value = 0; case .all: value = 1; case .local: value = 2; case .basic: value = 3 }
        defaults.set(value, forKey: key(root: root))
    }
}

/// Native adaptation of SaveSplitterPos: retain the three pane proportions,
/// then clamp to the source-style minimum content sizes on a different window.
public struct HistoryPaneLayout: Equatable, Sendable {
    public static let key = "LogDialog.PaneLayout.v1"
    public static let minimumHeights: [Double] = [200,110,130]
    public let fractions: [Double]
    public init?(heights: [Double]) {
        guard heights.count == 3, heights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let total = heights.reduce(0,+)
        guard total.isFinite, total > 0 else { return nil }
        let values = heights.map { $0 / total }
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        fractions = values
    }
    public func heights(available: Double) -> [Double] {
        guard available.isFinite, available > 0 else { return [0,0,0] }
        let minimum = Self.minimumHeights, minimumTotal = minimum.reduce(0,+)
        if available < minimumTotal { return minimum.map { $0 * available / minimumTotal } }
        var result = [0.0,0,0], remaining = available, active = Set(0..<3)
        while !active.isEmpty {
            let weight = active.reduce(0.0) { $0 + fractions[$1] }
            let fixed = active.filter { remaining * fractions[$0] / weight < minimum[$0] }
            if fixed.isEmpty {
                for index in active { result[index] = remaining * fractions[index] / weight }
                break
            }
            for index in fixed { result[index] = minimum[index]; remaining -= minimum[index]; active.remove(index) }
        }
        return result
    }
    public static func load(defaults: UserDefaults = .standard) -> Self? {
        guard defaults.integer(forKey: key + ".Version") == 1,
              let values = defaults.array(forKey: key) as? [Double] else { return nil }
        return Self(heights: values)
    }
    public func save(defaults: UserDefaults = .standard) {
        defaults.set(fractions,forKey:Self.key); defaults.set(1,forKey:Self.key + ".Version")
    }
}

/// Browser selections/recents contain Git tokens, never shell command text.
public enum HistoryReferenceSelection: Equatable, Sendable {
    case tips([String]), range(HistoryRevisionRange)
    public init?(expression: String) {
        guard !expression.isEmpty, !expression.contains("\0"), !expression.contains("\n"), !expression.contains("\r") else { return nil }
        let names = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !names.isEmpty else { return nil }
        if names.count == 1 {
            let value = names[0]
            let delimiter = value.contains("...") ? "..." : ".."
            if let split = value.range(of: delimiter) {
                let from = String(value[..<split.lowerBound]), to = String(value[split.upperBound...])
                guard !from.isEmpty, !to.isEmpty, !to.contains("..") else { return nil }
                self = .range(HistoryRevisionRange(from: from, to: to, kind: delimiter == "..." ? .symmetricDifference : .difference)); return
            }
        }
        self = .tips(names)
    }
    public var expression: String {
        switch self { case .tips(let names): return names.joined(separator: " "); case .range(let range): return range.expression }
    }
}

public struct HistoryStartReferences: Equatable, Sendable {
    public let branch: String
    public let fetchHead: String?
    public init(branch: String, fetchHead: String?) { self.branch = branch; self.fetchHead = fetchHead }
}

public struct HistoryOptions: Sendable {
    public var useMailmap = true
    public var ordering: HistoryOrdering = .topological
    public var walk = HistoryWalkOptions()
    public var allBranches = false
    public var referenceScope = HistoryReferenceScope.current
    public var startRevisions: [String] = []
    public var includeBoundaryCommits = false
    /// Log projection needs hidden search rows for lane/rollup state. Limit the
    /// raw Git walk and carry match flags instead of returning only matches.
    public var retainFilteredRows = false
    public var endRevision: String?
    public var revisionRange: HistoryRevisionRange?
    /// Positive limits count rows; zero returns none; negative walks the full scope.
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
    public init(defaults: UserDefaults = .standard) { useMailmap = defaults.object(forKey: "UseMailmap") as? Bool ?? true }
}

public struct CommitFile: Identifiable, Hashable, Codable, Sendable {
    public var id: String { parentIndex.map { "\0parent\($0)\0" + path } ?? path }
    /// Present only for separate occurrences in a merge Log's parent groups.
    public let parentIndex: Int?
    public let path: String
    public let oldPath: String?
    public var displayPath:String { RepositoryBrowserGitPath.display(key:path) }
    public var displayOldPath:String? { oldPath.map { RepositoryBrowserGitPath.display(key:$0) } }
    public var isPathRepresentable:Bool { (try? RepositoryBrowserGitPath(key:path).isRepresentable) == true && (oldPath.map { (try? RepositoryBrowserGitPath(key:$0).isRepresentable) == true } ?? true) }
    public let action: String
    public let added: Int?
    public let removed: Int?
    public let hasStatistics: Bool
    public let isSubmodule: Bool
    /// Captured object provenance supplied by the selected history diff engine.
    public let oldObjectID:String?,newObjectID:String?
    public let oldMode:UInt32?,newMode:UInt32?
    public init(path: String, oldPath: String?, action: String, added: Int?, removed: Int?, hasStatistics: Bool, isSubmodule: Bool, parentIndex: Int? = nil,oldObjectID:String? = nil,newObjectID:String? = nil,oldMode:UInt32? = nil,newMode:UInt32? = nil) {
        self.oldObjectID=oldObjectID;self.newObjectID=newObjectID;self.oldMode=oldMode;self.newMode=newMode
        self.path = path; self.oldPath = oldPath; self.action = action
        self.added = added; self.removed = removed; self.hasStatistics = hasStatistics
        self.isSubmodule = isSubmodule; self.parentIndex = parentIndex
    }
    public static func == (lhs:Self,rhs:Self) -> Bool {
        GitReferenceName.equal(lhs.path,rhs.path) && lhs.oldPath.map { GitReferenceName($0) } == rhs.oldPath.map { GitReferenceName($0) } && lhs.parentIndex == rhs.parentIndex && lhs.action == rhs.action && lhs.added == rhs.added && lhs.removed == rhs.removed && lhs.hasStatistics == rhs.hasStatistics && lhs.isSubmodule == rhs.isSubmodule && lhs.oldObjectID == rhs.oldObjectID && lhs.newObjectID == rhs.newObjectID && lhs.oldMode == rhs.oldMode && lhs.newMode == rhs.newMode
    }
    public func hash(into hasher:inout Hasher) {
        hasher.combine(GitReferenceName(path)); hasher.combine(oldPath.map { GitReferenceName($0) }); hasher.combine(parentIndex)
        hasher.combine(action); hasher.combine(added); hasher.combine(removed); hasher.combine(hasStatistics); hasher.combine(isSubmodule);hasher.combine(oldObjectID);hasher.combine(newObjectID);hasher.combine(oldMode);hasher.combine(newMode)
    }
    public func inParentGroup(_ index: Int) -> Self {
        Self(path: path, oldPath: oldPath, action: action, added: added, removed: removed, hasStatistics: hasStatistics, isSubmodule: isSubmodule, parentIndex: index,oldObjectID:oldObjectID,newObjectID:newObjectID,oldMode:oldMode,newMode:newMode)
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
        let rawRecords=raw.split(separator:0).map { Data($0) }
        var gitlinks=GitPathSet(),cursor=0
        while cursor+1<rawRecords.count {
            let header=String(decoding:rawRecords[cursor],as:UTF8.self).split(separator:" ");cursor+=1
            guard header.count==5,header[0].hasPrefix(":") else { break }
            var bytes=rawRecords[cursor];cursor+=1
            if header[4].hasPrefix("R") || header[4].hasPrefix("C") {
                guard cursor<rawRecords.count else { break };bytes=rawRecords[cursor];cursor+=1
            }
            if let path=HistoricalGitPath.key(bytes),header[1]=="160000" || (header[1]=="000000" && header[0]==":160000") {gitlinks.insert(path)}
        }
        let numbers=statistics.split(separator:0,omittingEmptySubsequences:false).map { Data($0) }
        var stats=GitPathMap<(Int?,Int?)>(),i=0
        while i<numbers.count {
            let parts=numbers[i].split(separator:9,maxSplits:2,omittingEmptySubsequences:false);i+=1
            guard parts.count==3 else {continue}
            var bytes=Data(parts[2])
            if bytes.isEmpty,i+1<numbers.count {bytes=numbers[i+1];i+=2}
            if let path=HistoricalGitPath.key(bytes) {stats[path]=(Int(String(decoding:parts[0],as:UTF8.self)),Int(String(decoding:parts[1],as:UTF8.self)))}
        }
        let records=names.split(separator:0).map { Data($0) };i=0
        var files:[CommitFile]=[]
        while i+1<records.count {
            let action=String(decoding:records[i],as:UTF8.self);i+=1
            var oldPath:String?
            if action.hasPrefix("R") || action.hasPrefix("C") {
                guard i+1<records.count,let old=HistoricalGitPath.key(records[i]) else {break};oldPath=old;i+=1
            }
            guard i<records.count,let path=HistoricalGitPath.key(records[i]) else {break};i+=1
            files.append(CommitFile(path:path,oldPath:oldPath,action:action,added:stats[path]?.0,removed:stats[path]?.1,hasStatistics:stats[path] != nil,isSubmodule:gitlinks.contains(path)))
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

public struct CommitGraphRow: Equatable, Sendable {
    public struct Edge: Equatable, Sendable {
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
    public typealias Projection = (entries: [LogEntry], graph: [CommitGraphRow], rollups: [String: HistoryRollupInfo])
    /// Compression changes only graph copies, never action/detail parent metadata.
    public static func project(_ entries: [LogEntry], walk: HistoryWalkOptions, references: HistoryReferenceVisibility = .all, rollupStates: [String: HistoryRollupChoice] = [:]) -> Projection {
        project(entries, walk: walk, references: references, rollupStates: rollupStates, checkingCancellation: {})
    }
    /// Identical source graph projection with cooperative cancellation. No partial
    /// projection escapes: a retired native owner must await this work's drain.
    public static func project(_ entries: [LogEntry], walk: HistoryWalkOptions, references: HistoryReferenceVisibility = .all, rollupStates: [String: HistoryRollupChoice] = [:], cancellation: OperationCancellation) throws -> Projection {
        try project(entries, walk: walk, references: references, rollupStates: rollupStates, checkingCancellation: { try cancellation.check() })
    }
    static func project(_ entries: [LogEntry], walk: HistoryWalkOptions, references: HistoryReferenceVisibility = .all, rollupStates: [String: HistoryRollupChoice] = [:], checkingCancellation check: () throws -> Void) rethrows -> Projection {
        try check()
        var children: [String: Set<String>] = [:]
        var rollups: [String: HistoryRollupInfo] = [:]
        var expanded = Set<String>(), collapsed = Set<String>()
        let visible = try entries.filter { entry in
            try check()
            if entry.hash.isEmpty { return true }
            for parent in entry.graphParents ?? entry.parents { try check(); children[parent, default: []].insert(entry.hash) }
            let labeled = try entry.isHead || entry.references.contains { try check(); return references.keepsCommit($0) }
            let descendants = children[entry.hash, default: []]
            let fork = descendants.count > 1
            let special = labeled || entry.parents.count > 1 || fork
            var show = walk.graphMode == .all || labeled || walk.graphMode == .compressed && special
            var defaultCollapse = walk.graphMode != .all
            var rolled = defaultCollapse
            if walk.graphMode != .labeled && !rollupStates.isEmpty {
                let child = descendants.count == 1 ? descendants.first : nil
                let childExpanded = child.map { expanded.contains($0) } ?? false
                let childCollapsed = !childExpanded && (child.map { collapsed.contains($0) } ?? false)
                let showAny = walk.graphMode == .all
                show = special || childExpanded || (showAny && !childCollapsed)
                defaultCollapse = (special && !showAny) || (!special && childCollapsed)
                rolled = show ? rollupStates[entry.hash].map { $0 == .collapse } ?? defaultCollapse : defaultCollapse
                if rolled { collapsed.insert(entry.hash) } else { expanded.insert(entry.hash) }
            }
            rollups[entry.hash] = HistoryRollupInfo(collapsed: rolled, forced: rolled != defaultCollapse)
            return show && entry.matchesHistoryFilter
        }
        var visibleHashes = Set<String>()
        for entry in visible { try check(); visibleHashes.insert(entry.hash) }
        var records: [String: LogEntry] = [:]
        for entry in entries {
            try check()
            precondition(records.updateValue(entry, forKey: entry.hash) == nil, "Duplicate history hash")
        }
        func graphParents(_ entry: LogEntry) -> [String] {
            let parents = entry.graphParents ?? entry.parents
            return walk.firstParent ? Array(parents.prefix(1)) : parents
        }
        func nearestVisible(_ origin: String, checkingCancellation check: () throws -> Void) rethrows -> [String] {
            var pending = [origin], seen = Set<String>(), result: [String] = []
            while let hash = pending.popLast() {
                try check()
                guard seen.insert(hash).inserted else { continue }
                if visibleHashes.contains(hash) || records[hash] == nil { result.append(hash) }
                else if let entry = records[hash] {
                    for parent in graphParents(entry).reversed() { try check(); pending.append(parent) }
                }
            }
            return result
        }
        let graphEntries = try visible.map { entry -> LogEntry in
            try check()
            var copy = entry, seen = Set<String>()
            copy.parents = try graphParents(entry).flatMap { try check(); return try nearestVisible($0, checkingCancellation: check) }.filter { try check(); return seen.insert($0).inserted }
            copy.graphParents = nil
            return copy
        }
        // append(hash, visible, firstParent) updates upstream lanes even when
        // visible is false. Preserve each raw row's snapshot before filtering.
        var machine = HistoryLanes()
        var sourceRows: [String: (lanes: [HistoryLane], column: Int)] = [:]
        for entry in entries {
            try check()
            let lanes = try machine.consume(hash: entry.hash, parents: entry.graphParents ?? entry.parents, mergeCommit: entry.parents.count > 1, boundary: entry.isBoundary, firstParent: walk.firstParent, checkingCancellation: check)
            sourceRows[entry.hash] = (lanes,machine.activeLane)
        }
        let mergeCommits = try visible.map { try check(); return $0.parents.count > 1 }
        let rows = try layout(graphEntries, mergeCommits: mergeCommits, firstParent: walk.firstParent, checkingCancellation: check)
        let graph = try zip(visible, rows).map { entry, row in
            try check()
            let snapshot = sourceRows[entry.hash]!
            return CommitGraphRow(column: snapshot.column, color: snapshot.column, lanes: snapshot.lanes,
                junction: entry.parents.count > 1 || children[entry.hash, default: []].count > 1,
                collapsed: rollups[entry.hash]?.collapsed ?? false, edges: row.edges, width: snapshot.lanes.count)
        }
        try check()
        return (visible, graph, rollups)
    }
    public static func layout(_ entries: [LogEntry]) -> [CommitGraphRow] {
        layout(entries, checkingCancellation: {})
    }
    public static func layout(_ entries: [LogEntry], cancellation: OperationCancellation) throws -> [CommitGraphRow] {
        try layout(entries, checkingCancellation: { try cancellation.check() })
    }
    static func layout(_ entries: [LogEntry], checkingCancellation check: () throws -> Void) rethrows -> [CommitGraphRow] {
        let merges = try entries.map { try check(); return $0.parents.count > 1 }
        return try layout(entries, mergeCommits: merges, firstParent: false, checkingCancellation: check)
    }
    private static func layout(_ entries: [LogEntry], mergeCommits: [Bool], firstParent: Bool, checkingCancellation check: () throws -> Void) rethrows -> [CommitGraphRow] {
        try check()
        var source = HistoryLanes()
        var rowIndex = 0
        var lanes: [Lane] = []
        var nextColor = 0
        var childCounts: [String: Int] = [:]
        for entry in entries { try check(); for parent in entry.graphParents ?? entry.parents { try check(); childCounts[parent, default: 0] += 1 } }
        let rows = try entries.map { entry in
            try check()
            let parents = entry.graphParents ?? entry.parents
            let sourceLanes = try source.consume(hash: entry.hash, parents: parents, mergeCommit: mergeCommits[rowIndex], boundary: entry.isBoundary, firstParent: firstParent, checkingCancellation: check)
            let sourceColumn = source.activeLane
            rowIndex += 1
            let hasIncoming = try lanes.contains(where: { try check(); return $0.hash == entry.hash })
            if !hasIncoming {
                lanes.append(Lane(hash: entry.hash, color: nextColor)); nextColor += 1
            }
            let before = lanes
            let column = try lanes.firstIndex { try check(); return $0.hash == entry.hash }!
            let color = lanes[column].color
            lanes.remove(at: column)
            for (index, parent) in parents.enumerated() {
                try check()
                if try lanes.contains(where: { try check(); return $0.hash == parent }) { continue }
                let lane = Lane(hash: parent, color: index == 0 ? color : nextColor)
                if index == 0 { lanes.insert(lane, at: min(column, lanes.count)) }
                else { lanes.append(lane); nextColor += 1 }
            }
            var edges: [CommitGraphRow.Edge] = []
            for (index, lane) in before.enumerated() {
                try check()
                if lane.hash == entry.hash {
                    if hasIncoming { edges.append(.init(from: index, to: column, color: lane.color, startsAtNode: false, endsAtNode: true)) }
                } else if let destination = try lanes.firstIndex(where: { try check(); return $0.hash == lane.hash }) {
                    edges.append(.init(from: index, to: destination, color: lane.color, startsAtNode: false, endsAtNode: false))
                }
            }
            for parent in parents {
                try check()
                if let destination = try lanes.firstIndex(where: { try check(); return $0.hash == parent }) {
                    edges.append(.init(from: column, to: destination, color: lanes[destination].color, startsAtNode: true, endsAtNode: false))
                }
            }
            return CommitGraphRow(column: sourceColumn, color: sourceColumn, lanes: sourceLanes,
                junction: entry.parents.count > 1 || childCounts[entry.hash, default: 0] > 1,
                collapsed: false, edges: edges, width: sourceLanes.count)
        }
        try check()
        return rows
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
/// GitLogList's unified merge menu: an individual parent, -m, -c or --cc.
public enum LogRevisionDiffMode: Equatable, Sendable {
    case firstParent, parent(Int), allParents, combined, extraMergeChanges
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
    public let acceptedBackend:GitLibGit2Configuration?
    public let engine:GitNotesEngineKind?
    public init(revision:String,notesRef:String,text:String,minimumLength:Int,acceptedBackend:GitLibGit2Configuration?=nil,engine:GitNotesEngineKind?=nil) {
        self.revision=revision;self.notesRef=notesRef;self.text=text;self.minimumLength=minimumLength;self.acceptedBackend=acceptedBackend;self.engine=engine
    }
    public var id: String { revision }
    public func accepts(_ text: String) -> Bool { text.utf16.count >= minimumLength && !text.contains("\0") }
}
public enum CommitNoteFailure: LocalizedError {
    case invalidText, minimumLength(Int), savedButRefreshFailed(String), saveOutcomeUnknown(String)
    public var errorDescription: String? {
        switch self {
        case .invalidText: return "The note is not valid UTF-8 text or contains a NUL character."
        case .minimumLength(let size): return "The note must contain at least \(size) characters."
        case .savedButRefreshFailed(let message): return "Notes saved, but the displayed notes could not be refreshed: " + message
        case .saveOutcomeUnknown(let message): return "The note may have been saved. Inspect the note before retrying: " + message
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
                let subject=try singleCommitDetails(revision:parent,cancellation:cancellation).asLogEntry().subject
                choices.append(LogParentChoice(number: index + 1, hash: parent, subject: subject))
            } catch {try cancellation?.check();choices.append(LogParentChoice(number: index + 1, hash: parent)) }
        }
        try cancellation?.check()
        return choices
    }
    /// Source GitRevert: reverse the chosen mainline into index/worktree without committing.
    /// Source multi-selection may include a root even though its single-row menu
    /// is omitted. Keep that allowance explicit; ordinary callers remain strict.
    public func revertLogRevision(revision: String, mainline: Int? = nil, allowRoot:Bool = false, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, backend:GitLibGit2Configuration? = nil) throws -> GitResult {
        try cancellation?.check()
        let executor=try (backend ?? libgit2Configuration ?? .load()).executor(for:.revert)
        guard try run(["rev-parse", "--is-bare-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) != "true" else { throw LogRevertFailure.bare }
        guard try !logMergeActive(cancellation: cancellation) else { throw LogRevertFailure.mergeActive }
        let hash = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        let parents = try run(["show", "-s", "--no-notes", "--format=%P", hash, "--"], cancellation: cancellation).text.split(whereSeparator: \.isWhitespace)
        guard allowRoot || !parents.isEmpty else { throw LogRevertFailure.root }
        if parents.count > 1 { guard let mainline, (1...parents.count).contains(mainline) else { throw LogRevertFailure.parent } }
        else if mainline != nil { throw LogRevertFailure.parent }
        var arguments = ["revert", "--no-edit", "--no-commit"]
        if let mainline { arguments += ["--mainline", String(mainline)] }
        arguments.append(hash)
        return try run(arguments,cancellation:cancellation,onOutput:onOutput,executorOverride:executor)
    }
    /// Source GetGitNotes is unconditional libgit2, independent of command masks.
    /// SHA-256 repositories retain the explicit native Git extension.
    public func editableCommitNote(revision:String,cancellation:OperationCancellation?=nil)throws->CommitNoteSnapshot {
        try cancellation?.check()
        let backend=libgit2Configuration ?? .load(),engine=try notesEngine(cancellation:cancellation)
        let lookupBackend=GitLibGit2Configuration(enabled:engine == .libgit2,mask:backend.mask,helperURL:backend.helperURL)
        guard let hash=try revisionLookup(revision,requirement:.commit,cancellation:cancellation,backend:lookupBackend).objectID else{throw GitNotesEngineFailure.revision}
        let note=try readNotes(revision:hash,ref:nil,engine:engine,backend:backend,cancellation:cancellation)
        let properties=try projectConfiguration(pattern:"^tgit[.]logminsize$",cancellation:cancellation)
        let minimum=max(0,(properties["tgit.logminsize"] as NSString?)?.integerValue ?? 0)
        try cancellation?.check()
        return .init(revision:hash,notesRef:note.notesRef,text:note.text,minimumLength:minimum,acceptedBackend:backend,engine:engine)
    }
    /// The captured ref and revision remain immutable through editing and retry.
    /// A failed write receipt never triggers a second mutation: bounded read-only
    /// recovery distinguishes a completed write from an unknown outcome.
    public func saveCommitNote(_ note:CommitNoteSnapshot,text:String,cancellation:OperationCancellation?=nil)throws->String {
        let token=cancellation ?? OperationCancellation();try token.check()
        guard !text.contains("\0"),text.utf8.count<=16_777_216 else{throw CommitNoteFailure.invalidText}
        guard note.accepts(text) else{throw CommitNoteFailure.minimumLength(note.minimumLength)}
        let backend=note.acceptedBackend ?? libgit2Configuration ?? .load(),engine=try note.engine ?? notesEngine(cancellation:token)
        let expected=Self.notesBlobOID(text,engine:engine)
        let before=try readNotes(revision:note.revision,ref:note.notesRef,engine:engine,backend:backend,cancellation:token)
        do {try writeNotes(revision:note.revision,ref:note.notesRef,text:text,engine:engine,backend:backend,cancellation:token)}
        catch {
            let mutationError=error,recovery=OperationCancellation()
            // Keep the independent reader bounded even when the caller cancelled.
            let deadline=DispatchWorkItem{recovery.cancel()}
            DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+2,execute:deadline)
            defer{deadline.cancel()}
            let after:GitNotesValue,settled:GitNotesValue
            do {
                after=try readNotes(revision:note.revision,ref:note.notesRef,engine:engine,backend:backend,cancellation:recovery)
                settled=try readNotes(revision:note.revision,ref:note.notesRef,engine:engine,backend:backend,cancellation:recovery)
            }catch{throw CommitNoteFailure.saveOutcomeUnknown(mutationError.localizedDescription+"\n\n"+error.localizedDescription)}
            guard after.refOID==settled.refOID,after.blobOID==settled.blobOID,GitReferenceName.equal(after.notesRef,settled.notesRef) else{throw CommitNoteFailure.saveOutcomeUnknown(mutationError.localizedDescription)}
            // An already identical note is not evidence of this write. Preserve
            // a failed signature/pre-write cancellation when nothing published.
            if before.refOID==after.refOID,before.blobOID==after.blobOID,GitReferenceName.equal(before.notesRef,after.notesRef){throw mutationError}
            if before.refOID != after.refOID,after.blobOID==expected{throw CommitNoteFailure.savedButRefreshFailed(mutationError.localizedDescription)}
            throw CommitNoteFailure.saveOutcomeUnknown(mutationError.localizedDescription)
        }
        do{return try readNotes(revision:note.revision,ref:note.notesRef,engine:engine,backend:backend,cancellation:token).text}
        catch{throw CommitNoteFailure.savedButRefreshFailed(error.localizedDescription)}
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
            if try replayMergeBase(from:ancestor,to:descendant,cancellation:cancellation).fastForward { return index }
        }
        try cancellation?.check()
        return nil
    }
    public func history(options: HistoryOptions = HistoryOptions(), cancellation: OperationCancellation? = nil, issueProperties: IssueTrackerProperties? = nil, dateSettings: HistoryDateSettings = .load(), onProgress: (@Sendable (Int) -> Void)? = nil, onBatch: (@Sendable ([LogEntry]) -> Void)? = nil) throws -> [LogEntry] {
        try cancellation?.check()
        func historyRun(_ arguments: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(["-c", "core.precomposeunicode=false"] + arguments, successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }
        if options.limit == 0 { return [] }
        // An unborn HEAD is valid; --all may still have commits in other branches.
        if !options.allBranches && options.referenceScope == .current && options.startRevisions.isEmpty && options.endRevision == nil && options.revisionRange == nil {
            do { _ = try historyRun(["rev-parse", "--verify", "--quiet", "HEAD"]) }
            catch let failure as GitFailure where failure.code == 1 { return [] }
        }
        if options.walk.followRenames {
            let paths = (options.path.map { $0.isEmpty ? [] : [$0] } ?? []) + options.paths
            guard !options.allBranches, options.referenceScope == .current, try canFollowHistory(paths: paths, revision: options.revisionRange?.to ?? options.endRevision ?? options.startRevisions.first, cancellation: cancellation) else { throw HistoryWalkFailure.singleFile }
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
        let filterInMemory = filtering && (options.retainFilteredRows || options.searchRegex || options.searchFields != .messages || query.simpleLiteral == nil)
        let authorName = options.useMailmap ? "%aN" : "%an", authorEmail = options.useMailmap ? "%aE" : "%ae"
        let committerName = options.useMailmap ? "%cN" : "%cn", committerEmail = options.useMailmap ? "%cE" : "%ce"
        let format = "%H%x00%P%x00" + authorName + "%x00" + authorEmail + "%x00%aI%x00%s%x00%B%x00" + committerName + "%x00" + committerEmail + "%x00%cI%x00%m%x00"
        var args = ["log", "--encoding=UTF-8", options.useMailmap ? "--use-mailmap" : "--no-use-mailmap"] + options.ordering.arguments + ["--no-notes", "--format=" + format]
        // Match GetLogCmd: parent rewriting for normal walks, raw full history.
        let rewritesParents = !options.walk.fullHistory
        if options.includeBoundaryCommits { args += ["--left-right", "--boundary"] }
        if rewritesParents { args.append("--parents") }
        if options.walk.firstParent { args.append("--first-parent") }
        if options.walk.noMerges { args.append("--no-merges") }
        if options.walk.followRenames { args += ["--follow", diffDetection.renameArgument] }
        if options.walk.fullHistory { args.append("--full-history") }
        if options.limit > 0 && (options.retainFilteredRows || !filterInMemory) { args.append("-\(options.limit)") }
        if let range = options.revisionRange {
            let from = try historyRun(["rev-parse", "--verify", "--end-of-options", range.from + "^{commit}"]).text.trimmingCharacters(in: .newlines)
            let to = try historyRun(["rev-parse", "--verify", "--end-of-options", range.to + "^{commit}"]).text.trimmingCharacters(in: .newlines)
            args.append(from + range.separator + to)
        } else if let revision = options.endRevision {
            let hash = try historyRun(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
            args.append(hash)
        } else if !options.startRevisions.isEmpty {
            for revision in options.startRevisions {
                let hash = try historyRun(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
                args.append(hash)
            }
        } else { args += (options.allBranches ? HistoryReferenceScope.all : options.referenceScope).arguments }
        if filtering && !filterInMemory {
            args.append("--fixed-strings")
            if !options.searchCaseSensitive { args.append("--regexp-ignore-case") }
            args.append("--grep=" + (query.simpleLiteral ?? options.search))
        }
        if let since = options.since { args.append("--since=@\(Int(since.timeIntervalSince1970))") }
        if let until = options.until { args.append("--until=@\(Int(until.timeIntervalSince1970))") }
        args.append("--")
        var pathArguments:[Int:Data]=[:]
        for key in (options.path.map { $0.isEmpty ? [] : [$0] } ?? []) + options.paths {
            let path=try HistoricalGitPath.argument(key)
            pathArguments[args.count+2]=path.bytes;args.append(path.caption)
        }
        let refObjects = try historyReferenceObjects(cancellation: cancellation)
        var references: [String: [RevisionReference]] = [:]
        var peeledReferenceNames: [String: [String]] = [:]
        var annotatedObjects: [String: [String]] = [:]
        for reference in refObjects {
            try cancellation?.check()
            references[reference.target, default: []].append(RevisionReference(name: reference.name))
            if reference.peeled != nil {
                peeledReferenceNames[reference.target, default: []].append(reference.name + "^{}")
                if reference.name.hasPrefix("refs/tags/") { annotatedObjects[reference.target, default: []].append(reference.object) }
            }
        }
        // Notes are separate payloads: their text can contain NUL bytes, unlike
        // the fields in the commit record. Avoid per-commit work in repositories
        // with no notes refs or notes configuration.
        let notesConfigured = try historyRun(["config", "--get-regexp", "^(core[.]notesref|notes[.]displayref)$"], successfulExitCodes: 0...1).exitCode == 0
        let hasNotes = references.values.contains { $0.contains { $0.name.hasPrefix("refs/notes/") } }
            || notesConfigured || ProcessInfo.processInfo.environment["GIT_NOTES_REF"] != nil
        var metadataEntries:[LogEntry]=[],metadataPositions:[String:Int]=[:]
        func metadataBatch(_ hash:String) -> [LogEntry] {
            guard let index=metadataPositions[hash] else { return [] }
            let start=index/128*128;return Array(metadataEntries[start..<min(start+128,metadataEntries.count)])
        }
        var notesCache:[String:String]=[:],tagCache:[String:String]=[:],pathCache:[String:[String]]=[:]
        func notes(_ hash:String) throws -> String {
            guard hasNotes else { return "" }
            if let value=notesCache[hash] { return value }
            let values=try historyNotes(metadataBatch(hash).map(\.hash),cancellation:cancellation)
            notesCache.merge(values) { _,new in new };return notesCache[hash] ?? ""
        }
        func tagInfo(_ hash:String) throws -> String {
            let objects=annotatedObjects[hash] ?? []
            if objects.contains(where:{ tagCache[$0]==nil }) {
                var seen=Set<String>()
                let pending=metadataBatch(hash).flatMap { annotatedObjects[$0.hash] ?? [] }.filter { tagCache[$0]==nil && seen.insert($0).inserted }
                tagCache.merge(try historyTagObjects(pending,cancellation:cancellation)) { _,new in new }
            }
            return objects.compactMap { tagCache[$0] }.joined(separator:"\n")
        }
        func changedPaths(_ hash:String) throws -> [String] {
            if let value=pathCache[hash] { return value }
            let changes=try revisionChanges(in:metadataBatch(hash),cancellation:cancellation)
            for (hash,files) in changes {
                var paths=Set<GitReferenceName>()
                for file in files { paths.insert(GitReferenceName(file.path));if let old=file.oldPath { paths.insert(GitReferenceName(old)) } }
                pathCache[hash]=paths.map { RepositoryBrowserGitPath.display(key:$0.rawValue) }.sorted()
            }
            return pathCache[hash] ?? []
        }
        let hasBisectRefs = references.values.contains { $0.contains { $0.name.hasPrefix("refs/bisect/") } }
        let bisectTerms = hasBisectRefs ? try historyBisectTerms(cancellation: cancellation) : HistoryBisectTerms()
        let head = try? historyRun(["rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentRef = try? historyRun(["symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
        func label(_ input: LogEntry) -> LogEntry {
            var entry = input
            entry.references = (references[entry.hash] ?? []).map { value in
                var reference = value; reference.isCurrent = currentRef.map { GitReferenceName.equal(value.name, $0) } ?? false
                let short = HistoryReferenceLabel.shortName(value.name, terms: bisectTerms)
                reference.kind = short.kind; reference.displayName = short.text
                if value.name.utf8.starts(with: "refs/tags/".utf8), (peeledReferenceNames[entry.hash] ?? []).contains(where: { GitReferenceName.equal($0, value.name + "^{}") }) { reference.kind = .annotatedTag }
                return reference
            }
            entry.isHead = entry.hash == head
            return entry
        }
        var entries: [LogEntry] = []
        var regexTexts: [String] = [], pending: [LogEntry] = []
        func flush() throws {
            guard !pending.isEmpty else { return }
            try cancellation?.check()
            var ready = pending
            if filtering && options.searchRegex {
                let matches = try IssueRegexRuntime.logMatches(regexTexts, pattern: options.search, caseSensitive: options.searchCaseSensitive, executable: options.regexExecutable, cancellation: cancellation)
                if options.retainFilteredRows { ready = zip(ready, matches).map { item, matches in var item = item; item.matchesHistoryFilter = matches; return item } }
                else { ready = zip(ready, matches).filter { $0.1 }.map { $0.0 } }
            }
            if filtering && filterInMemory && !options.retainFilteredRows && options.limit > 0 { ready = Array(ready.prefix(max(0, options.limit - entries.count))) }
            try cancellation?.check()
            entries += ready; onBatch?(ready)
            pending.removeAll(keepingCapacity: true); regexTexts.removeAll(keepingCapacity: true)
        }
        func consumeRecords(_ records:[LogEntry]) throws {
            for start in stride(from:0,to:records.count,by:128) {
                try cancellation?.check()
                let rawEntries=Array(records[start..<min(start+128,records.count)])
                if filtering && !options.retainFilteredRows && options.limit>0 && entries.count>=options.limit { continue }
                metadataEntries=[];metadataPositions=[:];notesCache=[:];tagCache=[:];pathCache=[:]
                var actualParents: [String: [String]] = [:]
                if rewritesParents {
                    let hashes = rawEntries.map(\.hash)
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
                for raw in rawEntries {
                    try cancellation?.check()
                    metadataPositions[raw.hash] = metadataEntries.count
                    metadataEntries.append(LogEntry(hash: raw.hash, author: "", date: "", subject: "", parents: actualParents[raw.hash] ?? raw.parents))
                }
                for raw in rawEntries {
                    try cancellation?.check()
                    let hash = raw.hash, walkedParents = raw.parents
                    let parents = actualParents[hash] ?? walkedParents
                    var matchesFilter = true
                    if filterInMemory {
                        var searchable: [String] = []
                        let messageParts = LogEntry.splitHistoryMessage(raw.message)
                        if !options.searchFields.intersection([.subject, .messages]).isEmpty { searchable.append(messageParts.subject) }
                        if options.searchFields.contains(.messages) { searchable.append(messageParts.body) }
                        if options.searchFields.contains(.bugIDs) { searchable.append(try issueIDs(hash, message: raw.message)) }
                        if options.searchFields.contains(.authors) { searchable += [raw.author, raw.committer] }
                        if options.searchFields.contains(.emails) { searchable += [raw.email, raw.committerEmail] }
                        if options.searchFields.contains(.revisions) { searchable.append(hash) }
                        if options.searchFields.contains(.notes) { searchable.append(try notes(hash)) }
                        if options.searchFields.contains(.referenceNames) {
                            searchable += (references[hash] ?? []).map(\.name) + (peeledReferenceNames[hash] ?? [])
                        }
                        if options.searchFields.contains(.tagInfo) { searchable.append(dateSettings.tagInfo(try tagInfo(hash))) }
                        if options.searchFields.contains(.paths) { searchable += try changedPaths(hash) }
                        let text = searchable.isEmpty ? "" : searchable.joined(separator: "\n") + "\n"
                        if options.searchRegex { regexTexts.append(text) }
                        else { matchesFilter = query.matches(text); if !matchesFilter && !options.retainFilteredRows { continue } }
                    }
                    var entry = raw; entry.parents = parents
                    entry.matchesHistoryFilter = matchesFilter
                    entry.isBoundary = options.includeBoundaryCommits && raw.isBoundary
                    if rewritesParents { entry.graphParents = walkedParents }
                    entry.issueIDs = try issueIDs(hash, message: raw.message)
                    entry.notes = try notes(hash); entry.tagInfo = try tagInfo(hash); pending.append(label(entry))
                    if pending.count == 128 { try flush() }
                    if filtering && !options.retainFilteredRows && options.limit > 0 && entries.count + (options.searchRegex ? 0 : pending.count) >= options.limit { break }
                }
                try flush()
            }
        }
        let stream=HistoryRecordStream()
        var lastWalkBytes=Date()
        _ = try run(["-c", "core.precomposeunicode=false"] + args,argumentBytes:pathArguments,cancellation:cancellation,retainStandardOutput:false,consumeOutput:{ chunk in
            guard case .stdout=chunk.stream else { return }
            if !chunk.data.isEmpty {
                lastWalkBytes=Date()
                if let count=stream.ingest(chunk.data) { onProgress?(count) }
            }
            // Full batches amortize metadata subprocesses. An idle producer can
            // still publish its short first prefix without waiting for exit.
            let minimum=chunk.data.isEmpty && Date().timeIntervalSince(lastWalkBytes)>=0.1 ? 1 : 128
            while true {
                let ready=try stream.drain(minimum:minimum)
                if ready.isEmpty { break };try consumeRecords(ready)
            }
        })
        try consumeRecords(stream.finish())
        try flush()
        try cancellation?.check()
        return entries
    }
    public func canFollowHistory(paths: [String], revision: String? = nil, cancellation: OperationCancellation? = nil) throws -> Bool {
        try cancellation?.check()
        guard paths.count == 1, let path = paths.first else {return false}
        let rawPath=try HistoricalGitPath.argument(path).bytes
        guard !rawPath.isEmpty,rawPath != Data([46]),rawPath.last != 47 else {return false}
        let bare = try run(["-c", "core.precomposeunicode=false", "rev-parse", "--is-bare-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true"
        if !bare, !path.utf8.contains(0), (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.type] as? FileAttributeType) == .typeDirectory { return false }
        let pinned = try run(["-c", "core.precomposeunicode=false", "rev-parse", "--verify", "--quiet", "--end-of-options", (revision ?? "HEAD") + "^{commit}"], successfulExitCodes: 0...1, cancellation: cancellation)
        if pinned.exitCode == 1 { return true }
        let hash = pinned.text.trimmingCharacters(in: .newlines)
        let tree = try run(["-c", "core.precomposeunicode=false", "ls-tree", "-z", hash, "--", try HistoricalGitPath.argument(path).caption], argumentBytes:[6:try HistoricalGitPath.argument(path).bytes], cancellation: cancellation).stdout
        let record = String(decoding: tree, as: UTF8.self)
        return !record.hasPrefix("040000 ") && !record.hasPrefix("160000 ")
    }
    public func historyPathScopes(paths: [String], revision: String? = nil, cancellation: OperationCancellation? = nil) throws -> [HistoryPathScope] {
        guard !paths.isEmpty else { return [] }
        let bare = try run(["-c", "core.precomposeunicode=false", "rev-parse", "--is-bare-repository"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == "true"
        let pinned = try run(["-c", "core.precomposeunicode=false", "rev-parse", "--verify", "--quiet", "--end-of-options", (revision ?? "HEAD") + "^{commit}"], successfulExitCodes: 0...1, cancellation: cancellation)
        let hash = pinned.text.trimmingCharacters(in: .newlines)
        return try paths.map { path in
            try cancellation?.check()
            let rawPath=try HistoricalGitPath.argument(path).bytes
            var directory = rawPath == Data([46]) || rawPath.last == 47
            if !bare, !path.utf8.contains(0), (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.type] as? FileAttributeType) == .typeDirectory { directory = true }
            if !directory, pinned.exitCode == 0 {
                let record = String(decoding: try run(["-c", "core.precomposeunicode=false", "ls-tree", "-z", hash, "--", try HistoricalGitPath.argument(path).caption], argumentBytes:[6:try HistoricalGitPath.argument(path).bytes], cancellation: cancellation).stdout, as: UTF8.self)
                directory = record.hasPrefix("040000 ") || record.hasPrefix("160000 ")
            }
            return HistoryPathScope(path: path, isDirectory: directory)
        }
    }
    /// Full log clipboard details for a pinned commit, including every parent's
    /// changed paths, Git notes and annotated tags. Use native LF line endings.
    public func commitLogText(revision: String, includePaths: Bool = true, cancellation: OperationCancellation? = nil, dateSettings: HistoryDateSettings = .load(), useMailmap: Bool = true) throws -> String {
        try cancellation?.check()
        func clipboardRun(_ arguments: [String]) throws -> GitResult {
            try cancellation?.check()
            return try run(arguments, cancellation: cancellation)
        }
        let hash = try clipboardRun(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines)
        let format = "%H%x00%P%x00" + (useMailmap ? "%aN%x00%aE" : "%an%x00%ae") + "%x00%aI%x00%s%x00%B%x00"
        let data = try clipboardRun(["show", "--encoding=UTF-8", "-s", "--no-notes", "--format=" + format, hash, "--"]).stdout
        guard let entry = LogEntry.parseHistory(data).first, entry.hash == hash else { throw RevisionComparisonFailure.range }
        var text = "Revision: \(hash)\nAuthor: \(entry.author) <\(entry.email)>\nDate: \(dateSettings.format(entry.date))\nMessage:\n\(entry.message)"
        if !text.hasSuffix("\n") { text += "\n" }
        let notes = try clipboardRun(["show", "--encoding=UTF-8", "-s", "--format=%N", hash, "--"]).text.trimmingCharacters(in: .newlines)
        if !notes.isEmpty { text += "----\nNotes:\n\(notes)\n" }
        for reference in try historyReferenceObjects(cancellation: cancellation) where reference.name.hasPrefix("refs/tags/") && reference.peeled == hash {
            try cancellation?.check()
            let tag = try clipboardRun(["cat-file", "tag", reference.object]).text
            text += "----\nTag info: \(reference.name)\n\(dateSettings.tagInfo(tag))"
            if !text.hasSuffix("\n") { text += "\n" }
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
                text += "\(file.status): \(file.displayPath)"
                if let old = file.oldPath { text += " (from \(RepositoryBrowserGitPath.display(key:old)))" }
                text += "\n"
            }
        }
        try cancellation?.check()
        return text + "\n"
    }
    /// Lightweight name-status union across all parents for the lazy Log Actions column.
    public func revisionActions(in entry: LogEntry, cancellation: OperationCancellation? = nil) throws -> LogRevisionActions {
        try revisionActions(in:[entry],cancellation:cancellation)[entry.hash] ?? LogRevisionActions()
    }
    /// Stop at the first result in source Find order. In particular, do not
    /// fetch paths from later rows merely to find a match in the first row.
    public func findNextHistoryMatch(in entries: [LogEntry], after previous: Int?, query: String,
                                     regex: Bool = false, caseSensitive: Bool = false,
                                     cachedFiles: [String: [CommitFile]] = [:], dateSettings: HistoryDateSettings = .load(),
                                     regexExecutable: URL? = nil, cancellation: OperationCancellation? = nil,backend:GitLibGit2Configuration? = nil) throws -> (index: Int, wrapped: Bool)? {
        try cancellation?.check()
        guard !entries.isEmpty else { return nil }
        let previous = previous.flatMap { entries.indices.contains($0) ? $0 : nil }
        let start = previous.map { $0 + 1 } ?? 0
        let count = entries.count - (previous == nil ? 0 : 1)
        for offset in 0..<count {
            try cancellation?.check()
            let position = start + offset, index = position % entries.count
            let matches = try findHistoryMatches(in: [entries[index]], query: query, regex: regex, caseSensitive: caseSensitive,
                                                 cachedFiles: cachedFiles, dateSettings: dateSettings, regexExecutable: regexExecutable, cancellation: cancellation,backend:backend)
            if matches.first == true { return (index, position >= entries.count) }
        }
        return nil
    }

    /// GitLogListBase::OnFindDialogMessage searches LOGFILTER_ALL in the displayed
    /// batch, independently of the Log filter and without re-walking history.
    /// Cached files retain source rename pairs; uncached rows use the simple
    /// all-parent path list, including root commits. An empty hash is the working row.
    public func findHistoryMatches(in entries: [LogEntry], query: String, regex: Bool = false,
                                  caseSensitive: Bool = false, cachedFiles: [String: [CommitFile]] = [:],
                                  dateSettings: HistoryDateSettings = .load(), regexExecutable: URL? = nil,
                                  cancellation: OperationCancellation? = nil,backend:GitLibGit2Configuration? = nil) throws -> [Bool] {
        let selected=backend ?? libgit2Configuration ?? .load()
        try cancellation?.check()
        guard entries.allSatisfy({ entry in
            entry.hash.isEmpty || ((entry.hash.count == 40 || entry.hash.count == 64) && entry.hash.allSatisfy { $0.isASCII && $0.isHexDigit })
        }) else { throw RevisionComparisonFailure.range }
        let filter = HistoryTextQuery(query, caseSensitive: caseSensitive)
        if !regex && !filter.isActive { return entries.map { _ in true } }
        var texts: [String] = []
        for entry in entries {
            try cancellation?.check()
            let message = LogEntry.splitHistoryMessage(entry.message.isEmpty ? entry.subject : entry.message)
            var fields = [message.subject, message.body, entry.issueIDs, entry.author, entry.committer,
                          entry.email, entry.committerEmail, entry.hash, entry.notes]
            fields += entry.references.map { $0.name + ($0.kind == .annotatedTag ? "^{}" : "") }
            if !entry.references.isEmpty { fields.append(dateSettings.tagInfo(entry.tagInfo)) }
            if let cached = cachedFiles[entry.hash] {
                fields += cached.map { $0.displayPath + "|" + ($0.displayOldPath ?? "") }
            } else if entry.hash.isEmpty {
                let working = try workingTreeHistory(cancellation: cancellation)
                fields += (working?.files ?? []).map { $0.path + "|" + ($0.oldPath ?? "") }
            } else {
                // --no-renames matches SafeGetSimpleList's tree diff: a rename
                // contributes both its deleted old path and added new path.
                if selected.requests(.logListDiff) {
                    fields += try historyDiff(revision:entry.hash,simple:true,backend:selected,cancellation:cancellation).paths.map { RepositoryBrowserGitPath.display(key:$0) }
                } else {
                let paths = try run(["diff-tree", "--root", "-m", "--no-commit-id", "--name-only", "-z", "-r", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color", entry.hash, "--"],
                                    environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout
                fields += paths.split(separator: 0).compactMap { HistoricalGitPath.key(Data($0)) }.map { RepositoryBrowserGitPath.display(key:$0) }
                }
            }
            try cancellation?.check()
            texts.append(fields.joined(separator: "\n") + "\n")
        }
        if regex { return try IssueRegexRuntime.logMatches(texts, pattern: query, caseSensitive: caseSensitive, executable: regexExecutable, cancellation: cancellation) }
        return try texts.map { text in try cancellation?.check(); return filter.matches(text) }
    }

    public func files(in entry: LogEntry, cache: HistoryFileCache? = nil, cancellation: OperationCancellation? = nil,backend:GitLibGit2Configuration? = nil) throws -> [CommitFile] {
        let selected=backend ?? libgit2Configuration ?? .load()
        _ = try selected.executor(for:.logListDiff)
        try cancellation?.check()
        let context = cache.flatMap { _ in try? historyFileCacheContext(entry, cancellation: cancellation,backend:selected) }
        if let cache, let context, let record = cache.read(context.key, cancellation: cancellation), record.context == context.context,
           let attributes = try? historyFileAttributesFingerprint(record.files, info: context.infoAttributes, global: context.globalAttributes, cancellation: cancellation), attributes == record.attributes {
            try cancellation?.check(); return record.files
        }
        try cancellation?.check()
        if selected.requests(.logListDiff) {
            let output=try historyDiff(revision:entry.hash,simple:false,backend:selected,cancellation:cancellation)
            let index:Int
            if let parent=entry.parents.first {guard let found=output.parents.firstIndex(of:parent) else{throw GitDiffEngineFailure.metadata};index=found} else {index=0}
            let files=output.groups[index]
            if let cache,let context,let attributes=try? historyFileAttributesFingerprint(files,info:context.infoAttributes,global:context.globalAttributes,cancellation:cancellation),let settled=try? historyFileCacheContext(entry,cancellation:cancellation,backend:selected),settled.context==context.context {
                cache.write(.init(key:context.key,context:context.context,attributes:attributes,files:files),cancellation:cancellation)
            }
            try cancellation?.check();return files
        }
        var args = ["diff-tree", "--root", "--no-commit-id", "-r"] + diffDetection.historyArguments + ["--no-ext-diff", "--no-color"]
        if let parent = entry.parents.first { args.append(parent) }
        args += [entry.hash, "--"]
        var names = args; names.insert(contentsOf: ["--name-status", "-z"], at: 1)
        var numbers = args; numbers.insert(contentsOf: ["--numstat", "-z"], at: 1)
        var raw = args; raw.insert(contentsOf: ["--raw", "-z"], at: 1)
        let nameData = try run(names, cancellation: cancellation).stdout
        let beforeAttributes = context.flatMap { value in
            try? historyFileAttributesFingerprint(CommitFile.parse(names: nameData, statistics: Data(), raw: Data()),
                info: value.infoAttributes, global: value.globalAttributes, cancellation: cancellation)
        }
        try cancellation?.check()
        let numberData = try run(numbers, cancellation: cancellation).stdout
        try cancellation?.check()
        let rawData = try run(raw, cancellation: cancellation).stdout
        try cancellation?.check()
        let files = CommitFile.parse(names: nameData, statistics: numberData, raw: rawData)
        try cancellation?.check()
        if let cache, let context,
           let attributes = try? historyFileAttributesFingerprint(files, info: context.infoAttributes, global: context.globalAttributes, cancellation: cancellation),
           attributes == beforeAttributes {
            try cancellation?.check()
            // Do not publish results under a configuration/index/tree context
            // which changed while the three Git diff reads were running.
            if let settled = try? historyFileCacheContext(entry, cancellation: cancellation,backend:selected), settled.context == context.context {
                cache.write(.init(key: context.key, context: context.context, attributes: attributes, files: files), cancellation: cancellation)
            }
        }
        try cancellation?.check(); return files
    }
    /// GitRevLoglist::GetFiles reads every actual parent in commit order.
    /// Resolve metadata from the pinned commit rather than a caller's cached
    /// parent list; preserve empty groups and duplicate paths across groups.
    public func logFileGroups(in entry: LogEntry, cache: HistoryFileCache? = nil, cancellation: OperationCancellation? = nil,backend:GitLibGit2Configuration? = nil) throws -> [LogFileGroup] {
        let selected=backend ?? libgit2Configuration ?? .load()
        if selected.requests(.logListDiff) {
            let output=try historyDiff(revision:entry.hash,simple:false,backend:selected,cancellation:cancellation)
            return output.groups.enumerated().map { index,files in
                let parent=output.parents.indices.contains(index) ? output.parents[index]:nil
                var scoped=entry;scoped.parents=parent.map{[$0]} ?? []
                return LogFileGroup(id:index,parent:parent,entry:scoped,files:files)
            }
        }
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
            let changed = try files(in: scoped, cache: cache, cancellation: cancellation,backend:selected)
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
                  group.files.contains(where: { GitReferenceName.equal($0.path, file.path) && $0.oldPath.map { GitReferenceName($0) } == file.oldPath.map { GitReferenceName($0) } && $0.action == file.action }) else { throw RevisionComparisonFailure.selection }
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
    public func revisionFileDiff(_ entry: LogEntry, files: [CommitFile], workingTree: Bool = false,backend:GitLibGit2Configuration? = nil) throws -> String {
        String(decoding: try revisionFileDiffData(entry, files: files, workingTree: workingTree,backend:backend), as: UTF8.self)
    }
    /// Preserve Git's patch bytes for external unified-diff viewers.
    public func revisionFileDiffData(_ entry: LogEntry, files: [CommitFile], workingTree: Bool = false, cancellation: OperationCancellation? = nil,backend:GitLibGit2Configuration? = nil) throws -> Data {
        try cancellation?.check()
        func read(_ args: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(args, successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }

        guard !files.isEmpty else { throw RevisionComparisonFailure.selection }
        var seen = Set<String>(), patch = Data()
        for file in files where seen.insert(file.id).inserted {
            try cancellation?.check()
            guard !file.path.isEmpty else {throw RevisionComparisonFailure.selection}
            try validateComparisonPath(file.path,allowsRaw:!workingTree)
            if let old=file.oldPath {try validateComparisonPath(old,allowsRaw:!workingTree)}
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
                args.insert(contentsOf: workingTree ? diffDetection.comparisonArguments : diffDetection.historyArguments, at: 1)
                args += ["--", oldPath, file.path]
                patch.append(try unifiedDiffData(arguments:args,cancellation:cancellation,backend:backend))
            } else { patch.append(try revisionDiffData(scoped, path: file.path, workingTree: workingTree, cancellation: cancellation,backend:backend)) }
        }
        return patch
    }
    public func revisionDiff(_ entry: LogEntry, path: String? = nil, workingTree: Bool = false,backend:GitLibGit2Configuration? = nil) throws -> String {
        String(decoding: try revisionDiffData(entry, path: path, workingTree: workingTree,backend:backend), as: UTF8.self)
    }
    public func revisionDiffData(_ entry: LogEntry, path: String? = nil, paths: [String] = [], workingTree: Bool = false, mode: LogRevisionDiffMode = .firstParent, cancellation: OperationCancellation? = nil,backend:GitLibGit2Configuration? = nil) throws -> Data {
        try cancellation?.check()
        func read(_ args: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(args, successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }

        var args: [String]
        if workingTree { args = ["diff", "--no-ext-diff", "--no-color", entry.hash] }
        else {
            switch mode {
            case .firstParent:
                if let parent = entry.parents.first { args = ["diff", "--no-ext-diff", "--no-color", parent, entry.hash] }
                else { args = ["show", "--format=", "--no-ext-diff", "--no-color", entry.hash] }
            case .parent(let number):
                guard number > 0, number <= entry.parents.count else { throw RevisionComparisonFailure.selection }
                args = ["diff", "--no-ext-diff", "--no-color", entry.parents[number - 1], entry.hash]
            case .allParents, .combined:
                args = ["diff-tree", "-r", "-p", mode == .allParents ? "-m" : "-c", "--stat", "--no-ext-diff", "--no-color", entry.hash]
            case .extraMergeChanges:
                args = ["diff-tree", "--cc", "--no-ext-diff", "--no-color", entry.hash]
            }
        }
        args.insert(contentsOf: workingTree ? diffDetection.comparisonArguments : diffDetection.historyArguments, at: 1)
        let scope=path.map {[$0]} ?? paths
        for value in scope {try validateComparisonPath(value,allowsRaw:!workingTree)}
        args.append("--"); args += scope
        return try unifiedDiffData(arguments:args,cancellation:cancellation,backend:backend)
    }
    /// FillPatchView: whole changes with stats, or selected versioned rows in list order.
    public func logPatchPreviewData(_ entry: LogEntry, files: [CommitFile]? = nil, cancellation: OperationCancellation? = nil,backend:GitLibGit2Configuration? = nil) throws -> Data {
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
        let flags = ["--no-ext-diff", "--no-textconv", "--no-color"] + (working ? diffDetection.comparisonArguments : diffDetection.historyArguments)
        if let files {
            var output = Data()
            func validPath(_ path:String)->Bool {(try? validateComparisonPath(path,allowsRaw:!working)) != nil}
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
                output.append(try unifiedDiffData(arguments:args + (file.oldPath.map { [$0, file.path] } ?? [file.path]),cancellation:cancellation,backend:backend))
            }
            return output
        }
        if working { return try unifiedDiffData(arguments:["diff", "--stat", "-p"] + flags + [hash, "--"],cancellation:cancellation,backend:backend) }
        return try unifiedDiffData(arguments:["diff-tree", "-r", "-p", "--stat"] + flags + [parents[0], hash, "--"],cancellation:cancellation,backend:backend)
    }
}

/// GitLogListAction ID_COMBINE_COMMIT uses hard/soft reset, forced Amend, then
/// replays commits above the selected range. Keep the original HEAD for recovery.
public struct HistoryCombinePlan: Sendable {
    public let originalHead: String
    public let originalReference: String?
    public let first: String
    public let last: String
    public let lastParentCount: Int
    public let message: String
    public let firstAuthorDate: Date
    public let lastAuthorDate: Date
}
public enum HistoryCombineFailure: LocalizedError {
    case selection, dirty, changed, rollback(String)
    public var errorDescription: String? {
        switch self {
        case .selection: return "Only a continuous range on the checked-out branch can be combined."
        case .dirty: return "Commit or stash tracked changes before combining commits."
        case .changed: return "HEAD or the checked-out branch changed during Combine."
        case .rollback(let detail): return "Restoring the original HEAD failed.\n\n" + detail
        }
    }
}
extension GitRepository {
    /// Check every captured visible row, rather than only the endpoints of a
    /// potentially filtered/nonlinear Log list. Menu checks do not reject dirtiness.
    public func validateHistoryCombineSelection(hashes:[String],firstOffset:Int,expectedHead:String,cancellation:OperationCancellation?=nil) throws -> String? {
        try cancellation?.check()
        guard hashes.count > 1,firstOffset >= 0,!hashes.contains(where:{$0.isEmpty}),try !isBare(cancellation:cancellation),try !logMergeActive(cancellation:cancellation) else { throw HistoryCombineFailure.selection }
        let head=try run(["rev-parse","--verify","HEAD"],cancellation:cancellation).text.trimmingCharacters(in:.newlines)
        guard head == expectedHead else { throw HistoryCombineFailure.changed }
        let reference=try? run(["symbolic-ref","--quiet","HEAD"],cancellation:cancellation).text.trimmingCharacters(in:.newlines)
        for (index,hash) in hashes.enumerated() {
            let actual=try run(["rev-parse","--verify","HEAD~" + String(firstOffset + index)],cancellation:cancellation).text.trimmingCharacters(in:.newlines)
            guard actual == hash else { throw HistoryCombineFailure.selection }
        }
        try cancellation?.check();return reference
    }
    public func prepareHistoryCombine(hashes:[String],firstOffset:Int,expectedHead:String,cancellation:OperationCancellation?=nil) throws -> HistoryCombinePlan {
        let reference=try validateHistoryCombineSelection(hashes:hashes,firstOffset:firstOffset,expectedHead:expectedHead,cancellation:cancellation)
        let head=expectedHead
        guard try replayWorktreeIsClean(stagedOK:false,cancellation:cancellation) else {throw HistoryCombineFailure.dirty}
        guard try validateHistoryCombineSelection(hashes:hashes,firstOffset:firstOffset,expectedHead:expectedHead,cancellation:cancellation)==reference else {throw HistoryCombineFailure.changed}
        let first = hashes[0], last = hashes[hashes.count - 1]
        let parents = try run(["show", "-s", "--no-notes", "--format=%P", last, "--"], cancellation: cancellation).text.split(whereSeparator: \.isWhitespace)
        func date(_ hash: String) throws -> Date {
            let value = try run(["show", "-s", "--no-notes", "--format=%aI", hash, "--"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            guard let date = ISO8601DateFormatter().date(from: value) else { throw HistoryCombineFailure.selection }; return date
        }
        var message = ""
        for hash in hashes {
            let value = try run(["show", "--encoding=UTF-8", "-s", "--no-notes", "--format=%B", hash, "--"], cancellation: cancellation).text
            message += value.hasSuffix("\n") ? value : value + "\n"
        }
        let firstDate = try date(first), lastDate = try date(last)
        try cancellation?.check()
        return HistoryCombinePlan(originalHead: head, originalReference: reference, first: first, last: last, lastParentCount: parents.count, message: message, firstAuthorDate: firstDate, lastAuthorDate: lastDate)
    }
    private func verifyHistoryCombineReference(_ plan: HistoryCombinePlan, cancellation: OperationCancellation? = nil) throws {
        let reference = try? run(["symbolic-ref", "--quiet", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        try cancellation?.check()
        guard reference == plan.originalReference else { throw HistoryCombineFailure.changed }
    }
    public func beginHistoryCombine(_ plan: HistoryCombinePlan, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try verifyHistoryCombineReference(plan, cancellation: cancellation)
        guard try run(["rev-parse", "--verify", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == plan.originalHead else { throw HistoryCombineFailure.changed }
        guard try replayWorktreeIsClean(stagedOK:false,cancellation:cancellation) else {throw HistoryCombineFailure.dirty}
        try verifyHistoryCombineReference(plan,cancellation:cancellation)
        guard try run(["rev-parse","--verify","HEAD"],cancellation:cancellation).text.trimmingCharacters(in:.newlines)==plan.originalHead else {throw HistoryCombineFailure.changed}
        do {
            let output = try run(["reset", "--hard", plan.first, "--"], cancellation: cancellation, onOutput: onOutput).text
            return output + (try run(["reset", "--soft", plan.last, "--"], cancellation: cancellation, onOutput: onOutput).text)
        } catch {
            do { _ = try abortHistoryCombine(plan, onOutput: onOutput) } catch { throw HistoryCombineFailure.rollback(error.localizedDescription) }
            throw error
        }
    }
    public func verifyHistoryCombineAmend(_ plan: HistoryCombinePlan, cancellation: OperationCancellation? = nil) throws {
        try verifyHistoryCombineReference(plan, cancellation: cancellation)
        guard try run(["rev-parse", "--verify", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) == plan.last else { throw HistoryCombineFailure.changed }
    }
    public func finishHistoryCombine(_ plan: HistoryCombinePlan, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try verifyHistoryCombineReference(plan, cancellation: cancellation)
        guard plan.first != plan.originalHead else { return "" }
        let hashes = try run(["rev-list", "--reverse", plan.first + ".." + plan.originalHead, "--"], cancellation: cancellation).text.split(whereSeparator: \.isWhitespace)
        var output = ""
        for hash in hashes { output += try run(["cherry-pick", String(hash)], cancellation: cancellation, onOutput: onOutput).text }
        return output
    }
    public func abortHistoryCombine(_ plan: HistoryCombinePlan, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        // Recovery is intentionally independent of the cancelled worker token.
        try verifyHistoryCombineReference(plan)
        return try run(["reset", "--hard", plan.originalHead, "--"], onOutput: onOutput).text
    }
}

/// SetDialogs / LogDlg::DescribeCommit preferences at the pinned source.
public enum HistoryDescribeStrategy: Int, CaseIterable, Sendable {
    case annotatedTags = 0, allTags = 1, allReferences = 2
    public var title: String {
        switch self { case .annotatedTags: return "Annotated tags"; case .allTags: return "All tags"; case .allReferences: return "All refs" }
    }
}
public struct HistoryDescribeOptions: Equatable, Sendable {
    public var enabled: Bool
    public var strategy: HistoryDescribeStrategy
    public var abbreviatedSize: Int
    public var alwaysLong: Bool
    public var firstParent: Bool
    public init(enabled: Bool = false, strategy: HistoryDescribeStrategy = .annotatedTags, abbreviatedSize: Int = 7, alwaysLong: Bool = false, firstParent: Bool = false) {
        self.enabled = enabled; self.strategy = strategy; self.abbreviatedSize = abbreviatedSize
        self.alwaysLong = alwaysLong; self.firstParent = firstParent
    }
    public static func load(defaults: UserDefaults = .standard) -> Self {
        Self(enabled: defaults.bool(forKey: "ShowDescribe"), strategy: HistoryDescribeStrategy(rawValue: defaults.integer(forKey: "DescribeStrategy")) ?? .annotatedTags,
             abbreviatedSize: (defaults.object(forKey: "DescribeAbbreviatedSize") as? NSNumber)?.intValue ?? 7,
             alwaysLong: defaults.bool(forKey: "DescribeAlwaysLong"), firstParent: defaults.bool(forKey: "DescribeOnlyFollowFirstParent"))
    }
}
extension GitRepository {
    public func describeHistoryCommit(_ hash: String, options: HistoryDescribeOptions, cancellation: OperationCancellation? = nil) throws -> String? {
        guard (hash.count == 40 || hash.count == 64), hash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              (0...64).contains(options.abbreviatedSize) else { throw RevisionComparisonFailure.range }
        try cancellation?.check()
        guard options.enabled else { return nil }
        var arguments = ["describe", "--abbrev=\(options.abbreviatedSize)"]
        if options.strategy == .allTags { arguments.append("--tags") }
        if options.strategy == .allReferences { arguments.append("--all") }
        if options.alwaysLong { arguments.append("--long") }
        if options.firstParent { arguments.append("--first-parent") }
        arguments += [hash]
        let result = try run(arguments, environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], successfulExitCodes: 0...128, cancellation: cancellation)
        // Upstream omits Describe when no matching name can be found.
        guard result.exitCode == 0 else { return nil }
        return result.text.trimmingCharacters(in: .newlines)
    }
}


extension GitRepository {
    public func historyStartReferences(cancellation: OperationCancellation? = nil) throws -> HistoryStartReferences {
        try cancellation?.check()
        let current = try branch(cancellation: cancellation)
        let fetched = try run(["rev-parse", "--verify", "--quiet", "FETCH_HEAD^{commit}"], successfulExitCodes: 0...1, cancellation: cancellation)
        try cancellation?.check()
        return HistoryStartReferences(branch: current, fetchHead: fetched.exitCode == 0 ? fetched.text.trimmingCharacters(in: .newlines) : nil)
    }
}
