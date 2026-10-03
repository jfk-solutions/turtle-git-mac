import XCTest
@testable import TurtleGitCore

final class StashTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, String) {
        let (root, repo, path) = try await GitPatchTests().fixture()
        try Data("*.ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try await repo.stage([".gitignore"]); _ = try await repo.commit(message: "ignore rules")
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("working\n".utf8).write(to: root.appendingPathComponent(path))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("-untracked 雪.txt"))
        try Data("ignored\n".utf8).write(to: root.appendingPathComponent("sample.ignored"))
        return (root, repo, path)
    }
    func testDefaultStashPreservesHeadAndSeparateIndexWorktreeLeavingUntrackedIgnored() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        var options = StashSaveOptions(); options.message = "Review 雪 'quotes'"
        let result = try await repo.saveStash(options)
        XCTAssertTrue(result.created); XCTAssertNil(result.previous)
        let after = try await repo.run(["rev-parse", "HEAD"]).text, index = try await repo.diff(staged: true), working = try await repo.diff()
        let savedIndex = try await repo.run(["show", "refs/stash^2:" + path]).text, savedWorking = try await repo.run(["show", "refs/stash:" + path]).text
        let subject = try await repo.run(["show", "-s", "--format=%s", "refs/stash"]).text
        XCTAssertEqual(head, after); XCTAssertTrue(index.isEmpty); XCTAssertTrue(working.isEmpty)
        XCTAssertEqual(savedIndex, "staged\n"); XCTAssertEqual(savedWorking, "working\n"); XCTAssertTrue(subject.contains(options.message))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("-untracked 雪.txt"), encoding: .utf8), "untracked\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("sample.ignored"), encoding: .utf8), "ignored\n")
    }
    func testIncludeUntrackedSavesThirdParentAndLeavesIgnoredFiles() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = StashSaveOptions(); options.includeUntracked = true
        let result = try await repo.saveStash(options); XCTAssertTrue(result.created)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("-untracked 雪.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sample.ignored").path))
        let saved = try await repo.run(["show", "refs/stash^3:-untracked 雪.txt"]).text
        let subject = try await repo.run(["show", "-s", "--format=%s", "refs/stash"]).text
        XCTAssertEqual(saved, "untracked\n"); XCTAssertTrue(subject.contains("WIP on main"), "An empty optional message must use Git's default")
    }
    func testAllStashRestoresTrackedIndexWorktreeUntrackedAndIgnoredContents() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try await repo.diff(staged: true), working = try await repo.diff()
        var options = StashSaveOptions(); options.all = true
        let result = try await repo.saveStash(options); XCTAssertTrue(result.created)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sample.ignored").path))
        let ignored = try await repo.run(["show", "refs/stash^3:sample.ignored"]).text; XCTAssertEqual(ignored, "ignored\n")
        _ = try await repo.run(["stash", "apply", "--index"])
        let restoredIndex = try await repo.diff(staged: true), restoredWork = try await repo.diff()
        XCTAssertEqual(index, restoredIndex); XCTAssertEqual(working, restoredWork)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "working\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("-untracked 雪.txt"), encoding: .utf8), "untracked\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("sample.ignored"), encoding: .utf8), "ignored\n")
    }
    func testNoChangesDoesNotCreateOrReplaceStashAndInvalidOptionsDoNotMutate() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try await repo.diff(staged: true), working = try await repo.diff()
        var options = StashSaveOptions(); options.all = true; options.includeUntracked = true
        do { _ = try await repo.saveStash(options); XCTFail("Combined options accepted") } catch StashFailure.combination {}
        options = StashSaveOptions(); options.message = "invalid\0message"
        do { _ = try await repo.saveStash(options); XCTFail("NUL message accepted") } catch StashFailure.message {}
        let afterIndex = try await repo.diff(staged: true), afterWorking = try await repo.diff()
        XCTAssertEqual(index, afterIndex); XCTAssertEqual(working, afterWorking)
        let saved = try await repo.saveStash(StashSaveOptions())
        let unchanged = try await repo.saveStash(StashSaveOptions())
        XCTAssertFalse(unchanged.created); XCTAssertEqual(saved.current, unchanged.current); XCTAssertEqual(unchanged.previous, unchanged.current)
    }
}
