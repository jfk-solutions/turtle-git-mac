import XCTest
@testable import TurtleGitCore

final class SynchronizationTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-sync-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/git")
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Sync QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        _ = try await repo.commit(message: "base")
        let base = try await hash(repo)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", base])
        return (root, repo, base)
    }
    private func hash(_ repo: GitRepository) async throws -> String {
        String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func testBranchControlsUsePullTrackingRatherThanPushOverrides() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["origin", "publish"] { _ = try await repo.run(["remote", "add", name, "/tmp/" + name]) }
        for (key, value) in [("branch.main.remote", "origin"), ("branch.main.merge", "refs/heads/review/雪"), ("branch.main.pushRemote", "publish"), ("branch.main.pushbranch", "release"), ("remote.pushDefault", "publish")] { _ = try await repo.run(["config", key, value]) }
        _ = try await repo.run(["branch", "other"])
        _ = try await repo.run(["config", "branch.other.merge", "refs/tags/release \t"])
        // Packed refs can represent both spellings on normalization-insensitive APFS.
        let oid = try await hash(repo)
        let names = ["refs/heads/café", "refs/heads/cafe\u{301}"].sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        try Data(("# pack-refs with: sorted\n" + names.map { oid + " " + $0 + "\n" }.joined()).utf8).write(to: root.appendingPathComponent(".git/packed-refs"))
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let catalog = try await repo.synchronizationBranches()
        XCTAssertEqual(catalog.currentBranch, "main"); XCTAssertEqual(catalog.localBranches.count, 4)
        for spelling in ["café", "cafe\u{301}", "main", "other"] { XCTAssertTrue(catalog.localBranches.contains { GitReferenceName.equal($0, spelling) }) }
        XCTAssertEqual(catalog.remotes, ["origin", "publish"])
        XCTAssertEqual(catalog.trackedRemote, "origin"); XCTAssertEqual(catalog.trackedBranch, "review/雪")
        let other = try await repo.synchronizationBranches(localBranch: "other")
        XCTAssertEqual(other.trackedRemote, ""); XCTAssertEqual(other.trackedBranch, "tags/release")
        let untracked = try await repo.synchronizationBranches(localBranch: "absent")
        XCTAssertEqual(untracked.trackedRemote, ""); XCTAssertEqual(untracked.trackedBranch, "")
        _ = try await repo.run(["switch", "--detach"])
        let detached = try await repo.synchronizationBranches()
        XCTAssertEqual(detached.currentBranch, ""); XCTAssertEqual(detached.trackedRemote, "")
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.synchronizationBranches(cancellation: token); XCTFail("cancelled catalog read ran") } catch is OperationCancellationFailure {}
        do { _ = try await repo.synchronizationBranches(localBranch: "main\0bad"); XCTFail("NUL accepted") } catch SynchronizationFailure.invalidInput {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
    }
    func testAheadEqualMissingAndIncomingUsePinnedRevisions() async throws {
        let (root, repo, base) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let equal = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main")
        XCTAssertEqual(equal.disposition, .upToDate); XCTAssertFalse(equal.canEmailPatch); XCTAssertNil(equal.comparison)
        let path = "new 雪\t🐢.txt"
        try Data("new\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "outgoing")
        let tip = try await hash(repo)
        let ahead = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main")
        XCTAssertEqual(ahead.disposition, .outgoing); XCTAssertTrue(ahead.fastForward && ahead.canEmailPatch)
        XCTAssertEqual(ahead.commits.map(\.hash), [tip]); XCTAssertEqual(ahead.comparison?.files.map(\.path), [path]); XCTAssertEqual(ahead.mergeBase, base)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", tip])
        XCTAssertEqual(ahead.remoteHash, base) // The old snapshot remains pinned.
        let incoming = try await repo.synchronizationIncoming(from: base, to: tip)
        XCTAssertEqual(incoming.commits.map(\.hash), [tip]); XCTAssertEqual(incoming.comparison.files.map(\.path), [path])
        let unchanged = try await repo.synchronizationIncoming(from: tip, to: tip)
        XCTAssertTrue(unchanged.commits.isEmpty && unchanged.comparison.files.isEmpty)
        for remote in ["https://example.invalid/repository", "/tmp/repository", "host:path/to/repository", "C:\\repository"] {
            let unknown = try await repo.synchronizationOutgoing(localBranch: "missing", remote: remote, remoteBranch: "main", force: true)
            XCTAssertEqual(unknown.disposition, .unknownURL); XCTAssertNil(unknown.localHash); XCTAssertFalse(unknown.canEmailPatch)
        }
        let missing = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "absent", force: true)
        XCTAssertEqual(missing.disposition, .unknownRemoteBranch); XCTAssertTrue(missing.commits.isEmpty)
    }
    func testDivergedForceUsesMergeBaseAndPreservesIndexAndWorkingTree() async throws {
        let (root, repo, base) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["switch", "-c", "remote-tip"])
        try Data("remote\n".utf8).write(to: root.appendingPathComponent("remote")); try await repo.stage(["remote"]); _ = try await repo.commit(message: "remote change")
        let remote = try await hash(repo); _ = try await repo.run(["update-ref", "refs/remotes/origin/main", remote]); _ = try await repo.run(["switch", "main"])
        try Data("local\n".utf8).write(to: root.appendingPathComponent("local")); try await repo.stage(["local"]); _ = try await repo.commit(message: "local change")
        let tip = try await hash(repo)
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        try Data("unstaged\n".utf8).write(to: root.appendingPathComponent("file"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let blocked = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main")
        XCTAssertEqual(blocked.disposition, .needsForce); XCTAssertNil(blocked.comparison); XCTAssertFalse(blocked.canEmailPatch)
        let forced = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main", force: true)
        XCTAssertFalse(forced.fastForward); XCTAssertEqual(forced.mergeBase, base); XCTAssertEqual(forced.commits.map(\.hash), [tip])
        XCTAssertEqual(forced.comparison?.from, .revision(base)); XCTAssertEqual(forced.comparison?.files.map(\.path), ["local"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "unstaged\n")
        let head = try await hash(repo); XCTAssertEqual(head, tip)
        let behind = try await repo.synchronizationOutgoing(localBranch: base, remote: "origin", remoteBranch: "main", force: true)
        XCTAssertEqual(behind.disposition, .outgoing); XCTAssertTrue(behind.commits.isEmpty && behind.canEmailPatch)
    }
    func testSourceCopyDetectionRetainsOriginalPath() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("copied 雪"))
        try Data("modified\n".utf8).write(to: root.appendingPathComponent("file"))
        try await repo.stage(["file", "copied 雪"]); _ = try await repo.commit(message: "copy source")
        let snapshot = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main")
        let copied = snapshot.comparison!.files.first { $0.path == "copied 雪" }!
        XCTAssertTrue(copied.action.hasPrefix("C")); XCTAssertEqual(copied.oldPath, "file")
        XCTAssertTrue(snapshot.comparison!.options.detectCopies)
    }
    func testFullOutgoingWalkIsNotTruncatedToLogDefault() async throws {
        let (root, repo, base) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = String(decoding: try await repo.run(["rev-parse", "HEAD^{tree}"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        var tip = base
        for number in 0..<205 { tip = String(decoding: try await repo.run(["commit-tree", tree, "-p", tip, "-m", "sync \(number)"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        _ = try await repo.run(["update-ref", "refs/heads/main", tip])
        let snapshot = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main")
        XCTAssertEqual(snapshot.commits.count, 205); XCTAssertEqual(snapshot.commits.first?.hash, tip); XCTAssertTrue(snapshot.comparison!.files.isEmpty)
    }
    func testCancellationInvalidInputsAndUnrelatedForceWorkingCopyFallback() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repo.run(["show-ref"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.synchronizationOutgoing(localBranch: "main", remote: "origin", remoteBranch: "main", cancellation: token); XCTFail("Cancelled projection ran") } catch is OperationCancellationFailure {}
        do { _ = try await repo.synchronizationOutgoing(localBranch: "main\0bad", remote: "origin", remoteBranch: "main"); XCTFail("NUL accepted") } catch SynchronizationFailure.invalidInput {}
        let tree = String(decoding: try await repo.run(["rev-parse", "HEAD^{tree}"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let unrelated = String(decoding: try await repo.run(["commit-tree", tree, "-m", "unrelated root"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        try Data("working change\n".utf8).write(to: root.appendingPathComponent("file"))
        let forced = try await repo.synchronizationOutgoing(localBranch: unrelated, remote: "origin", remoteBranch: "main", force: true)
        XCTAssertEqual(forced.disposition, .outgoing); XCTAssertTrue(forced.canEmailPatch); XCTAssertNil(forced.mergeBase)
        XCTAssertEqual(forced.commits.map(\.hash), [unrelated]); XCTAssertEqual(forced.comparison?.from, .workingTree)
        XCTAssertEqual(forced.comparison?.files.map(\.path), ["file"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "working change\n")
        let refs = try await repo.run(["show-ref"]).stdout; XCTAssertEqual(refs, before); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
}
