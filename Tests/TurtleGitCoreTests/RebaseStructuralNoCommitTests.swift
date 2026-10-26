import XCTest
import Darwin
@testable import TurtleGitCore

final class RebaseStructuralNoCommitTests:XCTestCase {
    var editor:URL {RebaseTests().editor}
    struct Fixture {
        let root:URL,repo:GitRepository,onto:LogEntry,leader:LogEntry,a:LogEntry,b:LogEntry,side:LogEntry,merge:LogEntry,tail:LogEntry
        var plan:RebasePlan
    }
    func commit(_ repo:GitRepository,_ path:String,_ message:String?=nil)async throws->LogEntry {
        try Data((path+"\n").utf8).write(to:repo.root.appendingPathComponent(path));try await repo.stage([path])
        _ = try await repo.commit(message:message ?? path);return try await repo.rebaseCommit("HEAD")
    }
    func fixture(conflict:Bool=false,empty:Bool=false,emptyLeader:Bool=false)async throws->Fixture {
        let (root,initial,_)=try await GitPatchTests().fixture()
        var accepted=false;defer{if !accepted {try? FileManager.default.removeItem(at:root)}}
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? initial.executable.path)
        let repo=GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false))
        _ = try await repo.run(["config","core.hooksPath","/dev/null"])
        let base=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["checkout","-b","upstream"])
        var onto=try await commit(repo,conflict ? "payload-a.txt":"upstream.txt","upstream")
        if conflict {
            try Data("different upstream payload\n".utf8).write(to:root.appendingPathComponent("payload-a.txt"));try await repo.stage(["payload-a.txt"])
            _ = try await repo.run(["commit","--amend","--no-edit"]);onto=try await repo.rebaseCommit("HEAD")
        }
        _ = try await repo.run(["checkout","-b","topic",base.hash])
        var leader=try await commit(repo,"leader.txt")
        if emptyLeader {
            let raw=try await repo.run(["cat-file","commit",leader.hash]).stdout,boundary=try XCTUnwrap(raw.range(of:Data([10,10])))
            let headers=String(decoding:raw.subdata(in:0..<boundary.lowerBound),as:UTF8.self).components(separatedBy:"\n").map{$0.hasPrefix("author ") ? "author Empty Structural Leader <empty-leader@example.invalid> 1700000000 +0200":$0}.joined(separator:"\n")
            let data=Data((headers+"\n\n\nReached empty leader body\n").utf8)
            let hash=try await repo.run(["hash-object","-w","-t","commit","--stdin"],input:data).text.trimmingCharacters(in:.newlines)
            _ = try await repo.run(["reset","--hard",hash]);leader=try await repo.rebaseCommit("HEAD")
        }
        let originalA=try await commit(repo,"payload-a.txt"),b=try await commit(repo,"payload-b.txt")
        var a=originalA
        if empty {
            let raw=try await repo.run(["cat-file","commit",originalA.hash]).stdout,boundary=try XCTUnwrap(raw.range(of:Data([10,10])))
            var bytes=raw.subdata(in:0..<boundary.upperBound);bytes.append(Data("\nStructural empty body\n".utf8))
            let hash=try await repo.run(["hash-object","-w","-t","commit","--stdin"],input:bytes).text.trimmingCharacters(in:.newlines)
            a=try await repo.rebaseCommit(hash)
            // Descendant B must actually name the empty-message occurrence.
            let bTree=try await repo.run(["rev-parse",b.hash+"^{tree}"]).text.trimmingCharacters(in:.newlines)
            let file=root.appendingPathComponent(".git/structural-b-message");try Data(b.message.utf8).write(to:file)
            let rewritten=try await repo.run(["commit-tree",bTree,"-p",a.hash,"-F",file.path],environmentOverrides:["GIT_AUTHOR_NAME":b.author,"GIT_AUTHOR_EMAIL":b.email,"GIT_AUTHOR_DATE":b.date]).text.trimmingCharacters(in:.newlines)
            _ = try await repo.run(["reset","--hard",rewritten])
        }
        let actualB=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["checkout","-b","side",base.hash]);let side=try await commit(repo,"side.txt")
        _ = try await repo.run(["checkout","topic"]);_ = try await repo.run(["merge","--no-ff","-m","descendant merge","side"])
        let merge=try await repo.rebaseCommit("HEAD"),tail=try await commit(repo,"tail.txt")
        for (key,value) in [("rebase.updateRefs","true"),("notes.rewrite.rebase","true"),("notes.rewriteRef","refs/notes/commits"),("notes.rewriteMode","concatenate")] {_ = try await repo.run(["config",key,value])}
        for (name,hash) in [("leader-witness",leader.hash),("group-start",a.hash),("group-end",actualB.hash),("side-witness",side.hash),("merge-witness",merge.hash),("tail-witness",tail.hash)] {_ = try await repo.run(["branch",name,hash])}
        for (number,entry) in [a,actualB].enumerated(){_ = try await repo.run(["notes","add","-m","structural group note "+String(number),entry.hash])}
        var settings=RebaseOptions();settings.branch="topic";settings.upstream="upstream";settings.preserveMerges=true
        var plan=try await repo.rebasePlan(settings)
        let byHash=Dictionary(uniqueKeysWithValues:plan.entries.map{($0.commit.hash,$0)})
        plan.entries=try [leader,a,actualB,side,merge,tail].map{try XCTUnwrap(byHash[$0.hash])}
        plan.entries[0].action = .skip;plan.entries[1].action = .squash;plan.entries[2].action = .squash
        accepted=true
        return .init(root:root,repo:repo,onto:onto,leader:leader,a:a,b:actualB,side:side,merge:merge,tail:tail,plan:plan)
    }
    func approval(_ f:Fixture)async throws->RebaseExecution {
        let result=try await f.repo.startRebase(f.plan,editorExecutable:editor)
        XCTAssertEqual(result.state.noCommitSquash?.phase,.approval,result.output)
        XCTAssertEqual(result.state.squashMessage?.isNewCommit,true)
        let head=try await f.repo.rebaseCommit("HEAD");XCTAssertEqual(head.hash,f.onto.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("leader.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("side.txt").path),"Structural reset/side replay ran while group changes were staged")
        return result
    }
    func verifyDescendants(_ f:Fixture,groupHead:String)async throws {
        let final=try await f.repo.rebaseCommit("HEAD"),merge=try await f.repo.rebaseCommit("HEAD^"),side=try await f.repo.rebaseCommit("side-witness")
        XCTAssertEqual(final.subject,f.tail.subject);XCTAssertEqual(final.parents,[merge.hash])
        XCTAssertEqual(merge.parents,[groupHead,side.hash]);XCTAssertEqual(side.parents,[f.onto.hash])
        let groupStart=try await f.repo.rebaseCommit("group-start"),groupEnd=try await f.repo.rebaseCommit("group-end"),mergeRef=try await f.repo.rebaseCommit("merge-witness"),tailRef=try await f.repo.rebaseCommit("tail-witness")
        XCTAssertEqual(groupStart.hash,groupHead);XCTAssertEqual(groupEnd.hash,groupHead);XCTAssertEqual(mergeRef.hash,merge.hash);XCTAssertEqual(tailRef.hash,final.hash)
        let skippedLeader=try await f.repo.rebaseCommit("leader-witness");XCTAssertEqual(skippedLeader.hash,f.onto.hash)
        let notes=try await f.repo.run(["notes","show",groupHead]).text
        XCTAssertTrue(notes.contains("structural group note 0"));XCTAssertTrue(notes.contains("structural group note 1"))
        let actualTree=try await f.repo.run(["rev-parse","HEAD^{tree}"]).stdout
        // Independent Git construction verifies the descendant merge tree;
        // unlike Core's structural todo it uses explicit real branches.
        _ = try await f.repo.run(["checkout","-b","expected-group",f.onto.hash])
        _ = try await f.repo.run(["cherry-pick","--no-commit",f.a.hash,f.b.hash])
        _ = try await f.repo.commit(message:"Independent group")
        _ = try await f.repo.run(["checkout","-b","expected-side",f.onto.hash]);_ = try await f.repo.run(["cherry-pick",f.side.hash])
        _ = try await f.repo.run(["checkout","expected-group"]);_ = try await f.repo.run(["merge","--no-ff","-m","Independent merge","expected-side"])
        _ = try await f.repo.run(["cherry-pick",f.tail.hash])
        let expectedTree=try await f.repo.run(["rev-parse","HEAD^{tree}"]).stdout
        XCTAssertEqual(actualTree,expectedTree)
    }
    func testApprovalDefersStructuralResetAndRewritesLabelsNotesAndReferences()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let review=try await approval(f),staged=try await f.repo.run(["diff","--cached","--name-only","-z"]).stdout
        XCTAssertEqual(Set(staged.split(separator:0).map{String(decoding:$0,as:UTF8.self)}),["payload-a.txt","payload-b.txt"])
        let reopened=GitRepository(root:f.root,executable:f.repo.executable),saved=try await reopened.rebaseState()
        XCTAssertEqual(saved.noCommitSquash,review.state.noCommitSquash)
        let completed=try await reopened.continueRebase(squashMessage:"Approved structural group",editorExecutable:editor)
        XCTAssertEqual(completed.exitCode,0,completed.output);XCTAssertFalse(completed.state.active)
        let group=try await reopened.rebaseCommit("group-end")
        XCTAssertEqual(group.parents,[f.onto.hash]);XCTAssertEqual(group.subject,"Approved structural group")
        try await verifyDescendants(f,groupHead:group.hash)
    }
    func testSplitFinalApprovalPublishesOnlyFinalPartToStructuralLabels()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _ = try await approval(f)
        let split=try await f.repo.beginRebaseSplit();XCTAssertTrue(split.isNewCommit)
        var options=CommitOptions();options.amendDiffToLastCommit=false
        _ = try await f.repo.commitRebaseSplit(message:"Structural first part",paths:["payload-a.txt"],staging:false,options:options,expected:split)
        let first=try await f.repo.rebaseCommit("HEAD"),state=try await f.repo.rebaseState()
        XCTAssertEqual(first.parents,[f.onto.hash]);XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("side.txt").path))
        _ = try await f.repo.commitRebaseSplit(message:"Structural second part",paths:["payload-b.txt"],staging:false,options:options,expected:try XCTUnwrap(state.split))
        let second=try await f.repo.rebaseCommit("HEAD");XCTAssertEqual(second.parents,[first.hash])
        let done=try await f.repo.continueRebase(editorExecutable:editor);XCTAssertFalse(done.state.active,done.output)
        try await verifyDescendants(f,groupHead:second.hash)
    }
    func testConflictSelectedStagingCancellationReopenAndAbortKeepTopology()async throws {
        let f=try await fixture(conflict:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let result=try await f.repo.startRebase(f.plan,editorExecutable:editor)
        XCTAssertEqual(result.state.noCommitSquash?.phase,.conflicted);XCTAssertEqual(result.state.conflicts,["payload-a.txt"])
        try Data("resolved structural payload\n".utf8).write(to:f.root.appendingPathComponent("payload-a.txt"))
        let before=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        let token=OperationCancellation();token.cancel()
        do {_ = try await f.repo.continueRebaseNoCommitSquash(paths:["payload-a.txt"],expected:result.state,expectedHead:f.onto.hash,cancellation:token);XCTFail("Cancelled resolution staged")}catch OperationCancellationFailure.cancelled {}
        let unchanged=try await f.repo.run(["ls-files","--stage","-z"]).stdout;XCTAssertEqual(unchanged,before)
        let reopened=GitRepository(root:f.root,executable:f.repo.executable),saved=try await reopened.rebaseState()
        let approval=try await reopened.continueRebaseNoCommitSquash(paths:["payload-a.txt"],expected:saved,expectedHead:f.onto.hash)
        XCTAssertEqual(approval.state.noCommitSquash?.phase,.approval);XCTAssertTrue(approval.state.conflicts.isEmpty)
        let head=try await reopened.rebaseCommit("HEAD");XCTAssertEqual(head.hash,f.onto.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("side.txt").path))
        _ = try await reopened.abortRebase()
        let restored=try await reopened.rebaseCommit("HEAD"),groupRef=try await reopened.rebaseCommit("group-end")
        XCTAssertEqual(restored.hash,f.plan.branchHash);XCTAssertEqual(groupRef.hash,f.b.hash)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent("payload-a.txt")),Data("payload-a.txt\n".utf8))
    }
    func testPendingEditsAndCurrentRowSkipRetainEarlierPatchAndSourceTopology()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let review=try await approval(f),index=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        for action in [RebaseAction.skip,.edit,.pick] {
            let snapshot=try await f.repo.rebaseActionEditSnapshot()
            let changed=try await f.repo.changePendingRebaseActions(action,ids:[f.plan.entries.last!.id],expected:snapshot,editorExecutable:editor)
            XCTAssertEqual(changed.replay.last?.action,action)
            let saved=try await f.repo.rebaseState(),current=try await f.repo.run(["ls-files","--stage","-z"]).stdout
            XCTAssertEqual(saved.noCommitSquash?.id,review.state.noCommitSquash?.id);XCTAssertEqual(current,index)
        }
        do {_ = try await f.repo.skipRebase();XCTFail("Skip left a selected descendant merge with an unreplayed first parent")}catch RebaseFailure.preservePlan {}
        let intact=try await f.repo.run(["ls-files","--stage","-z"]).stdout;XCTAssertEqual(intact,index)
        let snapshot=try await f.repo.rebaseActionEditSnapshot()
        _ = try await f.repo.changePendingRebaseActions(.skip,ids:[f.plan.entries[4].id],expected:snapshot,editorExecutable:editor)
        let skipped=try await f.repo.skipRebase()
        XCTAssertEqual(skipped.state.noCommitSquash?.phase,.approval,skipped.output)
        XCTAssertEqual(skipped.state.stoppedEntryID,f.plan.entries[1].id)
        let staged=try await f.repo.run(["diff","--cached","--name-only","-z"]).stdout
        XCTAssertEqual(staged,Data("payload-a.txt\0".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("payload-a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("payload-b.txt").path))
        let done=try await f.repo.continueRebase(squashMessage:"Approved A after skipping B",editorExecutable:editor);XCTAssertFalse(done.state.active,done.output)
        let first=try await f.repo.rebaseCommit("group-start"),last=try await f.repo.rebaseCommit("group-end"),merge=try await f.repo.rebaseCommit("merge-witness"),side=try await f.repo.rebaseCommit("side-witness"),tail=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(first.parents,[f.onto.hash]);XCTAssertEqual(first.subject,"Approved A after skipping B")
        XCTAssertEqual(last.hash,f.onto.hash);XCTAssertEqual(merge.hash,side.hash);XCTAssertEqual(side.parents,[f.onto.hash]);XCTAssertEqual(tail.parents,[side.hash])
        let retainedTree=try await f.repo.run(["ls-tree","--name-only",first.hash]).text
        XCTAssertTrue(retainedTree.contains("payload-a.txt"));XCTAssertFalse(retainedTree.contains("payload-b.txt"))
        for path in ["payload-a.txt","payload-b.txt","leader.txt"] {XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent(path).path))}
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("tail.txt").path))
    }
    func testEmptyIntermediateApprovalDoesNotPublishOrResetBeforeGroupCompletion()async throws {
        let f=try await fixture(empty:true);defer {try? FileManager.default.removeItem(at:f.root)}
        let warning=try await f.repo.startRebase(f.plan,editorExecutable:editor),receipt=try XCTUnwrap(warning.state.emptyMessageWarning,warning.output)
        XCTAssertEqual(receipt.commit,f.a.hash)
        let first=try await f.repo.acknowledgeRebaseEmptyMessage(receipt,expected:warning.state,expectedHead:f.onto.hash)
        XCTAssertEqual(first.state.noCommitSquash?.phase,.approval);XCTAssertFalse(first.state.canSplit)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("payload-b.txt").path))
        let next=try await f.repo.continueRebase(squashMessage:"Reviewed structural intermediate\n\nStructural empty body",editorExecutable:editor)
        XCTAssertEqual(next.state.noCommitSquash?.phase,.approval,next.output)
        let head=try await f.repo.rebaseCommit("HEAD");XCTAssertEqual(head.hash,f.onto.hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("side.txt").path))
        let message=try XCTUnwrap(next.state.squashMessage).message
        XCTAssertEqual(message.components(separatedBy:"Structural empty body").count-1,1)
        let done=try await f.repo.continueRebase(squashMessage:message,editorExecutable:editor);XCTAssertFalse(done.state.active,done.output)
        let group=try await f.repo.rebaseCommit("group-end")
        try await verifyDescendants(f,groupHead:group.hash)
    }
    func testInterruptedStructuralGroupRefusesAutomaticContinuationButCanAbort()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _ = try await approval(f)
        let path=f.root.appendingPathComponent(".git/rebase-merge/turtlegit-no-commit-squash.json"),index=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [String:Any]);object["phase"]="applying"
        try JSONSerialization.data(withJSONObject:object).write(to:path)
        let reopened=GitRepository(root:f.root,executable:f.repo.executable),state=try await reopened.rebaseState()
        XCTAssertEqual(state.noCommitSquash?.phase,.uncertain)
        do {_ = try await reopened.continueRebase(editorExecutable:editor);XCTFail("Interrupted structural payload was reapplied")}catch RebaseFailure.noCommitSquashUncertain {}
        let head=try await reopened.rebaseCommit("HEAD"),current=try await reopened.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(head.hash,f.onto.hash);XCTAssertEqual(current,index)
        _ = try await reopened.abortRebase();let restored=try await reopened.rebaseCommit("HEAD")
        XCTAssertEqual(restored.hash,f.plan.branchHash)
    }
    func testMergeSquashLeadingPhysicalSquashAndUnreplayedFirstParentRemainRefused()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let index=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        var leading=f.plan;leading.entries[0].action = .squash
        do {_ = try await f.repo.rebaseTodo(leading);XCTFail("Literal leading Squash admitted")}catch RebaseFailure.squash {}
        var merge=f.plan;merge.entries[4].action = .squash
        do {_ = try await f.repo.rebaseTodo(merge);XCTFail("Merge row Squash admitted")}catch RebaseFailure.preservePlan {}
        var missing=f.plan
        let deferred=missing.entries.remove(at:2);missing.entries.insert(deferred,at:4)
        do {_ = try await f.repo.rebaseTodo(missing);XCTFail("Unreplayed first merge parent admitted")}catch RebaseFailure.preservePlan {}
        let head=try await f.repo.rebaseCommit("HEAD"),after=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(head.hash,f.plan.branchHash);XCTAssertEqual(after,index)
    }
    func testReachedEmptyLeaderSkipDefersPriorLabelsAndKeepsCapturedSourceAuthor()async throws {
        var f=try await fixture(emptyLeader:true);defer {try? FileManager.default.removeItem(at:f.root)}
        f.plan.entries[0].action = .pick
        let warning=try await f.repo.startRebase(f.plan,editorExecutable:editor),decision=try XCTUnwrap(warning.state.emptyMessageWarning,warning.output)
        XCTAssertEqual(decision.commit,f.leader.hash);XCTAssertEqual(decision.head,f.onto.hash)
        let reopened=GitRepository(root:f.root,executable:f.repo.executable),pending=try await reopened.rebaseState()
        XCTAssertEqual(pending.emptyMessageWarning,decision)
        let review=try await reopened.skipRebase()
        XCTAssertEqual(review.state.noCommitSquash?.phase,.approval,review.output)
        XCTAssertTrue(review.state.noCommitSquash?.preservesLeaderAuthor==true)
        let staged=try await reopened.run(["diff","--cached","--name-only","-z"]).stdout,head=try await reopened.rebaseCommit("HEAD")
        XCTAssertEqual(head.hash,f.onto.hash)
        XCTAssertEqual(Set(staged.split(separator:0).map{String(decoding:$0,as:UTF8.self)}),["payload-a.txt","payload-b.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("leader.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("side.txt").path))
        let secondOwner=GitRepository(root:f.root,executable:f.repo.executable),saved=try await secondOwner.rebaseState()
        XCTAssertEqual(saved.noCommitSquash,review.state.noCommitSquash)
        let message="Reviewed reached structural group\n\nReached empty leader body\npayload-a.txt\npayload-b.txt"
        let done=try await secondOwner.continueRebase(squashMessage:message,editorExecutable:editor)
        XCTAssertFalse(done.state.active,done.output)
        let group=try await secondOwner.rebaseCommit("group-end")
        XCTAssertEqual(group.author,f.leader.author);XCTAssertEqual(group.email,f.leader.email)
        XCTAssertEqual(try XCTUnwrap(ISO8601DateFormatter().date(from:group.date)),try XCTUnwrap(ISO8601DateFormatter().date(from:f.leader.date)))
        XCTAssertEqual(group.message.trimmingCharacters(in:.newlines),message)
        try await verifyDescendants(f,groupHead:group.hash)
    }
    func testPendingSideSquashRegroupsAcrossStructuralControlsAndCollapsesMergeParents()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.repo.run(["notes","add","-m","regrouped side note",f.side.hash])
        _ = try await f.repo.run(["notes","add","-m","collapsed original merge note",f.merge.hash])
        let first=try await approval(f),snapshot=try await f.repo.rebaseActionEditSnapshot(),index=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        let sideID=f.plan.entries[3].id,tailID=f.plan.entries[5].id
        _ = try await f.repo.changePendingRebaseActions(.pick,ids:[sideID,tailID],expected:snapshot,changes:[sideID:.skip,tailID:.squash],editorExecutable:editor)
        let logicalNext=try await f.repo.rebaseState(),unchangedHead=try await f.repo.rebaseCommit("HEAD"),unchangedIndex=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertTrue(logicalNext.canSplit,"A retained logical merge Pick precedes the later Tail Squash, including reset-only/collapsed merges")
        XCTAssertEqual(unchangedHead.hash,f.onto.hash);XCTAssertEqual(unchangedIndex,index)
        let restore=try await f.repo.rebaseActionEditSnapshot()
        _ = try await f.repo.changePendingRebaseActions(.pick,ids:[sideID,tailID],expected:restore,editorExecutable:editor)
        let restored=try await f.repo.rebaseActionEditSnapshot()
        let changed=try await f.repo.changePendingRebaseActions(.squash,ids:[sideID],expected:restored,editorExecutable:editor)
        XCTAssertEqual(changed.replay.first{$0.id==f.plan.entries[3].id}?.action,.squash)
        let pending=try await f.repo.rebaseState()
        XCTAssertEqual(pending.noCommitSquash?.id,first.state.noCommitSquash?.id)
        XCTAssertFalse(pending.canSplit,"Next retained Squash must block Split even across labels/reset controls")
        let next=try await f.repo.continueRebase(squashMessage:"First approved subgroup",editorExecutable:editor)
        XCTAssertEqual(next.state.noCommitSquash?.phase,.approval,next.output)
        let head=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(head.hash,f.onto.hash,"Side regrouping must preserve the original group parent")
        let staged=try await f.repo.run(["diff","--cached","--name-only","-z"]).stdout
        XCTAssertEqual(Set(staged.split(separator:0).map{String(decoding:$0,as:UTF8.self)}),["payload-a.txt","payload-b.txt","side.txt"])
        let message=try XCTUnwrap(next.state.squashMessage).message
        XCTAssertEqual(message.components(separatedBy:"First approved subgroup").count-1,1)
        XCTAssertTrue(message.contains("side.txt"))
        let done=try await f.repo.continueRebase(squashMessage:"Final regrouped structural commit",editorExecutable:editor)
        XCTAssertEqual(done.exitCode,0,done.output);XCTAssertFalse(done.state.active)
        let final=try await f.repo.rebaseCommit("HEAD"),group=try await f.repo.rebaseCommit("group-end")
        XCTAssertEqual(group.parents,[f.onto.hash]);XCTAssertEqual(final.parents,[group.hash]);XCTAssertEqual(final.subject,f.tail.subject)
        for reference in ["group-start","side-witness","merge-witness"] {
            let mapped=try await f.repo.rebaseCommit(reference);XCTAssertEqual(mapped.hash,group.hash,reference)
        }
        let tail=try await f.repo.rebaseCommit("tail-witness");XCTAssertEqual(tail.hash,final.hash)
        let notes=try await f.repo.run(["notes","show",group.hash]).text
        for text in ["structural group note 0","structural group note 1","regrouped side note","collapsed original merge note"] {XCTAssertEqual(notes.components(separatedBy:text).count-1,1,notes)}
        let actualTree=try await f.repo.run(["rev-parse","HEAD^{tree}"]).stdout
        _ = try await f.repo.run(["checkout","-b","expected-regroup",f.onto.hash])
        _ = try await f.repo.run(["cherry-pick","--no-commit",f.a.hash,f.b.hash,f.side.hash])
        _ = try await f.repo.commit(message:"Independent regroup")
        _ = try await f.repo.run(["cherry-pick",f.tail.hash])
        let expectedTree=try await f.repo.run(["rev-parse","HEAD^{tree}"]).stdout
        XCTAssertEqual(actualTree,expectedTree)
    }
    func testConsumedStructuralResultTransportFailureReturnsOnceAndExplicitRetryFinishes()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.repo.run(["config","rebase.rescheduleFailedExec","true"])
        _ = try await f.repo.run(["notes","add","-m","checkpoint merge note",f.merge.hash])
        _ = try await approval(f)
        let snapshot=try await f.repo.rebaseActionEditSnapshot()
        _ = try await f.repo.changePendingRebaseActions(.squash,ids:[f.plan.entries[3].id],expected:snapshot,editorExecutable:editor)
        let regroup=try await f.repo.continueRebase(squashMessage:"Approved first subgroup",editorExecutable:editor)
        XCTAssertEqual(regroup.state.noCommitSquash?.phase,.approval,regroup.output)
        let folder=f.root.appendingPathComponent(".git/checkpoint-transport")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        let wrapper=folder.appendingPathComponent("git"),attempts=folder.appendingPathComponent("attempts"),failed=folder.appendingPathComponent("failed"),pidFile=folder.appendingPathComponent("refused-pid")
        let done=f.root.appendingPathComponent(".git/rebase-merge/done")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        is_rebase=0
        is_continue=0
        for arg in "$@"; do
          [ "$arg" = rebase ] && is_rebase=1
          [ "$arg" = --continue ] && is_continue=1
        done
        if [ "$is_rebase" = 1 ] && [ "$is_continue" = 1 ] && [ -f \(quote(done.path)) ] && tail -n 1 \(quote(done.path)) | grep -q '^# turtlegit-structural-result:'; then
          printf 'continue\n' >> \(quote(attempts.path))
          if [ ! -f \(quote(failed.path)) ]; then
            printf '%s\n' "$$" > \(quote(pidFile.path))
            : > \(quote(failed.path))
            printf 'Private consumed-checkpoint transport refused\n' >&2
            exit 73
          fi
        fi
        exec \(quote(f.repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let transport=GitRepository(root:f.root,executable:wrapper,libgit2Configuration:.init(enabled:false)),token=OperationCancellation()
        let watchdog=Task {try await Task.sleep(nanoseconds:30_000_000_000);token.cancel()};defer{watchdog.cancel()}
        let failure=try await transport.continueRebase(squashMessage:"Approved final collapsed group",cancellation:token,editorExecutable:editor)
        XCTAssertFalse(token.isCancelled,"Checkpoint recursion reached cancellation bound")
        XCTAssertEqual(failure.exitCode,73,failure.output);XCTAssertTrue(failure.state.hasStructuralResultCheckpoint)
        XCTAssertTrue(failure.state.active);XCTAssertFalse(failure.state.needsFileRecovery);XCTAssertFalse(failure.state.canSplit)
        XCTAssertNil(failure.state.noCommitSquash);XCTAssertNil(failure.state.mainlineDecision)
        XCTAssertEqual(try String(contentsOf:attempts,encoding:.utf8),"continue\n")
        let pid=try XCTUnwrap(Int32(try String(contentsOf:pidFile,encoding:.utf8).trimmingCharacters(in:.newlines)))
        XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH,"Refused private wrapper was not reaped")
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("tail.txt").path))
        let group=try await f.repo.rebaseCommit("HEAD"),rewrite=f.root.appendingPathComponent(".git/rebase-merge/rewritten-list")
        let rows=try String(contentsOf:rewrite,encoding:.utf8).split(separator:"\n").filter{$0.hasPrefix(f.merge.hash+" ")}
        XCTAssertEqual(rows.map(String.init),[f.merge.hash+" "+group.hash])
        let reopened=GitRepository(root:f.root,executable:wrapper,libgit2Configuration:.init(enabled:false)),saved=try await reopened.rebaseState()
        XCTAssertTrue(saved.hasStructuralResultCheckpoint);XCTAssertEqual(saved.stoppedEntryID,failure.state.stoppedEntryID)
        let completed=try await reopened.continueRebase(expectedReplayState:saved,expectedReplayHead:group.hash,editorExecutable:editor)
        XCTAssertEqual(completed.exitCode,0,completed.output);XCTAssertFalse(completed.state.active)
        XCTAssertEqual(try String(contentsOf:attempts,encoding:.utf8),"continue\ncontinue\n")
        let final=try await reopened.rebaseCommit("HEAD");XCTAssertEqual(final.parents,[group.hash]);XCTAssertEqual(final.subject,f.tail.subject)
        let notes=try await reopened.run(["notes","show",group.hash]).text
        for text in ["structural group note 0","structural group note 1","checkpoint merge note"] {XCTAssertEqual(notes.components(separatedBy:text).count-1,1,notes)}
    }
}
