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
}
