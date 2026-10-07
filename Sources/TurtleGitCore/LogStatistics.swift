import Foundation

/// StatGraphDlg defaults. The displayed Log snapshot supplies the revisions;
/// statistics must not silently walk a different range or include a working row.
public struct LogStatisticsOptions: Equatable, Sendable {
    public var caseSensitive = true
    public var sortByCommitCount = true
    public var useCommitterNames = false
    public var useCommitDates = true
    public init() {}
}
public enum LogStatisticsUnit: String, Sendable { case day, week, month, quarter, year }
public struct LogStatisticsChanges: Equatable, Sendable {
    public var files = 0
    public var added = 0
    public var removed = 0
    public var newFileLines = 0
    public var deletedFileLines = 0
    public init() {}
    public init(files: [CommitFile]) {
        self.files = files.count
        for file in files {
            if file.action.first == "D" { deletedFileLines += file.removed ?? 0 }
            else if file.action.first == "A" { newFileLines += file.added ?? 0 }
            else { added += file.added ?? 0; removed += file.removed ?? 0 }
        }
    }
    public var linesWithoutNewDeletedFiles: Int { added + removed }
    public var linesIncludingNewDeletedFiles: Int { added + removed + newFileLines + deletedFileLines }
}
public struct LogStatisticsInterval: Sendable {
    /// Last (oldest) revision in this occupied interval, as in StatGraphDlg.
    public var date: Date
    public var commits: [String: Int] = [:]
    public var fileChanges: [String: Int] = [:]
    public var linesIncludingNewDeletedFiles: [String: Int] = [:]
    public var linesWithoutNewDeletedFiles: [String: Int] = [:]
}
public struct LogStatisticsSummary: Sendable {
    public let unit: LogStatisticsUnit
    public let elapsedDays: Int
    public let elapsedWeeks: Int
    public let totalCommits: Int
    public let changesCalculated: Bool
    public let totalChanges: LogStatisticsChanges
    public let commitsByAuthor: [String: Int]
    public let authorshipPercent: [String: Double]
    public let authorsByActivity: [String]
    public let displayedAuthors: [String]
    public let intervals: [LogStatisticsInterval]
    /// Preserve the source's occupied-interval denominator (last - first,
    /// minimum one), including its integer averages; do not fill calendar gaps.
    public var displayedIntervalCount: Int { intervals.isEmpty ? 0 : max(intervals.count - 1, 1) }
    public var averageCommits: Int { displayedIntervalCount == 0 ? 0 : totalCommits / displayedIntervalCount }
    public var minimumCommits: Int { intervals.map { $0.commits.values.reduce(0, +) }.min() ?? 0 }
    public var maximumCommits: Int { intervals.map { $0.commits.values.reduce(0, +) }.max() ?? 0 }
    public func activity(for author: String) -> (average: Int, minimum: Int, maximum: Int) {
        let values = intervals.map { $0.commits[author] ?? 0 }
        return (displayedIntervalCount == 0 ? 0 : (commitsByAuthor[author] ?? 0) / displayedIntervalCount, values.min() ?? 0, values.max() ?? 0)
    }
}
public enum LogStatisticsFailure: LocalizedError {
    case date(String), revision, incompleteChanges
    public var errorDescription: String? {
        switch self {
        case .date(let hash): return "Could not read the statistics date for revision \(hash)."
        case .revision: return "Statistics require actual commit revisions."
        case .incompleteChanges: return "Calculate file changes for every analyzed revision before showing totals."
        }
    }
}

