import XCTest
@testable import TurtleGitCore

final class WorkingTreeTests: XCTestCase {
    func testScopedStatusIncludesOtherStagedFilesOnlyWhenEnabledAndPreservesMixedChanges() async throws {
        let (root, repo, unusual) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: root.appendingPathComponent("folder/inside.txt"))
        try await repo.stage(["folder/inside.txt"]); _ = try await repo.commit(message: "inside")
        try Data("index change\n".utf8).write(to: root.appendingPathComponent(unusual)); try await repo.stage([unusual])
        try Data("later working change\n".utf8).write(to: root.appendingPathComponent(unusual))
        try Data("inside changed\n".utf8).write(to: root.appendingPathComponent("folder/inside.txt"))
        let rows = try await repo.workingTreeStatus()
        var filter = WorkingTreeFilter(); filter.paths = ["folder"]; filter.wholeProject = false
        XCTAssertEqual(Set(rows.filter(filter.includes).map(\.id)), [unusual, "folder/inside.txt"])
        filter.showAllStaged = false
        XCTAssertEqual(rows.filter(filter.includes).map(\.id), ["folder/inside.txt"])
        filter.paths = [unusual]
        XCTAssertEqual(rows.filter(filter.includes).map(\.id), [unusual], "Turning off show-all-staged must retain staged files inside scope")
        let diff = try await repo.workingTreeDiff(paths: [unusual])
        XCTAssertTrue(diff.contains("+later working change")); XCTAssertFalse(diff.contains("+index change"))
        let index = try await repo.run(["show", ":" + unusual]).text
        XCTAssertEqual(index, "index change\n")
    }
    func testCleanIgnoredUnversionedAndIndexFlagsWithLiteralNames() async throws {
        let (root, repo, unusual) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("*.ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("sample.ignored"))
        var rows = try await repo.workingTreeStatus(), filter = WorkingTreeFilter()
        XCTAssertEqual(rows.first { $0.id == unusual }?.state, .normal)
        XCTAssertFalse(rows.filter(filter.includes).contains { $0.id == unusual || $0.id == "sample.ignored" })
        XCTAssertTrue(rows.filter(filter.includes).contains { $0.id == ".gitignore" })
        filter.showUnversioned = false; filter.showIgnored = true; filter.showUnmodified = true
        XCTAssertEqual(Set(rows.filter(filter.includes).map(\.id)), [unusual, "sample.ignored"])
        _ = try await repo.run(["update-index", "--assume-unchanged", "--", unusual])
        rows = try await repo.workingTreeStatus()
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.id == unusual }).assumeUnchanged)
        XCTAssertFalse(rows.filter(filter.includes).contains { $0.id == unusual })
        filter.showLocalChangesIgnored = true
        XCTAssertTrue(rows.filter(filter.includes).contains { $0.id == unusual })
        _ = try await repo.run(["update-index", "--skip-worktree", "--", unusual])
        rows = try await repo.workingTreeStatus()
        XCTAssertTrue(try XCTUnwrap(rows.first { $0.id == unusual }).skipWorktree)
    }
    func testUnbornWorkingTreeDiffIncludesIndexWithoutCreatingHead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        try Data("new line\n".utf8).write(to: root.appendingPathComponent("new.txt")); try await repo.stage(["new.txt"])
        let diff = try await repo.workingTreeDiff(paths: ["new.txt"])
        XCTAssertTrue(diff.contains("+new line"))
        let rows = try await repo.workingTreeStatus(); XCTAssertEqual(rows.first?.state, .added)
    }
}
