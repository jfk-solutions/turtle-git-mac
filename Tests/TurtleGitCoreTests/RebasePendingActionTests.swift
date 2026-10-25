import XCTest
@testable import TurtleGitCore

final class RebasePendingActionTests: XCTestCase {
    var editor: URL { RebaseTests().editor }
    func paused(structural: Bool = false) async throws -> (URL, GitRepository, RebasePlan) {
        let (root,repo,_) = try await RebaseTests().fixture()
        if structural {
            _ = try await repo.run(["switch","-c","side","main"])
            try Data("side\n".utf8).write(to:root.appendingPathComponent("side"));try await repo.stage(["side"]);_ = try await repo.commit(message:"side")
            _ = try await repo.run(["switch","topic"]);_ = try await repo.run(["merge","--no-ff","--no-edit","side"])
        }
        var options=RebaseTests().options();options.preserveMerges=structural
        var plan=try await repo.rebasePlan(options);plan.entries[0].action = .edit
        let result=try await repo.startRebase(plan,editorExecutable:editor)
        XCTAssertTrue(result.state.isEditPause,"Must stop at first editable occurrence")
        return (root,repo,plan)
    }
    func testPendingPickEditSkipPersistsAndContinueUsesSavedTodo() async throws {
        let (root,repo,plan)=try await paused();defer {try? FileManager.default.removeItem(at:root)}
        let before=try await repo.rebaseActionEditSnapshot(),index=try Data(contentsOf:root.appendingPathComponent(".git/index")),work=try Data(contentsOf:root.appendingPathComponent("first.txt"))
        let future=plan.entries[1].id
        let edited=try await repo.changePendingRebaseActions(.edit,ids:[future],expected:before,editorExecutable:editor)
        XCTAssertEqual(edited.replay[1].action,.edit);XCTAssertEqual(edited.head,before.head);XCTAssertFalse(edited.fileRecovery)
        let reopened=GitRepository(root:root,executable:repo.executable),receipt=try await reopened.rebaseActionEditSnapshot()
        XCTAssertEqual(receipt.replay[1].action,.edit)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("first.txt")),work)
        let next=try await repo.continueRebase();XCTAssertTrue(next.state.isEditPause);XCTAssertEqual(next.state.stoppedEntryID,future)
        let current=try await repo.rebaseActionEditSnapshot()
        _ = try await repo.changePendingRebaseActions(.skip,ids:[current.replay[0].id,future],expected:current,editorExecutable:editor)
        let unchanged=try await repo.rebaseActionEditSnapshot();XCTAssertEqual(unchanged.replay.map(\.action),current.replay.map(\.action))
        let final=try await repo.continueRebase();XCTAssertFalse(final.state.active)
    }
    func testNewPendingSquashInstallsMessageEditorAndPreservesEveryMessage() async throws {
        let (root,repo,plan)=try await paused();defer {try? FileManager.default.removeItem(at:root)}
        let before=try await repo.rebaseActionEditSnapshot()
        _ = try await repo.changePendingRebaseActions(.squash,ids:[plan.entries[1].id],expected:before,editorExecutable:editor)
        let result=try await repo.continueRebase()
        XCTAssertNotNil(result.state.squashMessage);XCTAssertTrue(result.state.squashMessage?.message.contains("first")==true);XCTAssertTrue(result.state.squashMessage?.message.contains("second")==true)
        let final=try await repo.continueRebase(squashMessage:"Saved new squash")
        XCTAssertFalse(final.state.active)
        let history=try await repo.run(["log","--format=%s","upstream..topic"]).text
        XCTAssertEqual(history,"Saved new squash\n")
    }
    func testStructuralFutureActionsRegenerateOnlyUnexecutedCommandsAndMergeEdit() async throws {
        let (root,repo,plan)=try await paused(structural:true);defer {try? FileManager.default.removeItem(at:root)}
        let path=root.appendingPathComponent(".git/rebase-merge/done"),done=try Data(contentsOf:path)
        let merge=plan.entries.first{$0.commit.parents.count>1}!
        for action in [RebaseAction.skip,.pick,.edit] {
            let snapshot=try await repo.rebaseActionEditSnapshot()
            let changed=try await repo.changePendingRebaseActions(action,ids:[merge.id],expected:snapshot,editorExecutable:editor)
            XCTAssertEqual(changed.replay.first{$0.id==merge.id}?.action,action);XCTAssertEqual(try Data(contentsOf:path),done)
        }
        let paused=try await repo.continueRebase();XCTAssertTrue(paused.state.isStructuralMergeEdit);XCTAssertEqual(paused.state.stoppedEntryID,merge.id)
        let final=try await repo.continueRebase();XCTAssertFalse(final.state.active)
        let head=try await repo.rebaseCommit("HEAD");XCTAssertEqual(head.parents.count,2)
    }
    func testStructuralFutureSquashCanExtendStoppedEditGroup() async throws {
        let (root,repo,plan)=try await paused(structural:true);defer {try? FileManager.default.removeItem(at:root)}
        let receipt=try await repo.rebaseActionEditSnapshot(),second=receipt.replay[1]
        XCTAssertEqual(second.commit.parents.count,1)
        _ = try await repo.changePendingRebaseActions(.squash,ids:[second.id],expected:receipt,editorExecutable:editor)
        let pause=try await repo.continueRebase();XCTAssertNotNil(pause.state.squashMessage)
        let final=try await repo.continueRebase(squashMessage:"Structural changed group")
        XCTAssertFalse(final.state.active)
        let changed=try await repo.run(["diff","--name-only",plan.branchHash,"HEAD","--"]).text
        XCTAssertEqual(changed,"upstream.txt\n")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("upstream.txt")),Data("upstream\n".utf8))
        XCTAssertEqual(plan.entries.count,4)
    }
    func testCherryPickRepeatedOccurrenceSkipDoesNotRetargetCurrentObject() async throws {
        let (root,repo,_)=try await RebaseTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        let history=try await repo.history(),second=history[0],first=history[1]
        _ = try await repo.run(["switch","-c","target","main"])
        let initial=try await repo.cherryPickPlan(revisions:[second.hash,first.hash])
        var plan=try await repo.addingRebaseCommits(initial,revisions:[first.hash]);plan.entries[0].action = .edit
        _ = try await repo.startRebase(plan,editorExecutable:editor)
        let before=try await repo.rebaseActionEditSnapshot()
        XCTAssertNotEqual(before.replay[0].id,before.replay[2].id)
        let saved=try await repo.changePendingRebaseActions(.skip,ids:[before.replay[0].id,before.replay[2].id],expected:before,editorExecutable:editor)
        XCTAssertEqual(saved.replay.map(\.action),[.edit,.pick,.skip])
        let final=try await repo.continueRebase();XCTAssertFalse(final.state.active)
        let count=try await repo.run(["rev-list","--count","main..target"]).text;XCTAssertEqual(count,"2\n")
    }
    func testSkippedCherryMergeCanBePickedWithCapturedMainlineAndAttribution() async throws {
        let (root,repo,source)=try await paused(structural:true);defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.abortRebase();_ = try await repo.run(["switch","-c","target","main"])
        let first=source.entries.first{$0.commit.subject=="first"}!,second=source.entries.first{$0.commit.subject=="second"}!,merge=source.entries.first{$0.commit.parents.count>1}!
        var plan=try await repo.cherryPickPlan(revisions:[second.commit.hash,merge.commit.hash,first.commit.hash]);plan.entries[0].action = .edit;plan.entries[1].action = .skip;plan.entries[2].action = .squash;plan.options.addCherryPickedFrom=true
        _ = try await repo.startRebase(plan,editorExecutable:editor)
        let before=try await repo.rebaseActionEditSnapshot()
        let deferred=try await repo.changePendingRebaseActions(.pick,ids:[merge.id],expected:before,editorExecutable:editor)
        XCTAssertEqual(deferred.replay[1].action,.pick);XCTAssertNil(deferred.replay[1].mainline)
        XCTAssertEqual(deferred.head,before.head,"A future parent question must not mutate the stopped HEAD")
        let deferredSnapshot=try await repo.rebaseActionEditSnapshot()
        _ = try await repo.changePendingRebaseActions(.skip,ids:[merge.id],expected:deferredSnapshot,editorExecutable:editor)
        let restored=try await repo.rebaseActionEditSnapshot()
        let changed=try await repo.changePendingRebaseActions(.pick,ids:[merge.id],expected:restored,mainlines:[merge.id:1],editorExecutable:editor)
        XCTAssertEqual(changed.replay[1].mainline,1);XCTAssertEqual(changed.replay[1].action,.pick)
        let pending=try await repo.continueRebase();XCTAssertNotNil(pending.state.squashMessage)
        let message=try XCTUnwrap(pending.state.squashMessage?.message)
        XCTAssertTrue(message.contains("cherry picked from commit "+merge.commit.hash))
        let result=try await repo.continueRebase(squashMessage:message);XCTAssertFalse(result.state.active)
        let head=try await repo.rebaseCommit("HEAD");XCTAssertEqual(head.parents.count,1);XCTAssertTrue(head.message.contains("cherry picked from commit "+merge.commit.hash))
    }
    func testPendingSquashKeepsConfiguredReferenceUpdatesAtFinalGroupResult() async throws {
        let (root,repo,_)=try await RebaseTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","rebase.updateRefs","true"]);_ = try await repo.run(["branch","future","topic"])
        var plan=try await repo.rebasePlan(RebaseTests().options());plan.entries[0].action = .edit
        _ = try await repo.startRebase(plan,editorExecutable:editor)
        let before=try await repo.rebaseActionEditSnapshot()
        _ = try await repo.changePendingRebaseActions(.squash,ids:[plan.entries[1].id],expected:before,editorExecutable:editor)
        let pending=try await repo.continueRebase();XCTAssertNotNil(pending.state.squashMessage)
        _ = try await repo.continueRebase(squashMessage:"Updated group")
        let topic=try await repo.run(["rev-parse","topic"]).stdout,future=try await repo.run(["rev-parse","future"]).stdout
        XCTAssertEqual(topic,future)
    }
    func testStaleBytesLockAndCancellationRefuseWithoutChangingSession() async throws {
        let (root,repo,plan)=try await paused();defer {try? FileManager.default.removeItem(at:root)}
        let before=try await repo.rebaseActionEditSnapshot(),todo=root.appendingPathComponent(".git/rebase-merge/git-rebase-todo"),bytes=try Data(contentsOf:todo)
        try (bytes+Data("# external edit\n".utf8)).write(to:todo)
        do {_ = try await repo.changePendingRebaseActions(.skip,ids:[plan.entries[1].id],expected:before,editorExecutable:editor);XCTFail("Stale todo accepted")}catch RebaseFailure.changed {}
        try bytes.write(to:todo)
        let lock=root.appendingPathComponent(".git/rebase-merge/git-rebase-todo.lock");try Data().write(to:lock)
        do {_ = try await repo.changePendingRebaseActions(.skip,ids:[plan.entries[1].id],expected:before,editorExecutable:editor);XCTFail("Lock ignored")}catch RebaseFailure.actionEditLocked {}
        try FileManager.default.removeItem(at:lock)
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.changePendingRebaseActions(.skip,ids:[plan.entries[1].id],expected:before,editorExecutable:editor,cancellation:token);XCTFail("Cancellation ignored")}catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf:todo),bytes)
        let state=try await repo.rebaseActionEditSnapshot();XCTAssertEqual(state.replay.map(\.action),before.replay.map(\.action));XCTAssertEqual(state.head,before.head)
        _ = try await repo.abortRebase()
    }
    func testInterruptedActionJournalRestoresOldOrFinishesNewSide() async throws {
        let (root,repo,plan)=try await paused();defer {try? FileManager.default.removeItem(at:root)}
        let directory=root.appendingPathComponent(".git/rebase-merge"),names=["git-rebase-todo","done","turtlegit-replay-identities.json","turtlegit-message-editor.json","turtlegit-cherry-pick.json"]
        var old:[String:[String:String]]=[:]
        for name in names {old[name]=(try? Data(contentsOf:directory.appendingPathComponent(name))).map{["bytes":$0.base64EncodedString()]} ?? [:]}
        var new=old
        var identities=try JSONSerialization.jsonObject(with:Data(base64Encoded:old["turtlegit-replay-identities.json"]!["bytes"]!)!) as! [[String:Any]]
        identities[1]["action"]="drop"
        new["turtlegit-replay-identities.json"]=["bytes":try JSONSerialization.data(withJSONObject:identities).base64EncodedString()]
        let todo=String(decoding:Data(base64Encoded:old["git-rebase-todo"]!["bytes"]!)!,as:UTF8.self).replacingOccurrences(of:"pick ",with:"drop ")
        new["git-rebase-todo"]=["bytes":Data(todo.utf8).base64EncodedString()]
        let journal=try JSONSerialization.data(withJSONObject:["version":1,"before":old,"after":new])
        let journalURL=directory.appendingPathComponent("turtlegit-action-edit.json")
        for committed in [false,true] {
            try Data(base64Encoded:new["turtlegit-replay-identities.json"]!["bytes"]!)!.write(to:directory.appendingPathComponent("turtlegit-replay-identities.json"))
            if committed {try Data(todo.utf8).write(to:directory.appendingPathComponent("git-rebase-todo"))}
            try journal.write(to:journalURL)
            let state=try await repo.rebaseActionEditSnapshot()
            XCTAssertEqual(state.replay[1].action,committed ? .skip:.pick);XCTAssertFalse(FileManager.default.fileExists(atPath:journalURL.path))
        }
        XCTAssertEqual(plan.entries.count,2)
        let final=try await repo.continueRebase();XCTAssertFalse(final.state.active)
        let count=try await repo.run(["rev-list","--count","upstream..topic"]).text;XCTAssertEqual(count,"1\n")
    }
    func testUnknownExternalTodoCommandIsNotSilentlyDiscarded() async throws {
        let (root,repo,plan)=try await paused();defer {try? FileManager.default.removeItem(at:root)}
        let todo=root.appendingPathComponent(".git/rebase-merge/git-rebase-todo")
        var bytes=try Data(contentsOf:todo);bytes.append(Data("exec true\n".utf8));try bytes.write(to:todo)
        let before=try await repo.rebaseActionEditSnapshot()
        do {_ = try await repo.changePendingRebaseActions(.skip,ids:[plan.entries[1].id],expected:before,editorExecutable:editor);XCTFail("Unknown command discarded")}catch RebaseFailure.changed {}
        XCTAssertEqual(try Data(contentsOf:todo),bytes);_ = try await repo.abortRebase()
    }
}
