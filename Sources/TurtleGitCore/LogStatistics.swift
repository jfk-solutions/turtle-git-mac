import Foundation

public enum StatisticsGraphFormat:String,CaseIterable,Sendable {
    case pdf,png,jpeg,bmp,gif
    public var fileExtension:String {self == .jpeg ? "jpg":rawValue}
    public init?(fileExtension:String) {
        switch fileExtension.lowercased() {case "jpg","jpeg":self = .jpeg;default:guard let value=Self(rawValue:fileExtension.lowercased()) else{return nil};self=value}
    }
}
public enum StatisticsGraphExportFilter:String,CaseIterable,Sendable {case pictures,allFiles}
public enum StatisticsGraphDestinationFailure:LocalizedError,Sendable {
    case destination,metafile
    public var errorDescription:String? {
        switch self {
        case .destination:return "Choose a file for the statistics graph."
        case .metafile:return "WMF and EMF statistics export are unavailable on macOS. Choose PDF for a vector graph."
        }
    }
}
/// StatGraphDlg's filename chooses the encoder. Pictures defaults to PDF as the
/// native replacement for its Windows enhanced-metafile default.
public struct StatisticsGraphExportDestination:Sendable {
    public let url:URL
    public let format:StatisticsGraphFormat
    public init(url:URL,filter:StatisticsGraphExportFilter = .allFiles)throws {
        guard url.isFileURL,!url.hasDirectoryPath else{throw StatisticsGraphDestinationFailure.destination}
        let filename=try Self.normalizedFilename(url.lastPathComponent,filter:filter)
        self.url=filename.utf8.elementsEqual(url.lastPathComponent.utf8) ? url:url.deletingLastPathComponent().appendingPathComponent(filename)
        guard let format=Self.suffix(filename).flatMap({StatisticsGraphFormat(fileExtension:$0)}) else{throw StatisticsGraphDestinationFailure.destination}
        self.format=format
    }
    public static func normalizedFilename(_ filename:String,filter:StatisticsGraphExportFilter = .allFiles)throws->String {
        guard !filename.isEmpty,filename != ".",filename != "..",!filename.contains("/"),!filename.contains("\0") else{throw StatisticsGraphDestinationFailure.destination}
        var value=filename
        if !value.utf8.contains(46),filter == .pictures {value += ".pdf"}
        let extensionName=suffix(value)?.lowercased()
        if extensionName == "wmf" || extensionName == "emf" {throw StatisticsGraphDestinationFailure.metafile}
        if extensionName.flatMap({StatisticsGraphFormat(fileExtension:$0)}) == nil {value += ".jpg"}
        return value
    }
    private static func suffix(_ filename:String)->String? {
        guard let dot=filename.utf8.lastIndex(of:46) else{return nil}
        return String(decoding:filename.utf8[filename.utf8.index(after:dot)...],as:UTF8.self)
    }
}

