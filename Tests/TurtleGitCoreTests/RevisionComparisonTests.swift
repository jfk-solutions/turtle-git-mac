import XCTest
@testable import TurtleGitCore

final class RevisionComparisonTests: XCTestCase {
    func testHistoricalRenameBinaryAndLiteralNamesStayPinned() async throws {
        let (root, repo, original) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let renamed = ":(glob)* renamed 雪\n.txt", binary = "binary.dat"
        _ = try await repo.run(["mv", "--", original, renamed])
        try Data([0, 1, 2, 255]).write(to: root.appendingPathComponent(binary))
        try await repo.stage([binary]); _ = try await repo.commit(message: "rename and binary")
        let snapshot = try await repo.revisionComparison(from: .revision(base), to: .revision("HEAD"))
        let rename = try XCTUnwrap(snapshot.files.first { $0.path == renamed })
        XCTAssertEqual(rename.oldPath, original)
        XCTAssertNil(try XCTUnwrap(snapshot.files.first { $0.path == binary }).added)
        let patch = try await repo.revisionComparisonPatch(snapshot, paths: [renamed])
        XCTAssertTrue(patch.contains("rename from")); XCTAssertFalse(patch.contains("binary.dat"))
        try Data("later\n".utf8).write(to: root.appendingPathComponent(renamed))
        try await repo.stage([renamed]); _ = try await repo.commit(message: "advance HEAD")
        let pinned = try await repo.revisionComparisonPatch(snapshot, paths: [renamed])
        XCTAssertEqual(pinned, patch)
        do { _ = try await repo.revisionComparisonPatch(snapshot, paths: ["outside.txt"]); XCTFail("Unreviewed paths must fail") } catch RevisionComparisonFailure.selection {}
        let (other, otherRepo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: other) }
        do { _ = try await otherRepo.revisionComparisonPatch(snapshot); XCTFail("Another repository must fail") } catch RevisionComparisonFailure.selection {}
    }

    func testWorkingTreeIncludesStagedAndUnstagedChangesWithoutWritesAndReverses() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("working\n".utf8).write(to: root.appendingPathComponent(path))
        let stagedOnly = "staged-only.txt"
        try Data("added\n".utf8).write(to: root.appendingPathComponent(stagedOnly)); try await repo.stage([stagedOnly])
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("untracked.txt"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let comparison = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree)
        XCTAssertEqual(Set(comparison.files.map(\.path)), Set([path, stagedOnly]))
        let patch = try await repo.revisionComparisonPatch(comparison, paths: [path])
        XCTAssertTrue(patch.contains("+working")); XCTAssertFalse(patch.contains("+staged"))
        let reverse = try await repo.revisionComparison(from: .workingTree, to: .revision("HEAD"))
        let reversed = try await repo.revisionComparisonPatch(reverse, paths: [path])
        XCTAssertTrue(reversed.contains("-working")); XCTAssertTrue(reversed.contains("+line 1"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path)), "working\n")
        do { _ = try await repo.revisionComparison(from: .workingTree, to: .workingTree); XCTFail("Two working trees must fail") } catch RevisionComparisonFailure.range {}
    }

    func testEmptyTreeAndWhitespaceOptionsAgreeWithPatch() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let added = try await repo.revisionComparison(from: .emptyTree, to: .revision("HEAD"))
        XCTAssertEqual(added.files.first?.status, "Added"); XCTAssertEqual(added.files.first?.added, 30)
        let removed = try await repo.revisionComparison(from: .revision("HEAD"), to: .emptyTree)
        XCTAssertEqual(removed.files.first?.status, "Deleted"); XCTAssertEqual(removed.files.first?.removed, 30)
        let text = try String(contentsOf: root.appendingPathComponent(path))
        try Data(text.replacingOccurrences(of: "line 2\n", with: "line   2  \n").utf8).write(to: root.appendingPathComponent(path))
        var options = RevisionDiffOptions(); options.ignoreAllSpace = true
        let ignored = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree, options: options)
        XCTAssertEqual(ignored.files.map(\.path), [path])
        let patch = try await repo.revisionComparisonPatch(ignored); XCTAssertTrue(patch.isEmpty)
        options.ignoreAllSpace = false; options.ignoreSpaceAtEnd = true
        let visible = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree, options: options)
        XCTAssertEqual(visible.files.map(\.path), [path])
    }

    func testCommonAncestorPreservesUpstreamDirectComparisonForDivergentCommits() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "other"])
        try Data("main branch\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "main change")
        let main = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "other"])
        try Data("other branch\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "other change")
        var options = RevisionDiffOptions(); options.commonAncestor = true
        let snapshot = try await repo.revisionComparison(from: .revision(main), to: .revision("HEAD"), options: options)
        XCTAssertEqual(snapshot.from, .revision(main))
        let patch = try await repo.revisionComparisonPatch(snapshot)
        XCTAssertTrue(patch.contains("-main branch")); XCTAssertTrue(patch.contains("+other branch"))
        let identical = try await repo.revisionComparison(from: .revision(main), to: .revision(main))
        XCTAssertTrue(identical.files.isEmpty)
    }
}
