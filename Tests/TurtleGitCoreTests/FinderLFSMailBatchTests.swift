// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class FinderLFSMailBatchTests: XCTestCase {
    func testMetadataDefaultsMarkerLinkedWorktreeAndRoundTrip() async throws {
        let old = Data(#"{"bare":false,"bisectActive":false,"mergeActive":false,"hasStash":false,"hasSubmoduleConfig":false}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(FinderRepositoryMetadata.self, from: old).hasLFS)
        let (root, repo, _) = try await GitPatchTests().fixture()
        let linked = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: linked) }
        var metadata = try await repo.finderMetadata(); XCTAssertFalse(metadata.hasLFS)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/lfs"), withIntermediateDirectories: true)
        metadata = try await repo.finderMetadata(); XCTAssertTrue(metadata.hasLFS)
        XCTAssertEqual(try JSONDecoder().decode(FinderRepositoryMetadata.self, from: JSONEncoder().encode(metadata)), metadata)
        _ = try await repo.run(["worktree", "add", "-b", "linked", linked.path])
        let child = GitRepository(root: linked)
        let childMetadata = try await child.finderMetadata(); XCTAssertTrue(childMetadata.hasLFS)
        let snapshot = FinderSnapshot(roots: [root.path, linked.path], states: [:], repositories: [root.path: metadata, linked.path: childMetadata])
        let decoded = try JSONDecoder().decode(FinderSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.repositories[linked.path]?.hasLFS, true)
    }
    func testFinderLockTargetsAreLiteralVersionedFilesAndDoNotChangeGit() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repo.finderLFSPaths([path]); XCTFail("Unconfigured LFS accepted") } catch LFSLocksFailure.selection {}
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/lfs"), withIntermediateDirectories: true)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let paths = try await repo.finderLFSPaths([path, path]); XCTAssertEqual(paths, [path])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(afterHead, head)
        let untracked = "new 雪\nfile"; try Data().write(to: root.appendingPathComponent(untracked))
        for paths in [[untracked], [path, untracked], ["../escape"], [".git/config"]] {
            do { _ = try await repo.finderLFSPaths(paths); XCTFail("Invalid batch accepted") } catch {}
        }
        _ = try await repo.run(["rm", "--cached", "--", path])
        let deleted = try await repo.finderLFSPaths([path]); XCTAssertEqual(deleted, [path], "Staged deletions remain versioned in HEAD")
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.finderLFSPaths([path], cancellation: token); XCTFail("Canceled preflight executed") } catch {}
    }
    func testSourceNestedConditionsPreferencesAndURLGroups() throws {
        let file: FinderShellFlags = [.inGit, .inVersionedFolder, .onlyOne]
        XCTAssertTrue(FinderShellRules.allows(.lfs, flags: file)); XCTAssertFalse(FinderShellRules.allows(.lfsLocks, flags: file))
        XCTAssertTrue(FinderShellRules.allows(.lfsLock, flags: file)); XCTAssertTrue(FinderShellRules.allows(.lfsUnlock, flags: file))
        let folder = file.union([.folder, .folderInGit])
        XCTAssertTrue(FinderShellRules.allows(.lfsLocks, flags: folder)); XCTAssertFalse(FinderShellRules.allows(.lfsLock, flags: folder))
        XCTAssertTrue(FinderShellRules.allows(.sendMail, flags: [.patchFile]))
        XCTAssertTrue(FinderShellRules.allows(.sendMail, flags: [.extended]))
        XCTAssertFalse(FinderShellRules.allows(.sendMail, flags: [.extended, .folder]))
        XCTAssertFalse(FinderShellRules.allows(.sendMail, flags: file))
        var settings = FinderMenuSettings(); settings.set(.lfs, checked: true, extendedOnly: true)
        XCTAssertFalse(settings.visible(.lfs, extended: false)); XCTAssertTrue(settings.visible(.lfs, extended: true))
        for action in [RepositoryAction.lfsLocks, .lfsLock, .lfsUnlock] {
            XCTAssertEqual(FinderMenuEntry.entry(for: action), .lfs)
            let request = FinderRequest(action: action, paths: [URL(fileURLWithPath: "/repo/file 雪\n&?.txt")])
            XCTAssertEqual(try XCTUnwrap(FinderRequest(url: XCTUnwrap(request.url))).paths, request.paths)
        }
        XCTAssertNil(FinderRequest(action: .lfs, paths: [URL(fileURLWithPath: "/repo")]).url)
        XCTAssertNil(FinderRequest(url: URL(string: "turtlegit://action?command=lfs&path=%2Frepo")!))
        XCTAssertEqual(FinderMenuEntry.allCases.filter(\.availableInFinder).count, 49)
    }
}