public enum LogStatistics {
    public static func analyze(_ entries: [LogEntry], options: LogStatisticsOptions = LogStatisticsOptions(), changes: [String: LogStatisticsChanges]? = nil, calendar: Calendar = .current, cancellation: OperationCancellation? = nil) throws -> LogStatisticsSummary {
        try cancellation?.check()
        let parser = ISO8601DateFormatter()
        let fractionalParser = ISO8601DateFormatter(); fractionalParser.formatOptions.insert(.withFractionalSeconds)
        if let changes, entries.contains(where: { $0.parents.count <= 1 && changes[$0.hash] == nil }) { throw LogStatisticsFailure.incompleteChanges }
        var dated: [(Int, LogEntry, Date)] = []
        for (index, entry) in entries.enumerated() {
            try cancellation?.check()
            let text = options.useCommitDates ? entry.committerDate : entry.date
            guard let date = parser.date(from: text) ?? fractionalParser.date(from: text) else { throw LogStatisticsFailure.date(entry.hash) }
            dated.append((index, entry, date))
        }
        dated.sort { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }
        let span = dated.isEmpty ? 0 : dated.first!.2.timeIntervalSince(dated.last!.2)
        let days = Int(ceil(span / 86400)), weeks = Int(ceil(span / 604800))
        let unit: LogStatisticsUnit = days < 8 ? .day : weeks < 15 ? .week : weeks < 80 ? .month : weeks < 320 ? .quarter : .year
        func key(_ date: Date) -> Int {
            switch unit {
            case .day: return calendar.component(.month, from: date) * 100 + calendar.component(.day, from: date)
            case .week: return calendar.component(.weekOfYear, from: date)
            case .month: return calendar.component(.month, from: date)
            case .quarter: return (calendar.component(.month, from: date) - 1) / 3 + 1
            case .year: return calendar.component(.year, from: date)
            }
        }
        var totals = LogStatisticsChanges(), authors: [String: Int] = [:], contribution: [String: Double] = [:], intervals: [LogStatisticsInterval] = []
        var previousKey: Int?
        for (position, value) in dated.enumerated() {
            try cancellation?.check()
            let entry = value.1, date = value.2
            var author = options.useCommitterNames ? entry.committer : entry.author
            if author.isEmpty { author = "(unknown)" }
            if !options.caseSensitive { author = author.lowercased() }
            // Upstream Calculate deliberately skips merge diffs.
            let delta = entry.parents.count > 1 ? LogStatisticsChanges() : changes?[entry.hash] ?? LogStatisticsChanges()
            let dateKey = key(date)
            if previousKey != dateKey { intervals.append(LogStatisticsInterval(date: date)) }
            previousKey = dateKey
            let index = intervals.count - 1
            intervals[index].date = date
            intervals[index].commits[author, default: 0] += 1
            intervals[index].fileChanges[author, default: 0] += delta.files
            intervals[index].linesIncludingNewDeletedFiles[author, default: 0] += delta.linesIncludingNewDeletedFiles
            intervals[index].linesWithoutNewDeletedFiles[author, default: 0] += delta.linesWithoutNewDeletedFiles
            authors[author, default: 0] += 1
            let distance = dated.count - position - 1
            let coefficient = distance == 0 ? 1 : Double(distance) / 2
            contribution[author, default: 0] += coefficient * Double(delta.files == 0 ? 1 : delta.files)
            totals.files += delta.files; totals.added += delta.added; totals.removed += delta.removed
            totals.newFileLines += delta.newFileLines; totals.deletedFileLines += delta.deletedFileLines
        }
        let totalContribution = contribution.values.reduce(0, +)
        let percentages = contribution.mapValues { totalContribution == 0 ? 0 : $0 * 100 / totalContribution }
        func alphabetical(_ left: String, _ right: String) -> Bool { left.utf16.lexicographicallyPrecedes(right.utf16) }
        let ranking = authors.keys.sorted { authors[$0] == authors[$1] ? alphabetical($0, $1) : authors[$0]! > authors[$1]! }
        try cancellation?.check()
        return LogStatisticsSummary(unit: unit, elapsedDays: days, elapsedWeeks: weeks, totalCommits: entries.count, changesCalculated: changes != nil, totalChanges: totals, commitsByAuthor: authors, authorshipPercent: percentages, authorsByActivity: ranking, displayedAuthors: options.sortByCommitCount ? ranking : authors.keys.sorted(by: alphabetical), intervals: intervals)
    }
}

extension GitRepository {
    /// Calculate against the accepted Log snapshot, with owned cancellation and
    /// no publication of a partial cache after failure/cancellation.
    public func logStatisticsChanges(_ entries: [LogEntry], cancellation: OperationCancellation? = nil, progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> [String: LogStatisticsChanges] {
        try cancellation?.check()
        func valid(_ hash: String) -> Bool { (hash.count == 40 || hash.count == 64) && hash.allSatisfy { $0.isASCII && $0.isHexDigit } }
        guard entries.allSatisfy({ valid($0.hash) && $0.parents.allSatisfy(valid) }) else { throw LogStatisticsFailure.revision }
        var result: [String: LogStatisticsChanges] = [:]
        for (index, entry) in entries.enumerated() {
            try cancellation?.check()
            if result[entry.hash] == nil { result[entry.hash] = entry.parents.count > 1 ? LogStatisticsChanges() : LogStatisticsChanges(files: try files(in: entry, cancellation: cancellation)) }
            progress?(index + 1, entries.count)
            try cancellation?.check()
        }
        return result
    }
}
