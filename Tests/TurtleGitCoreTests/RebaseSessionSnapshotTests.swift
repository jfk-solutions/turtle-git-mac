import XCTest
@testable import TurtleGitCore

final class RebaseSessionSnapshotTests:XCTestCase {
    func testContinuationRefusesChangedResolutionAndHeadBeforeMutatingReplay() async throws {
        let tests=RebaseTests(),(root,repo,path)=try await tests.fixture(conflict:true)
        defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.startRebase(try await repo.rebasePlan(tests.options()),editorExecutable:tests.editor)
        let old=try await repo.rebaseSessionSnapshot()
        try Data("resolved continuation\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path])
        let current=try await repo.rebaseSessionSnapshot(retaining:old.identity)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        do {_ = try await repo.continueRebase(expectedReplayState:old.state,expectedReplayHead:old.head);XCTFail("Changed resolution accepted")} catch RebaseFailure.changed {}
        do {_ = try await repo.continueRebase(expectedReplayState:current.state,expectedReplayHead:String(repeating:"0",count:40));XCTFail("Wrong HEAD accepted")} catch RebaseFailure.changed {}
        try await repo.validateRebaseContinuation(expected:current.state,expectedHead:current.head)
        XCTAssertEqual(index,try Data(contentsOf:root.appendingPathComponent(".git/index")))
        let head=try await repo.rebaseCommit("HEAD");XCTAssertEqual(head.hash,current.head)
        let result=try await repo.continueRebase(expectedReplayState:current.state,expectedReplayHead:current.head)
        XCTAssertEqual(result.exitCode,0);XCTAssertFalse(result.state.active)
    }
    func testCancelledContinuationAndValidationPreserveActiveResolvedReplay() async throws {
        let tests=RebaseTests(),(root,repo,path)=try await tests.fixture(conflict:true)
        defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.startRebase(try await repo.rebasePlan(tests.options()),editorExecutable:tests.editor)
        try Data("resolved cancellation\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path])
        let captured=try await repo.rebaseSessionSnapshot(),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let token=OperationCancellation();token.cancel()
        do {try await repo.validateRebaseContinuation(expected:captured.state,expectedHead:captured.head,cancellation:token);XCTFail("Cancelled validation ran")} catch is OperationCancellationFailure {}
        do {_ = try await repo.continueRebase(expectedReplayState:captured.state,expectedReplayHead:captured.head,cancellation:token);XCTFail("Cancelled continue ran")} catch is OperationCancellationFailure {}
        XCTAssertEqual(index,try Data(contentsOf:root.appendingPathComponent(".git/index")))
        let state=try await repo.rebaseState();XCTAssertTrue(state.active);XCTAssertEqual(state.currentStep,captured.state.currentStep)
        _ = try await repo.abortRebase()
    }

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
    func testConflictSnapshotCarriesActualIndexFlagsWithoutChangingIndexOrConflictStages() async throws {
        let tests=RebaseTests(),(root,repo,_)=try await tests.fixture(conflict:true);defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.startRebase(try await repo.rebasePlan(tests.options()),editorExecutable:tests.editor)
        let path="flagged 雪.txt";try Data("private flag content\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path])
        _ = try await repo.run(["update-index","--assume-unchanged","--",path])
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),stages=try await repo.run(["ls-files","--unmerged","-z"]).stdout
        let snapshot=try await repo.rebaseSessionSnapshot()
        let flags=try XCTUnwrap(snapshot.indexFlags[path]);XCTAssertTrue(flags.assumeUnchanged);XCTAssertFalse(flags.skipWorktree)
        let entry=try XCTUnwrap(snapshot.rows.first {$0.path==path})
        XCTAssertTrue(IndexFlagAction.clear.isAvailable(for:entry,flags:flags))
        XCTAssertFalse(IndexFlagAction.skipWorktree.isAvailable(for:entry,flags:flags))
        XCTAssertFalse(IndexFlagAction.assumeUnchanged.isAvailable(for:entry,flags:flags))
        let conflict=try XCTUnwrap(snapshot.rows.first {$0.state == .conflicted})
        XCTAssertFalse(IndexFlagAction.skipWorktree.isAvailable(for:conflict,flags:FinderIndexFlags()))
        XCTAssertEqual(index,try Data(contentsOf:root.appendingPathComponent(".git/index")))
        let after=try await repo.run(["ls-files","--unmerged","-z"]).stdout;XCTAssertEqual(stages,after)
    }
    func testUnbornSnapshotHasNoRecoveryOrReplayData() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit.UnbornSnapshot."+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root);_ = try await repo.run(["init","-b","main"])
        let snapshot=try await repo.rebaseSessionSnapshot()
        XCTAssertFalse(snapshot.state.active);XCTAssertTrue(snapshot.head.isEmpty);XCTAssertNil(snapshot.identity);XCTAssertTrue(snapshot.remaining.isEmpty)
    }
}
