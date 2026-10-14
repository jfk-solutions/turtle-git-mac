import XCTest
@testable import TurtleGitCore

final class RebaseSessionSnapshotTests:XCTestCase {
    func testConflictSnapshotRetainsResolvedCheckedFileRecoveryAndReplayRows() async throws {
        let tests=RebaseTests(),(root,repo,path)=try await tests.fixture(conflict:true);defer {try? FileManager.default.removeItem(at:root)}
        let plan=try await repo.rebasePlan(tests.options());let stopped=try await repo.startRebase(plan,editorExecutable:tests.editor)
        XCTAssertNotEqual(stopped.exitCode,0);let snapshot=try await repo.rebaseSessionSnapshot()
        XCTAssertTrue(snapshot.fileRecovery);XCTAssertEqual(snapshot.rows.map(\.path),[path]);XCTAssertEqual(snapshot.conflicts.map(\.path),[path]);XCTAssertFalse(snapshot.remaining.isEmpty);XCTAssertFalse(snapshot.replay.isEmpty)
        try Data("resolved\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path])
        let resolved=try await repo.rebaseSessionSnapshot(retaining:snapshot.identity)
        XCTAssertTrue(resolved.fileRecovery);XCTAssertTrue(resolved.conflicts.isEmpty);XCTAssertEqual(resolved.identity,snapshot.identity);XCTAssertTrue(resolved.rows.contains {$0.path == path})
        _ = try await repo.abortRebase();let ended=try await repo.rebaseSessionSnapshot(retaining:snapshot.identity)
        XCTAssertFalse(ended.state.active);XCTAssertFalse(ended.fileRecovery);XCTAssertNil(ended.identity);XCTAssertTrue(ended.rows.isEmpty);XCTAssertTrue(ended.replay.isEmpty)
    }
    func testCherryPickSnapshotPreservesSessionKindAndStoppedIdentity() async throws {
        let tests=RebaseTests(),(root,repo,path)=try await tests.fixture(conflict:true);defer {try? FileManager.default.removeItem(at:root)}
        let topic=try await repo.rebaseCommit("topic~1");_ = try await repo.run(["switch","upstream"])
        let plan=try await repo.cherryPickPlan(revisions:[topic.hash]);_ = try await repo.startRebase(plan,editorExecutable:tests.editor)
        let snapshot=try await repo.rebaseSessionSnapshot()
        XCTAssertTrue(snapshot.state.isCherryPick);XCTAssertTrue(snapshot.identity?.cherryPick == true);XCTAssertEqual(snapshot.state.stoppedCommit,topic.hash);XCTAssertEqual(snapshot.rows.map(\.path),[path])
        _ = try await repo.abortRebase()
    }
    func testCancelledSnapshotReadLeavesActiveConflictAndWorkingBytesUntouched() async throws {
        let tests=RebaseTests(),(root,repo,path)=try await tests.fixture(conflict:true);defer {try? FileManager.default.removeItem(at:root)}
        let plan=try await repo.rebasePlan(tests.options());_ = try await repo.startRebase(plan,editorExecutable:tests.editor)
        let bytes=try Data(contentsOf:root.appendingPathComponent(path)),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.rebaseSessionSnapshot(cancellation:token);XCTFail("Cancelled snapshot accepted")}catch is OperationCancellationFailure {}
        let after=try await repo.rebaseSessionSnapshot()
        XCTAssertTrue(after.fileRecovery);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),bytes)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(afterHead,head);_ = try await repo.abortRebase()
    }
    func testUnbornSnapshotHasNoRecoveryOrReplayData() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit.UnbornSnapshot."+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root);_ = try await repo.run(["init","-b","main"])
        let snapshot=try await repo.rebaseSessionSnapshot()
        XCTAssertFalse(snapshot.state.active);XCTAssertTrue(snapshot.head.isEmpty);XCTAssertNil(snapshot.identity);XCTAssertTrue(snapshot.remaining.isEmpty)
    }
}
