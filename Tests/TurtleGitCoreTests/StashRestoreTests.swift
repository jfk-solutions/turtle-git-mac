import XCTest
@testable import TurtleGitCore

final class StashRestoreTests: XCTestCase {
    func testApplyRetainsThenPopDropsStashWithoutRestoringIndexByDefault() async throws {
        let (root, repo, path) = try await StashTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var options = StashSaveOptions(); options.all = true
        let saved = try await repo.saveStash(options)
        let applied = try await repo.restoreStash(pop: false)
        XCTAssertFalse(applied.conflicted)
        let stash = try await repo.run(["rev-parse", "refs/stash"]).text.trimmingCharacters(in: .newlines)
        let index = try await repo.diff(staged: true)
        XCTAssertEqual(stash, saved.current); XCTAssertTrue(index.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "working\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sample.ignored").path))
        // Restore the clean fixture through Git itself before testing Pop.
        _ = try await repo.run(["reset", "--hard", "HEAD"])
        _ = try await repo.run(["clean", "-fdx"])
        let popped = try await repo.restoreStash(pop: true)
        XCTAssertFalse(popped.conflicted)
        do { _ = try await repo.run(["rev-parse", "--verify", "refs/stash"]); XCTFail("Successful pop must remove the only stash") } catch is GitFailure {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "working\n")
    }
    func testConflictedPopRetainsStashAndUnmergedEntries() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("stashed\n".utf8).write(to: root.appendingPathComponent(path))
        let saved = try await repo.saveStash(StashSaveOptions())
        try Data("new head\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.commit(message: "divergent head")
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        let result = try await repo.restoreStash(pop: true)
        XCTAssertTrue(result.conflicted)
        let stash = try await repo.run(["rev-parse", "refs/stash"]).text.trimmingCharacters(in: .newlines)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text
        let status = try await repo.status()
        XCTAssertEqual(stash, saved.current); XCTAssertEqual(head, afterHead)
        XCTAssertEqual(status.first?.state, .conflicted)
        let unmerged = try await repo.run(["ls-files", "-u", "-z"]).stdout
        XCTAssertFalse(unmerged.isEmpty)
    }
    func testSelectedApplyNormalizesUpstreamRefFormsWithoutDroppingNewerStash() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for text in ["older\n", "newer\n"] {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
            _ = try await repo.saveStash(StashSaveOptions())
        }
        let latest = try await repo.run(["rev-parse", "refs/stash"]).text
        for ref in ["refs/stash@{1}", "stash{1}"] {
            let result = try await repo.restoreStash(pop: false, reference: ref)
            XCTAssertFalse(result.conflicted)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "older\n")
            let current = try await repo.run(["rev-parse", "refs/stash"]).text
            XCTAssertEqual(current, latest)
            _ = try await repo.run(["reset", "--hard", "HEAD"])
        }
    }
    func testMissingStashAndOverwrittenLocalChangesFailWithoutDroppingOrMutating() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repo.restoreStash(pop: false); XCTFail("Missing stash accepted") } catch is GitFailure {}
        try Data("stashed\n".utf8).write(to: root.appendingPathComponent(path))
        let saved = try await repo.saveStash(StashSaveOptions())
        try Data("local\n".utf8).write(to: root.appendingPathComponent(path))
        for pop in [false, true] {
            do { _ = try await repo.restoreStash(pop: pop); XCTFail("Overwrite accepted") } catch is GitFailure {}
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "local\n")
            let stash = try await repo.run(["rev-parse", "refs/stash"]).text.trimmingCharacters(in: .newlines)
            XCTAssertEqual(stash, saved.current)
        }
        do { _ = try await repo.restoreStash(pop: false, reference: "--help"); XCTFail("Option accepted as revision") } catch is GitFailure {}
        do { _ = try await repo.restoreStash(pop: false, reference: "stash\0@{0}"); XCTFail("NUL reference accepted") } catch is GitFailure {}
    }
}
