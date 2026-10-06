import XCTest
@testable import TurtleGitCore

final class FinderRepositoryMetadataTests: XCTestCase {
    func testSnapshotCompatibilityAndRootSelection() throws {
        let info = FinderRepositoryMetadata(bare: true, bisectActive: true, hasStash: true)
        let snapshot = FinderSnapshot(roots: ["/repo", "/repo/nested"], states: ["/repo/file": .modified],
            repositories: ["/repo": info, "/repo/nested": FinderRepositoryMetadata(hasSubmoduleConfig: true)])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FinderSnapshot.self, from: data)
        XCTAssertEqual(decoded.repositories, snapshot.repositories)
        struct OldReader: Decodable { let roots: [String]; let states: [String: FileState]; let updated: Date }
        let old = try JSONDecoder().decode(OldReader.self, from: data)
        XCTAssertEqual(old.roots, snapshot.roots); XCTAssertEqual(old.states, snapshot.states); XCTAssertEqual(old.updated, snapshot.updated)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); legacy.removeValue(forKey: "repositories")
        let restored = try JSONDecoder().decode(FinderSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(restored.repositories.isEmpty)
        XCTAssertEqual(decoded.repositoryMetadata(for: [URL(fileURLWithPath: "/repo/nested/file")])?.hasSubmoduleConfig, true)
        XCTAssertEqual(decoded.repositoryMetadata(for: [URL(fileURLWithPath: "/repo/file")]), info)
        XCTAssertNil(decoded.repositoryMetadata(for: [URL(fileURLWithPath: "/repo-other/file")]))
        XCTAssertNil(decoded.repositoryMetadata(for: []))
    }
    func testRepositoryClauses() {
        let ordinary = FinderRepositoryMetadata()
        XCTAssertTrue(ordinary.allows(.stash))
        for action in [RepositoryAction.stashApply, .stashPop, .stashList, .submoduleUpdate] { XCTAssertFalse(ordinary.allows(action)) }
        let available = FinderRepositoryMetadata(hasStash: true, hasSubmoduleConfig: true)
        for action in [RepositoryAction.stashApply, .stashPop, .stashList, .submoduleUpdate] { XCTAssertTrue(available.allows(action)) }
        for info in [FinderRepositoryMetadata(bisectActive: true), FinderRepositoryMetadata(mergeActive: true)] {
            for action in [RepositoryAction.pull, .merge, .rebase] { XCTAssertFalse(info.allows(action)) }
            XCTAssertTrue(info.allows(.fetch)); XCTAssertTrue(info.allows(.commit))
        }
        XCTAssertTrue(FinderRepositoryMetadata(bisectActive: true).allows(.stash))
        XCTAssertFalse(FinderRepositoryMetadata(mergeActive: true).allows(.stash))
        XCTAssertTrue(ordinary.allows(.bisectStart))
        XCTAssertFalse(FinderRepositoryMetadata(bisectActive: true).allows(.bisectStart))
        XCTAssertFalse(FinderRepositoryMetadata(mergeActive: true).allows(.bisectStart))
        for action in [RepositoryAction.bisectGood, .bisectBad, .bisectSkip, .bisectReset] {
            XCTAssertFalse(ordinary.allows(action)); XCTAssertTrue(FinderRepositoryMetadata(bisectActive: true).allows(action))
        }
        let bare = FinderRepositoryMetadata(bare: true, hasStash: true, hasSubmoduleConfig: true)
        for action in RepositoryAction.allCases {
            XCTAssertEqual(bare.allows(action), [RepositoryAction.fetch, .push, .log, .reflog, .repositoryBrowser, .export, .worktreeList].contains(action))
        }
    }
    func testRealRegularRepositoryMarkersAndPackedStash() async throws {
        let folder = fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await prepare(folder.appendingPathComponent("repo 雪\n", isDirectory: true))
        let initial = try await repo.finderMetadata(); XCTAssertEqual(initial, FinderRepositoryMetadata())
        let gitDir = try await directory(repo)
        for name in ["BISECT_START", "MERGE_HEAD"] { try Data().write(to: gitDir.appendingPathComponent(name)) }
        try Data().write(to: repo.root.appendingPathComponent(".gitmodules"))
        let active = try await repo.finderMetadata(knownBare: false)
        XCTAssertTrue(active.bisectActive && active.mergeActive && active.hasSubmoduleConfig)
        for name in ["BISECT_START", "MERGE_HEAD"] { try FileManager.default.removeItem(at: gitDir.appendingPathComponent(name)) }
        try Data("changed".utf8).write(to: repo.root.appendingPathComponent("file"))
        _ = try await repo.run(["stash", "push", "-m", "metadata"])
        _ = try await repo.run(["pack-refs", "--all", "--prune"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("refs/stash").path))
        let packed = try await repo.finderMetadata(); XCTAssertTrue(packed.hasStash); XCTAssertFalse(packed.mergeActive || packed.bisectActive)
        _ = try await repo.run(["stash", "drop"])
        let dropped = try await repo.finderMetadata(); XCTAssertFalse(dropped.hasStash)
    }
    func testRealLinkedWorktreeMarkersAndBareRepository() async throws {
        let folder = fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await prepare(folder.appendingPathComponent("main", isDirectory: true))
        try Data("changed".utf8).write(to: repo.root.appendingPathComponent("file"))
        _ = try await repo.run(["stash", "push"])
        let linkedURL = folder.appendingPathComponent("linked", isDirectory: true)
        _ = try await repo.run(["worktree", "add", "-b", "linked", linkedURL.path])
        let linked = GitRepository(root: linkedURL)
        let mainDir = try await directory(repo), linkedDir = try await directory(linked)
        try Data().write(to: mainDir.appendingPathComponent("BISECT_START"))
        try Data().write(to: linkedDir.appendingPathComponent("MERGE_HEAD"))
        let main = try await repo.finderMetadata(), child = try await linked.finderMetadata()
        XCTAssertTrue(main.bisectActive && !main.mergeActive && main.hasStash)
        XCTAssertTrue(!child.bisectActive && child.mergeActive && child.hasStash)
        let bareURL = folder.appendingPathComponent("bare.git", isDirectory: true)
        _ = try await repo.run(["clone", "--bare", repo.root.path, bareURL.path])
        let bare = try await GitRepository(root: bareURL).finderMetadata()
        XCTAssertTrue(bare.bare); XCTAssertFalse(bare.bisectActive || bare.mergeActive || bare.hasSubmoduleConfig)
    }
    private func fixture() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMetadata-" + UUID().uuidString, isDirectory: true) }
    private func prepare(_ url: URL) async throws -> GitRepository {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let repo = GitRepository(root: url)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Metadata QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        try Data("initial".utf8).write(to: url.appendingPathComponent("file"))
        _ = try await repo.run(["add", "file"]); _ = try await repo.run(["commit", "-m", "Initial"])
        return repo
    }
    private func directory(_ repo: GitRepository) async throws -> URL {
        var bytes = try await repo.run(["rev-parse", "--absolute-git-dir"]).stdout
        if bytes.last == 10 { bytes.removeLast() }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }
}
