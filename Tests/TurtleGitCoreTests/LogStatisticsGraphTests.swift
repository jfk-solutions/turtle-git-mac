import XCTest
@testable import TurtleGitCore

final class LogStatisticsGraphTests: XCTestCase {
    private func summary(_ counts: [String: Int]) throws -> LogStatisticsSummary {
        var entries: [LogEntry] = []
        for author in counts.keys.sorted() {
            for index in 0..<counts[author]! { entries.append(LogEntry(hash: author + String(index), author: author, date: "2024-01-01T12:00:00Z", subject: "", committerDate: "2024-01-01T12:00:00Z")) }
        }
        return try LogStatistics.analyze(entries, changes: Dictionary(uniqueKeysWithValues: entries.map { ($0.hash, LogStatisticsChanges()) }))
    }
    func testAuthorSliderHintUsesActivityAndLoneAuthorException() throws {
        let summary = try summary(["Z": 5, "A": 3, "B": 2, "C": 1])
        XCTAssertEqual(summary.authorSliderHint(limit: 2, metric: .commitsByDate), "2 most active author(s) with at least 3 commits each (27 %)")
        XCTAssertEqual(summary.authorSliderHint(limit: 3, metric: .commitsByAuthor), "3 most active author(s) with at least 1 commits each (9 %)")
        XCTAssertEqual(summary.authorSliderHint(limit: Int.max, metric: .commitsByDate), "4 most active author(s) with at least 1 commits each (9 %)")
        XCTAssertEqual(summary.authorSliderHint(limit: Int.min, metric: .commitsByDate), "1 most active author(s) with at least 5 commits each (45 %)")
        let empty = try LogStatistics.analyze([])
        XCTAssertEqual(empty.authorSliderHint(limit: 1, metric: .commitsByDate), "1 most active author(s) with at least 0 commits each (0 %)")
    }
    func testAuthorshipSliderUsesContributionRankingButCommitThreshold() throws {
        let summary = try summary(["A": 1, "B": 4, "C": 2, "D": 3])
        let ranked = summary.rankedAuthors(for: .authorship)
        XCTAssertEqual(Set(ranked), Set(["A", "B", "C", "D"].map { LogStatisticsAuthor($0) }))
        let commits = try XCTUnwrap(summary.commitsByAuthor[ranked[1]])
        XCTAssertEqual(summary.authorSliderHint(limit: 2, metric: .authorship), "2 most active author(s) with at least \(commits) commits each (\(commits * 10) %)")
        let graph = try LogStatisticsGraph.make(summary, metric: .authorship, authorsShown: 2)
        XCTAssertEqual(graph.includedAuthors, Array(ranked.prefix(2)))
    }

