import XCTest
import Darwin
@testable import TurtleGitCore

final class RebaseProgressTests:XCTestCase {
    final class Receipts:@unchecked Sendable {
        private let lock=NSLock();private var storage=[RebaseProgress]()
        func append(_ value:RebaseProgress){lock.lock();storage.append(value);lock.unlock()}
        var values:[RebaseProgress]{lock.lock();defer{lock.unlock()};return storage}
    }
    func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    func wait(_ condition:@escaping ()->Bool)async throws {
        let deadline=Date().addingTimeInterval(15)
        while !condition() {if Date()>deadline {throw NSError(domain:"RebaseProgressTests",code:1,userInfo:[NSLocalizedDescriptionKey:"Owned progress milestone not observed"])};try await Task.sleep(nanoseconds:20_000_000)}
    }
    func testLiveLogicalMilestonesArriveWhileGitIsHeldAndIgnoreFakeHumanCounts()async throws {
        let(root,repo,_)=try await RebaseTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        var options=RebaseTests().options();options.force=true
        let plan=try await repo.rebasePlan(options),receipts=Receipts(),token=OperationCancellation()
        let hooks=root.appendingPathComponent(".git/progress-hooks",isDirectory:true),gate=root.appendingPathComponent(".git/progress-gate",isDirectory:true)
        try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:gate,withIntermediateDirectories:true)
        let hook=hooks.appendingPathComponent("prepare-commit-msg")
        let script="""
        #!/bin/sh
        gate=\(quote(gate.path))
        n=0; [ ! -f "$gate/count" ] || read n < "$gate/count"
        n=$((n + 1)); printf '%s\n' "$n" > "$gate/count"
        printf '%s\n' "$$" > "$gate/pid-$n"
        printf 'Rebasing (999/1) unrelated localized diagnostic\n' >&2
        : > "$gate/entered-$n"
        while [ ! -f "$gate/release-$n" ]; do /bin/sleep 0.02; done
        """
        try Data(script.utf8).write(to:hook);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        _=try await repo.run(["config","core.hooksPath",hooks.path])
        let operation=Task {try await repo.startRebase(plan,editorExecutable:RebaseTests().editor,cancellation:token,onProgress:{receipts.append($0)})}
        do {
            var session:String?
            for step in 1...plan.entries.count {
                try await wait {FileManager.default.fileExists(atPath:gate.appendingPathComponent("entered-\(step)").path) && receipts.values.contains{$0.currentStep==step && !$0.finished}}
                let actual=try XCTUnwrap(receipts.values.last)
                XCTAssertEqual(actual.entries.map(\.id),plan.entries.map(\.id));XCTAssertEqual(actual.entries.map(\.action),plan.entries.map(\.action))
                XCTAssertEqual(actual.currentEntryID,plan.entries[step-1].id);XCTAssertEqual(actual.completed,step-1);XCTAssertEqual(actual.total,plan.entries.count)
                XCTAssertTrue(GitLocalReferenceProtocol.validOID(actual.head));if let session {XCTAssertEqual(actual.sessionID,session)}else{session=actual.sessionID}
                try Data().write(to:gate.appendingPathComponent("release-\(step)"))
            }
            let result=try await operation.value;XCTAssertEqual(result.exitCode,0,result.output);XCTAssertFalse(result.state.active)
            let final=try XCTUnwrap(receipts.values.last);XCTAssertTrue(final.finished);XCTAssertEqual(final.completed,plan.entries.count);XCTAssertNil(final.currentEntryID)
            XCTAssertEqual(final.sessionID,session);let head=try await repo.rebaseCommit("HEAD");XCTAssertEqual(final.head,head.hash)
            for step in 1...plan.entries.count {let pid=try String(contentsOf:gate.appendingPathComponent("pid-\(step)"),encoding:.utf8);XCTAssertNotEqual(kill(Int32(pid.trimmingCharacters(in:.newlines))!,0),0)}
        }catch {
            token.cancel();for step in 1...plan.entries.count {try? Data().write(to:gate.appendingPathComponent("release-\(step)"))};_=try? await operation.value;throw error
        }
    }
    func testStructuralInternalCommandsAndSkippedRowsRetainSourceLogicalCountsAcrossContinue()async throws {
        let(root,repo,_)=try await RebaseTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        var options=RebaseTests().options();options.preserveMerges=true;options.force=true
        var plan=try await repo.rebasePlan(options);plan.entries[0].action = .edit;plan.entries[1].action = .skip
        let first=Receipts(),stopped=try await repo.startRebase(plan,editorExecutable:RebaseTests().editor,onProgress:{first.append($0)})
        XCTAssertTrue(stopped.state.isEditPause)
        let initial=try XCTUnwrap(first.values.last);XCTAssertEqual(initial.currentStep,1);XCTAssertEqual(initial.completed,0);XCTAssertEqual(initial.total,2);XCTAssertFalse(initial.finished)
        XCTAssertEqual(initial.entries.map(\.action),[.edit,.skip])
        let second=Receipts(),done=try await repo.continueRebase(editMessage:plan.entries[0].commit.message,editorExecutable:RebaseTests().editor,onProgress:{second.append($0)})
        XCTAssertFalse(done.state.active);XCTAssertEqual(done.exitCode,0,done.output)
        let final=try XCTUnwrap(second.values.last);XCTAssertTrue(final.finished);XCTAssertEqual(final.completed,2);XCTAssertEqual(final.total,2);XCTAssertEqual(final.sessionID,initial.sessionID)
        XCTAssertTrue((first.values+second.values).allSatisfy{$0.total==2 && $0.currentStep<=2 && $0.completed<=2})
    }
    func testRepeatedCherryPickOccurrencesRetainDistinctIdentityAndOriginalActions()async throws {
        let(root,original,_)=try await GitPatchTests().fixture();let repo=GitRepository(root:root,executable:URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? original.executable.path));defer{try? FileManager.default.removeItem(at:root)}
        let base=try await repo.rebaseCommit("HEAD")
        try Data("repeat\n".utf8).write(to:root.appendingPathComponent("repeat.txt"));try await repo.stage(["repeat.txt"]);_=try await repo.run(["commit","-m","add repeated path"])
        let add=try await repo.rebaseCommit("HEAD");_=try await repo.run(["rm","repeat.txt"]);_=try await repo.run(["commit","-m","remove repeated path"])
        let remove=try await repo.rebaseCommit("HEAD");_=try await repo.run(["checkout","--detach",base.hash])
        let originalPlan=try await repo.cherryPickPlan(revisions:[remove.hash,add.hash])
        let plan=try await repo.addingRebaseCommits(originalPlan,revisions:[add.hash]),receipts=Receipts()
        XCTAssertNotEqual(plan.entries[0].id,plan.entries[2].id)
        let done=try await repo.startRebase(plan,editorExecutable:RebaseTests().editor,onProgress:{receipts.append($0)})
        XCTAssertEqual(done.exitCode,0,done.output);XCTAssertFalse(done.state.active)
        let final=try XCTUnwrap(receipts.values.last);XCTAssertEqual(final.entries.map(\.id),plan.entries.map(\.id));XCTAssertEqual(final.entries.map(\.action),plan.entries.map(\.action));XCTAssertEqual(final.completed,3)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("repeat.txt"),encoding:.utf8),"repeat\n")
    }
    func testObserverRejectsReplacementSessionAndCancellationWithoutLateCallbacks()async throws {
        let(root,repo,_)=try await RebaseTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        var plan=try await repo.rebasePlan(RebaseTests().options());plan.entries[0].action = .edit
        _=try await repo.startRebase(plan,editorExecutable:RebaseTests().editor)
        let directory=root.appendingPathComponent(".git/rebase-merge",isDirectory:true),saved=root.appendingPathComponent(".git/retired-progress-session",isDirectory:true),head=root.appendingPathComponent(".git/HEAD")
        let receipts=Receipts(),observer=RebaseProgressObservation(directory:directory,headFile:head,plan:nil,cancellation:nil,callback:{receipts.append($0)})
        observer.sample(force:true);XCTAssertFalse(receipts.values.isEmpty);let before=receipts.values
        try FileManager.default.moveItem(at:directory,to:saved);try FileManager.default.copyItem(at:saved,to:directory)
        observer.sample(force:true);XCTAssertEqual(receipts.values,before)
        try FileManager.default.removeItem(at:directory);try FileManager.default.moveItem(at:saved,to:directory)
        observer.sample(force:true);XCTAssertEqual(receipts.values,before,"Retired session cannot become current again")
        let token=OperationCancellation(),cancelled=Receipts(),second=RebaseProgressObservation(directory:directory,headFile:head,plan:nil,cancellation:token,callback:{cancelled.append($0)})
        token.cancel();second.sample(force:true);second.finish(head:before[0].head);XCTAssertTrue(cancelled.values.isEmpty)
        _=try await repo.abortRebase()
    }
}
