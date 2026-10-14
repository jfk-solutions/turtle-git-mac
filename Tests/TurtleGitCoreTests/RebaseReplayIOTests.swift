import XCTest
@testable import TurtleGitCore
final class RebaseReplayIOTests: XCTestCase {
    // CI runs swift test before building the Xcode app; use the same package
    // editor and explicit override as the other rebase integration families.
    func editor() -> URL { RebaseTests().editor }
    func testPreCancelledReplayEntryPointsDoNotMutateAndScopeDoesNotLeak() async throws {
        let (root,repo,plan)=try await RebaseTests().splitFixture();defer{try? FileManager.default.removeItem(at:root)}
        let before=try await repo.run(["rev-parse","HEAD"]).stdout,token=OperationCancellation();token.cancel()
        do {_ = try await repo.startRebase(plan,editorExecutable:editor(),cancellation:token);XCTFail("Started cancelled replay")}catch OperationCancellationFailure.cancelled{}
        do {_ = try await repo.continueRebase(cancellation:token);XCTFail("Continued cancelled replay")}catch OperationCancellationFailure.cancelled{}
        do {_ = try await repo.skipRebase(cancellation:token);XCTFail("Skipped cancelled replay")}catch OperationCancellationFailure.cancelled{}
        do {_ = try await repo.abortRebase(cancellation:token);XCTFail("Aborted cancelled replay")}catch OperationCancellationFailure.cancelled{}
        do {_ = try await repo.beginRebaseSplit(cancellation:token);XCTFail("Prepared cancelled Split")}catch OperationCancellationFailure.cancelled{}
        let after=try await repo.run(["rev-parse","HEAD"]).stdout,state=try await repo.rebaseState();XCTAssertEqual(before,after);XCTAssertFalse(state.active)
    }
    final class Chunks:@unchecked Sendable {let lock=NSLock();var data=Data();func add(_ c:GitOutputChunk){lock.lock();data.append(c.data);lock.unlock()};func text()->String{lock.lock();defer{lock.unlock()};return String(decoding:data,as:UTF8.self)}}
    func testRunningContinueStreamsAndCancellationLeavesRecoverableSessionWithoutPoisoningLaterReads() async throws {
        let (root,real,plan)=try await RebaseTests().splitFixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await real.startRebase(plan,editorExecutable:editor())
        let helper=root.appendingPathComponent("gated-replay"),marker=root.appendingPathComponent(".git/replay-ready")
        let script = #"""
        #!/bin/sh
        replay=0;continue=0
        for argument in "$@";do [ "$argument" = rebase ] && replay=1;[ "$argument" = --continue ] && continue=1;done
        if [ "$replay" = 1 ] && [ "$continue" = 1 ];then
          printf 'Replay: 10%%\rReplay: 35%%\r\nUnicode ';printf '\351\233';/bin/sleep 0.05;printf '\252\n'
          : > "$3/.git/replay-ready"
          while :;do /bin/sleep 0.05;done
        fi
        exec "$TG_REPLAY_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_REPLAY_GIT",real.executable.path,1);defer{unsetenv("TG_REPLAY_GIT")}
        let repo=GitRepository(root:root,executable:helper),token=OperationCancellation(),chunks=Chunks(),head=try await real.run(["rev-parse","HEAD"]).stdout
        let operation=Task{try await repo.continueRebase(cancellation:token,onOutput:chunks.add)}
        var ready=false;for _ in 0..<1000{if FileManager.default.fileExists(atPath:marker.path) && chunks.text().contains("Unicode 雪"){ready=true;break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(ready);token.cancel();do {_ = try await operation.value;XCTFail("Cancelled command completed")}catch is GitCommandCancellationFailure{}
        let state=try await repo.rebaseState(),after=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertTrue(state.active);XCTAssertEqual(head,after);XCTAssertTrue(chunks.text().contains("Replay: 35%"));XCTAssertFalse(chunks.text().contains("refs/heads/topic"))
        _ = try await repo.abortRebase();let ended=try await repo.rebaseState();XCTAssertFalse(ended.active)
    }
    func testSplitCommitStreamsAndRetainsDurableContinuationAndFirstParents() async throws {
        let (root,repo,plan)=try await RebaseTests().splitFixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.startRebase(plan,editorExecutable:editor());let split=try await repo.beginRebaseSplit(),chunks=Chunks()
        var options=CommitOptions();options.amend=true;options.amendDiffToLastCommit=false
        _ = try await repo.commitRebaseSplit(message:"split part",paths:["left 雪\n.txt"],staging:false,options:options,expected:split,onOutput:chunks.add)
        let state=try await repo.rebaseState(),head=try await repo.rebaseCommit("HEAD")
        XCTAssertEqual(state.split?.parts,1);XCTAssertEqual(state.split?.expectedHead,head.hash);XCTAssertEqual(head.parents,split.firstParents);XCTAssertTrue(chunks.text().contains("split part"))
        _ = try await repo.abortRebase()
    }
    func testQueuedCancellationStillRecordsCompletedSplitPartBeforeReturning() async throws {
        let (root,real,plan)=try await RebaseTests().splitFixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await real.startRebase(plan,editorExecutable:editor());let split=try await real.beginRebaseSplit()
        let helper=root.appendingPathComponent("protected-commit"),marker=root.appendingPathComponent(".git/commit-ready"),release=root.appendingPathComponent(".git/commit-release")
        let script = #"""
        #!/bin/sh
        if [ "$4" = commit ];then
          : > "$3/.git/commit-ready"
          while [ ! -f "$3/.git/commit-release" ];do /bin/sleep 0.05;done
        fi
        exec "$TG_PROTECTED_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_PROTECTED_GIT",real.executable.path,1);defer{unsetenv("TG_PROTECTED_GIT")}
        let repo=GitRepository(root:root,executable:helper),token=OperationCancellation();var options=CommitOptions();options.amend=true;options.amendDiffToLastCommit=false
        let operation=Task{try await repo.commitRebaseSplit(message:"protected part",paths:["left 雪\n.txt"],staging:false,options:options,expected:split,cancellation:token)}
        var ready=false;for _ in 0..<1000{if FileManager.default.fileExists(atPath:marker.path){ready=true;break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(ready);token.cancel();try Data().write(to:release)
        do {_ = try await operation.value;XCTFail("Queued cancellation was lost")}catch OperationCancellationFailure.cancelled{}
        let state=try await repo.rebaseState(),head=try await repo.rebaseCommit("HEAD")
        XCTAssertEqual(state.split?.parts,1);XCTAssertEqual(state.split?.expectedHead,head.hash);XCTAssertEqual(head.parents,split.firstParents)
        _ = try await repo.abortRebase()
    }

    func testCancelledSkipRestoresProvisionalSquashBookkeepingWhenHeadDidNotAdvance() async throws {
        let (root,real,_)=try await RebaseTests().fixture(conflict:true);defer{try? FileManager.default.removeItem(at:root)}
        var plan=try await real.rebasePlan(RebaseTests().options());plan.entries[1].action = .squash
        _ = try await real.startRebase(plan,editorExecutable:editor())
        let helper=root.appendingPathComponent("gated-skip"),marker=root.appendingPathComponent(".git/skip-ready")
        let script = #"""
        #!/bin/sh
        skip=0;for arg in "$@";do [ "$arg" = --skip ] && skip=1;done
        if [ "$skip" = 1 ];then
          : > "$3/.git/skip-ready"
          while :;do /bin/sleep 0.05;done
        fi
        exec "$TG_SKIP_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_SKIP_GIT",real.executable.path,1);defer{unsetenv("TG_SKIP_GIT")}
        let repo=GitRepository(root:root,executable:helper),token=OperationCancellation(),operation=Task{try await repo.skipRebase(cancellation:token)}
        var ready=false;for _ in 0..<1000{if FileManager.default.fileExists(atPath:marker.path){ready=true;break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertTrue(ready);token.cancel();do {_ = try await operation.value;XCTFail("Cancelled Skip completed")}catch is GitCommandCancellationFailure{}
        let path=root.appendingPathComponent(".git/rebase-merge/turtlegit-skipped-steps.json")
        let skipped=try JSONDecoder().decode(Set<Int>.self,from:Data(contentsOf:path));XCTAssertTrue(skipped.isEmpty)
        _ = try await repo.abortRebase()
    }

}
