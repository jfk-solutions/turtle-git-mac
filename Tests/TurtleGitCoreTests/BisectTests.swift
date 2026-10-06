import XCTest
@testable import TurtleGitCore

final class BisectTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, [String]) {
        let (root, _, _) = try await GitPatchTests().fixture()
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_BISECT_TEST_GIT"] ?? "/usr/bin/git")
        let repo = GitRepository(root: root, executable: executable)
        var hashes = [try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)]
        for number in 1...7 {
            try Data("\(number)\n".utf8).write(to: root.appendingPathComponent("change"))
            try await repo.stage(["change"]); _ = try await repo.commit(message: "step \(number)")
            hashes.append(try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines))
        }
        return (root, repo, hashes)
    }
    func testFindRegressionReopenAndResetRestoresBranch() async throws {
        let (root, repo, hashes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let start = try await repo.startBisect(good: hashes[0], bad: hashes[7])
        XCTAssertEqual(start.exitCode, 0); XCTAssertTrue(start.state.active); XCTAssertEqual(start.state.originalRevision, "main")
        let reopened = GitRepository(root: root, executable: repo.executable)
        var state = try await reopened.bisectState()
        for _ in 0..<10 {
            if state.head == hashes[4], state.firstBadCommit == hashes[4] { break }
            let index = try XCTUnwrap(hashes.firstIndex(of: state.head))
            let result = try await reopened.bisect(index >= 4 ? .bad : .good)
            XCTAssertEqual(result.exitCode, 0); state = result.state
        }
        XCTAssertEqual(state.head, hashes[4]); XCTAssertEqual(state.firstBadCommit, hashes[4], state.log)
        let reset = try await reopened.bisect(.reset)
        XCTAssertEqual(reset.exitCode, 0); XCTAssertFalse(reset.state.active); XCTAssertEqual(reset.state.head, hashes[7])
        let branch = try await repo.branch(); XCTAssertEqual(branch, "main")
    }
    func testCustomTermsBatchSkipAndAmbiguousResultRemainRecoverable() async throws {
        let (root, repo, hashes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["bisect", "start", "--term-good=old", "--term-bad=new", hashes[7], hashes[0]])
        let state = try await repo.bisectState(); XCTAssertEqual(state.goodTerm, "old"); XCTAssertEqual(state.badTerm, "new")
        let classified = try await repo.bisect(.good, revisions: [hashes[1]])
        XCTAssertEqual(classified.exitCode, 0); XCTAssertTrue(classified.state.log.contains("git bisect old"))
        let skipped = try await repo.bisect(.skip, revisions: Array(hashes[2...6]))
        XCTAssertNotEqual(skipped.exitCode, 0); XCTAssertTrue(skipped.state.active); XCTAssertTrue(skipped.output.contains("could be any of"))
        let reset = try await repo.bisect(.reset); XCTAssertFalse(reset.state.active)
    }
    func testPreflightRejectsDirtyInvalidBareAndExistingSessions() async throws {
        let (root, repo, hashes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for invalid in ["--help", "missing", ""] {
            do { _ = try await repo.startBisect(good: invalid, bad: "HEAD"); XCTFail("Invalid good accepted") } catch is BisectFailure {}
            do { _ = try await repo.startBisect(good: hashes[0], bad: invalid); XCTFail("Invalid bad accepted") } catch is BisectFailure {}
        }
        try Data("dirty".utf8).write(to: root.appendingPathComponent("change"))
        do { _ = try await repo.startBisect(good: hashes[0], bad: "HEAD"); XCTFail("Dirty tree accepted") } catch BisectFailure.dirty {}
        try await repo.stage(["change"])
        do { _ = try await repo.startBisect(good: hashes[0], bad: "HEAD"); XCTFail("Dirty index accepted") } catch BisectFailure.dirty {}
        let idle = try await repo.bisectState(); XCTAssertFalse(idle.active); XCTAssertEqual(idle.head, hashes[7])
        _ = try await repo.run(["reset", "--hard", "HEAD"])
        do { _ = try await repo.bisect(.good); XCTFail("Inactive operation accepted") } catch BisectFailure.inactive {}
        _ = try await repo.startBisect(good: hashes[0], bad: "HEAD")
        do { _ = try await repo.startBisect(good: hashes[0], bad: "HEAD"); XCTFail("Active start accepted") } catch BisectFailure.active {}
        do { _ = try await repo.bisect(.good, revisions: Array(hashes[0...1])); XCTFail("Multiple good accepted") } catch BisectFailure.operation {}
        do { _ = try await repo.bisect(.reset, revisions: [hashes[0]]); XCTFail("Reset target accepted") } catch BisectFailure.operation {}
        _ = try await repo.bisect(.reset)
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", "--", root.path, bareRoot.path])
        do { _ = try await GitRepository(root: bareRoot, executable: repo.executable).startBisect(good: hashes[0], bad: "HEAD"); XCTFail("Bare start accepted") } catch BisectFailure.workingTree {}
    }
    func testFailedCheckoutKeepsUntrackedFileAndExposesResetRecovery() async throws {
        let (root, repo, hashes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let obstructing = root.appendingPathComponent("obstructing")
        try Data("tracked intermediate".utf8).write(to: obstructing)
        try await repo.stage(["obstructing"]); _ = try await repo.commit(message: "introduce obstruction")
        let good = hashes[7]
        for number in 0..<4 { _ = try await repo.run(["commit", "--allow-empty", "-m", "middle \(number)"]) }
        _ = try await repo.run(["rm", "--", "obstructing"]); _ = try await repo.commit(message: "remove obstruction")
        let original = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let untracked = Data("keep untracked bytes".utf8); try untracked.write(to: obstructing)
        let execution = try await repo.startBisect(good: good, bad: "HEAD")
        XCTAssertNotEqual(execution.exitCode, 0); XCTAssertTrue(execution.state.active)
        XCTAssertTrue(execution.output.contains("untracked working tree files"))
        XCTAssertEqual(try Data(contentsOf: obstructing), untracked)
        let reset = try await repo.bisect(.reset)
        XCTAssertEqual(reset.exitCode, 0); XCTAssertFalse(reset.state.active); XCTAssertEqual(reset.state.head, original)
        XCTAssertEqual(try Data(contentsOf: obstructing), untracked)
    }
    func testLinkedWorktreeSessionUsesItsOwnMetadataAndResetTarget() async throws {
        let (root, repo, hashes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("linked 雪")
        _ = try await repo.run(["worktree", "add", "-b", "bisect-child", child.path, hashes[7]])
        let linked = GitRepository(root: child, executable: repo.executable)
        let start = try await linked.startBisect(good: hashes[0], bad: "HEAD")
        XCTAssertTrue(start.state.active); XCTAssertEqual(start.state.originalRevision, "bisect-child")
        let parent = try await repo.bisectState(); XCTAssertFalse(parent.active); XCTAssertEqual(parent.head, hashes[7])
        let reopened = GitRepository(root: child, executable: repo.executable)
        let reset = try await reopened.bisect(.reset); XCTAssertFalse(reset.state.active); XCTAssertEqual(reset.state.head, hashes[7])
        let branch = try await linked.branch(); XCTAssertEqual(branch, "bisect-child")
    }
}
