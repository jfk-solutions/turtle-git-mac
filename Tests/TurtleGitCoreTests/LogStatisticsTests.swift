import XCTest
@testable import TurtleGitCore

final class LogStatisticsTests: XCTestCase {
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4; return value }
    private func entry(_ hash: String, _ author: String, _ date: String, committer: String = "Integrator", commitDate: String? = nil, parents: [String] = []) -> LogEntry {
        LogEntry(hash: hash, author: author, date: date, subject: hash, parents: parents, committer: committer, committerDate: commitDate ?? date)
    }
    func testDefaultNamesDatesCaseGroupingRankingAndLegacyOccupiedIntervals() throws {
        let entries = [entry("a", "Alice", "2024-01-01T12:00:00Z", commitDate: "2024-01-03T12:00:00Z"), entry("b", "alice", "2024-01-01T12:00:00Z", commitDate: "2024-01-03T10:00:00Z"), entry("c", "", "2024-01-02T12:00:00Z")]
        let summary = try LogStatistics.analyze(entries, calendar: calendar)
        XCTAssertEqual(summary.unit, .day); XCTAssertEqual(summary.totalCommits, 3)
        XCTAssertEqual(summary.commitsByAuthor, ["Alice": 1, "alice": 1, "(unknown)": 1])
        XCTAssertEqual(summary.intervals.count, 2); XCTAssertEqual(summary.displayedIntervalCount, 1)
        XCTAssertEqual(summary.averageCommits, 3); XCTAssertEqual(summary.minimumCommits, 1); XCTAssertEqual(summary.maximumCommits, 2)
        XCTAssertFalse(summary.changesCalculated)
        // Source weighting from newest to oldest for three commits: 1, 0.5, 1.
        XCTAssertEqual(summary.authorshipPercent["alice"]!, 20, accuracy: 0.0001)
        var options = LogStatisticsOptions(); options.caseSensitive = false; options.useCommitDates = false
        let authors = try LogStatistics.analyze(entries, options: options, calendar: calendar)
        XCTAssertEqual(authors.commitsByAuthor["alice"], 2); XCTAssertEqual(authors.authorsByActivity.first, "alice")
        XCTAssertEqual(authors.activity(for: "alice").minimum, 0)
        options.sortByCommitCount = false
        XCTAssertEqual(try LogStatistics.analyze(entries, options: options, calendar: calendar).displayedAuthors, ["(unknown)", "alice"])
        options.useCommitterNames = true
        XCTAssertEqual(try LogStatistics.analyze(entries, options: options, calendar: calendar).commitsByAuthor, ["integrator": 3])
    }
    func testLazyDiffCategoriesBinaryAndMergeExclusion() throws {
        let files = [CommitFile(path: "new", oldPath: nil, action: "A", added: 5, removed: 0, hasStatistics: true, isSubmodule: false), CommitFile(path: "deleted", oldPath: nil, action: "D", added: 0, removed: 7, hasStatistics: true, isSubmodule: false), CommitFile(path: "renamed", oldPath: "old", action: "R100", added: 2, removed: 3, hasStatistics: true, isSubmodule: false), CommitFile(path: "binary", oldPath: nil, action: "M", added: nil, removed: nil, hasStatistics: true, isSubmodule: false)]
        let delta = LogStatisticsChanges(files: files)
        XCTAssertEqual(delta.files, 4); XCTAssertEqual(delta.linesWithoutNewDeletedFiles, 5); XCTAssertEqual(delta.linesIncludingNewDeletedFiles, 17)
        let entries = [entry("a", "Alice", "2024-01-01T12:00:00Z"), entry("b", "Bob", "2024-01-01T13:00:00Z", parents: ["x", "y"])]
        let summary = try LogStatistics.analyze(entries, changes: ["a": delta, "b": delta], calendar: calendar)
        XCTAssertThrowsError(try LogStatistics.analyze(entries, changes: [:], calendar: calendar))
        XCTAssertTrue(summary.changesCalculated); XCTAssertEqual(summary.totalChanges, delta)
        XCTAssertEqual(summary.totalCommits, 2); XCTAssertEqual(summary.intervals[0].fileChanges["Bob"], 0)
        XCTAssertEqual(summary.authorshipPercent.values.reduce(0, +), 100, accuracy: 0.0001)
    }
    func testAllUnitThresholdsEmptyMalformedAndCancellation() throws {
        let start = ISO8601DateFormatter().date(from: "2020-01-01T12:00:00Z")!
        for (days, unit) in [(7, LogStatisticsUnit.day), (8, .week), (105, .month), (560, .quarter), (2240, .year)] {
            let date = ISO8601DateFormatter().string(from: start.addingTimeInterval(Double(days) * 86400))
            let result = try LogStatistics.analyze([entry("a", "A", "2020-01-01T12:00:00Z"), entry("b", "B", date)], calendar: calendar)
            XCTAssertEqual(result.unit, unit); XCTAssertEqual(result.elapsedDays, days)
        }
        let empty = try LogStatistics.analyze([], calendar: calendar)
        XCTAssertEqual(empty.totalCommits, 0); XCTAssertEqual(empty.averageCommits, 0); XCTAssertTrue(empty.intervals.isEmpty)
        XCTAssertThrowsError(try LogStatistics.analyze([entry("bad", "A", "invalid")]))
        let cancellation = OperationCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try LogStatistics.analyze([], cancellation: cancellation))
    }
    func testActualRenameDeleteBinaryAndMergeMeasurementRules() async throws {
        let (root, fixture, tracked) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixture.executable
        let repo = GitRepository(root: root, executable: executable)
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        for name in ["added", "delete-me"] { try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent(name)) }
        try Data([0, 255, 1]).write(to: root.appendingPathComponent("binary"))
        try await repo.stage(["added", "delete-me", "binary"]); _ = try await repo.commit(message: "add files")
        let branch = try await repo.run(["symbolic-ref", "--short", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["branch", "side"])
        _ = try await repo.run(["mv", "--", tracked, "renamed"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("delete-me"))
        try Data("one\ntwo\nthree\n".utf8).write(to: root.appendingPathComponent("added"))
        try Data([0, 255, 2]).write(to: root.appendingPathComponent("binary"))
        _ = try await repo.run(["add", "-A"]); _ = try await repo.commit(message: "change files")
        let entries = try await repo.history()
        let changes = try await repo.logStatisticsChanges(entries)
        let delta = changes[entries[0].hash]!
        XCTAssertEqual(delta.files, 4); XCTAssertEqual(delta.deletedFileLines, 2)
        XCTAssertEqual(delta.newFileLines, 0); XCTAssertEqual(delta.added, 1); XCTAssertEqual(delta.removed, 0)
        let summary = try LogStatistics.analyze(entries, changes: changes, calendar: calendar)
        XCTAssertEqual(summary.totalChanges.files, 8); XCTAssertEqual(summary.totalChanges.linesWithoutNewDeletedFiles, 1)
        XCTAssertEqual(summary.totalChanges.linesIncludingNewDeletedFiles, 37)
        _ = try await repo.run(["checkout", "side"])
        try Data("side\n".utf8).write(to: root.appendingPathComponent("side-file")); try await repo.stage(["side-file"]); _ = try await repo.commit(message: "side")
        _ = try await repo.run(["checkout", branch]); _ = try await repo.run(["merge", "--no-ff", "--no-gpg-sign", "-m", "merge", "side"])
        let merged = try await repo.history(); XCTAssertEqual(merged[0].parents.count, 2)
        let mergedChanges = try await repo.logStatisticsChanges(merged)
        XCTAssertEqual(mergedChanges[merged[0].hash], LogStatisticsChanges())
    }
    func testRealCommitCalculationPreservesRepositoryAndCancellationPublishesNoCache() async throws {
        let (root, fixture, tracked) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixture.executable
        let repo = GitRepository(root: root, executable: executable)
        try Data("changed\n".utf8).write(to: root.appendingPathComponent(tracked))
        try await repo.stage([tracked]); _ = try await repo.commit(message: "change")
        let entries = try await repo.history()
        let metadata = [".git/index", ".git/config", ".git/HEAD", tracked]
        let before = try metadata.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let changes = try await repo.logStatisticsChanges(entries)
        XCTAssertEqual(Set(changes.keys), Set(entries.map(\.hash)))
        let summary = try LogStatistics.analyze(entries, changes: changes, calendar: calendar)
        XCTAssertEqual(summary.totalChanges.files, 2); XCTAssertGreaterThan(summary.totalChanges.linesIncludingNewDeletedFiles, 0)
        let cancellation = OperationCancellation()
        do { _ = try await repo.logStatisticsChanges(entries, cancellation: cancellation) { _, _ in cancellation.cancel() }; XCTFail("Cancellation ignored") } catch is OperationCancellationFailure {}
        do { _ = try await repo.logStatisticsChanges([entry("working-copy", "A", "2024-01-01T12:00:00Z")]); XCTFail("Working row accepted") } catch LogStatisticsFailure.revision {}
        let after = try metadata.map { try Data(contentsOf: root.appendingPathComponent($0)) }; XCTAssertEqual(before, after)
    }
}

