import XCTest
@testable import TurtleGitCore

final class RebaseMainlineTests:XCTestCase {
    var editor:URL {RebaseTests().editor}
    struct Fixture {
        let root:URL,repo:GitRepository
        let base:LogEntry,merge:LogEntry,before:LogEntry,after:LogEntry
        var plan:RebasePlan
    }
    func commit(_ repo:GitRepository,_ path:String)async throws->LogEntry {
        try Data((path+"\n").utf8).write(to:repo.root.appendingPathComponent(path))
        try await repo.stage([path]);_ = try await repo.commit(message:path)
        return try await repo.rebaseCommit("HEAD")
    }
    func fixture(emptyMerge:Bool=false,repeated:Bool=false)async throws->Fixture {
        let (root,original,_)=try await GitPatchTests().fixture()
        var accepted=false;defer {if !accepted {try? FileManager.default.removeItem(at:root)}}
        let git=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? original.executable.path)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["config","core.hooksPath",root.appendingPathComponent(".git/disabled-hooks").path])
        let base=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["checkout","-b","left",base.hash]);_ = try await commit(repo,"left.txt")
        _ = try await repo.run(["checkout","-b","right",base.hash]);_ = try await commit(repo,"right.txt")
        _ = try await repo.run(["checkout","left"]);_ = try await repo.run(["merge","--no-ff","-m","merge source","right"])
        var merge=try await repo.rebaseCommit("HEAD")
        if emptyMerge {
            let file=root.appendingPathComponent(".git/raw-mainline-message")
            try Data("\nraw merge body\n".utf8).write(to:file)
            let tree=try await repo.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
            let hash=try await repo.run(["commit-tree",tree]+merge.parents.flatMap{["-p",$0]}+["-F",file.path],environmentOverrides:["GIT_AUTHOR_NAME":merge.author,"GIT_AUTHOR_EMAIL":merge.email,"GIT_AUTHOR_DATE":merge.date]).text.trimmingCharacters(in:.newlines)
            merge=try await repo.rebaseCommit(hash)
        }
        _ = try await repo.run(["checkout","-b","source",base.hash]);let before=try await commit(repo,"before.txt"),after=try await commit(repo,"after.txt")
        _ = try await repo.run(["checkout","-b","target",base.hash])
        var plan:RebasePlan
        if repeated {
            let initial=try await repo.cherryPickPlan(revisions:[merge.hash])
            plan=try await repo.addingRebaseCommits(initial,revisions:[merge.hash])
        } else {
            // Log selections are newest-first; execution reverses this order.
            plan=try await repo.cherryPickPlan(revisions:[after.hash,merge.hash,before.hash])
        }
        plan.options.addCherryPickedFrom=true
        accepted=true;return .init(root:root,repo:repo,base:base,merge:merge,before:before,after:after,plan:plan)
    }
    func decision(_ execution:RebaseExecution) throws -> RebaseMainlineDecision {
        try XCTUnwrap(execution.state.mainlineDecision,"Expected reached merge decision; exit=\(execution.exitCode) active=\(execution.state.active) step=\(execution.state.currentStep) stopped=\(execution.state.stoppedCommit) output=\(execution.output)")
    }
    func testReachedChoiceFollowsEarlierReplayAndMatchesBothGitMainlines()async throws {
        for parent in 1...2 {
            let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
            let result=try await f.repo.startRebase(f.plan,editorExecutable:editor)
            let decision=try self.decision(result)
            XCTAssertEqual(decision.entryID,f.plan.entries[1].id);XCTAssertEqual(decision.step,2);XCTAssertEqual(decision.parents,f.merge.parents)
            XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("before.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("after.txt").path))
            XCTAssertFalse(result.state.needsFileRecovery);XCTAssertNil(RebaseConflictIdentity(result.state));XCTAssertFalse(result.state.canSplit)
            let snapshot=try await f.repo.rebaseSessionSnapshot()
            XCTAssertFalse(snapshot.fileRecovery);XCTAssertEqual(snapshot.replay.map(\.id),f.plan.entries.map(\.id))
            XCTAssertEqual(snapshot.replay[1].action,.pick)
            let physicalTodo=try await f.repo.run(["rev-parse","--git-path","rebase-merge/git-rebase-todo"]).text.trimmingCharacters(in:.newlines)
            let todoURL=physicalTodo.hasPrefix("/") ? URL(fileURLWithPath:physicalTodo):f.root.appendingPathComponent(physicalTodo)
            let rawTodo=try String(contentsOf:todoURL,encoding:.utf8)
            XCTAssertTrue(rawTodo.contains("drop "+f.merge.hash),rawTodo)
            XCTAssertFalse(rawTodo.contains("pick "+f.merge.hash),rawTodo)
            let reopened=GitRepository(root:f.root,executable:f.repo.executable)
            let state=try await reopened.rebaseState();XCTAssertEqual(state.mainlineDecision,decision)
            do {_ = try await reopened.continueRebase();XCTFail("Unanswered choice continued")}catch RebaseFailure.mainline {}
            let completed=try await reopened.selectRebaseMainline(decision,parent:parent,expected:state,expectedHead:decision.head)
            XCTAssertEqual(completed.exitCode,0,completed.output);XCTAssertFalse(completed.state.active)
            let actualTree=try await reopened.run(["rev-parse","HEAD^{tree}"]).stdout
            let actual=try await reopened.rebaseCommit("HEAD~1")
            XCTAssertEqual(actual.author,f.merge.author);XCTAssertEqual(actual.email,f.merge.email);XCTAssertEqual(actual.date,f.merge.date)
            XCTAssertTrue(actual.message.contains("(cherry picked from commit "+f.merge.hash+")"))
            _ = try await reopened.run(["checkout","-b","expected",f.base.hash])
            _ = try await reopened.run(["cherry-pick","-x",f.before.hash])
            _ = try await reopened.run(["cherry-pick","-x","-m",String(parent),f.merge.hash])
            _ = try await reopened.run(["cherry-pick","-x",f.after.hash])
            let expectedTree=try await reopened.run(["rev-parse","HEAD^{tree}"]).stdout
            XCTAssertEqual(actualTree,expectedTree)
        }
    }
    func testEmptySubjectWarningPrecedesParentAndSkipAppliesNeither()async throws {
        let f=try await fixture(emptyMerge:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let initial=try await f.repo.startRebase(f.plan,editorExecutable:editor)
        let warning=try XCTUnwrap(initial.state.emptyMessageWarning,initial.output)
        XCTAssertNil(initial.state.mainlineDecision)
        let reached=try await f.repo.acknowledgeRebaseEmptyMessage(warning,expected:initial.state,expectedHead:warning.head)
        let choice=try decision(reached)
        XCTAssertEqual(choice.head,warning.head);XCTAssertEqual(choice.requestedAction,.pick)
        let approved=try await f.repo.selectRebaseMainline(choice,parent:1,expected:reached.state,expectedHead:choice.head)
        XCTAssertTrue(approved.state.isEditPause);XCTAssertEqual(approved.state.stoppedCommit,f.merge.hash)
        let finished=try await f.repo.continueRebase(editMessage:"Reviewed merge body\n",editorExecutable:editor)
        XCTAssertFalse(finished.state.active)
        let message=try await f.repo.rebaseCommit("HEAD~1")
        XCTAssertEqual(message.historySubject,"Reviewed merge body")
        _ = try await f.repo.run(["checkout","-B","target",f.base.hash])
        let again=try await f.repo.cherryPickPlan(revisions:[f.after.hash,f.merge.hash])
        let empty=try await f.repo.startRebase(again,editorExecutable:editor)
        XCTAssertNotNil(empty.state.emptyMessageWarning)
        let skipped=try await f.repo.skipRebase()
        XCTAssertFalse(skipped.state.active);XCTAssertNil(skipped.state.mainlineDecision)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("right.txt").path))
        _ = try await f.repo.run(["checkout","-B","target",f.base.hash])
        let lastPlan=try await f.repo.cherryPickPlan(revisions:[f.after.hash,f.merge.hash])
        let lastWarning=try await f.repo.startRebase(lastPlan,editorExecutable:editor)
        let review=try XCTUnwrap(lastWarning.state.emptyMessageWarning)
        let parentPending=try await f.repo.acknowledgeRebaseEmptyMessage(review,expected:lastWarning.state,expectedHead:review.head)
        XCTAssertNotNil(parentPending.state.mainlineDecision)
        let skippedAfterWarning=try await f.repo.skipRebase()
        XCTAssertFalse(skippedAfterWarning.state.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("right.txt").path))
    }
    func testRepeatedMergeOccurrencesHaveIndependentReachedParents()async throws {
        let f=try await fixture(repeated:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let first=try await f.repo.startRebase(f.plan,editorExecutable:editor),one=try decision(first)
        let second=try await f.repo.selectRebaseMainline(one,parent:1,expected:first.state,expectedHead:one.head)
        let two=try decision(second)
        XCTAssertNotEqual(one.entryID,two.entryID);XCTAssertEqual(two.entryID,f.plan.entries[1].id)
        XCTAssertNotEqual(one.head,two.head)
        let rows=try await f.repo.rebaseReplayEntries()
        XCTAssertEqual(rows.map(\.id),f.plan.entries.map(\.id));XCTAssertEqual(rows.map(\.mainline),[1,nil])
        do {_ = try await f.repo.selectRebaseMainline(one,parent:2,expected:second.state,expectedHead:two.head);XCTFail("Earlier occurrence receipt reused")}catch RebaseFailure.changed {}
        let done=try await f.repo.selectRebaseMainline(two,parent:2,expected:second.state,expectedHead:two.head)
        XCTAssertFalse(done.state.active);XCTAssertEqual(done.exitCode,0,done.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("left.txt").path));XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("right.txt").path))
    }
    func testSkipAndAbortAtReachedMergePreserveEarlierProgressAndOriginalBranch()async throws {
        for skip in [true,false] {
            let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
            let reached=try await f.repo.startRebase(f.plan,editorExecutable:editor),choice=try decision(reached)
            if skip {
                let done=try await f.repo.skipRebase();XCTAssertFalse(done.state.active)
                let last=try await f.repo.rebaseCommit("HEAD")
                XCTAssertEqual(last.parents,[choice.head]);XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("right.txt").path))
                XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("before.txt").path));XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("after.txt").path))
            } else {
                _ = try await f.repo.abortRebase()
                let head=try await f.repo.rebaseCommit("HEAD"),branch=try await f.repo.run(["symbolic-ref","HEAD"]).text.trimmingCharacters(in:.newlines)
                XCTAssertEqual(head.hash,f.base.hash);XCTAssertEqual(branch,"refs/heads/target")
            }
        }
    }
    func testInvalidParentChangedTodoAndMovedHeadRefuseWithoutRetargeting()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let reached=try await f.repo.startRebase(f.plan,editorExecutable:editor),choice=try decision(reached)
        let todo=f.root.appendingPathComponent(".git/rebase-merge/git-rebase-todo"),before=try Data(contentsOf:todo),index=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        for invalid in [Int.min,0,Int.max] {
            do {_ = try await f.repo.selectRebaseMainline(choice,parent:invalid,expected:reached.state,expectedHead:choice.head);XCTFail("Invalid parent accepted")}catch RebaseFailure.mainline {}
        }
        XCTAssertEqual(try Data(contentsOf:todo),before)
        let doneFile=f.root.appendingPathComponent(".git/rebase-merge/done"),doneBytes=try Data(contentsOf:doneFile)
        var forged=doneBytes;forged.append(Data(("exec false # turtlegit-mainline:"+f.before.hash+"\n").utf8));try forged.write(to:doneFile)
        do {_ = try await f.repo.rebaseState();XCTFail("Unowned lookalike marker was accepted")}catch RebaseFailure.plan {}
        XCTAssertEqual(try Data(contentsOf:doneFile),forged);try doneBytes.write(to:doneFile)
        var changed=before;changed.append(Data("# external edit\n".utf8));try changed.write(to:todo)
        do {_ = try await f.repo.selectRebaseMainline(choice,parent:1,expected:reached.state,expectedHead:choice.head);XCTFail("Changed todo accepted")}catch RebaseFailure.changed {}
        XCTAssertEqual(try Data(contentsOf:todo),changed);try before.write(to:todo)
        _ = try await f.repo.run(["update-ref","HEAD",f.base.hash])
        let reopened=try await f.repo.rebaseState()
        XCTAssertEqual(reopened.mainlineDecision?.head,choice.head,"Reopening must retain the reached HEAD, not silently retarget to an external change")
        do {try await f.repo.validateRebaseContinuation(expected:reopened,expectedHead:f.base.hash);XCTFail("Moved HEAD admitted a new prompt")}catch RebaseFailure.changed {}
        XCTAssertEqual(try Data(contentsOf:todo),before);XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
        _ = try await f.repo.abortRebase()
    }
    func testPendingSkipCanBecomeDeferredMergeWithoutEagerParentChoice()async throws {
        var f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        f.plan.entries[0].action = .edit;f.plan.entries[1].action = .skip
        let stopped=try await f.repo.startRebase(f.plan,editorExecutable:editor)
        XCTAssertTrue(stopped.state.isEditPause)
        let snapshot=try await f.repo.rebaseActionEditSnapshot()
        _ = try await f.repo.changePendingRebaseActions(.pick,ids:[f.plan.entries[1].id],expected:snapshot,editorExecutable:editor)
        let next=try await f.repo.continueRebase(editorExecutable:editor)
        XCTAssertEqual(next.state.mainlineDecision?.entryID,f.plan.entries[1].id)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("before.txt").path));XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("after.txt").path))
        _ = try await f.repo.abortRebase()
    }
    func testDeferredSquashUsesPreparedAttributionAndOriginalGroupMetadata()async throws {
        var f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        f.plan.entries[1].action = .squash;f.plan.entries[2].action = .squash
        f.plan.options.squashDate = .latest
        let reached=try await f.repo.startRebase(f.plan,editorExecutable:editor),choice=try decision(reached)
        XCTAssertEqual(choice.requestedAction,.squash);XCTAssertNil(reached.state.squashMessage)
        let review=try await f.repo.selectRebaseMainline(choice,parent:1,expected:reached.state,expectedHead:choice.head)
        let message=try XCTUnwrap(review.state.squashMessage)
        XCTAssertTrue(message.message.contains("merge source"));XCTAssertTrue(message.message.contains("after.txt"))
        XCTAssertEqual(message.message.components(separatedBy:"(cherry picked from commit "+f.merge.hash+")").count-1,1)
        let done=try await f.repo.continueRebase(squashMessage:"Approved deferred group\n",editorExecutable:editor)
        XCTAssertFalse(done.state.active);XCTAssertEqual(done.exitCode,0,done.output)
        let head=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(head.author,f.before.author);XCTAssertEqual(head.email,f.before.email);XCTAssertEqual(head.date,f.after.date)
        XCTAssertEqual(head.historySubject,"Approved deferred group")
        _ = try await f.repo.run(["checkout","-B","target",f.base.hash])
        let skippedStart=try await f.repo.startRebase(f.plan,editorExecutable:editor)
        XCTAssertNotNil(skippedStart.state.mainlineDecision,skippedStart.output)
        let skipped=try await f.repo.skipRebase()
        XCTAssertNotNil(skipped.state.squashMessage,skipped.output)
        let skipDone=try await f.repo.continueRebase(squashMessage:"Approved group without merge\n",editorExecutable:editor)
        XCTAssertFalse(skipDone.state.active);XCTAssertEqual(skipDone.exitCode,0,skipDone.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("before.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("after.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("right.txt").path))
    }
    func testLeadingDeferredMergeRestoresFollowingSquashAfterChoice()async throws {
        var f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        f.plan.entries[0].action = .skip
        f.plan.entries[2].action = .squash
        let reached=try await f.repo.startRebase(f.plan,editorExecutable:editor),choice=try decision(reached)
        XCTAssertEqual(choice.entryID,f.plan.entries[1].id)
        let remaining=try await f.repo.remainingRebaseEntries()
        XCTAssertEqual(remaining.map(\.action),[.pick,.squash])
        XCTAssertEqual(reached.state.remainingCommands.compactMap {$0.split(separator:" ").first.flatMap {RebaseAction(rawValue:String($0))}},[.pick,.squash])
        let review=try await f.repo.selectRebaseMainline(choice,parent:1,expected:reached.state,expectedHead:choice.head)
        let message=try XCTUnwrap(review.state.squashMessage,review.output)
        XCTAssertTrue(message.message.contains("merge source"));XCTAssertTrue(message.message.contains("after.txt"))
        let done=try await f.repo.continueRebase(squashMessage:"Approved leading merge group\n",editorExecutable:editor)
        XCTAssertEqual(done.exitCode,0,done.output);XCTAssertFalse(done.state.active)
        let head=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(head.author,f.merge.author);XCTAssertEqual(head.email,f.merge.email)
        XCTAssertEqual(head.historySubject,"Approved leading merge group")
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("right.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("after.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("before.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("left.txt").path))
    }
    func testAcceptedParentSurvivesCancelledContinuationWithoutAnotherQuestion()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let reached=try await f.repo.startRebase(f.plan,editorExecutable:editor),choice=try decision(reached)
        let wrapper=f.root.appendingPathComponent(".git/held-mainline-git")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let environment=GitRuntime.environment(executable:f.repo.executable).sorted{$0.key<$1.key}.map{"export "+$0.key+"="+quote($0.value)+"\n"}.joined()
        let script="""
        #!/bin/sh
        \(environment)for argument in "$@"; do
          if [ "$argument" = --continue ]; then
            printf 'MAINLINE_ACCEPTED\n'
            exec /bin/sleep 30
          fi
        done
        exec \(quote(f.repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let held=GitRepository(root:f.root,executable:wrapper),token=OperationCancellation()
        do {
            _ = try await held.selectRebaseMainline(choice,parent:1,expected:reached.state,expectedHead:choice.head,cancellation:token,onOutput:{chunk in
                if String(decoding:chunk.data,as:UTF8.self).contains("MAINLINE_ACCEPTED") {token.cancel()}
            })
            XCTFail("Held parent-selection continuation completed")
        } catch let cancelled as GitCommandCancellationFailure {
            XCTAssertEqual(cancelled.result.exitCode,130)
            XCTAssertTrue(cancelled.outputWasDelivered)
            XCTAssertTrue(String(decoding:cancelled.result.stdout,as:UTF8.self).contains("MAINLINE_ACCEPTED"))
        }
        XCTAssertTrue(token.isCancelled)
        let saved=try await f.repo.rebaseState(),rows=try await f.repo.rebaseReplayEntries(),head=try await f.repo.rebaseCommit("HEAD")
        XCTAssertNil(saved.mainlineDecision);XCTAssertTrue(saved.hasMainlineCheckpoint)
        XCTAssertEqual(rows[1].mainline,1);XCTAssertEqual(head.hash,choice.head)
        _ = try await f.repo.run(["update-ref","HEAD",f.base.hash])
        let moved=try await f.repo.rebaseState()
        do {try await f.repo.validateRebaseContinuation(expected:moved,expectedHead:f.base.hash);XCTFail("Accepted parent was retargeted after external HEAD change")}catch RebaseFailure.changed {}
        _ = try await f.repo.run(["update-ref","HEAD",head.hash])
        let done=try await f.repo.continueRebase(expectedReplayState:saved,expectedReplayHead:head.hash,editorExecutable:editor)
        XCTAssertFalse(done.state.active);XCTAssertEqual(done.exitCode,0,done.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("right.txt").path));XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("after.txt").path))
    }
}
