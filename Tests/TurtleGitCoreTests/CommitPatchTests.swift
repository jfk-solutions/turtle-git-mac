import XCTest
@testable import TurtleGitCore

final class CommitPatchTests: XCTestCase {
    func testWorkingTreePatchIncludesStagedAndUnstagedChangesWithoutMutation() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "file\t雪.txt"
        try helper.write(root, path, "base\nother\n"); try await repo.stage([path]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        try helper.write(root, path, "staged\nother\n"); try await repo.stage([path]); try helper.write(root, path, "staged\nworking\n")
        let index = try await repo.diff(staged: true), working = try await repo.diff()
        let document = try await repo.workingTreePatch(paths: [path])
        XCTAssertTrue(document.text.contains("+staged")); XCTAssertTrue(document.text.contains("+working")); XCTAssertTrue(document.text.contains("-base"))
        let partial = try await repo.patch(paths: [path], staged: false)
        XCTAssertFalse(partial.text.contains("+staged")); XCTAssertTrue(partial.text.contains("+working"))
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text
        let afterIndex = try await repo.diff(staged: true), afterWorking = try await repo.diff()
        XCTAssertEqual(head, afterHead); XCTAssertEqual(index, afterIndex); XCTAssertEqual(working, afterWorking)
    }
    func testComparisonPatchUsesParentAndIncludesBothSidesOfRename() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "old.txt", "base\n"); try await repo.stage(["old.txt"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["mv", "old.txt", "new.txt"]); _ = try await repo.commit(message: "rename")
        let base = try await repo.commitComparisonBase(amendToParent: true)
        let ordinary = try await repo.workingTreePatch(paths: ["old.txt", "new.txt"])
        let previous = try await repo.workingTreePatch(paths: ["old.txt", "new.txt"], base: base)
        XCTAssertEqual(ordinary.text, ""); XCTAssertTrue(previous.text.contains("rename from old.txt")); XCTAssertTrue(previous.text.contains("rename to new.txt"))
    }
    func testUnbornComparisonAndRepositoryPreferences() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "initial.txt", "initial\n"); try await repo.stage(["initial.txt"])
        let patch = try await repo.workingTreePatch(paths: ["initial.txt"])
        XCTAssertTrue(patch.text.contains("+initial"))
        let index = try await repo.diff(staged: true)
        try await repo.saveCommitPreferences(staging: true, showPatch: true)
        var settings = try await repo.commitPreferences(); XCTAssertTrue(settings.staging); XCTAssertTrue(settings.showPatch)
        try await repo.saveCommitPreferences(showPatch: false)
        settings = try await repo.commitPreferences(); XCTAssertTrue(settings.staging); XCTAssertFalse(settings.showPatch)
        let reopened = GitRepository(root: root), restored = try await reopened.commitPreferences()
        XCTAssertTrue(restored.staging); XCTAssertFalse(restored.showPatch)
        let after = try await repo.diff(staged: true); XCTAssertEqual(index, after)
    }
}