/// StatGraphDlg uses std::wstring author keys. Swift String equality instead
/// merges canonical Unicode spellings, even when Authors case sensitive is on.
/// Keep the original valid UTF-8 namespace while ordering by UTF-16 as upstream.
public struct LogStatisticsAuthor: Hashable, Comparable, Sendable, Identifiable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name:String
    public init(_ name:String){self.name=name}
    public init(stringLiteral value:String){name=value}
    public var id:String{"log-author:"+Data(name.utf8).base64EncodedString()}
    public var description:String{name}
    public static func ==(_ lhs:Self,_ rhs:Self)->Bool{GitReferenceName.equal(lhs.name,rhs.name)}
    public static func <(_ lhs:Self,_ rhs:Self)->Bool{lhs.name.utf16.lexicographicallyPrecedes(rhs.name.utf16)}
    public func hash(into hasher:inout Hasher){hasher.combine(GitReferenceName(name))}
}

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
    public var commits: [LogStatisticsAuthor: Int] = [:]
    public var fileChanges: [LogStatisticsAuthor: Int] = [:]
    public var linesIncludingNewDeletedFiles: [LogStatisticsAuthor: Int] = [:]
    public var linesWithoutNewDeletedFiles: [LogStatisticsAuthor: Int] = [:]
}
public struct LogStatisticsSummary: Sendable {
    public let unit: LogStatisticsUnit
    public let elapsedDays: Int
    public let elapsedWeeks: Int
    public let totalCommits: Int
    public let changesCalculated: Bool
    public let totalChanges: LogStatisticsChanges
    public let commitsByAuthor: [LogStatisticsAuthor: Int]
    public let authorshipPercent: [LogStatisticsAuthor: Double]
    public let authorsByActivity: [LogStatisticsAuthor]
    public let displayedAuthors: [LogStatisticsAuthor]
    public let intervals: [LogStatisticsInterval]
    /// Preserve the source's occupied-interval denominator (last - first,
    /// minimum one), including its integer averages; do not fill calendar gaps.
    public var displayedIntervalCount: Int { intervals.isEmpty ? 0 : max(intervals.count - 1, 1) }
    public var averageCommits: Int { displayedIntervalCount == 0 ? 0 : totalCommits / displayedIntervalCount }
    public var minimumCommits: Int { intervals.map { $0.commits.values.reduce(0, +) }.min() ?? 0 }
    public var maximumCommits: Int { intervals.map { $0.commits.values.reduce(0, +) }.max() ?? 0 }
    public func activity(for author: LogStatisticsAuthor) -> (average: Int, minimum: Int, maximum: Int) {
        let values = intervals.map { $0.commits[author] ?? 0 }
        return (displayedIntervalCount == 0 ? 0 : (commitsByAuthor[author] ?? 0) / displayedIntervalCount, values.min() ?? 0, values.max() ?? 0)
    }
    /// String callers still perform an exact lookup, never a String-keyed map.
    public func activity(for author:String)->(average:Int,minimum:Int,maximum:Int){activity(for:LogStatisticsAuthor(author))}
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
        var totals = LogStatisticsChanges(), authors: [LogStatisticsAuthor: Int] = [:], contribution: [LogStatisticsAuthor: Double] = [:], intervals: [LogStatisticsInterval] = []
        var previousKey: Int?
        for (position, value) in dated.enumerated() {
            try cancellation?.check()
            let entry = value.1, date = value.2
            var authorName = options.useCommitterNames ? entry.committer : entry.author
            if authorName.isEmpty { authorName = "(unknown)" }
            // Match the source's explicit lowercasing option, not canonical
            // equivalence or case-insensitive/diacritic-insensitive comparison.
            if !options.caseSensitive { authorName = authorName.lowercased() }
            let author=LogStatisticsAuthor(authorName)
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
        func alphabetical(_ left: LogStatisticsAuthor, _ right: LogStatisticsAuthor) -> Bool { left < right }
        let ranking = authors.keys.sorted { authors[$0] == authors[$1] ? alphabetical($0, $1) : authors[$0]! > authors[$1]! }
        try cancellation?.check()
        return LogStatisticsSummary(unit: unit, elapsedDays: days, elapsedWeeks: weeks, totalCommits: entries.count, changesCalculated: changes != nil, totalChanges: totals, commitsByAuthor: authors, authorshipPercent: percentages, authorsByActivity: ranking, displayedAuthors: options.sortByCommitCount ? ranking : authors.keys.sorted(by: alphabetical), intervals: intervals)
    }
}

extension GitRepository {
    /// Calculate against the accepted Log snapshot, with owned cancellation and
    /// no publication of a partial cache after failure/cancellation.
    public func logStatisticsChanges(_ entries: [LogEntry], cancellation: OperationCancellation? = nil, progress: (@Sendable (Int, Int) -> Void)? = nil,backend:GitLibGit2Configuration? = nil) throws -> [String: LogStatisticsChanges] {
        try cancellation?.check()
        func valid(_ hash: String) -> Bool { (hash.count == 40 || hash.count == 64) && hash.allSatisfy { $0.isASCII && $0.isHexDigit } }
        guard entries.allSatisfy({ valid($0.hash) && $0.parents.allSatisfy(valid) }) else { throw LogStatisticsFailure.revision }
        let backend=backend ?? libgit2Configuration ?? .load()
        var result: [String: LogStatisticsChanges] = [:]
        for (index, entry) in entries.enumerated() {
            try cancellation?.check()
            if result[entry.hash] == nil { result[entry.hash] = entry.parents.count > 1 ? LogStatisticsChanges() : LogStatisticsChanges(files: try files(in: entry, cancellation: cancellation,backend:backend)) }
            progress?(index + 1, entries.count)
            try cancellation?.check()
        }
        return result
    }
}
