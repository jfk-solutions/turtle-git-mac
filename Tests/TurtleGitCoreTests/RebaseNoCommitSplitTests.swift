import XCTest
@testable import TurtleGitCore

final class RebaseNoCommitSplitTests:XCTestCase {
    var editor:URL {RebaseTests().editor}
    func fixture()async throws->RebaseNoCommitSquashTests.Fixture {
        var f=try await RebaseNoCommitSquashTests().fixture()
        var accepted=false;defer {if !accepted {try? FileManager.default.removeItem(at:f.root)}}
        _ = try await f.repo.run(["checkout","-b","split-source",f.after.hash])
        let tail=try await RebaseMainlineTests().commit(f.repo,"tail.txt")
        _ = try await f.repo.run(["checkout","target"])
        f.plan=try await f.repo.cherryPickPlan(revisions:[tail.hash,f.after.hash,f.merge.hash])
        f.plan.entries[1].action = .squash;f.plan.entries[2].action = .squash
        accepted=true;return f
    }
    func approval(_ f:RebaseNoCommitSquashTests.Fixture)async throws->RebaseExecution {
        let result=try await RebaseNoCommitSquashTests().reachedThenSkip(f)
        XCTAssertEqual(result.state.noCommitSquash?.phase,.approval,result.output)
        XCTAssertTrue(result.state.canSplit);XCTAssertEqual(result.state.squashMessage?.isNewCommit,true)
        return result
    }
    func options(_ first:RebaseSplitState?=nil)->CommitOptions {
        var result=CommitOptions();result.amend=false;result.amendDiffToLastCommit=false
        if let first,!first.firstAuthor.isEmpty {result.author=first.firstAuthor;result.authorDate=ISO8601DateFormatter().date(from:first.firstDate)}
        return result
    }
    func testSplitPartsCreateChildrenWithoutAmendingBaseAndRewriteSourceNotes()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.repo.run(["config","notes.rewrite.rebase","true"])
        _ = try await f.repo.run(["config","notes.rewriteRef","refs/notes/commits"])
        _ = try await f.repo.run(["config","notes.rewriteMode","concatenate"])
        for (index,entry) in f.plan.entries.dropFirst().enumerated() {_ = try await f.repo.run(["notes","add","-m","source note "+String(index),entry.commit.hash])}
        let review=try await approval(f),index=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        let split=try await f.repo.beginRebaseSplit()
        XCTAssertTrue(split.isNewCommit);XCTAssertEqual(split.noCommitGroupID,review.state.noCommitSquash?.id)
        XCTAssertEqual(split.parts,0);XCTAssertEqual(split.firstParents,[f.base.hash])
        let base=try await f.repo.rebaseCommit("HEAD"),unchanged=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(base.hash,f.base.hash);XCTAssertEqual(unchanged,index)
        _ = try await f.repo.commitRebaseSplit(message:"First normal part\n",paths:["after.txt"],staging:false,options:options(split),expected:split)
        let first=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(first.parents,[f.base.hash]);XCTAssertEqual(first.author,f.merge.author);XCTAssertEqual(first.email,f.merge.email)
        let actualAuthorDate=try XCTUnwrap(ISO8601DateFormatter().date(from:first.date)),sourceAuthorDate=try XCTUnwrap(ISO8601DateFormatter().date(from:f.merge.date))
        XCTAssertEqual(actualAuthorDate,sourceAuthorDate)
        let firstTree=try await f.repo.run(["ls-tree","--name-only","HEAD"]).text
        XCTAssertTrue(firstTree.contains("after.txt"));XCTAssertFalse(firstTree.contains("tail.txt"))
        let stagedTail=try await f.repo.run(["show",":tail.txt"]).stdout
        XCTAssertEqual(stagedTail,Data("tail.txt\n".utf8),"Unchecked staged group path must survive the first part")
        do {_ = try await f.repo.commitRebaseSplit(message:"stale part",paths:["tail.txt"],staging:false,options:options(),expected:split);XCTFail("Stale part reused")}catch RebaseFailure.changed {}
        let reopened=GitRepository(root:f.root,executable:f.repo.executable),saved=try await reopened.rebaseState()
        let second=try XCTUnwrap(saved.split)
        XCTAssertEqual(second.parts,1);XCTAssertTrue(second.isNewCommit);XCTAssertEqual(second.expectedHead,first.hash)
        do {try await reopened.cancelUnstartedRebaseSplit();XCTFail("Unstarted Cancel accepted an already committed part")}catch RebaseFailure.changed {}
        let retained=try await reopened.rebaseState();XCTAssertEqual(retained.split?.parts,1)
        do {_ = try await reopened.continueRebase(editorExecutable:editor);XCTFail("Dirty remaining part finalized")}catch RebaseFailure.plan {}
        _ = try await reopened.commitRebaseSplit(message:"Second normal part\n",paths:["tail.txt"],staging:false,options:options(),expected:second)
        let last=try await reopened.rebaseCommit("HEAD"),configured=try await reopened.run(["config","user.name"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(last.parents,[first.hash]);XCTAssertEqual(last.author,configured)
        let done=try await reopened.continueRebase(editorExecutable:editor)
        XCTAssertFalse(done.state.active,done.output);XCTAssertEqual(done.exitCode,0)
        let final=try await reopened.rebaseCommit("HEAD");XCTAssertEqual(final.hash,last.hash)
        let notes=try await reopened.run(["notes","show",final.hash]).text
        XCTAssertTrue(notes.contains("source note 0"));XCTAssertTrue(notes.contains("source note 1"))
        let original=try await reopened.rebaseCommit(f.base.hash);XCTAssertEqual(original.message,f.base.message);XCTAssertEqual(original.parents,f.base.parents)
    }
    func testUnstartedCancelAndAbortPreserveApprovalAndOriginalRepository()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let review=try await approval(f),index=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        let token=OperationCancellation();token.cancel()
        do {_ = try await f.repo.beginRebaseSplit(cancellation:token);XCTFail("Cancelled Split began")}catch OperationCancellationFailure.cancelled {}
        let first=try await f.repo.beginRebaseSplit();XCTAssertTrue(first.isNewCommit)
        try await f.repo.cancelUnstartedRebaseSplit()
        let reopened=GitRepository(root:f.root,executable:f.repo.executable),restored=try await reopened.rebaseState()
        XCTAssertNil(restored.split);XCTAssertEqual(restored.squashMessage?.message,review.state.squashMessage?.message)
        XCTAssertEqual(restored.noCommitSquash?.id,review.state.noCommitSquash?.id)
        let currentIndex=try await reopened.run(["ls-files","--stage","-z"]).stdout;XCTAssertEqual(currentIndex,index)
        let split=try await reopened.beginRebaseSplit()
        _ = try await reopened.commitRebaseSplit(message:"Temporary first part",paths:["after.txt"],staging:false,options:options(),expected:split)
        _ = try await reopened.abortRebase()
        let head=try await reopened.rebaseCommit("HEAD"),state=try await reopened.rebaseState()
        XCTAssertEqual(head.hash,f.base.hash);XCTAssertFalse(state.active)
        for path in ["after.txt","tail.txt","right.txt"] {XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent(path).path))}
    }
    func testWrongAmendOptionsEmptyPartAndMovedHeadCannotMutateSplit()async throws {
        var f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        f.plan.entries[0].action = .skip
        let review=try await f.repo.startRebase(f.plan,editorExecutable:editor)
        XCTAssertEqual(review.state.noCommitSquash?.phase,.approval);XCTAssertTrue(review.state.canSplit)
        let split=try await f.repo.beginRebaseSplit(),index=try await f.repo.run(["ls-files","--stage","-z"]).stdout
        XCTAssertEqual(split.firstAuthor,"");XCTAssertEqual(split.firstDate,"");XCTAssertNil(split.squashDate)
        for bad in [CommitOptions(),{var value=options();value.amend=true;return value}()] {
            do {_ = try await f.repo.commitRebaseSplit(message:"Wrong amendment",paths:["after.txt"],staging:false,options:bad,expected:split);XCTFail("Base amendment options accepted")}catch RebaseFailure.changed {}
        }
        do {_ = try await f.repo.commitRebaseSplit(message:"No selected files",paths:[String](),staging:false,options:options(),expected:split);XCTFail("Empty selection committed")}catch {}
        let before=try await f.repo.rebaseCommit("HEAD");XCTAssertEqual(before.hash,f.base.hash)
        _ = try await f.repo.run(["update-ref","HEAD",f.merge.hash])
        do {_ = try await f.repo.commitRebaseSplit(message:"Moved base",paths:["after.txt"],staging:false,options:options(),expected:split);XCTFail("Moved HEAD accepted")}catch RebaseFailure.changed {}
        _ = try await f.repo.run(["update-ref","HEAD",f.base.hash])
        let after=try await f.repo.run(["ls-files","--stage","-z"]).stdout;XCTAssertEqual(after,index)
        let state=try await f.repo.rebaseState();XCTAssertEqual(state.split?.parts,0)
        var chosen=options();chosen.author="Chosen Split Author <chosen@example.invalid>";chosen.authorDate=ISO8601DateFormatter().date(from:"2026-10-09T09:30:00Z")
        _ = try await f.repo.commitRebaseSplit(message:"Explicit author choice",paths:["after.txt"],staging:false,options:chosen,expected:try XCTUnwrap(state.split))
        let authored=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(authored.author,"Chosen Split Author");XCTAssertEqual(authored.email,"chosen@example.invalid")
        XCTAssertEqual(ISO8601DateFormatter().date(from:authored.date),chosen.authorDate)
        XCTAssertEqual(authored.parents,[f.base.hash])
    }
    func testFailedChildCommitRetainsPartForExplicitRetry()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _ = try await approval(f);let split=try await f.repo.beginRebaseSplit()
        let hooks=f.root.appendingPathComponent(".git/split-hooks"),calls=hooks.appendingPathComponent("attempts")
        try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:false)
        let hook=hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nprintf 'attempt\\n' >> \"$(dirname \"$0\")/attempts\"\nprintf 'Private Split child refused\\n' >&2\nexit 73\n".utf8).write(to:hook)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        _ = try await f.repo.run(["config","core.hooksPath",hooks.path])
        do {_ = try await f.repo.commitRebaseSplit(message:"Held child draft",paths:["after.txt"],staging:false,options:options(),expected:split);XCTFail("Child failure accepted")}catch let failure as GitFailure {XCTAssertTrue(failure.message.contains("Private Split child refused"))}
        let saved=try await f.repo.rebaseState(),head=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(head.hash,f.base.hash);XCTAssertEqual(saved.split?.parts,0);XCTAssertNil(saved.cleanCommitFailure)
        XCTAssertEqual(try String(contentsOf:calls,encoding:.utf8),"attempt\n")
        _ = try await f.repo.run(["config","core.hooksPath","/dev/null"])
        _ = try await f.repo.commitRebaseSplit(message:"Retried exact child draft",paths:["after.txt"],staging:false,options:options(),expected:try XCTUnwrap(saved.split))
        let retried=try await f.repo.rebaseState();XCTAssertEqual(retried.split?.parts,1)
        let first=try await f.repo.rebaseCommit("HEAD");XCTAssertEqual(first.parents,[f.base.hash]);XCTAssertEqual(first.subject,"Retried exact child draft")
        XCTAssertEqual(try String(contentsOf:calls,encoding:.utf8),"attempt\n")
    }
    func testIntermediateApprovalFollowedBySquashCannotSplit()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        let raw=try await f.repo.run(["cat-file","commit",f.after.hash]).stdout
        let boundary=try XCTUnwrap(raw.range(of:Data([10,10])))
        var data=raw.subdata(in:0..<boundary.upperBound);data.append(Data("\nIntermediate body\n".utf8))
        let hash=try await f.repo.run(["hash-object","-w","-t","commit","--stdin"],input:data).text.trimmingCharacters(in:.newlines)
        var changed=f
        changed.plan=try await f.repo.cherryPickPlan(revisions:[f.plan.entries[2].commit.hash,hash,f.merge.hash]);changed.plan.entries[1].action = .squash;changed.plan.entries[2].action = .squash
        let reached=try await RebaseNoCommitSquashTests().reachedThenSkip(changed),warning=try XCTUnwrap(reached.state.emptyMessageWarning)
        let review=try await f.repo.acknowledgeRebaseEmptyMessage(warning,expected:reached.state,expectedHead:f.base.hash)
        XCTAssertEqual(review.state.noCommitSquash?.phase,.approval);XCTAssertFalse(review.state.canSplit)
        do {_ = try await f.repo.beginRebaseSplit();XCTFail("Intermediate source Squash boundary was split")}catch RebaseFailure.plan {}
        let state=try await f.repo.rebaseState();XCTAssertNil(state.split)
    }
    func testOrdinaryUpdateRefsUsesFinalSplitPart()async throws {
        let tests=RebaseTests(),(root,repo,_)=try await tests.fixture();defer {try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["checkout","topic"])
        let extra=try await RebaseMainlineTests().commit(repo,"third.txt")
        _ = try await repo.run(["config","rebase.updateRefs","true"])
        _ = try await repo.run(["branch","split-reference",extra.hash])
        var plan=try await repo.rebasePlan(tests.options());plan.entries[0].action = .skip
        for index in plan.entries.indices.dropFirst(){plan.entries[index].action = .squash}
        let review=try await repo.startRebase(plan,editorExecutable:editor),base=try await repo.rebaseCommit("HEAD")
        XCTAssertTrue(review.state.canSplit,review.output)
        let split=try await repo.beginRebaseSplit()
        _ = try await repo.commitRebaseSplit(message:"Ordinary first split",paths:["second.txt"],staging:false,options:options(),expected:split)
        let saved=try await repo.rebaseState()
        _ = try await repo.commitRebaseSplit(message:"Ordinary final split",paths:["third.txt"],staging:false,options:options(),expected:try XCTUnwrap(saved.split))
        let done=try await repo.continueRebase(editorExecutable:editor);XCTAssertFalse(done.state.active,done.output)
        let last=try await repo.rebaseCommit("HEAD"),first=try await repo.rebaseCommit("HEAD^"),mapped=try await repo.rebaseCommit("split-reference")
        XCTAssertEqual(first.parents,[base.hash]);XCTAssertEqual(last.parents,[first.hash]);XCTAssertEqual(mapped.hash,last.hash)
    }
    final class CancellationMarker:@unchecked Sendable {
        let token:OperationCancellation;let lock=NSLock();var bytes=Data()
        init(_ token:OperationCancellation){self.token=token}
        func consume(_ chunk:GitOutputChunk) {lock.lock();defer{lock.unlock()};bytes.append(chunk.data);if bytes.range(of:Data("SPLIT_PART_APPLIED".utf8)) != nil {token.cancel()}}
    }
    func testCancellationAfterActualPartPreservesPublishedPartAndNeverRepeatsIt()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _ = try await approval(f);let split=try await f.repo.beginRebaseSplit()
        let hooks=f.root.appendingPathComponent(".git/part-cancellation-hooks")
        try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:false)
        let hook=hooks.appendingPathComponent("post-commit")
        try Data("#!/bin/sh\nprintf 'SPLIT_PART_APPLIED\\n' >&2\n".utf8).write(to:hook)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        _ = try await f.repo.run(["config","core.hooksPath",hooks.path])
        let token=OperationCancellation(),marker=CancellationMarker(token)
        do {_ = try await f.repo.commitRebaseSplit(message:"Applied before cancel",paths:["after.txt"],staging:false,options:options(),expected:split,cancellation:token,onOutput:{marker.consume($0)});XCTFail("Cancellation was not reported")}catch OperationCancellationFailure.cancelled {}
        XCTAssertTrue(token.isCancelled)
        let reopened=GitRepository(root:f.root,executable:f.repo.executable),state=try await reopened.rebaseState(),head=try await reopened.rebaseCommit("HEAD")
        XCTAssertEqual(state.split?.parts,1);XCTAssertEqual(state.split?.expectedHead,head.hash);XCTAssertEqual(head.parents,[f.base.hash]);XCTAssertEqual(head.subject,"Applied before cancel")
        _ = try await reopened.run(["config","core.hooksPath","/dev/null"])
        _ = try await reopened.commitRebaseSplit(message:"Remaining after reopen",paths:["tail.txt"],staging:false,options:options(),expected:try XCTUnwrap(state.split))
        let done=try await reopened.continueRebase(editorExecutable:editor);XCTAssertFalse(done.state.active,done.output)
        let count=try await reopened.run(["rev-list","--count",f.base.hash+"..HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(count,"2")
    }
    func testDirtySkipRefusesAndCleanSkipKeepsAlreadyAcceptedPart()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _ = try await approval(f);let split=try await f.repo.beginRebaseSplit()
        _ = try await f.repo.commitRebaseSplit(message:"Keep accepted part",paths:["after.txt"],staging:false,options:options(),expected:split)
        let accepted=try await f.repo.rebaseCommit("HEAD")
        do {_ = try await f.repo.skipRebase();XCTFail("Dirty pending Split was discarded by Skip")}catch RebaseFailure.plan {}
        _ = try await f.repo.run(["restore","--source=HEAD","--staged","--worktree","--","tail.txt"])
        let done=try await f.repo.skipRebase();XCTAssertFalse(done.state.active,done.output)
        let final=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(final.hash,accepted.hash);XCTAssertEqual(final.parents,[f.base.hash]);XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("tail.txt").path))
    }
    func testFutureSquashAfterTwoPartsFoldsOnlyLastPartAndPreservesNotesAndReference()async throws {
        let tests=RebaseTests(),(root,repo,_)=try await tests.fixture();defer {try? FileManager.default.removeItem(at:root)}
        let third=try await RebaseMainlineTests().commit(repo,"third.txt"),fourth=try await RebaseMainlineTests().commit(repo,"fourth.txt")
        for (key,value) in [("rebase.updateRefs","true"),("notes.rewrite.rebase","true"),("notes.rewriteRef","refs/notes/commits"),("notes.rewriteMode","concatenate")] {_ = try await repo.run(["config",key,value])}
        _ = try await repo.run(["branch","future-split-reference",fourth.hash])
        var plan=try await repo.rebasePlan(tests.options())
        XCTAssertEqual(plan.entries.count,4)
        plan.entries[0].action = .skip;plan.entries[1].action = .squash;plan.entries[2].action = .squash
        for (number,entry) in plan.entries.dropFirst().enumerated(){_ = try await repo.run(["notes","add","-m","fold note "+String(number),entry.commit.hash])}
        let review=try await repo.startRebase(plan,editorExecutable:editor),base=try await repo.rebaseCommit("HEAD")
        XCTAssertTrue(review.state.canSplit,review.output)
        let split=try await repo.beginRebaseSplit()
        _ = try await repo.commitRebaseSplit(message:"Retained first part",paths:["second.txt"],staging:false,options:options(),expected:split)
        let first=try await repo.rebaseCommit("HEAD"),afterFirst=try await repo.rebaseState()
        _ = try await repo.commitRebaseSplit(message:"Fold this last part",paths:["third.txt"],staging:false,options:options(),expected:try XCTUnwrap(afterFirst.split))
        let last=try await repo.rebaseCommit("HEAD"),snapshot=try await repo.rebaseActionEditSnapshot()
        XCTAssertEqual(last.parents,[first.hash]);XCTAssertEqual(first.parents,[base.hash])
        let changed=try await repo.changePendingRebaseActions(.squash,ids:[plan.entries[3].id],expected:snapshot,editorExecutable:editor)
        XCTAssertEqual(changed.replay.last?.action,.squash)
        let reopened=GitRepository(root:root,executable:repo.executable),saved=try await reopened.rebaseState()
        XCTAssertEqual(saved.split?.parts,2)
        let next=try await reopened.continueRebase(editorExecutable:editor)
        XCTAssertEqual(next.state.noCommitSquash?.phase,.approval,next.output)
        let pendingHead=try await reopened.rebaseCommit("HEAD")
        XCTAssertEqual(pendingHead.hash,first.hash,"Future Squash may reset only the last accepted part")
        let message=try XCTUnwrap(next.state.squashMessage).message
        XCTAssertEqual(message.components(separatedBy:"Fold this last part").count-1,1)
        XCTAssertTrue(message.contains("fourth.txt"));XCTAssertFalse(message.contains("Retained first part"))
        let done=try await reopened.continueRebase(squashMessage:message,editorExecutable:editor)
        XCTAssertFalse(done.state.active,done.output)
        let final=try await reopened.rebaseCommit("HEAD"),previous=try await reopened.rebaseCommit("HEAD^"),reference=try await reopened.rebaseCommit("future-split-reference")
        XCTAssertEqual(previous.hash,first.hash);XCTAssertEqual(final.parents,[first.hash]);XCTAssertEqual(final.author,last.author);XCTAssertEqual(final.date,last.date)
        XCTAssertEqual(reference.hash,final.hash)
        let notes=try await reopened.run(["notes","show",final.hash]).text
        for number in 0..<3 {XCTAssertTrue(notes.contains("fold note "+String(number)),notes)}
        for path in ["second.txt","third.txt","fourth.txt"] {XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))}
        XCTAssertEqual(third.hash,plan.entries[2].commit.hash)
    }
    func testExplicitMessageOnlyPartCreatesOneNormalEmptyChildAndFinalizes()async throws {
        let f=try await fixture();defer {try? FileManager.default.removeItem(at:f.root)}
        _ = try await approval(f)
        _ = try await f.repo.run(["reset","--hard","HEAD"])
        let split=try await f.repo.beginRebaseSplit()
        var accepted=options(split);accepted.messageOnly=true
        _ = try await f.repo.commitRebaseSplit(message:"Explicit empty normal part",paths:[String](),staging:false,options:accepted,expected:split)
        let state=try await f.repo.rebaseState(),child=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(state.split?.parts,1);XCTAssertEqual(child.parents,[f.base.hash]);XCTAssertEqual(child.author,f.merge.author)
        let tree=try await f.repo.run(["rev-parse","HEAD^{tree}"]).stdout,baseTree=try await f.repo.run(["rev-parse",f.base.hash+"^{tree}"]).stdout
        XCTAssertEqual(tree,baseTree)
        let done=try await f.repo.continueRebase(editorExecutable:editor);XCTAssertFalse(done.state.active,done.output)
        let final=try await f.repo.rebaseCommit("HEAD")
        XCTAssertEqual(final.hash,child.hash);XCTAssertEqual(final.subject,"Explicit empty normal part")
        let count=try await f.repo.run(["rev-list","--count",f.base.hash+"..HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(count,"1")
    }
}
