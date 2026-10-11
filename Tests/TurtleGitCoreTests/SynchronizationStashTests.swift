import XCTest
@testable import TurtleGitCore

final class SynchronizationStashTests: XCTestCase {
    private func fixture() async throws -> GitRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-sync-stash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var ready = false; defer { if !ready { try? FileManager.default.removeItem(at: root) } }
        let git = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/git")
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main", "--template="])
        for (key,value) in [("user.name","Stash QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked 雪"))
        _ = try await repo.run(["add","--all"]); _ = try await repo.run(["commit","-m","base"])
        ready = true; return repo
    }
    func testSaveTrackedWorkApplyRetainsAndPopDropsWithoutRestoringIndex() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.root) }
        let file = repo.root.appendingPathComponent("tracked 雪"), untracked = repo.root.appendingPathComponent("untracked")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        try Data("staged\n".utf8).write(to: file); _ = try await repo.run(["add","--","tracked 雪"])
        try Data("working\n".utf8).write(to: file); try Data("keep me\n".utf8).write(to: untracked)
        let saved = try await repo.synchronizationStash(.save)
        XCTAssertEqual(saved.command.exitCode,0); XCTAssertTrue(saved.conflicts.isEmpty)
        XCTAssertEqual(try String(contentsOf:file),"base\n"); XCTAssertTrue(FileManager.default.fileExists(atPath:untracked.path))
        let stash = try await repo.run(["rev-parse","refs/stash"]).stdout
        let applied = try await repo.synchronizationStash(.apply)
        XCTAssertEqual(applied.command.exitCode,0); XCTAssertEqual(try String(contentsOf:file),"working\n")
        let retained = try await repo.run(["rev-parse","refs/stash"]).stdout, staged = try await repo.run(["diff","--cached","--name-only"]).stdout
        XCTAssertEqual(retained,stash); XCTAssertTrue(staged.isEmpty)
        _ = try await repo.run(["reset","--hard","HEAD"])
        let popped = try await repo.synchronizationStash(.pop)
        XCTAssertEqual(popped.command.exitCode,0); XCTAssertEqual(try String(contentsOf:file),"working\n")
        let missing = try await repo.run(["rev-parse","--verify","refs/stash"],successfulExitCodes:0...255), finalHead = try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertNotEqual(missing.exitCode,0); XCTAssertEqual(finalHead,head)
    }
    func testFailedPopAndApplyReportActualConflictsAndRetainStash() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.root) }
        let file = repo.root.appendingPathComponent("tracked 雪")
        try Data("stashed change\n".utf8).write(to:file); _ = try await repo.synchronizationStash(.save)
        try Data("new branch change\n".utf8).write(to:file); _ = try await repo.run(["commit","-am","diverge"])
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, stash = try await repo.run(["rev-parse","refs/stash"]).stdout
        for action in [SynchronizationStashAction.pop,.apply] {
            let result = try await repo.synchronizationStash(action)
            XCTAssertNotEqual(result.command.exitCode,0); XCTAssertEqual(result.conflicts.map(\.path),["tracked 雪"]); XCTAssertNil(result.conflictCheckError)
            let retained = try await repo.run(["rev-parse","refs/stash"]).stdout, current = try await repo.run(["rev-parse","HEAD"]).stdout
            XCTAssertEqual(retained,stash); XCTAssertEqual(current,head)
            _ = try await repo.run(["reset","--hard","HEAD"])
        }
    }
    func testMissingStashBareAndPreCancelledOperations() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.root) }
        let missing = try await repo.synchronizationStash(.pop)
        XCTAssertNotEqual(missing.command.exitCode,0); XCTAssertTrue(missing.conflicts.isEmpty); XCTAssertNil(missing.conflictCheckError)
        let index = try Data(contentsOf:repo.root.appendingPathComponent(".git/index")), token = OperationCancellation(); token.cancel()
        do { _ = try await repo.synchronizationStash(.save,cancellation:token); XCTFail("Cancelled Save must not run") } catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),index)
        let bare = GitRepository(root:repo.root.appendingPathComponent("bare.git"),executable:repo.executable)
        _ = try await repo.run(["init","--bare","--template=",bare.root.path])
        do { _ = try await bare.synchronizationStash(.save); XCTFail("Bare roots have no stash worktree") } catch is SynchronizationStashFailure {}
    }
}
