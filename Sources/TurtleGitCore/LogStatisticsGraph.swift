import Foundation

public enum LogStatisticsMetric: Int, CaseIterable, Sendable {
    case statistics = 1, commitsByDate = 6, commitsByAuthor = 5, authorship = 4, linesIncluding = 7, linesExcluding = 8
    public var title: String {
        switch self {
        case .statistics: return "Statistics"
        case .commitsByDate: return "Commits by date"
        case .commitsByAuthor: return "Commits by author"
        case .authorship: return "Percentage of authorship"
        case .linesIncluding: return "Lines changed by date including added/deleted files"
        case .linesExcluding: return "Lines changed by date excluding added/deleted files"
        }
    }
    public var needsChanges: Bool { [.authorship, .linesIncluding, .linesExcluding].contains(self) }
    public var byAuthor: Bool { self == .commitsByAuthor || self == .authorship }
}
public enum LogStatisticsStyle: Int, CaseIterable, Sendable { case stackedBar = 1, bar = 2, stackedLine = 3, line = 4, pie = 5 }
public struct LogStatisticsGraph: Sendable {
    public struct Point: Sendable {
        public let category: Int
        public let series: Int
        public let value: Int
    }
    public let categoryLabels: [String]
    public let seriesLabels: [String]
    public let points: [Point]
    public let includedAuthors: [String]
    public let skippedAuthors: [String]
    public static func make(_ summary: LogStatisticsSummary, metric: LogStatisticsMetric, authorsShown: Int, alphabetical: Bool = false, calendar: Calendar = .current) throws -> Self {
        if metric == .statistics { return Self(categoryLabels: [], seriesLabels: [], points: [], includedAuthors: [], skippedAuthors: []) }
        if metric.needsChanges && !summary.changesCalculated { throw LogStatisticsFailure.incompleteChanges }
        let round: (Double) -> Int = { Int($0.rounded(.toNearestOrAwayFromZero)) }
        var ranked = summary.authorsByActivity
        if metric == .authorship {
            ranked = summary.authorshipPercent.keys.filter { round(summary.authorshipPercent[$0]!) != 0 }.sorted {
                summary.authorshipPercent[$0] == summary.authorshipPercent[$1] ? $0.utf16.lexicographicallyPrecedes($1.utf16) : summary.authorshipPercent[$0]! > summary.authorshipPercent[$1]!
            }
        }
        var count = min(max(1, authorsShown), min(250, ranked.count))
        if count + 1 == ranked.count { count += 1 } // Source names the last lone author.
        var included = Array(ranked.prefix(count)); let skipped = Array(ranked.dropFirst(count))
        if alphabetical { included.sort { $0.utf16.lexicographicallyPrecedes($1.utf16) } }
        let labels = included + (skipped.isEmpty ? [] : ["Others (\(skipped.count))"])
        if metric.byAuthor {
            let value: (String) -> Int = { metric == .authorship ? round(summary.authorshipPercent[$0] ?? 0) : summary.commitsByAuthor[$0] ?? 0 }
            let values = included.map(value) + (skipped.isEmpty ? [] : [skipped.map(value).reduce(0, +)])
            return Self(categoryLabels: labels, seriesLabels: [metric.title], points: values.enumerated().map { Point(category: $0.offset, series: 0, value: $0.element) }, includedAuthors: included, skippedAuthors: skipped)
        }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        switch summary.unit {
        case .day: formatter.setLocalizedDateFormatFromTemplate("yyMd")
        case .week: formatter.dateFormat = "w/YY"
        case .month: formatter.dateFormat = "M/yy"
        case .quarter: formatter.dateFormat = "Q/yy"
        case .year: formatter.dateFormat = "yyyy"
        }
        let intervals = Array(summary.intervals.reversed())
        var points: [Point] = []
        for (category, interval) in intervals.enumerated() {
            let values: [String: Int]
            switch metric {
            case .linesIncluding: values = interval.linesIncludingNewDeletedFiles
            case .linesExcluding: values = interval.linesWithoutNewDeletedFiles
            default: values = interval.commits
            }
            for (series, author) in included.enumerated() { points.append(Point(category: category, series: series, value: values[author] ?? 0)) }
            if !skipped.isEmpty { points.append(Point(category: category, series: included.count, value: skipped.reduce(0) { $0 + (values[$1] ?? 0) })) }
        }
        return Self(categoryLabels: intervals.map { formatter.string(from: $0.date) }, seriesLabels: labels, points: points, includedAuthors: included, skippedAuthors: skipped)
    }
}
