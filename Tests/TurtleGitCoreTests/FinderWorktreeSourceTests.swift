import XCTest
@testable import TurtleGitCore

final class FinderWorktreeSourceTests: XCTestCase {
    func testWorkingAndBareRootsCaptureSourceWithoutDestinationOrClipboard() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FinderWorktree-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for bare in [false, true] {
            let root = folder.appendingPathComponent(bare ? "server 雪\n&?.git" : "checkout café\n&?")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var snapshot = FinderSnapshot.build(root: root, tracked: [], changes: [])
            snapshot.repositories[root.path] = FinderRepositoryMetadata(bare: bare)
            let request = try XCTUnwrap(FinderWorktreeContext.sourceRequest(selection: [root], snapshot: snapshot))
            let received = try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url)))
            XCTAssertEqual(received.action, .worktreeCreate)
            XCTAssertEqual(received.paths.map(\.path), [root.path])
            XCTAssertTrue(received.sources.isEmpty)
            XCTAssertNil(received.clipboardPatch)
            XCTAssertTrue(snapshot.repositories[root.path]!.allows(.worktreeCreate))
            XCTAssertTrue(FinderShellRules.allows(.worktreeCreate, flags: FinderShellRules.flags(paths: [root], snapshot: snapshot)))
        }
        XCTAssertFalse(RepositoryAction.worktreeCreate.requiresWorkingTree)
        XCTAssertEqual(FinderMenuEntry.entry(for: .worktreeCreate), .worktree)
        XCTAssertEqual(FinderMenuEntry.entry(for: .worktreeList), .worktree)
    }

    func testNestedMultipleUnknownMissingAndAdministrativeSelectionsAreNotSources() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FinderWorktree-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("checkout"), nested = root.appendingPathComponent("nested")
        let metadata = root.appendingPathComponent(".GiT")
        for directory in [nested, metadata] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let file = root.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        var snapshot = FinderSnapshot.build(root: root, tracked: ["file"], changes: [])
        snapshot.repositories[root.path] = FinderRepositoryMetadata(bare: false)
        for selection in [[], [nested], [file], [metadata], [root, nested], [root, root], [folder], [root.appendingPathComponent("missing")], [URL(string: "https://example.com/repo")!]] {
            XCTAssertNil(FinderWorktreeContext.sourceRequest(selection: selection, snapshot: snapshot), "Unexpected source: \(selection)")
        }
        XCTAssertNil(FinderWorktreeContext.sourceRequest(selection: [root], snapshot: nil))
        XCTAssertFalse(FinderShellRules.allows(.worktreeCreate, flags: FinderShellRules.flags(paths: [nested], snapshot: snapshot)))
        try FileManager.default.removeItem(at: root)
        XCTAssertNil(FinderWorktreeContext.sourceRequest(selection: [root], snapshot: snapshot), "Stale cached root must still exist")
    }

    func testEachCachedLinkedRootIsEligibleButParentOwnershipDoesNotPromoteChildren() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FinderWorktree-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("parent"), child = root.appendingPathComponent("linked"), nested = child.appendingPathComponent("subdirectory")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        var snapshot = FinderSnapshot(roots: [root.path, child.path], states: [:])
        snapshot.repositories[root.path] = FinderRepositoryMetadata(bare: false)
        snapshot.repositories[child.path] = FinderRepositoryMetadata(bare: false)
        XCTAssertEqual(FinderWorktreeContext.sourceRequest(selection: [child], snapshot: snapshot)?.paths.map(\.path), [child.path])
        XCTAssertNil(FinderWorktreeContext.sourceRequest(selection: [nested], snapshot: snapshot))
        snapshot.roots = [root.path]
        XCTAssertNil(FinderWorktreeContext.sourceRequest(selection: [child], snapshot: snapshot), "Directory inside a cached repository is not a selected root")
        XCTAssertFalse(FinderRepositoryMetadata(bare: true).allows(.commit), "Bare eligibility must not broaden unrelated working-tree commands")
    }
}
