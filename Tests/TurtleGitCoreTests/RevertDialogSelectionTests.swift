import XCTest
@testable import TurtleGitCore

final class RevertDialogSelectionTests: XCTestCase {
    func testRealScopedChangesPreselectDirectAndAddedFilesWithoutChangingGit() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["dir", "directory"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false) }
        let files = ["dir/modified", "dir/deleted", "directory/other", "direct 雪\n.txt"]
        for file in files { try Data("base".utf8).write(to: root.appendingPathComponent(file)) }
        try await repo.stage(files); _ = try await repo.commit(message: "scope")
        for file in files { try Data("changed".utf8).write(to: root.appendingPathComponent(file)) }
        try Data("added".utf8).write(to: root.appendingPathComponent("dir/added")); try await repo.stage(["dir/added"])
        try Data("untracked".utf8).write(to: root.appendingPathComponent("dir/new"))
        _ = try await repo.run(["rm", "--cached", "--", "dir/deleted"])
        let status = try await repo.status(), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let list = RevertDialogSelection(status: status, paths: ["dir", "direct 雪\n.txt"], directFiles: ["direct 雪\n.txt"])
        XCTAssertEqual(Set(list.entries.map(\.path)), ["dir/modified", "dir/deleted", "dir/added", "direct 雪\n.txt"])
        XCTAssertEqual(list.initiallyChecked, ["dir/added", "direct 雪\n.txt"])
        XCTAssertTrue(list.hasUnversionedItems)
        let rootList = RevertDialogSelection(status: status, paths: ["."], directFiles: [])
        XCTAssertEqual(rootList.initiallyChecked, ["dir/added"])
        let directList = RevertDialogSelection(status: status, paths: ["direct 雪\n.txt"], directFiles: ["direct 雪\n.txt"])
        XCTAssertFalse(directList.hasUnversionedItems)
        let deletedList = RevertDialogSelection(status: status, paths: ["dir/deleted"], directFiles: ["dir/deleted"])
        XCTAssertTrue(deletedList.hasUnversionedItems); XCTAssertEqual(deletedList.entries.first?.state, .deleted)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testFinderRevertEligibilityAndLiteralURLScope() throws {
        let root = URL(fileURLWithPath: "/repo"), changed = root.appendingPathComponent("dir/雪\n.txt")
        let snapshot = FinderSnapshot(roots: [root.path], states: [root.path: .modified, changed.path: .modified, "/repo/dir/new": .untracked, "/repo/clean": .normal])
        XCTAssertTrue(snapshot.canRevert([root])); XCTAssertTrue(snapshot.canRevert([root.appendingPathComponent("dir")]))
        XCTAssertTrue(snapshot.canRevert([changed]))
        XCTAssertFalse(snapshot.canRevert([changed, root.appendingPathComponent("dir/new")]))
        XCTAssertFalse(snapshot.canRevert([root.appendingPathComponent("clean")]))
        XCTAssertFalse(snapshot.canRevert([changed, URL(fileURLWithPath: "/repository/else")]))
        let request = FinderRequest(action: .revert, paths: [changed]), parsed = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
        XCTAssertEqual(parsed.action, .revert); XCTAssertEqual(parsed.relativePaths(root: root), ["dir/雪\n.txt"])
        XCTAssertEqual(parsed.action.icon, .revert); XCTAssertTrue(parsed.action.requiresWorkingTree)
    }
    func testRevertSelectedSubmoduleRootUsesSuperprojectWhileIndependentNestedRepoStaysIndependent() async throws {
        let (root, source, repo, child, path) = try await ConflictResolutionTests().submoduleFixture(initialized: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let checkout = try XCTUnwrap(child)
        let owner = try await checkout.discoverSelectionRoot(for: .revert, selected: checkout.root)
        XCTAssertEqual(owner, root.standardizedFileURL)
        let conflicts = try await repo.conflicts(); _ = try await repo.resolveConflicts(conflicts, using: .current)
        let ordinaryOwner = try await checkout.discoverSelectionRoot(for: .revert, selected: root.appendingPathComponent(path))
        XCTAssertEqual(ordinaryOwner, root.standardizedFileURL)
        let nested = root.appendingPathComponent("independent")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let independent = GitRepository(root: nested); _ = try await independent.run(["init"])
        let independentOwner = try await independent.discoverSelectionRoot(for: .revert, selected: nested)
        XCTAssertEqual(independentOwner, nested.standardizedFileURL)
    }
}