    func testSelectsMostActiveBeforeAlphabeticalAndNamesLastLoneAuthor() throws {
        let summary = try summary(["Z": 5, "A": 3, "B": 2, "C": 1])
        let graph = try LogStatisticsGraph.make(summary, metric: .commitsByAuthor, authorsShown: 2, alphabetical: true)
        XCTAssertEqual(graph.includedAuthors, ["A", "Z"]); XCTAssertEqual(graph.skippedAuthors, ["B", "C"])
        XCTAssertEqual(graph.categoryLabels, ["A", "Z", "Others (2)"])
        XCTAssertEqual(graph.points.map(\.value), [3, 5, 3])
        let last = try LogStatisticsGraph.make(summary, metric: .commitsByAuthor, authorsShown: 3)
        XCTAssertEqual(last.includedAuthors.count, 4); XCTAssertTrue(last.skippedAuthors.isEmpty)
    }
    func testDateSeriesAreOldestFirstAndPreserveOthersAndZeroValues() throws {
        let entries = [LogEntry(hash: "a", author: "A", date: "2024-01-01T12:00:00Z", subject: "", committerDate: "2024-01-01T12:00:00Z"), LogEntry(hash: "b", author: "B", date: "2024-01-03T12:00:00Z", subject: "", committerDate: "2024-01-03T12:00:00Z")]
        let summary = try LogStatistics.analyze(entries)
        let graph = try LogStatisticsGraph.make(summary, metric: .commitsByDate, authorsShown: 1)
        XCTAssertEqual(graph.seriesLabels, ["A", "B"])
        XCTAssertEqual(graph.points.map(\.value), [1, 0, 0, 1])
        XCTAssertEqual(graph.categoryLabels.count, 2); XCTAssertNotEqual(graph.categoryLabels[0], graph.categoryLabels[1])
        XCTAssertThrowsError(try LogStatisticsGraph.make(summary, metric: .authorship, authorsShown: 1))
        XCTAssertThrowsError(try LogStatisticsGraph.make(summary, metric: .linesIncluding, authorsShown: 1))
    }
    func testAuthorshipRoundsEachAuthorBeforeSummingOthers() throws {
        let summary = try summary(["A": 2, "B": 1, "C": 1, "D": 1])
        let graph = try LogStatisticsGraph.make(summary, metric: .authorship, authorsShown: 1)
        XCTAssertEqual(graph.skippedAuthors.count, 3)
        let rounded = graph.skippedAuthors.map { Int(summary.authorshipPercent[$0]!.rounded(.toNearestOrAwayFromZero)) }.reduce(0, +)
        XCTAssertEqual(graph.points.last?.value, rounded)
        XCTAssertEqual(graph.includedAuthors[0], summary.authorshipPercent.max { $0.value < $1.value }!.key)
    }
    func testAverageGuideTruncatesEachOriginalIntervalSeries() throws {
        let entries = [
            LogEntry(hash: "a", author: "A", date: "2024-01-01T12:00:00Z", subject: "", committerDate: "2024-01-01T12:00:00Z"),
            LogEntry(hash: "b", author: "A", date: "2024-01-02T12:00:00Z", subject: "", committerDate: "2024-01-02T12:00:00Z"),
            LogEntry(hash: "c", author: "A", date: "2024-01-02T12:00:00Z", subject: "", committerDate: "2024-01-02T12:00:00Z"),
            LogEntry(hash: "d", author: "B", date: "2024-01-02T12:00:00Z", subject: "", committerDate: "2024-01-02T12:00:00Z")
        ]
        let summary = try LogStatistics.analyze(entries)
        let dates = try LogStatisticsGraph.make(summary, metric: .commitsByDate, authorsShown: 2)
        XCTAssertEqual(dates.averageGuide, 0) // (1 / 2 + 3 / 2) / 2, not 4 / 4.
        let authors = try LogStatisticsGraph.make(summary, metric: .commitsByAuthor, authorsShown: 2)
        XCTAssertEqual(authors.averageGuide, 2)
        let empty = try LogStatisticsGraph.make(LogStatistics.analyze([]), metric: .commitsByDate, authorsShown: 1)
        XCTAssertEqual(empty.averageGuide, 0)
    }

    func testIntegerTicksUseStackTotalsForAuthorStackAndSourceStepBoundaries() throws {
        let values = try summary(["A": 5, "B": 3, "C": 2, "D": 1])
        let graph = try LogStatisticsGraph.make(values, metric: .commitsByAuthor, authorsShown: 4)
        XCTAssertEqual(graph.yAxisMaximum(style: .bar), 5)
        XCTAssertEqual(graph.yAxisTicks(style: .bar), [1, 2, 3, 4, 5])
        XCTAssertEqual(graph.yAxisMaximum(style: .stackedBar), 11)
        XCTAssertEqual(graph.yAxisTicks(style: .stackedBar), [2, 4, 6, 8, 10])
        let larger = try LogStatisticsGraph.make(summary(["A": 25, "B": 25]), metric: .commitsByAuthor, authorsShown: 2)
        XCTAssertEqual(larger.yAxisTicks(style: .bar), [5, 10, 15, 20, 25])
        XCTAssertEqual(larger.yAxisTicks(style: .stackedBar), [10, 20, 30, 40, 50])
        let empty = try LogStatisticsGraph.make(LogStatistics.analyze([]), metric: .commitsByDate, authorsShown: 1)
        XCTAssertEqual(empty.yAxisTicks(style: .bar), [1])
    }

