import XCTest
@testable import TurtleGitCore

final class RenameTests: XCTestCase {
    func testLiteralRenamePreservesMixedContentsAndUnrelatedIndex() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let staged = try String(contentsOf: root.appendingPathComponent(path)).replacingOccurrences(of: "line 1\n", with: "staged version\n")
        let working = staged.replacingOccurrences(of: "line 2\n", with: "working version\n")
        try Data(staged.utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data(working.utf8).write(to: root.appendingPathComponent(path))
        try Data("unrelated staged\n".utf8).write(to: root.appendingPathComponent("other.txt")); try await repo.stage(["other.txt"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        let originalBlob = try await repo.run(["show", ":" + path]).stdout
        let unrelated = try await repo.run(["show", ":other.txt"]).stdout
        let name = "-renamed [雪]*\n.txt"
        _ = try await repo.rename(RenameOptions(source: path, name: name))
        let renamedBlob = try await repo.run(["show", ":" + name]).stdout
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text
        let afterUnrelated = try await repo.run(["show", ":other.txt"]).stdout
        let status = try await repo.status()
        XCTAssertEqual(renamedBlob, originalBlob); XCTAssertEqual(afterHead, head); XCTAssertEqual(afterUnrelated, unrelated)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(name)), working)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        XCTAssertTrue(status.contains { $0.path == name && $0.index == "R" && $0.worktree == "M" && $0.originalPath == path })
    }
    func testDirectoryMoveRetainsUntrackedFilesAndIndexedChildren() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("destination"), withIntermediateDirectories: true)
        try Data("indexed\n".utf8).write(to: root.appendingPathComponent("folder/sub/tracked.txt")); try await repo.stage(["folder"])
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("folder/local.txt"))
        _ = try await repo.rename(RenameOptions(source: "folder", name: "destination/moved"))
        let tracked = try await repo.trackedPaths(), indexed = try await repo.run(["show", ":destination/moved/sub/tracked.txt"]).text
        XCTAssertTrue(tracked.contains("destination/moved/sub/tracked.txt")); XCTAssertFalse(tracked.contains("folder/sub/tracked.txt"))
        XCTAssertEqual(indexed, "indexed\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("destination/moved/local.txt")), "untracked\n")
        _ = try await repo.rename(RenameOptions(source: "destination/moved/sub/tracked.txt", name: "../../back.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("destination/back.txt").path))
    }
    func testInvalidCollisionAndNestedRepositoryTargetsLeaveIndexAndFilesUntouched() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        try Data("keep\n".utf8).write(to: root.appendingPathComponent("occupied"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("missing"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        _ = try await GitRepository(root: root.appendingPathComponent("nested")).run(["init", "-b", "nested"])
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        for name in [path, "/tmp/outside", "../outside", ".git/config", "occupied", "dangling", "nested/moved", "", "bad\0name"] {
            do { _ = try await repo.rename(RenameOptions(source: path, name: name)); XCTFail("Accepted invalid target: \(name)") } catch {}
        }
        do { _ = try await repo.rename(RenameOptions(source: "occupied", name: "untracked-move")); XCTFail("Renamed an untracked file") } catch RenameFailure.source {}
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(index, after); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), original)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("occupied")), "keep\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("dangling").path), root.appendingPathComponent("missing").path)
    }
    func testCaseOnlyRenameAndSymlinkRenameDoNotFollowExternalTargets() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("case contents\n".utf8).write(to: root.appendingPathComponent("case.txt")); try await repo.stage(["case.txt"])
        _ = try await repo.rename(RenameOptions(source: "case.txt", name: "Case.txt"))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path), paths = try await repo.trackedPaths()
        XCTAssertTrue(names.contains("Case.txt")); XCTAssertFalse(names.contains("case.txt")); XCTAssertTrue(paths.contains("Case.txt"))
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside preserved\n".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside.appendingPathComponent("missing")); try await repo.stage(["link"])
        _ = try await repo.rename(RenameOptions(source: "link", name: "new-link"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("new-link").path), outside.appendingPathComponent("missing").path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("live-link"), withDestinationURL: outside.appendingPathComponent("keep.txt")); try await repo.stage(["live-link"])
        _ = try await repo.rename(RenameOptions(source: "live-link", name: "new-live-link"))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("new-live-link").path), outside.appendingPathComponent("keep.txt").path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external-dir"), withDestinationURL: outside)
        do { _ = try await repo.rename(RenameOptions(source: "Case.txt", name: "external-dir/future/renamed")); XCTFail("Escaped via a symlink parent") } catch RenameFailure.outsideWorkingTree {}
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("keep.txt")), "outside preserved\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("future").path))
    }
    func testFinderEligibilityKeepsRenameScopedToOneVersionedSelection() {
        let root = URL(fileURLWithPath: "/fixture")
        let snapshot = FinderSnapshot.build(root: root, tracked: ["clean", "mixed", "folder/tracked"], changes: [StatusEntry(path: "mixed", originalPath: nil, index: " ", worktree: "M"), StatusEntry(path: "untracked", originalPath: nil, index: "?", worktree: "?")])
        XCTAssertTrue(snapshot.canRename([root.appendingPathComponent("clean")]))
        XCTAssertTrue(snapshot.canRename([root.appendingPathComponent("folder")]))
        XCTAssertFalse(snapshot.canRename([root]))
        XCTAssertFalse(snapshot.canRename([root.appendingPathComponent("untracked")]))
        XCTAssertFalse(snapshot.canRename([root.appendingPathComponent("clean"), root.appendingPathComponent("mixed")]))
        XCTAssertFalse(snapshot.canRename([URL(fileURLWithPath: "/fixture-other/clean")]))
    }
}
