import XCTest
@testable import TurtleGitCore

final class RebaseNoCommitSquashTests:XCTestCase {
    var editor:URL {RebaseTests().editor}
    struct Fixture {
        let root:URL,repo:GitRepository,base:LogEntry,merge:LogEntry,after:LogEntry
        var plan:RebasePlan
    }
    func fixture(conflict:Bool=false)async throws->Fixture {
        let original=try await RebaseMainlineTests().fixture()
        var accepted=false;defer {if !accepted {try? FileManager.default.removeItem(at:original.root)}}
        let repo=original.repo,file=original.root.appendingPathComponent(".git/group-source-message")
        try Data("Reached leader\n\nOriginal merge body\n".utf8).write(to:file)
        let tree=try await repo.run(["rev-parse",original.merge.hash+"^{tree}"]).text.trimmingCharacters(in:.newlines)
        let hash=try await repo.run(["commit-tree",tree]+original.merge.parents.flatMap{["-p",$0]}+["-F",file.path],environmentOverrides:["GIT_AUTHOR_NAME":"Reached Merge Author","GIT_AUTHOR_EMAIL":"leader@example.invalid","GIT_AUTHOR_DATE":"2026-10-10T10:00:00+0200"]).text.trimmingCharacters(in:.newlines)
        let merge=try await repo.rebaseCommit(hash)
        if conflict {
            try Data("destination content\n".utf8).write(to:original.root.appendingPathComponent("after.txt"))
            try await repo.stage(["after.txt"]);_ = try await repo.commit(message:"destination owns path")
        }
        let base=try await repo.rebaseCommit("HEAD")
        var plan=try await repo.cherryPickPlan(revisions:[original.after.hash,merge.hash])
        plan.entries[1].action = .squash
        accepted=true
        return .init(root:original.root,repo:repo,base:base,merge:merge,after:original.after,plan:plan)
    }
    func reachedThenSkip(_ f:Fixture)async throws->RebaseExecution {
        let reached=try await f.repo.startRebase(f.plan,editorExecutable:editor)
        let decision=try XCTUnwrap(reached.state.mainlineDecision,reached.output)
        XCTAssertEqual(decision.entryID,f.plan.entries[0].id)
        let reopened=GitRepository(root:f.root,executable:f.repo.executable)
        let cancelled=try await reopened.rebaseState()
        XCTAssertEqual(cancelled.mainlineDecision,decision)
        let head=try await reopened.rebaseCommit("HEAD")
        XCTAssertEqual(head.hash,f.base.hash,"Reading/cancelling the reached question applied the merge")
        return try await reopened.skipRebase()
    }
    func metadata(_ f:Fixture,_ name:String)async throws->URL {
        let path=try await f.repo.run(["rev-parse","--git-path","rebase-merge/"+name]).text.trimmingCharacters(in:.newlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath:path):f.root.appendingPathComponent(path)
    }
    func testReachedCancelledLeaderSkipRequiresNormalCommitAndRetainsSourceAuthor()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let calls=f.root.appendingPathComponent(".git/group-hook-calls"),hooks=f.root.appendingPathComponent(".git/group-hooks")
        try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:false)
        let hook=hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nprintf 'call\\n' >> \"$(git rev-parse --git-path group-hook-calls)\"\n".utf8).write(to:hook)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        _ = try await f.repo.run(["config","core.hooksPath",hooks.path])
        let review=try await reachedThenSkip(f),group=try XCTUnwrap(review.state.noCommitSquash,review.output)
        XCTAssertEqual(group.phase,.approval);XCTAssertEqual(group.baseHead,f.base.hash);XCTAssertTrue(group.preservesLeaderAuthor)
        XCTAssertEqual(review.state.squashMessage?.isNewCommit,true)
        let before=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(before.hash,f.base.hash);XCTAssertFalse(FileManager.default.fileExists(atPath:calls.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("right.txt").path))
        XCTAssertTrue(review.state.squashMessage?.message.contains("Original merge body")==true)
        XCTAssertTrue(review.state.squashMessage?.message.contains("after.txt")==true)
        let reopened=GitRepository(root:f.root,executable:f.repo.executable)
        let state=try await reopened.rebaseState();XCTAssertEqual(state.noCommitSquash,group)
        let message="Reviewed group\n\nOriginal merge body\n\nafter.txt\n"
        let done=try await reopened.continueRebase(squashMessage:message,expectedReplayState:state,expectedReplayHead:f.base.hash,editorExecutable:editor)
        XCTAssertEqual(done.exitCode,0,done.output);XCTAssertFalse(done.state.active)
        let final=try await reopened.rebaseCommit("HEAD")
        XCTAssertEqual(final.parents,[f.base.hash]);XCTAssertEqual(final.author,f.merge.author);XCTAssertEqual(final.email,f.merge.email);XCTAssertEqual(final.date,f.merge.date)
        XCTAssertEqual(final.message.trimmingCharacters(in:.newlines),message.trimmingCharacters(in:.newlines))
        XCTAssertEqual(try String(contentsOf:calls,encoding:.utf8),"call\n")
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent("after.txt")),Data("after.txt\n".utf8))
    }
    func testPreSkippedUnreachedLeaderUsesConfiguredIdentityAndAbortRestoresIndex()async throws {
        var f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        f.plan.entries[0].action = .skip
        let beforeIndex=try await f.repo.run(["ls-files","--stage"]).stdout
        let review=try await f.repo.startRebase(f.plan,editorExecutable:editor)
        let group=try XCTUnwrap(review.state.noCommitSquash,review.output)
        XCTAssertEqual(group.phase,.approval);XCTAssertFalse(group.preservesLeaderAuthor)
        XCTAssertFalse(review.state.squashMessage?.message.contains("Original merge body")==true)
        let configured=try await f.repo.run(["config","user.name"]).text.trimmingCharacters(in:.newlines)
        let completed=try await f.repo.continueRebase(squashMessage:"New orphan group\n",editorExecutable:editor)
        XCTAssertFalse(completed.state.active,completed.output)
        let final=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(final.parents,[f.base.hash]);XCTAssertEqual(final.author,configured);XCTAssertNotEqual(final.author,f.merge.author)
        _ = try await f.repo.run(["reset","--hard",f.base.hash])
        let again=try await f.repo.startRebase(f.plan,editorExecutable:editor)
        XCTAssertEqual(again.state.noCommitSquash?.phase,.approval)
        let reopened=GitRepository(root:f.root,executable:f.repo.executable)
        _ = try await reopened.abortRebase()
        let head=try await reopened.rebaseCommit("HEAD"),index=try await reopened.run(["ls-files","--stage"]).stdout
        XCTAssertEqual(head.hash,f.base.hash);XCTAssertEqual(index,beforeIndex)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("after.txt").path))
    }
    func testConflictedSelectedResolutionStagesOnlyBeforeApproval()async throws {
        let f=try await fixture(conflict:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let conflict=try await reachedThenSkip(f)
        XCTAssertEqual(conflict.state.noCommitSquash?.phase,.conflicted);XCTAssertTrue(conflict.state.conflicts.contains("after.txt"))
        try Data("chosen resolution\n".utf8).write(to:f.root.appendingPathComponent("after.txt"))
        let declined=try await f.repo.rebaseState(),head=try await f.repo.rebaseCommit("HEAD")
        do {_ = try await f.repo.continueRebaseNoCommitSquash(paths:[String](),expected:declined,expectedHead:head.hash);XCTFail("Unchecked unresolved conflict advanced")}catch RebaseFailure.plan {}
        let fresh=try await f.repo.rebaseState()
        let approval=try await f.repo.continueRebaseNoCommitSquash(paths:["after.txt"],expected:fresh,expectedHead:f.base.hash)
        XCTAssertEqual(approval.state.noCommitSquash?.phase,.approval);XCTAssertTrue(approval.state.conflicts.isEmpty)
        XCTAssertEqual(approval.state.squashMessage?.isNewCommit,true)
        let unchanged=try await f.repo.rebaseCommit("HEAD");XCTAssertEqual(unchanged.hash,f.base.hash)
        let staged=try await f.repo.run(["show",":after.txt"]).stdout
        XCTAssertEqual(staged,Data("chosen resolution\n".utf8))
        let done=try await f.repo.continueRebase(squashMessage:"Approved selected resolution\n",editorExecutable:editor)
        XCTAssertFalse(done.state.active,done.output)
        let final=try await f.repo.rebaseCommit("HEAD");XCTAssertEqual(final.parents,[f.base.hash]);XCTAssertEqual(final.author,f.merge.author)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent("after.txt")),staged)
    }
    func testCancelledApprovalAndChangedOrInterruptedJournalNeverApplyAgain()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let review=try await reachedThenSkip(f),path=try await metadata(f,"turtlegit-no-commit-squash.json")
        let original=try Data(contentsOf:path),index=try await f.repo.run(["ls-files","--stage"]).stdout
        let token=OperationCancellation();token.cancel()
        do {_ = try await f.repo.continueRebase(squashMessage:"Not accepted\n",expectedReplayState:review.state,expectedReplayHead:f.base.hash,cancellation:token,editorExecutable:editor);XCTFail("Cancelled approval committed")}catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf:path),original)
        _ = try await f.repo.run(["update-ref","HEAD",f.merge.hash])
        do {_ = try await f.repo.continueRebase(squashMessage:"Retargeted review\n",expectedReplayState:review.state,expectedReplayHead:f.merge.hash,editorExecutable:editor);XCTFail("Moved HEAD accepted group review")}catch RebaseFailure.changed {}
        _ = try await f.repo.run(["update-ref","HEAD",f.base.hash])
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:original) as? [String:Any])
        var leader=try XCTUnwrap(object["leader"] as? [String:Any])
        leader["name"]="externally changed author";object["leader"]=leader
        try JSONSerialization.data(withJSONObject:object).write(to:path)
        do {_ = try await f.repo.continueRebase(squashMessage:"Stale review\n",expectedReplayState:review.state,expectedReplayHead:f.base.hash,editorExecutable:editor);XCTFail("Changed group accepted stale review")}catch RebaseFailure.changed {}
        object["phase"]="applying";try JSONSerialization.data(withJSONObject:object).write(to:path)
        let reopened=GitRepository(root:f.root,executable:f.repo.executable),interrupted=try await reopened.rebaseState()
        XCTAssertEqual(interrupted.noCommitSquash?.phase,.uncertain)
        do {_ = try await reopened.continueRebase(squashMessage:"Unsafe retry\n",editorExecutable:editor);XCTFail("Interrupted patch was automatically reapplied")}catch RebaseFailure.noCommitSquashUncertain {}
        let head=try await reopened.rebaseCommit("HEAD"),after=try await reopened.run(["ls-files","--stage"]).stdout
        XCTAssertEqual(head.hash,f.base.hash);XCTAssertEqual(after,index)
        _ = try await reopened.abortRebase()
        let final=try await reopened.rebaseState();XCTAssertFalse(final.active)
    }
    func testEmptyIntermediateSquashReviewsBeforeFollowingRowWithoutDuplicateBody()async throws {
        for regeneratePendingActions in [false,true] {
            var f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
            let raw=try await f.repo.run(["cat-file","commit",f.after.hash]).stdout
            let separator=try XCTUnwrap(raw.range(of:Data([10,10])))
            var body=raw.subdata(in:0..<separator.upperBound);body.append(Data("\nEmpty intermediate body\n".utf8))
            let hash=try await f.repo.run(["hash-object","-t","commit","-w","--stdin"],input:body).text.trimmingCharacters(in:.newlines)
            let empty=try await f.repo.rebaseCommit(hash)
            _ = try await f.repo.run(["checkout","-b","squash-tail",f.after.hash])
            let tail=try await RebaseMainlineTests().commit(f.repo,"tail.txt")
            _ = try await f.repo.run(["checkout","target"])
            f.plan=try await f.repo.cherryPickPlan(revisions:[tail.hash,empty.hash,f.merge.hash]);f.plan.entries[1].action = .squash;f.plan.entries[2].action = .squash
            let warning=try await reachedThenSkip(f),receipt=try XCTUnwrap(warning.state.emptyMessageWarning,warning.output)
            XCTAssertEqual(receipt.entryID,f.plan.entries[1].id)
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("after.txt").path))
            let review=try await f.repo.acknowledgeRebaseEmptyMessage(receipt,expected:warning.state,expectedHead:f.base.hash)
            XCTAssertEqual(review.state.noCommitSquash?.phase,.approval)
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("tail.txt").path))
            let group=try XCTUnwrap(review.state.noCommitSquash),staged=try await f.repo.run(["ls-files","--stage"]).stdout
            let donePath=try await metadata(f,"done"),doneBytes=try Data(contentsOf:donePath)
            if regeneratePendingActions {
                for action in [RebaseAction.skip,.pick,.squash] {
                    let snapshot=try await f.repo.rebaseActionEditSnapshot()
                    let changed=try await f.repo.changePendingRebaseActions(action,ids:[f.plan.entries[2].id],expected:snapshot,editorExecutable:editor)
                    XCTAssertEqual(changed.replay.last?.action,action)
                    let reopened=GitRepository(root:f.root,executable:f.repo.executable),saved=try await reopened.rebaseState()
                    let currentIndex=try await reopened.run(["ls-files","--stage"]).stdout,head=try await reopened.rebaseCommit("HEAD")
                    XCTAssertEqual(saved.noCommitSquash?.id,group.id);XCTAssertEqual(saved.noCommitSquash?.phase,.approval)
                    XCTAssertEqual(saved.noCommitSquash?.baseHead,f.base.hash);XCTAssertEqual(head.hash,f.base.hash)
                    XCTAssertEqual(currentIndex,staged);XCTAssertEqual(try Data(contentsOf:donePath),doneBytes)
                }
            }
            let next=try await f.repo.continueRebase(squashMessage:"Reviewed intermediate\n\nEmpty intermediate body\n",editorExecutable:editor)
            XCTAssertEqual(next.state.noCommitSquash?.phase,.approval,next.output)
            let nextHead=try await f.repo.rebaseCommit("HEAD");XCTAssertEqual(nextHead.hash,f.base.hash)
            let message=try XCTUnwrap(next.state.squashMessage).message
            XCTAssertEqual(message.components(separatedBy:"Empty intermediate body").count-1,1)
            XCTAssertTrue(message.contains("tail.txt"))
            let done=try await f.repo.continueRebase(squashMessage:message,editorExecutable:editor)
            XCTAssertFalse(done.state.active,done.output)
            let final=try await f.repo.rebaseCommit("HEAD")
            XCTAssertEqual(final.parents,[f.base.hash]);XCTAssertEqual(final.author,f.merge.author)
            XCTAssertEqual(final.message.components(separatedBy:"Empty intermediate body").count-1,1)
        }
    }
    func testOrdinaryUpdateRefsMapsSquashedBranchToApprovedNewCommit()async throws {
        let tests=RebaseTests(),(root,repo,_)=try await tests.fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","rebase.updateRefs","true"])
        _ = try await repo.run(["branch","group-reference","topic"])
        var plan=try await repo.rebasePlan(tests.options())
        XCTAssertEqual(plan.entries.count,2)
        plan.entries[0].action = .skip;plan.entries[1].action = .squash
        let review=try await repo.startRebase(plan,editorExecutable:editor)
        XCTAssertEqual(review.state.noCommitSquash?.phase,.approval,review.output)
        let base=try await repo.rebaseCommit("HEAD")
        let done=try await repo.continueRebase(squashMessage:"Approved ordinary group\n",editorExecutable:editor)
        XCTAssertFalse(done.state.active,done.output)
        let final=try await repo.rebaseCommit("HEAD"),updated=try await repo.rebaseCommit("group-reference")
        XCTAssertEqual(final.parents,[base.hash]);XCTAssertEqual(updated.hash,final.hash)
        XCTAssertEqual(final.subject,"Approved ordinary group")
    }
    func testCleanNormalCommitFailureIgnoreKeepsBaseWithoutRerunningHook()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let review=try await reachedThenSkip(f)
        XCTAssertEqual(review.state.noCommitSquash?.phase,.approval)
        _ = try await f.repo.run(["reset","--hard","HEAD"])
        let hooks=f.root.appendingPathComponent(".git/rejected-group-hooks"),calls=f.root.appendingPathComponent(".git/rejected-group-calls")
        try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:false)
        let hook=hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nprintf 'call\\n' >> \"$(git rev-parse --git-path rejected-group-calls)\"\nprintf 'Owned normal group commit refused\\n' >&2\nexit 1\n".utf8).write(to:hook)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        _ = try await f.repo.run(["config","core.hooksPath",hooks.path])
        let failure:RebaseCleanCommitFailure
        do {
            _ = try await f.repo.continueRebase(squashMessage:"Rejected new group\n",emptySquashChoice:.commit,editorExecutable:editor)
            XCTFail("Clean normal commit failure was not retained");throw RebaseFailure.plan
        }catch let actual as RebaseCleanCommitFailure {failure=actual}
        XCTAssertEqual(failure.head,f.base.hash);XCTAssertTrue(failure.diagnostic.contains("Owned normal group commit refused"))
        XCTAssertEqual(try String(contentsOf:calls,encoding:.utf8),"call\n")
        let reopened=GitRepository(root:f.root,executable:f.repo.executable),saved=try await reopened.rebaseState()
        XCTAssertEqual(saved.cleanCommitFailure,failure);XCTAssertEqual(saved.noCommitSquash?.phase,.approval)
        let needsEmptyDecision=try await reopened.rebaseSquashIsEmpty()
        XCTAssertFalse(needsEmptyDecision,"Accepted empty Commit must survive failure/reopen without asking again")
        let done=try await reopened.ignoreRebaseCleanCommitFailure(failure,expected:saved,expectedHead:f.base.hash,editorExecutable:editor)
        XCTAssertEqual(done.exitCode,0,done.output);XCTAssertFalse(done.state.active);XCTAssertNil(done.state.noCommitSquash)
        let final=try await reopened.rebaseCommit("HEAD")
        XCTAssertEqual(final.hash,f.base.hash);XCTAssertEqual(final.parents,f.base.parents);XCTAssertEqual(final.message,f.base.message)
        XCTAssertEqual(try String(contentsOf:calls,encoding:.utf8),"call\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("after.txt").path))
    }
}