    func testPaletteMatchesPinnedCppReferenceIncludingHighAuthorCounts() throws {
        struct Reference: Decodable { let count: Int; let colors: [[Int]] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let reference = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: root.appendingPathComponent("docs/qa/statistics-palette-reference-2026-10-07.json")))
        for item in reference {
            let authors = Dictionary(uniqueKeysWithValues: (0..<item.count).map { (String(format: "A%04d", $0), 1) })
            let graph = try LogStatisticsGraph.make(summary(authors), metric: .commitsByAuthor, authorsShown: item.count)
            XCTAssertEqual(graph.colors.map { [Int($0.red), Int($0.green), Int($0.blue)] }, item.colors, "Pinned C++ palette for \(item.count) groups")
        }
    }

    func testSourceBarSlotsOmitZeroSeriesAndUseSharedWidthAndStackBases() throws {
        let entries = [
            LogEntry(hash: "a", author: "A", date: "2024-01-01T12:00:00Z", subject: "", committerDate: "2024-01-01T12:00:00Z"),
            LogEntry(hash: "b", author: "B", date: "2024-01-02T12:00:00Z", subject: "", committerDate: "2024-01-02T12:00:00Z"),
            LogEntry(hash: "c", author: "A", date: "2024-01-03T12:00:00Z", subject: "", committerDate: "2024-01-03T12:00:00Z"),
            LogEntry(hash: "d", author: "B", date: "2024-01-03T12:00:00Z", subject: "", committerDate: "2024-01-03T12:00:00Z")
        ]
        var cache: [String: LogStatisticsChanges] = [:]
        for (hash, lines) in [("a", 2), ("b", 0), ("c", 1), ("d", 3)] { var item = LogStatisticsChanges(); item.added = lines; cache[hash] = item }
        let graph = try LogStatisticsGraph.make(LogStatistics.analyze(entries, changes: cache), metric: .linesIncluding, authorsShown: 2)
        let bars = graph.barLayout(stacked: false)
        XCTAssertEqual(graph.pieCategories, [0, 2]); XCTAssertEqual(bars.count, 3); XCTAssertEqual(graph.barLabels, [graph.categoryLabels[0], graph.categoryLabels[2]])
        XCTAssertEqual(bars[0].left, 0.15, accuracy: 0.000001); XCTAssertEqual(bars[0].right, 0.575, accuracy: 0.000001)
        XCTAssertEqual(bars[2].left, 1.575, accuracy: 0.000001); XCTAssertEqual(bars[2].right, 2, accuracy: 0.000001)
        XCTAssertTrue(bars[0].contains(x: 0.2, y: 1)); XCTAssertFalse(bars[0].contains(x: 0.1, y: 1))
        let stacked = graph.barLayout(stacked: true)
        XCTAssertEqual(stacked[2].left, 1.15, accuracy: 0.000001); XCTAssertEqual(stacked[2].bottom, 1); XCTAssertEqual(stacked[2].top, 4)
        XCTAssertEqual(graph.tooltip(for: bars[1].point), "A: 1 Changed lines including added/deleted files (25%)")
        XCTAssertEqual(graph.averageTooltip(style: .bar), "Average: 1 Changed lines including added/deleted files (33%)")
        XCTAssertEqual(graph.piePoint(category: 2, x: -0.5, y: 0.5)?.series, 0)
        XCTAssertEqual(graph.piePoint(category: 2, x: 0.5, y: 0.5)?.series, 1)
        XCTAssertNil(graph.piePoint(category: 1, x: 0, y: 0)); XCTAssertNil(graph.piePoint(category: 2, x: 1.01, y: 0))
    }
    func testAuthorBarsFillOneSlotAndTooltipDenominatorUsesDisplayedAuthors() throws {
        let graph = try LogStatisticsGraph.make(summary(["A": 3, "B": 1]), metric: .commitsByAuthor, authorsShown: 2)
        let bars = graph.barLayout(stacked: false)
        XCTAssertEqual(graph.barLabels, [""]); XCTAssertEqual(bars[0].left, 0); XCTAssertEqual(bars[0].right, 0.5)
        XCTAssertEqual(bars[1].right, 1); XCTAssertEqual(graph.tooltip(for: bars[0].point), "A: 3 commits (75%)")
        let stack = graph.barLayout(stacked: true)
        XCTAssertEqual(stack[0].left, 0.15, accuracy: 0.000001); XCTAssertEqual(stack[1].bottom, 3); XCTAssertEqual(stack[1].top, 4)
    }

    func testLegendKeepsFinalGroupAndDoesNotElideOneOmittedGroup() throws {
        let graph = try LogStatisticsGraph.make(summary(["A": 8, "B": 7, "C": 6, "D": 5, "E": 4]), metric: .commitsByAuthor, authorsShown: 5)
        XCTAssertEqual(graph.legendGroupIndices(capacity: 3), [0, nil, 4])
        XCTAssertEqual(graph.legendGroupIndices(capacity: 4), [0, 1, 2, 3, 4])
        XCTAssertEqual(graph.legendGroupIndices(capacity: 1), [4])
        XCTAssertEqual(graph.legendGroupIndices(capacity: 0), [])
        XCTAssertEqual(graph.pieCategories, [0])
    }

}