extension LogStatisticsTests {
    func testExactAuthorSpellingSurvivesCaseOptionsIntervalsAndContribution() throws {
        let names = ["\u{00C9}va", "E\u{0301}va", "\u{00E9}va", "e\u{0301}va"]
        XCTAssertEqual(names[0], names[1], "Fixture must exercise Swift canonical equivalence")
        var changes: [String: LogStatisticsChanges] = [:]
        let entries = names.enumerated().map { index, name in
            var delta = LogStatisticsChanges(); delta.files = index + 1; delta.added = 10 + index; delta.removed = index; delta.newFileLines = 20 + index
            changes["exact-\(index)"] = delta
            return entry("exact-\(index)", name, "2024-01-0\(index + 1)T12:00:00Z", committer: names[3-index])
        }
        let summary = try LogStatistics.analyze(entries, changes: changes, calendar: calendar)
        XCTAssertEqual(summary.commitsByAuthor.count, 4)
        XCTAssertEqual(Set(summary.displayedAuthors.map(\.id)).count, 4)
        for (index, name) in names.enumerated() {
            let author = LogStatisticsAuthor(name)
            XCTAssertEqual(summary.commitsByAuthor[author], 1)
            let interval = try XCTUnwrap(summary.intervals.first { $0.commits[author] != nil })
            XCTAssertEqual(interval.fileChanges[author], index + 1)
            XCTAssertEqual(interval.linesWithoutNewDeletedFiles[author], 10 + 2 * index)
            XCTAssertEqual(interval.linesIncludingNewDeletedFiles[author], 30 + 3 * index)
            XCTAssertEqual(summary.activity(for: name).maximum, 1)
            XCTAssertEqual(summary.activity(for: name).minimum, 0)
        }
        XCTAssertEqual(summary.authorshipPercent.values.reduce(0,+), 100, accuracy: 0.00001)
        for (index, weight) in [1.0,1.0,3.0,6.0].enumerated() { XCTAssertEqual(try XCTUnwrap(summary.authorshipPercent[LogStatisticsAuthor(names[index])]), weight * 100 / 11, accuracy: 0.00001) }
        let expectedOrder = names.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.map { Data($0.utf8) }
        XCTAssertEqual(summary.authorsByActivity.map { Data($0.name.utf8) }, expectedOrder)
        var options = LogStatisticsOptions(); options.caseSensitive = false
        let folded = try LogStatistics.analyze(entries, options: options, changes: changes, calendar: calendar)
        XCTAssertEqual(folded.commitsByAuthor.count, 2)
        XCTAssertEqual(folded.commitsByAuthor[LogStatisticsAuthor(names[2])], 2)
        XCTAssertEqual(folded.commitsByAuthor[LogStatisticsAuthor(names[3])], 2)
        XCTAssertEqual(folded.intervals.reduce(0) { $0 + ($1.fileChanges[LogStatisticsAuthor(names[2])] ?? 0) }, 4)
        XCTAssertEqual(folded.intervals.reduce(0) { $0 + ($1.fileChanges[LogStatisticsAuthor(names[3])] ?? 0) }, 6)
        options.useCommitterNames = true
        let committers = try LogStatistics.analyze(entries, options: options, changes: changes, calendar: calendar)
        XCTAssertEqual(committers.commitsByAuthor.count, 2)
        XCTAssertEqual(committers.intervals.reduce(0) { $0 + ($1.fileChanges[LogStatisticsAuthor(names[2])] ?? 0) }, 6)
        XCTAssertEqual(committers.intervals.reduce(0) { $0 + ($1.fileChanges[LogStatisticsAuthor(names[3])] ?? 0) }, 4)
        XCTAssertEqual(Set(names.map { LogStatisticsAuthor($0) }).count, 4)
    }

