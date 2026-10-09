import XCTest
@testable import TurtleGitCore

final class HistoryReferenceDeletionTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-reference-delete-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"] ?? "/usr/bin/git")
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Deletion QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        return (root, repo)
    }
    func testLocalTagOtherUnmergedAndCurrentGuards() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repo.prepareHistoryReferenceDeletion("refs/heads/main"); XCTFail() } catch HistoryReferenceDeletionFailure.current {}
        _ = try await repo.run(["checkout", "-b", "topic"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "unmerged"])
        _ = try await repo.run(["checkout", "main"])
        let branch = try await repo.prepareHistoryReferenceDeletion("refs/heads/topic")
        XCTAssertTrue(branch.unmerged); XCTAssertTrue(branch.message.contains("not fully merged")); XCTAssertEqual(branch.choices.map(\.title), ["Delete", "Abort"])
        _ = try await repo.run(["config", "branch.topic.remote", "origin"])
        _ = try await repo.deleteHistoryReference(branch, choice: .delete)
        let config = try await repo.run(["config", "--get", "branch.topic.remote"], successfulExitCodes: 0...1); XCTAssertEqual(config.exitCode, 1)
        _ = try await repo.run(["-c", "tag.gpgsign=false", "tag", "-a", "release", "-m", "annotated"])
        let tag = try await repo.prepareHistoryReferenceDeletion("refs/tags/release^{}")
        _ = try await repo.deleteHistoryReference(tag, choice: .delete)
        _ = try await repo.run(["update-ref", "refs/custom/extra", "HEAD"])
        let other = try await repo.prepareHistoryReferenceDeletion("refs/custom/extra")
        _ = try await repo.deleteHistoryReference(other, choice: .delete)
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        _ = try await repo.run(["symbolic-ref", "refs/custom/alias", "refs/heads/main"])
        let alias = try await repo.prepareHistoryReferenceDeletion("refs/custom/alias")
        _ = try await repo.deleteHistoryReference(alias, choice: .delete)
        let headAfter = try await repo.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(headAfter, head)
        let aliasAfter = try await repo.run(["symbolic-ref", "--quiet", "refs/custom/alias"], successfulExitCodes: 0...1); XCTAssertEqual(aliasAfter.exitCode, 1)
        for ref in ["refs/heads/topic", "refs/tags/release", "refs/custom/extra"] {
            let result = try await repo.run(["show-ref", "--verify", "--quiet", ref], successfulExitCodes: 0...1); XCTAssertEqual(result.exitCode, 1)
        }
    }
    func testStaleSnapshotAndStashChoices() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "topic"])
        let before = try await repo.prepareHistoryReferenceDeletion("refs/heads/topic")
        _ = try await repo.run(["commit", "--allow-empty", "-m", "next"])
        _ = try await repo.run(["update-ref", "refs/heads/topic", "HEAD"])
        do { _ = try await repo.deleteHistoryReference(before, choice: .delete); XCTFail() } catch HistoryReferenceDeletionFailure.changed {}
        for n in 1...2 { try Data("dirty \(n)\n".utf8).write(to: root.appendingPathComponent("file")); _ = try await repo.run(["stash", "push", "-m", "stash \(n)"]) }
        let stash = try await repo.prepareHistoryReferenceDeletion("refs/stash")
        XCTAssertEqual(stash.stashEntries.count, 2); XCTAssertEqual(stash.choices.map(\.title), ["Delete", "Drop one stash", "Abort"])
        _ = try await repo.deleteHistoryReference(stash, choice: .stashOne)
        let remaining = try await repo.prepareHistoryReferenceDeletion("refs/stash"); XCTAssertEqual(remaining.stashEntries.count, 1)
        _ = try await repo.deleteHistoryReference(remaining, choice: .stashAll)
        let entries = try await repo.referenceLog("refs/stash"); XCTAssertTrue(entries.isEmpty)
    }
    func testRemoteLocalAndRemoteServerChoices() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let server = root.appendingPathComponent("server.git")
        _ = try await repo.run(["init", "--bare", server.path]); _ = try await repo.run(["remote", "add", "origin", server.path])
        _ = try await repo.run(["push", "origin", "HEAD:refs/heads/topic"])
        let tracking = try await repo.prepareHistoryReferenceDeletion("refs/remotes/origin/topic")
        XCTAssertEqual(tracking.choices.count, 3)
        _ = try await repo.deleteHistoryReference(tracking, choice: .remoteLocal)
        let serverAfterLocal = try await repo.run(["--git-dir=" + server.path, "show-ref", "--verify", "refs/heads/topic"]); XCTAssertEqual(serverAfterLocal.exitCode, 0)
        _ = try await repo.run(["fetch", "origin"])
        let refreshed = try await repo.prepareHistoryReferenceDeletion("refs/remotes/origin/topic")
        _ = try await repo.deleteHistoryReference(refreshed, choice: .remoteAndLocal)
        let serverAfter = try await repo.run(["--git-dir=" + server.path, "show-ref", "--verify", "--quiet", "refs/heads/topic"], successfulExitCodes: 0...1); XCTAssertEqual(serverAfter.exitCode, 1)
        let localAfter = try await repo.run(["show-ref", "--verify", "--quiet", "refs/remotes/origin/topic"], successfulExitCodes: 0...1); XCTAssertEqual(localAfter.exitCode, 1)
    }
}
