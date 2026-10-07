import Foundation

public enum LogStatisticsMetric: Int, CaseIterable, Sendable {
    case statistics = 1, commitsByDate = 6, commitsByAuthor = 5, authorship = 4, linesIncluding = 7, linesExcluding = 8
    public var title: String {
        switch self {
        case .statistics: return "Statistics"
        case .commitsByDate: return "Commits by date"
        case .commitsByAuthor: return "Commits by author"
        case .authorship: return "Percent of authorship"
        case .linesIncluding: return "Changed lines including added/deleted files by date"
        case .linesExcluding: return "Changed lines not including added/deleted files by date"
        }
    }
    public var yAxisLabel: String {
        switch self {
        case .statistics: return ""
        case .commitsByDate, .commitsByAuthor: return "commits"
        case .authorship: return "Percents"
        case .linesIncluding: return "Changed lines including added/deleted files"
        case .linesExcluding: return "Changed lines not including added/deleted files"
        }
    }
    public func xAxisLabel(unit: LogStatisticsUnit) -> String {
        if self == .statistics { return "" }
        if self == .commitsByAuthor { return "author" }
        if self == .authorship { return "author (>= 0.5%)" }
        return unit == .quarter ? "quarter of year" : unit.rawValue
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
    public let metric: LogStatisticsMetric
    public let unit: LogStatisticsUnit
    public var xAxisLabel: String { metric.xAxisLabel(unit: unit) }
    public var yAxisLabel: String { metric.yAxisLabel }
    public let categoryLabels: [String]
    public let seriesLabels: [String]
    public let points: [Point]
    public let includedAuthors: [String]
    public let skippedAuthors: [String]
    /// MyGraph truncates each original series average before averaging them.
    /// Original date series hold one interval's authors; author graphs have one
    /// series containing every author. This differs from averaging all points.
    public var averageGuide: Int {
        guard !points.isEmpty else { return 0 }
        if metric.byAuthor { return points.reduce(0) { $0 + $1.value } / points.count }
        guard !categoryLabels.isEmpty, !seriesLabels.isEmpty else { return 0 }
        let totals = Dictionary(grouping: points, by: \.category)
        return categoryLabels.indices.reduce(0) { total, category in
            total + (totals[category] ?? []).reduce(0) { $0 + $1.value } / seriesLabels.count
        } / categoryLabels.count
    }
    public func yAxisMaximum(style: LogStatisticsStyle) -> Int {
        if style == .stackedBar || style == .stackedLine {
            if metric.byAuthor { return max(1, points.reduce(0) { $0 + $1.value }) }
            return max(1, Dictionary(grouping: points, by: \.category).values.map { $0.reduce(0) { $0 + $1.value } }.max() ?? 0)
        }
        return max(1, points.map(\.value).max() ?? 0)
    }
    public func yAxisTicks(style: LogStatisticsStyle) -> [Int] {
        let maximum = yAxisMaximum(style: style)
        var step = 1
        // Equivalent to MyGraph's target-five-ticks 1/2/5 progression, using
        // division in comparisons to avoid overflowing intermediate products.
        while step <= maximum / 50 { step *= 10 }
        if step <= maximum / 25 { step *= 5 }
        if step <= maximum / 10 { step *= 2 }
        return (1...(maximum / step)).map { $0 * step }
    }
    public static func make(_ summary: LogStatisticsSummary, metric: LogStatisticsMetric, authorsShown: Int, alphabetical: Bool = false, calendar: Calendar = .current) throws -> Self {
        if metric == .statistics { return Self(metric: metric, unit: summary.unit, categoryLabels: [], seriesLabels: [], points: [], includedAuthors: [], skippedAuthors: []) }
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
            return Self(metric: metric, unit: summary.unit, categoryLabels: labels, seriesLabels: [metric.title], points: values.enumerated().map { Point(category: $0.offset, series: 0, value: $0.element) }, includedAuthors: included, skippedAuthors: skipped)
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
        return Self(metric: metric, unit: summary.unit, categoryLabels: intervals.map { formatter.string(from: $0.date) }, seriesLabels: labels, points: points, includedAuthors: included, skippedAuthors: skipped)
    }
}
