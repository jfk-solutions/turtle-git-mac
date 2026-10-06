import XCTest
@testable import TurtleGitCore

final class FinderSubmoduleScanTests: XCTestCase {
    func fixture() async throws -> (URL, URL, URL, GitRepository, URL, URL, String) {
        let (root, parent, _) = try await GitPatchTests().fixture()
        let (source, sourceRepo, file) = try await GitPatchTests().fixture()
        let (innerSource, _, _) = try await GitPatchTests().fixture()
        let outerPath = "modules/outer 雪\n", innerPath = "nested/inner 雪\n"
        _ = try await sourceRepo.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", "inner", "--", innerSource.path, innerPath])
        try await sourceRepo.stage([".gitmodules", innerPath]); _ = try await sourceRepo.commit(message: "nested module")
        _ = try await parent.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", "outer", "--", source.path, outerPath])
        try await parent.stage([".gitmodules", outerPath]); _ = try await parent.commit(message: "outer module")
        _ = try await parent.run(["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"])
        let outer = root.appendingPathComponent(outerPath, isDirectory: true), inner = outer.appendingPathComponent(innerPath, isDirectory: true)
        return (root, source, innerSource, parent, outer, inner, file)
    }
    func testRecursiveCollectionHasChildFactsAndPreservesIndexes() async throws {
        let (root, source, innerSource, parent, outer, inner, file) = try await fixture()
        defer { for path in [root, source, innerSource] { try? FileManager.default.removeItem(at: path) } }
        let child = GitRepository(root: outer)
        _ = try await child.run(["config", "user.name", "Cache Tests"]); _ = try await child.run(["config", "user.email", "cache@example.invalid"])
        try Data("stash change".utf8).write(to: outer.appendingPathComponent(file))
        _ = try await child.run(["stash", "push"])
        try Data("inner working change".utf8).write(to: inner.appendingPathComponent(file))
        let index = try await parent.run(["ls-files", "--stage", "-z"]).stdout
        let head = try await parent.run(["rev-parse", "HEAD"]).stdout
        let childIndex = try await child.run(["ls-files", "--stage", "-z"]).stdout
        let scan = try await parent.finderSubmoduleSnapshots(authorizedRoot: root)
        XCTAssertTrue(scan.failures.isEmpty, scan.failures.description)
        XCTAssertEqual(Set(scan.snapshots.flatMap(\.roots)), [outer.path, inner.path])
        let outerSnapshot = try XCTUnwrap(scan.snapshots.first { $0.roots == [outer.path] })
        let innerSnapshot = try XCTUnwrap(scan.snapshots.first { $0.roots == [inner.path] })
        XCTAssertEqual(outerSnapshot.repositories[outer.path]?.submoduleParentRoot, root.path)
        XCTAssertEqual(innerSnapshot.repositories[inner.path]?.submoduleParentRoot, outer.path)
        XCTAssertEqual(outerSnapshot.repositories[outer.path]?.hasStash, true)
        XCTAssertEqual(innerSnapshot.repositories[inner.path]?.hasStash, false)
        XCTAssertEqual(innerSnapshot.states[inner.appendingPathComponent(file).path], .modified)
        XCTAssertEqual(outerSnapshot.states[outer.appendingPathComponent(file).path], .normal)
        let afterIndex = try await parent.run(["ls-files", "--stage", "-z"]).stdout
        let afterHead = try await parent.run(["rev-parse", "HEAD"]).stdout
        let afterChildIndex = try await child.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(index, afterIndex); XCTAssertEqual(head, afterHead); XCTAssertEqual(childIndex, afterChildIndex)
    }
    func testDeinitializedSubmodulesDropFromRefreshedCache() async throws {
        let (root, source, innerSource, parent, outer, inner, _) = try await fixture()
        defer { for path in [root, source, innerSource] { try? FileManager.default.removeItem(at: path) } }
        let initial = try await parent.finderSubmoduleSnapshots(authorizedRoot: root)
        var cache = FinderSnapshot(roots: [root.path + "-other"], states: [root.path + "-other/file": .normal])
        var base = FinderSnapshot.build(root: root, tracked: try await parent.trackedPaths(), changes: try await parent.status())
        base.repositories[root.path] = try await parent.finderMetadata()
        cache.replaceSubtree(root: root, snapshots: [base] + initial.snapshots)
        XCTAssertTrue(cache.roots.contains(inner.path))
        _ = try await parent.run(["submodule", "deinit", "-f", "--", "modules/outer 雪\n"])
        let refreshed = try await parent.finderSubmoduleSnapshots(authorizedRoot: root)
        XCTAssertTrue(refreshed.snapshots.isEmpty); XCTAssertTrue(refreshed.failures.isEmpty)
        base = FinderSnapshot.build(root: root, tracked: try await parent.trackedPaths(), changes: try await parent.status())
        cache.replaceSubtree(root: root, snapshots: [base] + refreshed.snapshots)
        XCTAssertFalse(cache.roots.contains(outer.path)); XCTAssertFalse(cache.roots.contains(inner.path))
        XCTAssertNil(cache.repositories[outer.path]); XCTAssertFalse(cache.states.keys.contains { $0.hasPrefix(outer.path + "/") })
        XCTAssertTrue(cache.roots.contains(root.path + "-other")); XCTAssertEqual(cache.states[root.path + "-other/file"], .normal)
    }
    func testUnsafeConfiguredPathsAreReportedAndNotScanned() async throws {
        let (root, parent, _) = try await GitPatchTests().fixture()
        let (outside, outsideRepo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: outside.path)
        try Data().write(to: root.appendingPathComponent("not-directory"))
        let modules = root.appendingPathComponent(".gitmodules")
        for (name, value) in [("link", "escape"), ("traversal", "../outside"), ("file", "not-directory"), ("absent", "missing")] {
            _ = try await parent.run(["config", "--file", modules.path, "submodule." + name + ".path", value])
        }
        let head = try await outsideRepo.run(["rev-parse", "HEAD"]).stdout
        let scan = try await parent.finderSubmoduleSnapshots(authorizedRoot: root)
        XCTAssertTrue(scan.snapshots.isEmpty); XCTAssertEqual(scan.failures.count, 3)
        let after = try await outsideRepo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(head, after)
        do { _ = try await parent.finderSubmoduleSnapshots(authorizedRoot: outside); XCTFail("Outside grant accepted") } catch {}
    }
    func testIndependentlyOpenedNestedRepositorySurvivesParentRefresh() {
        let root = URL(fileURLWithPath: "/repo", isDirectory: true)
        var cache = FinderSnapshot(roots: ["/repo", "/repo/independent", "/repo/removed-module"],
            states: ["/repo/independent": .normal, "/repo/independent/file": .modified, "/repo/removed-module/file": .normal],
            repositories: ["/repo/independent": FinderRepositoryMetadata(hasStash: true),
                "/repo/removed-module": FinderRepositoryMetadata(submoduleParentRoot: "/repo")])
        let refreshedParent = FinderSnapshot(roots: ["/repo"], states: ["/repo": .untracked, "/repo/independent": .untracked])
        cache.replaceSubtree(root: root, snapshots: [refreshedParent])
        XCTAssertTrue(cache.roots.contains("/repo/independent"))
        XCTAssertEqual(cache.states["/repo/independent"], .normal)
        XCTAssertEqual(cache.states["/repo/independent/file"], .modified)
        XCTAssertEqual(cache.repositories["/repo/independent"]?.hasStash, true)
        XCTAssertFalse(cache.roots.contains("/repo/removed-module"))
        XCTAssertNil(cache.states["/repo/removed-module/file"])
    }
    func testSubtreeReplacementKeepsParentGitlinkStateAndOtherRoots() {
        let root = URL(fileURLWithPath: "/repo", isDirectory: true)
        var cache = FinderSnapshot(roots: ["/repo", "/repo/module", "/repo/removed", "/repo-other"],
            states: ["/repo/removed/file": .modified, "/repo-other/file": .normal],
            repositories: ["/repo/removed": FinderRepositoryMetadata(submoduleParentRoot: "/repo")])
        let parent = FinderSnapshot(roots: ["/repo"], states: ["/repo": .modified, "/repo/module": .modified])
        let child = FinderSnapshot(roots: ["/repo/module"], states: ["/repo/module": .normal, "/repo/module/file": .normal],
            repositories: ["/repo/module": FinderRepositoryMetadata(submoduleParentRoot: "/repo")])
        cache.replaceSubtree(root: root, snapshots: [child, parent])
        XCTAssertEqual(cache.states["/repo/module"], .modified)
        XCTAssertEqual(cache.states["/repo/module/file"], .normal)
        XCTAssertFalse(cache.roots.contains("/repo/removed")); XCTAssertNil(cache.repositories["/repo/removed"])
        XCTAssertNil(cache.states["/repo/removed/file"]); XCTAssertEqual(cache.states["/repo-other/file"], .normal)
        XCTAssertEqual(cache.repositoryMetadata(for: [URL(fileURLWithPath: "/repo/module/file")])?.submoduleParentRoot, "/repo")
    }
}
