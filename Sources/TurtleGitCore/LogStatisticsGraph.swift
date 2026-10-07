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
public struct LogStatisticsColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
}
public struct LogStatisticsGraph: Sendable {
    public struct Point: Sendable {
        public let category: Int
        public let series: Int
        public let value: Int
    }
    public struct Bar: Sendable {
        public let point: Point
        public let left: Double
        public let right: Double
        public let bottom: Double
        public let top: Double
        public func contains(x: Double, y: Double) -> Bool { x >= left && x < right && y >= bottom && y <= top }
    }
    public let metric: LogStatisticsMetric
    public let unit: LogStatisticsUnit
    public var xAxisLabel: String { metric.xAxisLabel(unit: unit) }
    public var yAxisLabel: String { metric.yAxisLabel }
    /// The source palette is independent of appearance; its disabled light-mode
    /// line-color alternative is intentionally not enabled here.
    public var colors: [LogStatisticsColor] {
        let count = metric.byAuthor ? categoryLabels.count : seriesLabels.count
        guard count > 0 else { return [] }
        let delta = 240 / count
        return (0..<count).map { group in
            let hue = delta * group, lum = 120 + 60 * (group % 2)
            let sat = 180 + 30 * ((1 - group % 2) * (group % 3))
            let magic2 = lum <= 120 ? (lum * (240 + sat) + 120) / 240 : lum + sat - (lum * sat + 120) / 240
            let magic1 = 2 * lum - magic2
            func channel(_ hue: Int) -> UInt8 {
                // Preserve the source WORD conversion before its range check.
                var value = Int(UInt16(truncatingIfNeeded: hue))
                if value > 240 { value -= 240 }
                let hls: Int
                if value < 40 { hls = magic1 + ((magic2 - magic1) * value + 20) / 40 }
                else if value < 120 { hls = magic2 }
                else if value < 160 { hls = magic1 + ((magic2 - magic1) * (160 - value) + 20) / 40 }
                else { hls = magic1 }
                return UInt8((hls * 255 + 120) / 240)
            }
            return LogStatisticsColor(red: channel(hue + 80), green: channel(hue), blue: channel(hue - 80))
        }
    }
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
    private var originalSeries: [[Point]] {
        if metric.byAuthor { return [points.sorted { $0.category < $1.category }] }
        let groups = Dictionary(grouping: points, by: \.category)
        return categoryLabels.indices.map { (groups[$0] ?? []).sorted { $0.series < $1.series } }
    }
    public var populatedBarSeries: [[Point]] { originalSeries.map { $0.filter { $0.value > 0 } }.filter { !$0.isEmpty } }
    public var legendLabels: [String] { metric.byAuthor ? categoryLabels : seriesLabels }
    public var pieCategories: [Int] { populatedBarSeries.map { metric.byAuthor ? 0 : $0[0].category } }
    /// MyGraph preserves the last group (often Others), replacing the penultimate
    /// visible row with dots. A lone omitted group is shown rather than elided.
    public func legendGroupIndices(capacity: Int) -> [Int?] {
        let count = legendLabels.count
        guard count > 0, capacity > 0 else { return [] }
        let shown = min(count, capacity + (capacity == count - 1 ? 1 : 0))
        if shown == count { return (0..<count).map { Optional($0) } }
        return (0..<shown).map { row in
            if row == shown - 2 { return nil }
            return row == shown - 1 ? count - 1 : row
        }
    }
    public func barLayout(stacked: Bool) -> [Bar] {
        let rows = populatedBarSeries
        guard let maximumGroups = rows.map(\.count).max(), maximumGroups > 0 else { return [] }
        let plotSize = stacked || rows.count > 1 ? 0.85 : 1.0
        let width = stacked ? plotSize : plotSize / Double(maximumGroups)
        var bars: [Bar] = []
        for (slot, row) in rows.enumerated() {
            var left = Double(slot + 1) - plotSize
            var base = 0.0
            for point in row {
                let top = base + Double(point.value)
                bars.append(Bar(point: point, left: left, right: left + width, bottom: base, top: top))
                if stacked { base = top } else { left += width }
            }
        }
        return bars
    }
    public var barLabels: [String] {
        populatedBarSeries.map { row in metric.byAuthor ? "" : categoryLabels[row[0].category] }
    }
    public func tooltip(for point: Point) -> String {
        let name = metric.byAuthor ? categoryLabels[point.category] : seriesLabels[point.series]
        let total = points.filter { metric.byAuthor || $0.category == point.category }.reduce(0) { $0 + $1.value }
        let percent = total == 0 ? 0 : Int(100.0 * Double(point.value) / Double(total))
        return "\(name): \(point.value) \(yAxisLabel) (\(percent)%)"
    }
    public func averageTooltip(style: LogStatisticsStyle) -> String {
        let percent = Int(100.0 * Double(averageGuide) / Double(yAxisMaximum(style: style)))
        return "Average: \(averageGuide) \(yAxisLabel) (\(percent)%)"
    }
    /// The native Canvas uses the same left-start, counterclockwise progression
    /// as WedgeEndFromDegrees. Coordinates are normalized to the pie radius.
    public func piePoint(category: Int, x: Double, y: Double) -> Point? {
        guard x.isFinite, y.isFinite, x*x + y*y <= 1 else { return nil }
        let wedges = points.filter { (metric.byAuthor || $0.category == category) && $0.value > 0 }
        let total = wedges.reduce(0) { $0 + $1.value }
        guard total > 0 else { return nil }
        var angle = Double.pi - atan2(y, x)
        if angle >= 2 * .pi { angle -= 2 * .pi }
        let target = angle / (2 * .pi) * Double(total)
        var running = 0.0
        for point in wedges { running += Double(point.value); if target < running { return point } }
        return wedges.last
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
