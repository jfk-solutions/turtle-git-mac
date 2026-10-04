import XCTest
@testable import TurtleGitCore

final class RemovalTests: XCTestCase {
    func testKeepLocalDeletionAmendPreservesCopyParentsAndUnrelatedStaging() async throws {
        for compareWithHead in [true, false] {
            let (root, repo, path) = try await GitPatchTests().fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("base other\n".utf8).write(to: root.appendingPathComponent("other.txt"))
            try await repo.stage(["other.txt"])
            _ = try await repo.commit(message: "second commit")
            let parents = try await repo.run(["show", "-s", "--format=%P", "HEAD"]).text
            try Data("staged other\n".utf8).write(to: root.appendingPathComponent("other.txt"))
            try await repo.stage(["other.txt"])
            try Data("working other\n".utf8).write(to: root.appendingPathComponent("other.txt"))
            try Data("retained target\n".utf8).write(to: root.appendingPathComponent(path))
            _ = try await repo.removeVersionedPath(path, keepLocal: true)
            let entries = try await repo.commitDialogStatus(amendToParent: !compareWithHead)
            XCTAssertTrue(entries.contains { $0.path == path && $0.index == "D" && $0.hasUnversionedCopy })
            var options = CommitOptions()
            options.amend = true
            options.amendDiffToLastCommit = compareWithHead
            _ = try await repo.commitSelected(message: "amended deletion", paths: [path], options: options)
            let names = try await repo.run(["ls-tree", "-r", "--name-only", "HEAD"]).text
            let afterParents = try await repo.run(["show", "-s", "--format=%P", "HEAD"]).text
            let otherIndex = try await repo.run(["show", ":other.txt"]).text
            XCTAssertFalse(names.split(separator: "\n").contains(Substring(path)))
            XCTAssertEqual(parents, afterParents)
            XCTAssertEqual(otherIndex, "staged other\n")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "working other\n")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path)), "retained target\n")
        }
    }
    func testKeepLocalRemovalAndSelectedDeletionCommitPreserveFilesAndUnrelatedIndex() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("unrelated original\n".utf8).write(to: root.appendingPathComponent("other.txt")); try await repo.stage(["other.txt"]); _ = try await repo.commit(message: "another base")
        try Data("unrelated index\n".utf8).write(to: root.appendingPathComponent("other.txt")); try await repo.stage(["other.txt"])
        try Data("unrelated worktree\n".utf8).write(to: root.appendingPathComponent("other.txt"))
        try Data("staged target\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("retained working target\n".utf8).write(to: root.appendingPathComponent(path))
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        _ = try await repo.removeVersionedPath(path, keepLocal: true)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text, tracked = try await repo.trackedPaths(), status = try await repo.status()
        XCTAssertEqual(head, afterHead); XCTAssertFalse(tracked.contains(path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path)), "retained working target\n")
        XCTAssertEqual(status.filter { $0.path == path }.count, 1, "One UI identity must retain the staged deletion and local-copy information")
        _ = try await repo.commitSelected(message: "remove target, keep local", paths: [path])
        let tree = try await repo.run(["ls-tree", "-r", "--name-only", "HEAD"]).text, index = try await repo.run(["show", ":other.txt"]).text
        XCTAssertFalse(tree.contains(path)); XCTAssertEqual(index, "unrelated index\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "unrelated worktree\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path)), "retained working target\n")
        let finalStatus = try await repo.status(); XCTAssertTrue(finalStatus.contains { $0.path == path && $0.state == .untracked })
    }
    func testForcedWorkingTreeRemovalStagesDeletionWithoutChangingHeadOrOtherContents() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("index changes\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("working changes\n".utf8).write(to: root.appendingPathComponent(path))
        try Data("untracked sibling\n".utf8).write(to: root.appendingPathComponent("keep.txt"))
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        _ = try await repo.removeVersionedPath(path, keepLocal: false)
        let status = try await repo.status(), after = try await repo.run(["rev-parse", "HEAD"]).text
        XCTAssertEqual(head, after); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        XCTAssertTrue(status.contains { $0.path == path && $0.index == "D" })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("keep.txt")), "untracked sibling\n")
    }
    func testRecursiveDirectoryRemovalLeavesUntrackedChildrenAndTreatsSymlinkAsLink() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder 雪[*]")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("tracked\n".utf8).write(to: folder.appendingPathComponent("tracked")); try await repo.stage(["folder 雪[*]/tracked"])
        try Data("local\n".utf8).write(to: folder.appendingPathComponent("local"))
        _ = try await repo.removeVersionedPath("folder 雪[*]", keepLocal: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tracked").path))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("local")), "local\n")
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside\n".utf8).write(to: outside); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside); try await repo.stage(["link"])
        _ = try await repo.removeVersionedPath("link", keepLocal: false)
        XCTAssertEqual(try String(contentsOf: outside), "outside\n")
        XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("link").path))
    }
    func testInvalidNestedAndStaleSelectionsFailBeforeMutatingTheirFiles() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        for target in ["", ".", "..", "../outside", "/tmp/outside", ".git/config", "x/.GIT/y", "bad\0path", "not-tracked"] {
            do { _ = try await repo.removeVersionedPath(target, keepLocal: false); XCTFail("Accepted \(target)") } catch {}
        }
        XCTAssertThrowsError(try RemovalRequest(paths: [path, ".git/config"], keepLocal: false))
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try await GitRepository(root: nested).run(["init", "-b", "main"])
        try Data("nested\n".utf8).write(to: nested.appendingPathComponent("local"))
        do { _ = try await repo.removeVersionedPath("nested/local", keepLocal: false); XCTFail("Removed from another repository") } catch RemovalFailure.outsideWorkingTree {}
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout; XCTAssertEqual(index, after)
        XCTAssertEqual(try String(contentsOf: nested.appendingPathComponent("local")), "nested\n")
        _ = try await repo.removeVersionedPath(path, keepLocal: true)
        do { _ = try await repo.removeVersionedPath(path, keepLocal: false); XCTFail("Removed a stale/untracked selection") } catch RemovalFailure.unversioned {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
    }
    func testCachedFinderRemovalExcludesAddedRootsAndMixedRepositories() throws {
        let root = URL(fileURLWithPath: "/fixture")
        let cache = FinderSnapshot.build(root: root, tracked: ["clean", "folder/tracked"], changes: [StatusEntry(path: "new", originalPath: nil, index: "A", worktree: " "), StatusEntry(path: "local", originalPath: nil, index: "?", worktree: "?")])
        XCTAssertTrue(cache.canRemove([root.appendingPathComponent("clean"), root.appendingPathComponent("folder")]))
        for selection in [[], [root], [root.appendingPathComponent("new")], [root.appendingPathComponent("local")], [root.appendingPathComponent("clean"), URL(fileURLWithPath: "/another/clean")]] { XCTAssertFalse(cache.canRemove(selection)) }
        let request = try RemovalRequest(paths: ["clean", "folder", "clean"], keepLocal: true)
        XCTAssertEqual(request.paths, ["clean", "folder"])
    }
}