extension LogStatisticsGraphTests {
    func testExactAuthorIdentityProjectsEveryMetricAndPreservesSyntheticOthers() throws {
        let names = ["Others (2)", "\u{00E9}va", "e\u{0301}va", "Z"]
        var entries: [LogEntry] = [], changes: [String: LogStatisticsChanges] = [:]
        for (index, count) in [5,4,3,2].enumerated() {
            for occurrence in 0..<count {
                let hash = "identity-\(index)-\(occurrence)", date = occurrence % 2 == 0 ? "2024-01-02T12:00:00Z" : "2024-01-01T12:00:00Z"
                entries.append(LogEntry(hash:hash,author:names[index],date:date,subject:"",committerDate:date))
                var delta = LogStatisticsChanges(); delta.files = index + 1; delta.added = 10 * (index + 1); delta.removed = index; delta.newFileLines = 3
                changes[hash] = delta
            }
        }
        let value = try LogStatistics.analyze(entries, changes: changes)
        XCTAssertEqual(value.commitsByAuthor.count, 4)
        for metric in LogStatisticsMetric.allCases where metric != .statistics {
            let full = try LogStatisticsGraph.make(value, metric:metric, authorsShown:4, alphabetical:true)
            XCTAssertEqual(Set(full.includedAuthors.map(\.id)).count, 4)
            XCTAssertEqual(full.includedAuthors.map { Data($0.name.utf8) }, names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.map { Data($0.utf8) })
            for point in full.points {
                let author = full.includedAuthors[metric.byAuthor ? point.category : point.series]
                let expected: Int
                if metric == .commitsByAuthor { expected = value.commitsByAuthor[author]! }
                else if metric == .authorship { expected = Int(value.authorshipPercent[author]!.rounded(.toNearestOrAwayFromZero)) }
                else {
                    let interval = Array(value.intervals.reversed())[point.category]
                    switch metric {
                    case .linesIncluding: expected = interval.linesIncludingNewDeletedFiles[author] ?? 0
                    case .linesExcluding: expected = interval.linesWithoutNewDeletedFiles[author] ?? 0
                    default: expected = interval.commits[author] ?? 0
                    }
                }
                XCTAssertEqual(point.value, expected)
                XCTAssertTrue(Data(full.tooltip(for:point).utf8).starts(with:Data((author.name+":").utf8)))
            }
            let limited = try LogStatisticsGraph.make(value, metric:metric, authorsShown:2)
            XCTAssertEqual(limited.includedAuthors.count, 2); XCTAssertEqual(limited.skippedAuthors.count, 2)
            XCTAssertEqual(Set((limited.includedAuthors+limited.skippedAuthors).map(\.id)).count, 4)
            XCTAssertEqual(limited.points.reduce(0) { $0+$1.value }, full.points.reduce(0) { $0+$1.value })
        }
        let collisions = try LogStatisticsGraph.make(value, metric:.commitsByAuthor, authorsShown:2)
        XCTAssertEqual(collisions.categoryLabels, ["Others (2)",names[1],"Others (2)"])
        XCTAssertEqual(collisions.points.map(\.value), [5,4,5])
        XCTAssertEqual(collisions.includedAuthors.map { Data($0.name.utf8) }, names.prefix(2).map { Data($0.utf8) })
    }
}
