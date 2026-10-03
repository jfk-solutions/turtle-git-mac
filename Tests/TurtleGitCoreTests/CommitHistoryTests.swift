import XCTest
@testable import TurtleGitCore

final class CommitHistoryTests: XCTestCase {
    private func entry(_ hash: String, _ parents: [String]) -> LogEntry {
        LogEntry(hash: hash, author: "A", date: "", subject: hash, parents: parents)
    }
    func testMergeAndBranchPointEdgesStayContinuous() {
        // Merge M has parents A and B, which share base R.
        let rows = CommitGraph.layout([entry("M", ["A", "B"]), entry("A", ["R"]), entry("B", ["R"]), entry("R", [])])
        XCTAssertTrue(rows[0].junction)
        XCTAssertTrue(rows[3].junction)
        XCTAssertEqual(rows[0].edges.filter(\.startsAtNode).count, 2)
        XCTAssertFalse(rows[0].edges.contains(where: \.endsAtNode)) // no invented ancestor above a tip
        for index in 0..<rows.count - 1 {
            let outgoing = rows[index].edges.filter { !$0.endsAtNode }.map { "\($0.to):\($0.color)" }.sorted()
            let incoming = rows[index + 1].edges.filter { !$0.startsAtNode }.map { "\($0.from):\($0.color)" }.sorted()
            // Multiple edges may join the same ancestor at a row boundary.
            XCTAssertEqual(Set(outgoing), Set(incoming))
        }
        XCTAssertTrue(rows[3].edges.allSatisfy(\.endsAtNode))
    }
    func testOctopusAndDisconnectedHistory() {
        let rows = CommitGraph.layout([entry("M", ["A", "B", "C"]), entry("A", []), entry("B", []), entry("C", []), entry("unrelated", [])])
        XCTAssertEqual(rows[0].width, 3)
        XCTAssertEqual(rows[0].edges.filter(\.startsAtNode).count, 3)
        XCTAssertEqual(rows[4].column, 0)
        XCTAssertTrue(rows[4].edges.isEmpty)
    }
    func testChangedPathParsingWithBinaryRenameTabsAndNewlines() {
        let files = CommitFile.parse(names: Data("R100\0old\nname\0new\tname\0M\0binary\0A\0雪\0".utf8),
            statistics: Data("0\t0\t\0old\nname\0new\tname\0-\t-\tbinary\03\t0\t雪\0".utf8))
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].oldPath, "old\nname")
        XCTAssertEqual(files[0].path, "new\tname")
        XCTAssertEqual(files[0].added, 0)
        XCTAssertNil(files[1].added)
        XCTAssertEqual(files[2].added, 3)
    }
    func testRealHistoryDetailsRefsFilteringAndMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "History Tests"])
        _ = try await repo.run(["config", "user.email", "history@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        let weird = "initial\t雪\n.txt"
        try Data("line one\nline two\n".utf8).write(to: root.appendingPathComponent(weird))
        try await repo.stage([weird]); _ = try await repo.commit(message: "Initial\n\nMultiline body\nAnother line")
        let initialHistory = try await repo.history()
        let initial = try XCTUnwrap(initialHistory.first)
        XCTAssertEqual(initial.email, "history@example.invalid")
        XCTAssertTrue(initial.message.contains("Multiline body\nAnother line"))
        XCTAssertTrue(initial.isHead)
        XCTAssertEqual(initial.references.filter(\.isCurrent).map(\.name), ["refs/heads/main"])
        let initialFiles = try await repo.files(in: initial)
        XCTAssertEqual(initialFiles.first?.path, weird)
        XCTAssertEqual(initialFiles.first?.added, 2)
        _ = try await repo.run(["switch", "-c", "feature"])
        _ = try await repo.run(["mv", "--", weird, "renamed.txt"])
        _ = try await repo.commit(message: "Rename on feature")
        let renamedHistory = try await repo.history()
        let renamed = try XCTUnwrap(renamedHistory.first)
        let renamedFiles = try await repo.files(in: renamed)
        XCTAssertEqual(renamedFiles.first?.oldPath, weird)
        XCTAssertEqual(renamedFiles.first?.status, "Renamed")
        XCTAssertEqual(renamedFiles.first?.removed, 0)
        _ = try await repo.run(["tag", "-a", "v1", "-m", "Annotated tag"])
        _ = try await repo.run(["switch", "main"])
        try Data("main change\n".utf8).write(to: root.appendingPathComponent("main.txt"))
        try await repo.stage(["main.txt"]); _ = try await repo.commit(message: "Main work")
        _ = try await repo.run(["merge", "--no-ff", "feature", "-m", "Merge feature"])
        let history = try await repo.history()
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history[0].parents.count, 2)
        XCTAssertTrue(history.first { $0.hash == renamed.hash }!.references.contains { $0.name == "refs/tags/v1" })
        let mergeFiles = try await repo.files(in: history[0])
        XCTAssertEqual(mergeFiles.first?.status, "Renamed")
        var options = HistoryOptions(); options.search = "Multiline body"
        let filtered = try await repo.history(options: options)
        XCTAssertEqual(filtered.map(\.hash), [initial.hash])
        options.search = ""; options.limit = 2
        let limited = try await repo.history(options: options)
        XCTAssertEqual(limited.count, 2)
        let diff = try await repo.revisionDiff(history[0])
        XCTAssertTrue(diff.contains("rename to renamed.txt"))
    }
}
