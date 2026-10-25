import XCTest
@testable import TurtleGitCore

final class RebaseEmptyMessageTests:XCTestCase {
    var editor:URL {RebaseTests().editor}
    struct Fixture {
        let root:URL,repository:GitRepository,base:String,originalHead:String
        let plan:RebasePlan,empty:LogEntry
    }
    func commit(_ repository:GitRepository,path:String,message:String,parents:[String]?=nil)async throws->LogEntry {
        try Data((path+"\n").utf8).write(to:repository.root.appendingPathComponent(path))
        try await repository.stage([path])
        let messageFile=repository.root.appendingPathComponent(".git/empty-message-fixture")
        try Data(message.utf8).write(to:messageFile)
        defer {try? FileManager.default.removeItem(at:messageFile)}
        let identity=["GIT_AUTHOR_NAME":path == "empty.txt" || path == "merge.txt" ? "Raw Empty Author":"Author "+path,"GIT_AUTHOR_EMAIL":"raw-empty@example.invalid","GIT_AUTHOR_DATE":path == "first.txt" ? "2026-10-10T10:00:00+0200":"2026-10-12T10:00:00+0200"]
        if let parents {
            let tree=String(decoding:try await repository.run(["write-tree"]).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
            let arguments=["commit-tree",tree]+parents.flatMap{["-p",$0]}+["-F",messageFile.path]
            let oid=String(decoding:try await repository.run(arguments,environmentOverrides:identity).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
            _=try await repository.run(["reset","--hard",oid])
        } else {
            _=try await repository.run(["commit","--allow-empty-message","--cleanup=verbatim","-F",messageFile.path],environmentOverrides:identity)
        }
        return try await repository.rebaseCommit("HEAD")
    }
    func fixture(message:String="",action:RebaseAction = .pick,followingSquash:Bool=false)async throws->Fixture {
        let(root,original,_)=try await GitPatchTests().fixture()
        var accepted=false
        defer {if !accepted {try? FileManager.default.removeItem(at:root)}}
        let git=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? original.executable.path)
        let repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["config","core.hooksPath","/dev/null"])
        _=try await repository.run(["config","rebase.updateRefs","false"])
        let base=try await repository.rebaseCommit("HEAD")
        _=try await repository.run(["switch","-c","upstream"])
        _=try await commit(repository,path:"upstream.txt",message:"upstream")
        _=try await repository.run(["switch","-c","topic",base.hash])
        _=try await commit(repository,path:"first.txt",message:"first")
        let empty=try await commit(repository,path:"empty.txt",message:message)
        _=try await commit(repository,path:"last.txt",message:"last")
        var options=RebaseOptions();options.branch="topic";options.upstream="upstream"
        var plan=try await repository.rebasePlan(options)
        let index=try XCTUnwrap(plan.entries.firstIndex{$0.commit.hash==empty.hash})
        plan.entries[index].action=action
        if followingSquash {plan.entries[index+1].action = .squash}
        accepted=true
        return .init(root:root,repository:repository,base:base.hash,originalHead:plan.branchHash,plan:plan,empty:empty)
    }
    func testSkippedEmptySubjectDoesNotStopOrApplyItsFile()async throws {
        let f=try await fixture(action:.skip);defer {try? FileManager.default.removeItem(at:f.root)}
        XCTAssertTrue(f.empty.subject.isEmpty)
        let result=try await f.repository.startRebase(f.plan,editorExecutable:editor)
        XCTAssertEqual(result.exitCode,0);XCTAssertFalse(result.state.active)
        let omitted=try await f.repository.run(["ls-tree","HEAD","--","empty.txt"]).stdout
        XCTAssertTrue(omitted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("last.txt").path))
    }
    func testWhitespaceSubjectIsNotAnEmptySubjectWarning()async throws {
        let f=try await fixture(message:" \nbody preserved\n");defer {try? FileManager.default.removeItem(at:f.root)}
        XCTAssertEqual(LogEntry.splitHistoryMessage(f.empty.message).subject," ","Source tests exact empty subject, never a trimmed entire message")
        let result=try await f.repository.startRebase(f.plan,editorExecutable:editor)
        XCTAssertEqual(result.exitCode,0);XCTAssertFalse(result.state.active)
        let history=try await f.repository.run(["log","--format=%B","upstream..topic"]).stdout
        XCTAssertTrue(String(decoding:history,as:UTF8.self).contains("body preserved"))
    }
    func paused(_ f:Fixture)async throws->(RebaseExecution,RebaseEmptyMessageWarning) {
        let result=try await f.repository.startRebase(f.plan,editorExecutable:editor)
        let warning=try XCTUnwrap(result.state.emptyMessageWarning)
        XCTAssertNotEqual(result.exitCode,0);XCTAssertTrue(result.state.active)
        XCTAssertEqual(warning.commit,f.empty.hash)
        XCTAssertEqual(warning.entryID,f.plan.entries.first{$0.commit.hash==f.empty.hash}?.id)
        let reachedHead=try await f.repository.rebaseCommit("HEAD");XCTAssertEqual(warning.head,reachedHead.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("empty.txt").path),"Warning must precede application")
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("last.txt").path))
        return(result,warning)
    }
    func acknowledge(_ repository:GitRepository,_ result:RebaseExecution,_ warning:RebaseEmptyMessageWarning)async throws->RebaseExecution {
        try await repository.acknowledgeRebaseEmptyMessage(warning,expected:result.state,expectedHead:warning.head)
    }
    func testPickAndExplicitEditWarnBeforeApplicationAndRetainRequestedActions()async throws {
        for action in [RebaseAction.pick,.edit] {
            let f=try await fixture(action:action);defer {try? FileManager.default.removeItem(at:f.root)}
            let(result,warning)=try await paused(f)
            XCTAssertEqual(warning.requestedAction,action)
            let reopened=GitRepository(root:f.root,executable:f.repository.executable,libgit2Configuration:.init(enabled:false))
            let saved=try await reopened.rebaseState()
            XCTAssertEqual(saved.emptyMessageWarning?.entryID,warning.entryID)
            let applied=try await acknowledge(reopened,result,warning)
            XCTAssertNil(applied.state.emptyMessageWarning);XCTAssertTrue(applied.state.isEditPause)
            XCTAssertEqual(applied.state.stoppedEntryID,warning.entryID)
            let rows=try await reopened.rebaseReplayEntries()
            XCTAssertEqual(rows.first{$0.id==warning.entryID}?.action,action,"Effective Edit must not rewrite requested row identity/action")
            let changed=try await reopened.rebaseCommit("HEAD")
            XCTAssertEqual(changed.author,f.empty.author);XCTAssertEqual(changed.email,f.empty.email);XCTAssertEqual(changed.date,f.empty.date)
            do {_=try await reopened.continueRebase(editMessage:"");XCTFail("Empty review accepted")}catch RebaseFailure.message {}
            let final=try await reopened.continueRebase(editMessage:"Approved empty message")
            XCTAssertFalse(final.state.active);XCTAssertEqual(final.exitCode,0)
            let approved=try await reopened.rebaseCommit("HEAD~1")
            XCTAssertEqual(approved.subject,"Approved empty message");XCTAssertEqual(approved.author,f.empty.author);XCTAssertEqual(approved.date,f.empty.date)
        }
    }
    func testBodyOnlyRawMessageUsesExactSourceSubjectAndKeepsBodyForReview()async throws {
        let f=try await fixture(message:"\nBody without a subject\n");defer {try? FileManager.default.removeItem(at:f.root)}
        XCTAssertTrue(LogEntry.splitHistoryMessage(f.empty.message).subject.isEmpty);XCTAssertTrue(f.empty.message.contains("Body without a subject"))
        let(result,warning)=try await paused(f)
        let applied=try await acknowledge(f.repository,result,warning)
        XCTAssertTrue(applied.state.isEditPause)
        let snapshot=try await f.repository.rebaseSessionSnapshot()
        XCTAssertTrue(snapshot.messageCommit?.message.contains("Body without a subject") == true)
        _=try await f.repository.abortRebase()
        let observedCommit1=try await f.repository.rebaseCommit("HEAD");XCTAssertEqual(observedCommit1.hash,f.originalHead)
    }
    func testEmptySquashPreservesFirstAuthorAndWaitsForExplicitCombinedMessage()async throws {
        let f=try await fixture(action:.squash);defer {try? FileManager.default.removeItem(at:f.root)}
        let first=try XCTUnwrap(f.plan.entries.first?.commit)
        let(result,warning)=try await paused(f)
        XCTAssertEqual(warning.requestedAction,.squash)
        let applied=try await acknowledge(f.repository,result,warning)
        XCTAssertNotNil(applied.state.squashMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("last.txt").path))
        let final=try await f.repository.continueRebase(squashMessage:"Reviewed combined group")
        XCTAssertFalse(final.state.active)
        let group=try await f.repository.rebaseCommit("HEAD~1")
        XCTAssertEqual(group.subject,"Reviewed combined group");XCTAssertEqual(group.author,first.author);XCTAssertEqual(group.date,first.date)
    }
    func testForcedEditBeforeFollowingSquashIsAMandatoryPause()async throws {
        let f=try await fixture(followingSquash:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let(result,warning)=try await paused(f)
        let applied=try await acknowledge(f.repository,result,warning)
        XCTAssertTrue(applied.state.isEditPause);XCTAssertNil(applied.state.squashMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("last.txt").path))
        let group=try await f.repository.continueRebase(editMessage:"Reviewed group first")
        XCTAssertNotNil(group.state.squashMessage)
        let final=try await f.repository.continueRebase(squashMessage:"Reviewed final group")
        XCTAssertFalse(final.state.active)
        let observedCommit2=try await f.repository.rebaseCommit("HEAD");XCTAssertEqual(observedCommit2.subject,"Reviewed final group")
    }
    func testWarningCancellationAndStaleAcknowledgementCannotApplyTheCommit()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let(result,warning)=try await paused(f)
        let index=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        let token=OperationCancellation();token.cancel()
        do {_=try await f.repository.acknowledgeRebaseEmptyMessage(warning,expected:result.state,expectedHead:warning.head,cancellation:token);XCTFail("Cancelled warning accepted")}catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
        let observedCommit3=try await f.repository.rebaseCommit("HEAD");XCTAssertEqual(observedCommit3.hash,warning.head)
        _=try await f.repository.abortRebase()
        do {_=try await acknowledge(f.repository,result,warning);XCTFail("Retired session accepted warning")}catch {}
        let observedCommit4=try await f.repository.rebaseCommit("HEAD");XCTAssertEqual(observedCommit4.hash,f.originalHead)
    }
    func testForcedEditCanSplitAndAbortRestoresTheOriginalBranch()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let(result,warning)=try await paused(f)
        _=try await acknowledge(f.repository,result,warning)
        let split=try await f.repository.beginRebaseSplit()
        XCTAssertEqual(split.entryID,warning.entryID);XCTAssertEqual(split.firstAuthor,f.empty.author+" <"+f.empty.email+">")
        var firstOptions=CommitOptions();firstOptions.amend=true;firstOptions.amendDiffToLastCommit=false
        _=try await f.repository.commitRebaseSplit(message:"Split reviewed empty",paths:["empty.txt"],staging:false,options:firstOptions,expected:split)
        _=try await f.repository.abortRebase()
        let observedCommit5=try await f.repository.rebaseCommit("HEAD");XCTAssertEqual(observedCommit5.hash,f.originalHead)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("empty.txt").path))
    }
    func testMiddleEmptySquashWarnsAndPausesBeforeTheFollowingSquash()async throws {
        let f=try await fixture(message:"\nEmpty middle body\n",action:.squash,followingSquash:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let(result,warning)=try await paused(f)
        XCTAssertEqual(warning.requestedAction,.squash)
        let stopped=try await acknowledge(f.repository,result,warning)
        XCTAssertNotNil(stopped.state.squashMessage,"Empty middle member needs its own editable review")
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("last.txt").path))
        let next=try await f.repository.continueRebase(squashMessage:"Reviewed middle group\n\nEmpty middle body\n")
        let combined=try XCTUnwrap(next.state.squashMessage?.message)
        XCTAssertEqual(combined.components(separatedBy:"Empty middle body").count-1,1,"Intermediate forced review duplicated its original body")
        XCTAssertTrue(combined.contains("last"))
        let approved=combined.replacingOccurrences(of:"Reviewed middle group",with:"Reviewed complete group")
        let final=try await f.repository.continueRebase(squashMessage:approved)
        XCTAssertFalse(final.state.active)
        let head=try await f.repository.rebaseCommit("HEAD")
        XCTAssertEqual(head.subject,"Reviewed complete group")
        XCTAssertEqual(head.message.components(separatedBy:"Empty middle body").count-1,1)
        XCTAssertEqual(head.message.trimmingCharacters(in:.newlines),approved.trimmingCharacters(in:.newlines))
        XCTAssertEqual(head.author,f.plan.entries[0].commit.author)
    }
    func testCherryPickAndRepeatedAddedOccurrenceRetainTheirExactWarningIdentity()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _=try await f.repository.run(["switch","main"])
        let cherry=try await f.repository.cherryPickPlan(revisions:[f.empty.hash])
        let first=try await f.repository.startRebase(cherry,editorExecutable:editor)
        let warning=try XCTUnwrap(first.state.emptyMessageWarning)
        XCTAssertTrue(first.state.isCherryPick);XCTAssertEqual(warning.entryID,cherry.entries[0].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("empty.txt").path))
        let applied=try await acknowledge(f.repository,first,warning)
        XCTAssertTrue(applied.state.isEditPause)
        let final=try await f.repository.continueRebase(editMessage:"Reviewed cherry")
        XCTAssertFalse(final.state.active)
        let head=try await f.repository.rebaseCommit("HEAD")
        XCTAssertEqual(head.author,f.empty.author);XCTAssertEqual(head.date,f.empty.date)

        _=try await f.repository.run(["switch","topic"])
        var repeated=try await f.repository.addingRebaseCommits(f.plan,revisions:[f.empty.hash])
        repeated.entries[1].action = .skip
        let duplicate=try XCTUnwrap(repeated.entries.last)
        XCTAssertEqual(duplicate.occurrence,1)
        let pause=try await f.repository.startRebase(repeated,editorExecutable:editor)
        let duplicateWarning=try XCTUnwrap(pause.state.emptyMessageWarning)
        XCTAssertEqual(duplicateWarning.entryID,duplicate.id);XCTAssertNotEqual(duplicateWarning.entryID,f.plan.entries[1].id)
        _=try await f.repository.abortRebase()
    }
    func structuralFixture(following:Bool=false)async throws->(Fixture,LogEntry,RebasePlan) {
        let f=try await fixture(message:"ordinary topic commit")
        var accepted=false;defer {if !accepted {try? FileManager.default.removeItem(at:f.root)}}
        _=try await f.repository.run(["switch","-c","side",f.base])
        let side=try await commit(f.repository,path:"side.txt",message:"side")
        _=try await f.repository.run(["switch","topic"])
        let before=try await f.repository.rebaseCommit("HEAD")
        _=try await f.repository.run(["merge","--no-ff","--no-commit","side"])
        let merge=try await commit(f.repository,path:"merge.txt",message:"",parents:[before.hash,side.hash])
        XCTAssertEqual(merge.parents.count,2);XCTAssertTrue(merge.subject.isEmpty)
        if following {_=try await commit(f.repository,path:"future.txt",message:"future after skipped merge")}
        var options=RebaseOptions();options.branch="topic";options.upstream="upstream";options.preserveMerges=true
        let plan=try await f.repository.rebasePlan(options)
        accepted=true;return(f,merge,plan)
    }
    func testStructuralEmptyMergeRetainsBothParentsThroughEditAndAbort()async throws {
        let(f,merge,plan)=try await structuralFixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let paused=try await f.repository.startRebase(plan,editorExecutable:editor)
        let warning=try XCTUnwrap(paused.state.emptyMessageWarning)
        XCTAssertEqual(warning.commit,merge.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("merge.txt").path))
        let applied=try await acknowledge(f.repository,paused,warning)
        XCTAssertTrue(applied.state.isEditPause)
        let appliedHead=try await f.repository.rebaseCommit("HEAD")
        XCTAssertEqual(appliedHead.parents.count,2)
        _=try await f.repository.amendRebaseCommit(message:"Reviewed merge")
        let amended=try await f.repository.rebaseCommit("HEAD")
        XCTAssertEqual(amended.parents,appliedHead.parents);XCTAssertEqual(amended.author,merge.author)
        _=try await f.repository.abortRebase()
        let restored=try await f.repository.rebaseCommit("HEAD")
        XCTAssertEqual(restored.hash,merge.hash);XCTAssertEqual(restored.parents,merge.parents)
    }
    func testSkipPendingStructuralWarningDoesNotResetOrApplyMergeBeforeFutureReplay()async throws {
        let(f,merge,plan)=try await structuralFixture(following:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let paused=try await f.repository.startRebase(plan,editorExecutable:editor)
        let warning=try XCTUnwrap(paused.state.emptyMessageWarning)
        XCTAssertEqual(warning.commit,merge.hash)
        let reached=try await f.repository.rebaseCommit("HEAD")
        XCTAssertEqual(reached.hash,warning.head)
        let final=try await f.repository.skipRebase()
        XCTAssertFalse(final.state.active);XCTAssertEqual(final.exitCode,0)
        let head=try await f.repository.rebaseCommit("HEAD")
        XCTAssertEqual(head.subject,"future after skipped merge")
        XCTAssertEqual(head.parents,[reached.hash],"Skip must retain checkpoint HEAD as fallback, never reset to the merge's target")
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("merge.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("future.txt").path))
        let ancestor=try await f.repository.run(["merge-base","--is-ancestor",merge.hash,"HEAD"],successfulExitCodes:0...1)
        XCTAssertEqual(ancestor.exitCode,1,"Skipped original merge must not become an ancestor")
    }
    func testPendingActionEditsRegenerateOrRemoveFutureWarnings()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        var plan=f.plan;plan.entries[0].action = .edit
        let result=try await f.repository.startRebase(plan,editorExecutable:editor)
        XCTAssertTrue(result.state.isEditPause);XCTAssertNil(result.state.emptyMessageWarning)
        let snapshot=try await f.repository.rebaseActionEditSnapshot()
        let id=plan.entries[1].id
        _=try await f.repository.changePendingRebaseActions(.skip,ids:[id],expected:snapshot,editorExecutable:editor)
        let skipped=try await f.repository.rebaseActionEditSnapshot()
        _=try await f.repository.changePendingRebaseActions(.pick,ids:[id],expected:skipped,editorExecutable:editor)
        let next=try await f.repository.continueRebase()
        let warning=try XCTUnwrap(next.state.emptyMessageWarning)
        XCTAssertEqual(warning.entryID,id);XCTAssertEqual(warning.requestedAction,.pick)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("empty.txt").path))
        _=try await f.repository.abortRebase()
    }
    func testExternalGitEditSessionArmsFutureWarningAndDurablyAdoptsWithoutReplayingCompletedWork()async throws {
        for finish in [false,true] {
            let f=try await fixture(message:"\nExternal empty-row body\n");defer {try? FileManager.default.removeItem(at:f.root)}
            let sequence=f.root.appendingPathComponent(".git/external-empty-sequence")
            let script="""
            #!/bin/sh
            /usr/bin/awk 'BEGIN { changed=0 } !changed && $1 == "pick" { sub(/^pick /,"edit "); changed=1 } { print }' "$1" > "$1.external"
            /bin/mv "$1.external" "$1"
            """
            try Data(script.utf8).write(to:sequence)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:sequence.path)
            _=try await f.repository.run(["-c","rebase.abbreviateCommands=false","rebase","-i","upstream","topic"],environmentOverrides:["GIT_SEQUENCE_EDITOR":"'"+sequence.path.replacingOccurrences(of:"'",with:"'\\''")+"'","GIT_EDITOR":"/usr/bin/true"])
            let directory=f.root.appendingPathComponent(".git/rebase-merge")
            XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-replay-identities.json").path),"Must originate in Git, not startRebase")
            let external=try await f.repository.rebaseState(),first=try await f.repository.rebaseCommit("HEAD")
            XCTAssertTrue(external.isEditPause);XCTAssertNil(external.emptyMessageWarning)
            let doneURL=directory.appendingPathComponent("done"),originalDone=try Data(contentsOf:doneURL)
            var forgedDone=originalDone
            forgedDone.append(Data(("exec false # turtlegit-empty-subject:"+f.empty.hash+"\n").utf8))
            try forgedDone.write(to:doneURL)
            let guardedNames=["done","git-rebase-todo","message","author-script","turtlegit-replay-identities.json","turtlegit-adopted-plan.json"]
            let beforeGuard=Dictionary(uniqueKeysWithValues:guardedNames.map{($0,try? Data(contentsOf:directory.appendingPathComponent($0)))})
            do {_=try await f.repository.rebaseActionEditSnapshot();XCTFail("Unowned marker was silently adopted")}catch RebaseFailure.plan {}catch RebaseFailure.changed {}
            let afterGuard=Dictionary(uniqueKeysWithValues:guardedNames.map{($0,try? Data(contentsOf:directory.appendingPathComponent($0)))})
            XCTAssertEqual(afterGuard,beforeGuard,"Refusing an unowned marker must not publish adoption metadata or alter todo")
            try originalDone.write(to:doneURL)
            let paused=try await f.repository.continueRebase(expectedReplayState:external,expectedReplayHead:first.hash,editorExecutable:editor)
            let warning=try XCTUnwrap(paused.state.emptyMessageWarning)
            XCTAssertEqual(warning.commit,f.empty.hash);XCTAssertEqual(warning.requestedAction,.pick)
            XCTAssertEqual(warning.head,first.hash,"Adoption must not replay already completed first row")
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("empty.txt").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-adopted-plan.json").path))
            let reopened=GitRepository(root:f.root,executable:f.repository.executable,libgit2Configuration:.init(enabled:false))
            let saved=try await reopened.rebaseState(),rows=try await reopened.rebaseReplayEntries()
            XCTAssertEqual(saved.emptyMessageWarning,warning)
            XCTAssertEqual(rows.first{$0.id==warning.entryID}?.action,.pick)
            if finish {
                let applied=try await acknowledge(reopened,paused,warning);XCTAssertTrue(applied.state.isEditPause)
                let final=try await reopened.continueRebase(editMessage:"Reviewed external empty",editorExecutable:editor)
                XCTAssertFalse(final.state.active)
                let approved=try await reopened.rebaseCommit("HEAD~1")
                XCTAssertEqual(approved.subject,"Reviewed external empty");XCTAssertEqual(approved.author,f.empty.author)
                XCTAssertEqual(approved.parents,[first.hash])
            } else {
                _=try await reopened.abortRebase()
                let restored=try await reopened.rebaseCommit("HEAD")
                XCTAssertEqual(restored.hash,f.originalHead)
            }
        }
    }
}