    func testActualGitAuthorAndCommitterSpellingsRemainDistinctInStatistics() async throws {
        let (root, fixture, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? fixture.executable
        let repo = GitRepository(root: root, executable: executable)
        let names = ["\u{00C9}va", "E\u{0301}va", "\u{00E9}va", "e\u{0301}va"]
        for (index, name) in names.enumerated() {
            _ = try await repo.run(["-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "--no-gpg-sign", "-m", "exact-statistics-\(index)"], environmentOverrides: ["GIT_AUTHOR_NAME":name,"GIT_AUTHOR_EMAIL":"author@example.invalid","GIT_COMMITTER_NAME":names[3-index],"GIT_COMMITTER_EMAIL":"committer@example.invalid"])
        }
        let metadata = [".git/HEAD", ".git/index", ".git/config"]
        let before = try metadata.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let entries = try await repo.history().filter { $0.subject.hasPrefix("exact-statistics-") }
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(Set(entries.map { Data($0.author.utf8) }), Set(names.map { Data($0.utf8) }))
        let changes = try await repo.logStatisticsChanges(entries)
        for committers in [false, true] {
            var options = LogStatisticsOptions(); options.useCommitterNames = committers
            let summary = try LogStatistics.analyze(entries, options: options, changes: changes, calendar: calendar)
            XCTAssertEqual(summary.commitsByAuthor.count, 4)
            XCTAssertEqual(Set(summary.displayedAuthors.map { Data($0.name.utf8) }), Set(names.map { Data($0.utf8) }))
            options.caseSensitive = false
            let folded = try LogStatistics.analyze(entries, options: options, changes: changes, calendar: calendar)
            XCTAssertEqual(folded.commitsByAuthor.count, 2)
            XCTAssertEqual(folded.commitsByAuthor.values.sorted(), [2,2])
        }
        XCTAssertEqual(try metadata.map { try Data(contentsOf: root.appendingPathComponent($0)) }, before)
    }
}
