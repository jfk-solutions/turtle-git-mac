import XCTest
@testable import TurtleGitCore

final class RebaseFailedPickTests: XCTestCase {
    private func failingPick(cherryPick: Bool = false, updateReferences: Bool = false, skipFirst: Bool = false) async throws -> (URL,GitRepository,RebaseExecution,RebaseTests) {
        let tests=RebaseTests(),(root,repo,_)=try await tests.fixture()
        var plan:RebasePlan
        if cherryPick {
            let first=try await repo.rebaseCommit("topic~1")
            _ = try await repo.run(["switch","upstream"])
            plan=try await repo.cherryPickPlan(revisions:[first.hash])
        } else {plan=try await repo.rebasePlan(tests.options())}
        if skipFirst {plan.entries[0].action = .skip}
        if updateReferences {
            _ = try await repo.run(["config","rebase.updateRefs","true"])
            _ = try await repo.run(["branch","intermediate","topic~1"])
        }
        _ = try await repo.run(["config","gpg.program","/usr/bin/false"])
        _ = try await repo.run(["config","commit.gpgsign","true"])
        let result=try await repo.startRebase(plan,editorExecutable:tests.editor)
        XCTAssertNotEqual(result.exitCode,0,result.output);XCTAssertTrue(result.state.active);XCTAssertTrue(result.state.conflicts.isEmpty)
        return (root,repo,result,tests)
    }
    private func obstruction(updateReferences: Bool = false) async throws -> (URL,GitRepository,RebaseExecution,RebaseTests) {
        let tests=RebaseTests(),(root,repo,_)=try await tests.fixture()
        if updateReferences {
            _ = try await repo.run(["config","rebase.updateRefs","true"])
            _ = try await repo.run(["branch","intermediate","topic~1"])
        }
        let hook=root.appendingPathComponent(".git/hooks/post-checkout")
        try Data("#!/bin/sh\nif [ -d .git/rebase-merge ]; then printf 'private obstruction\\n' > first.txt; fi\n".utf8).write(to:hook)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:hook.path)
        let result=try await repo.startRebase(try await repo.rebasePlan(tests.options()),editorExecutable:tests.editor)
        XCTAssertNotEqual(result.exitCode,0,result.output);XCTAssertTrue(result.state.active);XCTAssertTrue(result.state.conflicts.isEmpty)
        return (root,repo,result,tests)
    }
    private func recovery(_ repo:GitRepository,_ result:RebaseExecution) async throws -> RebaseFailedPickRecovery {
        let value=try await repo.failedPickRecovery(after:result)
        return try XCTUnwrap(value)
    }
    func testRescheduledOccurrenceUsesCompletePlanRatherThanRepeatedHashOrLegacyDoneCount()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let hash=String(repeating:"a",count:40),line="pick "+String(repeating:"a",count:7)+" repeated\n"
        let identities=(0..<3).map {["hash":hash,"occurrence":$0,"action":"pick"] as [String:Any]}
        try JSONSerialization.data(withJSONObject:identities).write(to:directory.appendingPathComponent("turtlegit-replay-identities.json"))
        try Data((line+line).utf8).write(to:directory.appendingPathComponent("git-rebase-todo"))
        try Data((line+line+line).utf8).write(to:directory.appendingPathComponent("done"))
        let legacy=try XCTUnwrap(RebaseEditor.rescheduledPick(in:directory))
        XCTAssertEqual(legacy.step,2);XCTAssertEqual(legacy.doneLine,1);XCTAssertEqual(legacy.duplicateLine,2)
        XCTAssertEqual(RebaseEditor.currentStep(in:directory),2)
        // The next planned occurrence may have the same hash without the
        // current occurrence having been rescheduled at all.
        try Data(line.utf8).write(to:directory.appendingPathComponent("git-rebase-todo"))
        try Data((line+line).utf8).write(to:directory.appendingPathComponent("done"))
        try Data("2\n".utf8).write(to:directory.appendingPathComponent("msgnum"))
        XCTAssertNil(RebaseEditor.rescheduledPick(in:directory));XCTAssertEqual(RebaseEditor.currentStep(in:directory),2)
        try Data((line+"pick bbbbbbb unrelated\n").utf8).write(to:directory.appendingPathComponent("git-rebase-todo"))
        XCTAssertNil(RebaseEditor.rescheduledPick(in:directory),"External plan edits must not be treated as a checked recovery occurrence")
    }
    func testLaterFailedPickRetryAndSkipPreservePreviouslyDroppedOccurrence()async throws {
        for action:RebaseFailedPickAction in [.retry,.skip] {
            let (root,repo,result,_)=try await failingPick(updateReferences:true,skipFirst:true)
            defer {try? FileManager.default.removeItem(at:root)}
            let captured=try await recovery(repo,result)
            XCTAssertEqual(captured.entry.commit.subject,"second");XCTAssertEqual(captured.state.currentStep,2)
            _ = try await repo.run(["config","commit.gpgsign","false"])
            let finished=try await repo.recoverFailedPick(captured,action:action)
            XCTAssertEqual(finished.exitCode,0,finished.output);XCTAssertFalse(finished.state.active)
            let subjects=try await repo.run(["log","--format=%s","upstream..HEAD"]).text.split(separator:"\n").map(String.init)
            XCTAssertEqual(subjects,action == .retry ? ["second"] : [])
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("first.txt").path))
            XCTAssertEqual(FileManager.default.fileExists(atPath:root.appendingPathComponent("second.txt").path),action == .retry)
        }
    }
    func testCapturedCustomReplayCommandsAreExcludedWhileGeneratedReferenceUpdatesRemainOwned()async throws {
        let (root,repo,result,_)=try await failingPick(updateReferences:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let directory=root.appendingPathComponent(".git/rebase-merge")
        let todo=directory.appendingPathComponent("git-rebase-todo"),done=directory.appendingPathComponent("done")
        let originalTodo=try Data(contentsOf:todo),originalDone=try Data(contentsOf:done)
        XCTAssertTrue(String(decoding:originalTodo,as:UTF8.self).contains("update-ref refs/heads/intermediate"))
        XCTAssertTrue(RebaseEditor.ordinaryReplayCommands(in:directory))
        let valid=try await repo.failedPickRecovery(after:result)
        XCTAssertNotNil(valid,"Generated update-ref records must not become a custom session")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let custom=["exec printf unowned", "break", "label external", "pick HEAD external", "update-ref refs/heads/unowned", "update-ref refs/heads/intermediate extra"]
        for command in custom {
            for target in [todo,done] {
                try originalTodo.write(to:todo);try originalDone.write(to:done)
                let bytes:Data
                if target==todo {bytes=originalTodo+Data((command+"\n").utf8)}
                else {bytes=Data((command+"\n").utf8)+originalDone}
                try bytes.write(to:target)
                // Capture the execution state AFTER custom commands were
                // introduced: receipt-versus-state equality alone cannot fence
                // commands that already existed at execution completion.
                let captured=RebaseExecution(output:result.output,exitCode:result.exitCode,state:try await repo.rebaseState(),witnessedHead:result.witnessedHead,witnessedSession:result.witnessedSession)
                XCTAssertFalse(RebaseEditor.ordinaryReplayCommands(in:directory),command)
                XCTAssertNil(RebaseEditor.rescheduledPick(in:directory),command)
                let recovery=try await repo.failedPickRecovery(after:captured)
                XCTAssertNil(recovery,"Custom instruction was admitted: \(target.lastPathComponent): \(command)")
                XCTAssertEqual(try Data(contentsOf:target),bytes,"Classification must not normalize a custom replay")
            }
        }
        try originalTodo.write(to:todo);try originalDone.write(to:done)
        let stillValid=try await repo.failedPickRecovery(after:result);XCTAssertNotNil(stillValid)
        let unchangedHead=try await repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(unchangedHead,head);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        _ = try await repo.abortRebase()
    }
    func testAppliedPickRetryAllowsSigningRepairAndPreservesOccurrence() async throws {
        let (root,repo,result,_)=try await failingPick();defer {try? FileManager.default.removeItem(at:root)}
        let before=try await repo.run(["write-tree"]).stdout
        let indexFile=root.appendingPathComponent(".git/index"),doneFile=root.appendingPathComponent(".git/rebase-merge/done"),todoFile=root.appendingPathComponent(".git/rebase-merge/git-rebase-todo")
        let indexBefore=try Data(contentsOf:indexFile),doneBefore=try Data(contentsOf:doneFile),todoBefore=try Data(contentsOf:todoFile)
        let captured=try await recovery(repo,result)
        XCTAssertEqual(try Data(contentsOf:indexFile),indexBefore);XCTAssertEqual(try Data(contentsOf:doneFile),doneBefore);XCTAssertEqual(try Data(contentsOf:todoFile),todoBefore)
        XCTAssertEqual(captured.entry.commit.subject,"first");XCTAssertNil(captured.pendingAction)
        let awaited1 = try await repo.run(["write-tree"]).stdout; XCTAssertEqual(awaited1,before)
        _ = try await repo.run(["config","commit.gpgsign","false"])
        let recovered=try await repo.recoverFailedPick(captured,action:.retry)
        XCTAssertEqual(recovered.exitCode,0,recovered.output);XCTAssertFalse(recovered.state.active)
        let subjects=try await repo.run(["log","--format=%s","upstream..HEAD"]).text.split(separator:"\n").map(String.init)
        XCTAssertEqual(subjects,["second","first"])
    }
    func testCherryPickFailureSkipRemovesOnlyFailedPatch() async throws {
        let (root,repo,result,_)=try await failingPick(cherryPick:true);defer {try? FileManager.default.removeItem(at:root)}
        let captured=try await recovery(repo,result)
        XCTAssertTrue(captured.state.isCherryPick)
        _ = try await repo.run(["config","commit.gpgsign","false"])
        let skipped=try await repo.recoverFailedPick(captured,action:.skip)
        XCTAssertEqual(skipped.exitCode,0,skipped.output);XCTAssertFalse(skipped.state.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("first.txt").path))
        let awaited2 = try await repo.run(["status","--porcelain"]).stdout.isEmpty; XCTAssertTrue(awaited2)
    }
    func testRescheduledPickRetryRepairsObstructionWithoutDuplicateReplayStep() async throws {
        let (root,repo,result,_)=try await obstruction();defer {try? FileManager.default.removeItem(at:root)}
        let captured=try await recovery(repo,result)
        XCTAssertEqual(captured.entry.commit.subject,"first")
        try FileManager.default.removeItem(at:root.appendingPathComponent(".git/hooks/post-checkout"))
        try FileManager.default.removeItem(at:root.appendingPathComponent("first.txt"))
        let recovered=try await repo.recoverFailedPick(captured,action:.retry)
        XCTAssertEqual(recovered.exitCode,0,recovered.output);XCTAssertFalse(recovered.state.active)
        let awaited3 = try await repo.run(["log","--format=%s","upstream..HEAD"]).text.split(separator:"\n").map(String.init); XCTAssertEqual(awaited3,["second","first"])
    }
    func testRescheduledPickSkipDoesNotRetryTargetOrDeleteUntrackedObstruction() async throws {
        let (root,repo,result,_)=try await obstruction();defer {try? FileManager.default.removeItem(at:root)}
        let captured=try await recovery(repo,result)
        let obstruction=try Data(contentsOf:root.appendingPathComponent("first.txt"))
        let skipped=try await repo.recoverFailedPick(captured,action:.skip)
        XCTAssertEqual(skipped.exitCode,0,skipped.output);XCTAssertFalse(skipped.state.active)
        let awaited4 = try await repo.run(["log","--format=%s","upstream..HEAD"]).text.split(separator:"\n").map(String.init); XCTAssertEqual(awaited4,["second"])
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("first.txt")),obstruction)
        let awaited5 = try await repo.run(["ls-files","--","first.txt"]).stdout.isEmpty; XCTAssertTrue(awaited5)
    }
    func testFailedSkipKeepsCleanupIntentAcrossReopenAndContinue() async throws {
        let (root,repo,result,_)=try await failingPick();defer {try? FileManager.default.removeItem(at:root)}
        let captured=try await recovery(repo,result)
        _ = try await repo.run(["config","commit.gpgsign","false"])
        let lock=root.appendingPathComponent(".git/index.lock")
        try Data("private lock".utf8).write(to:lock)
        let failed=try await repo.recoverFailedPick(captured,action:.skip)
        XCTAssertNotEqual(failed.exitCode,0,failed.output);XCTAssertTrue(failed.state.hasFailedPickCleanup)
        let cleanup=try await recovery(repo,failed)
        XCTAssertEqual(cleanup.pendingAction,.skip);XCTAssertTrue(cleanup.cleanupCommand?.contains("--skip") == true)
        XCTAssertFalse(cleanup.diagnostic.isEmpty)
        try FileManager.default.removeItem(at:lock)
        let reopened=GitRepository(root:root,executable:repo.executable)
        let state=try await reopened.rebaseState();XCTAssertTrue(state.hasFailedPickCleanup);XCTAssertFalse(state.needsFileRecovery)
        let finished=try await reopened.continueRebase()
        XCTAssertEqual(finished.exitCode,0,finished.output);XCTAssertFalse(finished.state.active)
        let awaited6 = try await reopened.run(["log","--format=%s","upstream..HEAD"]).text.split(separator:"\n").map(String.init); XCTAssertEqual(awaited6,["second"])
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("first.txt").path))
    }
    func testRecoveryRefusesTrackedMutationAndCancellationWithoutChangingReplay() async throws {
        let (root,repo,result,_)=try await failingPick();defer {try? FileManager.default.removeItem(at:root)}
        let captured=try await recovery(repo,result)
        let todo=root.appendingPathComponent(".git/rebase-merge/git-rebase-todo"),before=try Data(contentsOf:todo)
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.recoverFailedPick(captured,action:.skip,cancellation:token);XCTFail("Cancelled recovery mutated replay")} catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf:todo),before)
        try Data("external tracked change\n".utf8).write(to:root.appendingPathComponent("first.txt"))
        do {_ = try await repo.recoverFailedPick(captured,action:.skip);XCTFail("Changed tracked payload accepted")} catch RebaseFailure.changed {}
        XCTAssertEqual(try Data(contentsOf:todo),before)
        _ = try await repo.abortRebase()
    }
    func testOriginallyEmptyCommitCreationFailureIsNotBecameEmptyStop() async throws {
        let tests=RebaseTests(),(root,repo,_)=try await tests.fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["commit","--allow-empty","-m","kept empty"])
        let empty=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["switch","upstream"])
        let plan=try await repo.cherryPickPlan(revisions:[empty.hash])
        _ = try await repo.run(["config","gpg.program","/usr/bin/false"]);_ = try await repo.run(["config","commit.gpgsign","true"])
        let result=try await repo.startRebase(plan,editorExecutable:tests.editor)
        XCTAssertNotEqual(result.exitCode,0,result.output)
        let captured=try await recovery(repo,result)
        _ = try await repo.run(["config","commit.gpgsign","false"])
        let retried=try await repo.recoverFailedPick(captured,action:.retry)
        XCTAssertEqual(retried.exitCode,0,retried.output);XCTAssertFalse(retried.state.active)
        let awaited7 = try await repo.run(["log","--format=%s","-1"]).text.trimmingCharacters(in:.newlines); XCTAssertEqual(awaited7,"kept empty")
        let awaited8 = try await repo.run(["diff","--name-only","HEAD^","HEAD"]).stdout; XCTAssertEqual(awaited8,Data())
    }
    func testConflictsAndBecameEmptyKeepExistingRecoveryRoutes() async throws {
        let tests=RebaseTests(),(root,repo,_)=try await tests.fixture(conflict:true);defer {try? FileManager.default.removeItem(at:root)}
        let result=try await repo.startRebase(try await repo.rebasePlan(tests.options()),editorExecutable:tests.editor)
        let awaited9 = try await repo.failedPickRecovery(after:result); XCTAssertNil(awaited9);_ = try await repo.abortRebase()
        let first=try await repo.rebaseCommit("topic~1")
        _ = try await repo.run(["switch","main"])
        _ = try await repo.run(["cherry-pick",first.hash])
        try Data("target marker\n".utf8).write(to:root.appendingPathComponent("target-marker.txt"))
        try await repo.stage(["target-marker.txt"]);_ = try await repo.commit(message:"target marker")
        // An already-applied patch keeps its distinct Commit/Skip/Cancel route.
        let plan=try await repo.cherryPickPlan(revisions:[first.hash])
        let empty=try await repo.startRebase(plan,editorExecutable:tests.editor)
        XCTAssertNotEqual(empty.exitCode,0,empty.output);XCTAssertTrue(empty.state.active)
        let awaited10 = try await repo.failedPickRecovery(after:empty); XCTAssertNil(awaited10)
        XCTAssertFalse(first.hash.isEmpty);_ = try await repo.abortRebase()
    }
    func testRescheduledSkipCleanupRetriesAfterReferenceStepNormalization() async throws {
        let (root,repo,result,_)=try await obstruction(updateReferences:true);defer {try? FileManager.default.removeItem(at:root)}
        let captured=try await recovery(repo,result)
        let lock=root.appendingPathComponent(".git/index.lock");try Data("held".utf8).write(to:lock)
        let failed=try await repo.recoverFailedPick(captured,action:.skip)
        XCTAssertNotEqual(failed.exitCode,0,failed.output)
        let cleanup=try await recovery(repo,failed)
        XCTAssertEqual(cleanup.pendingAction,.skip)
        try FileManager.default.removeItem(at:lock)
        let retried=try await repo.recoverFailedPick(cleanup,action:.retry)
        XCTAssertEqual(retried.exitCode,0,retried.output);XCTAssertFalse(retried.state.active)
        let subjects=try await repo.run(["log","--format=%s","upstream..HEAD"]).text.split(separator:"\n").map(String.init)
        XCTAssertEqual(subjects,["second"])
    }
    func testPendingCleanupAbortRestoresOriginalBranchWithoutReplayingPick() async throws {
        let (root,repo,result,_)=try await failingPick();defer {try? FileManager.default.removeItem(at:root)}
        let captured=try await recovery(repo,result),original=result.state.originalHead
        let lock=root.appendingPathComponent(".git/index.lock");try Data("held".utf8).write(to:lock)
        _ = try await repo.recoverFailedPick(captured,action:.skip)
        try FileManager.default.removeItem(at:lock)
        let aborted=try await repo.abortRebase()
        XCTAssertEqual(aborted.exitCode,0,aborted.output);XCTAssertFalse(aborted.state.active)
        let head=try await repo.rebaseCommit("HEAD")
        XCTAssertEqual(head.hash,original)
    }
    func testClassifierRejectsHeadChangedAfterExecutionBeforeCapturingReceipt() async throws {
        let (root,repo,result,_)=try await failingPick();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["config","commit.gpgsign","false"])
        _ = try await repo.run(["commit","--allow-empty","-m","external commit"])
        let head=try await repo.rebaseCommit("HEAD"),index=try await repo.run(["write-tree"]).stdout
        do {_ = try await repo.failedPickRecovery(after:result);XCTFail("Changed failure HEAD was recaptured")} catch RebaseFailure.changed {}
        let after=try await repo.rebaseCommit("HEAD"),afterIndex=try await repo.run(["write-tree"]).stdout
        XCTAssertEqual(after.hash,head.hash);XCTAssertEqual(afterIndex,index)
        _ = try await repo.abortRebase()
    }

    func testInterruptedRescheduledSkipPublicationRestoresOrCompletesDurableIntent() async throws {
        let (root,repo,result,_)=try await obstruction();defer {try? FileManager.default.removeItem(at:root)}
        let captured=try await recovery(repo,result),directory=root.appendingPathComponent(".git/rebase-merge")
        let names=["git-rebase-todo","done","turtlegit-replay-identities.json","turtlegit-message-editor.json","turtlegit-cherry-pick.json"]
        var before:[String:[String:String]]=[:]
        for name in names {before[name]=(try? Data(contentsOf:directory.appendingPathComponent(name))).map {["bytes":$0.base64EncodedString()]} ?? [:]}
        var after=before
        var done=String(decoding:try XCTUnwrap(Data(base64Encoded:before["done"]!["bytes"]!)),as:UTF8.self).components(separatedBy:"\n")
        let last=try XCTUnwrap(done.lastIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}));done.remove(at:last)
        after["done"]=["bytes":Data(done.joined(separator:"\n").utf8).base64EncodedString()]
        var todo=String(decoding:try XCTUnwrap(Data(base64Encoded:before["git-rebase-todo"]!["bytes"]!)),as:UTF8.self).components(separatedBy:"\n")
        let first=try XCTUnwrap(todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}))
        let fields=todo[first].split(separator:" ",maxSplits:1);todo[first]="drop "+fields[1]
        after["git-rebase-todo"]=["bytes":Data(todo.joined(separator:"\n").utf8).base64EncodedString()]
        let index=try await repo.run(["ls-files","--stage","-v","-z"]).stdout
        let worktree=try await repo.run(["diff","--binary","--no-ext-diff","--no-textconv","--"]).stdout
        let state=try JSONSerialization.jsonObject(with:JSONEncoder().encode(captured.state))
        let intent:[String:Any]=["version":1,"state":state,"head":captured.head,"hash":captured.entry.commit.hash,"diagnostic":captured.diagnostic,
            "occurrence":captured.entry.occurrence,"prepared":true,"sessionIdentity":captured.sessionIdentity,"phase":"rescheduled","files":after,
            "index":index.base64EncodedString(),"worktree":worktree.base64EncodedString()]
        let marker="turtlegit-failed-pick.json",intentData=try JSONSerialization.data(withJSONObject:intent)
        before[marker]=[:];after[marker]=["bytes":intentData.base64EncodedString()]
        let journal=try JSONSerialization.data(withJSONObject:["version":2,"before":before,"after":after])
        let journalURL=directory.appendingPathComponent("turtlegit-action-edit.json")
        for committed in [false,true] {
            try journal.write(to:journalURL)
            try Data(base64Encoded:after["done"]!["bytes"]!)!.write(to:directory.appendingPathComponent("done"))
            if committed {try Data(base64Encoded:after["git-rebase-todo"]!["bytes"]!)!.write(to:directory.appendingPathComponent("git-rebase-todo"))}
            // Simulate a crash with the durable intent not yet installed. The
            // todo commit point must recover either the entire old or new side.
            let restored=try await repo.rebaseState()
            XCTAssertEqual(restored.hasFailedPickCleanup,committed)
            XCTAssertFalse(FileManager.default.fileExists(atPath:journalURL.path))
            XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent("done")),Data(base64Encoded:(committed ? after:before)["done"]!["bytes"]!))
        }
        let reopened=GitRepository(root:root,executable:repo.executable)
        let completed=try await reopened.continueRebase()
        XCTAssertEqual(completed.exitCode,0,completed.output);XCTAssertFalse(completed.state.active)
        let subjects=try await reopened.run(["log","--format=%s","upstream..HEAD"]).text.split(separator:"\n").map(String.init)
        XCTAssertEqual(subjects,["second"])
    }

    func testStagedSigningRetryUpdatesSideReferenceToRetriedCommit() async throws {
        let (root,repo,result,_)=try await failingPick(updateReferences:true);defer {try? FileManager.default.removeItem(at:root)}
        let captured=try await recovery(repo,result),original=try await repo.rebaseCommit("intermediate")
        _ = try await repo.run(["config","commit.gpgsign","false"])
        let recovered=try await repo.recoverFailedPick(captured,action:.retry)
        XCTAssertEqual(recovered.exitCode,0,recovered.output);XCTAssertFalse(recovered.state.active)
        let updated=try await repo.rebaseCommit("intermediate"),first=try await repo.rebaseCommit("HEAD^")
        XCTAssertEqual(updated.hash,first.hash);XCTAssertNotEqual(updated.hash,original.hash)
    }

    func testRetryKeepsStillRequestedSignaturesUntilConfigurationIsRepaired() async throws {
        let (root,repo,result,_)=try await failingPick();defer {try? FileManager.default.removeItem(at:root)}
        let captured=try await recovery(repo,result)
        let retried=try await repo.recoverFailedPick(captured,action:.retry)
        XCTAssertNotEqual(retried.exitCode,0,retried.output);XCTAssertTrue(retried.state.active)
        let requested=try String(contentsOf:root.appendingPathComponent(".git/rebase-merge/gpg_sign_opt"),encoding:.utf8)
        XCTAssertTrue(requested.hasPrefix("-S"));XCTAssertTrue(retried.output.lowercased().contains("gpg"),retried.output)
        let next=try await recovery(repo,retried)
        _ = try await repo.run(["config","commit.gpgsign","false"])
        let repaired=try await repo.recoverFailedPick(next,action:.retry)
        XCTAssertEqual(repaired.exitCode,0,repaired.output);XCTAssertFalse(repaired.state.active)
        let subjects=try await repo.run(["log","--format=%s","upstream..HEAD"]).text.split(separator:"\n").map(String.init)
        XCTAssertEqual(subjects,["second","first"])
    }

}
