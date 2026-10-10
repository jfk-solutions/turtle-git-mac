import XCTest
@testable import TurtleGitCore

final class HistoryOrderingTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, String, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Ordering Tests"), ("user.email", "ordering@example.invalid"), ("core.hooksPath", "/dev/null"), ("commit.gpgsign", "false")] { _ = try await repo.run(["config", key, value]) }
        func commit(_ title: String, _ parents: [String], _ committer: Int, _ author: Int) async throws -> String {
            try Data((title + "\n").utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
            let tree = try await repo.run(["write-tree"]).text.trimmingCharacters(in: .newlines)
            return try await repo.run(["commit-tree", tree, "-m", title] + parents.flatMap { ["-p", $0] }, environmentOverrides: ["GIT_COMMITTER_DATE": "2020-01-\(String(format: "%02d", committer))T12:00:00+0000", "GIT_AUTHOR_DATE": "2020-01-\(String(format: "%02d", author))T12:00:00+0000"]).text.trimmingCharacters(in: .newlines)
        }
        let base = try await commit("Root", [], 15, 15)
        let left = try await commit("Left one", [base], 9, 2)
        let leftTip = try await commit("Left two", [left], 10, 8)
        let right = try await commit("Right one", [base], 7, 9)
        let rightTip = try await commit("Right two", [right], 11, 3)
        let merge = try await commit("Merge", [leftTip, rightTip], 12, 12)
        _ = try await repo.run(["update-ref", "refs/heads/main", merge]); _ = try await repo.run(["branch", "left", leftTip]); _ = try await repo.run(["branch", "right", rightTip])
        _ = try await repo.run(["reset", "--hard", merge])
        return (root, repo, base, merge)
    }
    func testEveryOrderMatchesGitWalkWithSkewedDatesAndPreservesGraphInputAndRepository() async throws {
        let (root, repo, _, merge) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repo.run(["status", "--porcelain=v1", "-z"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), bytes = try Data(contentsOf: root.appendingPathComponent("file.txt"))
        var orders = Set<[String]>()
        for order in HistoryOrdering.allCases {
            var options = HistoryOptions(); options.ordering = order; options.limit = -1
            let entries = try await repo.history(options: options)
            let oracle = try await repo.run(["log", "--format=%H"] + order.arguments + ["HEAD", "--"]).text.split(separator: "\n").map(String.init)
            XCTAssertEqual(entries.map(\.hash), oracle); XCTAssertEqual(entries.count, 6); orders.insert(oracle)
            let graph = CommitGraph.project(entries, walk: options.walk)
            XCTAssertEqual(graph.entries.map(\.hash), oracle); XCTAssertEqual(graph.graph.count, entries.count)
        }
        XCTAssertGreaterThanOrEqual(orders.count, 3, "Fixture must distinguish real walk orders, not merely exercise four identical lists.")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines), after = try await repo.run(["status", "--porcelain=v1", "-z"]).stdout
        XCTAssertEqual(head, merge); XCTAssertEqual(before, after)
        XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index"))); XCTAssertEqual(config, try Data(contentsOf: root.appendingPathComponent(".git/config"))); XCTAssertEqual(bytes, try Data(contentsOf: root.appendingPathComponent("file.txt")))
    }
    func testOrderingSurvivesLimitPathSearchAndRangeScopes() async throws {
        let (root, repo, base, merge) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for order in HistoryOrdering.allCases {
            var options = HistoryOptions(); options.ordering = order; options.limit = 3; options.path = "file.txt"
            let limited = try await repo.history(options: options)
            let oracle = try await repo.run(["log", "--format=%H"] + order.arguments + ["--parents", "-3", "HEAD", "--", "file.txt"]).text.split(separator: "\n").map(String.init)
            XCTAssertEqual(limited.map(\.hash), oracle)
            options.limit = -1; options.path = nil; options.search = "one"
            let found = try await repo.history(options: options)
            let searched = try await repo.run(["log", "--format=%H"] + order.arguments + ["--fixed-strings", "--regexp-ignore-case", "--grep=one", "HEAD", "--"]).text.split(separator: "\n").map(String.init)
            XCTAssertEqual(found.map(\.hash), searched)
            options.search = ""; options.revisionRange = HistoryRevisionRange(from: base, to: merge, kind: .difference)
            let ranged = try await repo.history(options: options)
            let range = try await repo.run(["log", "--format=%H"] + order.arguments + [base + ".." + merge, "--"]).text.split(separator: "\n").map(String.init)
            XCTAssertEqual(ranged.map(\.hash), range)
        }
    }
    func testPersistedValuesDefaultAndInvalidFallbackAreIndependentOfWorkingRepository() {
        let suite = "TurtleGit.Ordering.Tests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(HistoryOrdering.load(defaults: defaults), .topological)
        for value in HistoryOrdering.allCases { value.save(defaults: defaults); XCTAssertEqual(HistoryOrdering.load(defaults: defaults), value) }
        for value in [-1, 4, 99] { defaults.set(value, forKey: HistoryOrdering.preferenceKey); XCTAssertEqual(HistoryOrdering.load(defaults: defaults), .topological) }
        defaults.set("unknown", forKey: HistoryOrdering.preferenceKey); XCTAssertEqual(HistoryOrdering.load(defaults: defaults), .topological)
        XCTAssertEqual(HistoryOrdering.chronological.arguments, [])
    }
}
