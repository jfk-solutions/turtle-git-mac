import XCTest
@testable import TurtleGitCore

final class GitReplayInspectionTests:XCTestCase {
    private let sampleOID=String(repeating:"a",count:40)
    private func frame(_ value:[String:Any]) throws -> Data {
        Data("TurtleGit Inspection v1:".utf8)+(try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])).base64EncodedData()+Data([10])
    }
    private func response(_ operation:String,_ rows:[[String:Any]]) throws -> Data {
        var data=try frame(["kind":"header","operation":operation]);for row in rows {data.append(try frame(row))};data.append(try frame(["kind":"end","count":rows.count]));return data
    }
    private func engine(_ bits:[GitLibGit2Operation],helper:URL?=nil)->GitLibGit2Configuration {
        .init(enabled:true,mask:bits.reduce(0){$0|$1.mask},helperURL:helper)
    }
    private func clone(_ repo:GitRepository,_ config:GitLibGit2Configuration)->GitRepository {
        .init(root:repo.root,executable:repo.executable,askpass:repo.askpass,diffDetection:repo.diffDetection,libgit2Configuration:config)
    }
    func testProtocolKeepsAbsentStagesNumericModesAndLiteralRequestedPaths() throws {
        let path="folder/[*]\t雪\nname"
        let data=try response("conflictInfo",[["kind":"conflict","path":path,"stages":[["number":1,"mode":0o100644,"oid":sampleOID],["number":3,"mode":0o160000,"oid":sampleOID]]],["kind":"conflict","path":"absent","stages":[]]])
        let result=try GitReplayInspectionProtocol.decode(data,operation:"conflictInfo",paths:[path,"absent"])
        XCTAssertEqual(result.entries.map(\.path),[path,"absent"]);XCTAssertEqual(result.entries[0].stages.map(\.mode),["100644","160000"]);XCTAssertEqual(result.entries[0].stages.map(\.number),[1,3]);XCTAssertTrue(result.entries[1].stages.isEmpty)
        XCTAssertEqual(try GitReplayInspectionProtocol.decode(response("mergeBase",[["kind":"mergeBase","base":NSNull(),"fastForward":false]]),operation:"mergeBase").mergeBase,.init(base:nil,fastForward:false))
    }
    func testProtocolRejectsWrongKindsNumbersPathsMissingRowsAndTrailingFrames() throws {
        for row in [["kind":"mergeBase","base":NSNull(),"fastForward":true],["kind":"mergeBase","base":"short","fastForward":false],["kind":"mergeBase","base":sampleOID,"fastForward":1]] as [[String:Any]] {
            XCTAssertThrowsError(try GitReplayInspectionProtocol.decode(response("mergeBase",[row]),operation:"mergeBase"))
        }
        let stage:[String:Any]=["number":2,"mode":0o100644,"oid":sampleOID]
        for rows in [[],[["kind":"conflict","path":"other","stages":[stage]]],[["kind":"conflict","path":"file","stages":[stage,stage]]],[["kind":"conflict","path":"file","stages":[["number":2,"mode":123,"oid":sampleOID]]]]] as [[[String:Any]]] {
            XCTAssertThrowsError(try GitReplayInspectionProtocol.decode(response("conflictInfo",rows),operation:"conflictInfo",paths:["file"]))
        }
        let valid=try response("clean",[["kind":"clean","clean":true]])
        XCTAssertThrowsError(try GitReplayInspectionProtocol.decode(valid.dropLast(),operation:"clean"))
        XCTAssertThrowsError(try GitReplayInspectionProtocol.decode(valid+frame(["kind":"end","count":1]),operation:"clean"))
        XCTAssertThrowsError(try GitReplayInspectionProtocol.decode(valid,operation:"conflicts"))
        let token=OperationCancellation();token.cancel();XCTAssertThrowsError(try GitReplayInspectionProtocol.decode(valid,operation:"clean",cancellation:token))
    }
    func testSelectedMergeBaseCoversEqualityAncestryDivergenceUnrelatedAndTags() async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["tag","-a","base-tag","-m","tag",base]);_ = try await repo.run(["commit","--allow-empty","-m","next"])
        let tip=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let selected=engine([.mergeBase])
        let equal=try await repo.replayMergeBase(from:tip,to:tip,backend:selected),forward=try await repo.replayMergeBase(from:"base-tag",to:tip,backend:selected),reverse=try await repo.replayMergeBase(from:tip,to:base,backend:selected)
        XCTAssertEqual(equal,.init(base:tip,fastForward:true));XCTAssertEqual(forward,.init(base:base,fastForward:true));XCTAssertEqual(reverse,.init(base:base,fastForward:false))
        let other=try await repo.run(["commit-tree","HEAD^{tree}"],input:Data("independent\n".utf8)).text.trimmingCharacters(in:.newlines)
        let unrelated=try await repo.replayMergeBase(from:tip,to:other,backend:selected);XCTAssertNil(unrelated.base);XCTAssertFalse(unrelated.fastForward)
        let invalid=try await repo.replayMergeBase(from:"missing-reference",to:tip,backend:selected);XCTAssertNil(invalid.base);XCTAssertFalse(invalid.fastForward)
    }
    func testSelectedCleanStagedOKUntrackedIgnoredAndUnbornMatchSource() async throws {
        let(root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let selected=engine([.checkCleanWorktree])
        let initialClean=try await repo.replayWorktreeIsClean(backend:selected);XCTAssertTrue(initialClean)
        try Data("untracked\n".utf8).write(to:root.appendingPathComponent("untracked"));try Data("ignored\n".utf8).write(to:root.appendingPathComponent(".git/info/exclude"))
        try Data("ignored\n".utf8).write(to:root.appendingPathComponent("ignored"));let untrackedClean=try await repo.replayWorktreeIsClean(backend:selected);XCTAssertTrue(untrackedClean)
        try Data("staged\n".utf8).write(to:root.appendingPathComponent(path));_ = try await repo.run(["add","--",path])
        let staged=try await repo.replayWorktreeIsClean(backend:selected),stagedOK=try await repo.replayWorktreeIsClean(stagedOK:true,backend:selected)
        XCTAssertFalse(staged);XCTAssertTrue(stagedOK)
        try Data("working\n".utf8).write(to:root.appendingPathComponent(path));let dirty=try await repo.replayWorktreeIsClean(stagedOK:true,backend:selected);XCTAssertFalse(dirty)
        let unborn=root.appendingPathComponent("unborn");try FileManager.default.createDirectory(at:unborn,withIntermediateDirectories:true);let empty=GitRepository(root:unborn);_ = try await empty.run(["init"])
        let clean=try await empty.replayWorktreeIsClean(backend:selected);XCTAssertFalse(clean)
    }
    func testReadinessConsumersCaptureCleanMergeBaseAndSVNPolicy() async throws {
        let(root,base,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let repo=clone(base,engine([.mergeBase,.checkCleanWorktree,.checkConflicts]))
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        var options=RebaseOptions();options.branch="HEAD";options.upstream=head
        let plan=try await repo.rebasePlan(options);XCTAssertEqual(plan.disposition,.equal)
        let ready=try await repo.synchronizationRebaseState(target:head);XCTAssertTrue(ready.canFastForward)
        let stash=try await repo.replayStashCondition(cherryPick:false);XCTAssertFalse(stash.dirty)
        try Data("changed\n".utf8).write(to:root.appendingPathComponent(path))
        let dirty=try await repo.replayStashCondition(cherryPick:false),svn=try await repo.svnTrackedChanges();XCTAssertTrue(dirty.dirty);XCTAssertTrue(svn)
    }
    func testSelectedBooleanConflictsMatchesActualIndexAndCorruptIndexIsFatal() async throws {
        let(root,repo,_)=try await ConflictResolutionTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let selected=engine([.checkConflicts])
        let conflicts=try await repo.hasWorkingTreeConflicts(backend:selected);XCTAssertTrue(conflicts)
        let before=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try Data("corrupt-index".utf8).write(to:root.appendingPathComponent(".git/index"))
        do {_ = try await repo.hasWorkingTreeConflicts(backend:selected);XCTFail("corrupt index silently became no conflicts")}catch{}
        try before.write(to:root.appendingPathComponent(".git/index"))
        let entries=try await repo.conflicts();_ = try await repo.resolveConflicts(entries,using:.current,backend:selected)
        let resolved=try await repo.hasWorkingTreeConflicts(backend:selected);XCTAssertFalse(resolved)
    }
    func testMineTheirsSelectedStageInfoPreservesBinaryAndUnrelatedIndex() async throws {
        for choice in [ResolveChoice.mine,.theirs] {
            let(root,repo,path)=try await ConflictResolutionTests().fixture(binary:true);defer{try? FileManager.default.removeItem(at:root)}
            let entries=try await repo.conflicts(),entry=try XCTUnwrap(entries.first{$0.path==path}),stage=try XCTUnwrap(entry.stages.first{$0.number==choice.rawValue})
            let expected=try await repo.run(["cat-file","blob",stage.object]).stdout,other=try await repo.run(["show",":other.txt"]).stdout
            _ = try await repo.resolveConflicts([entry],using:choice,backend:engine([.getConflictInfo]))
            let actual=try await repo.run(["show",":"+path]).stdout,afterOther=try await repo.run(["show",":other.txt"]).stdout
            XCTAssertEqual(actual,expected);XCTAssertEqual(afterOther,other);XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("other.txt")),"other working\n")
        }
    }
    func testMissingConflictIsSkippedForBothEnginesButCurrentRemainsStale() async throws {
        for selected in [engine([.getConflictInfo]),GitLibGit2Configuration(enabled:false)] {
            let(root,repo,path)=try await ConflictResolutionTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
            let entries=try await repo.conflicts();_ = try await repo.run(["add","-f","--",path])
            let before=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            let output=try await repo.resolveConflicts(entries,using:.mine,backend:selected)
            XCTAssertTrue(output.contains("Skip: "+path));XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before)
            do {_ = try await repo.resolveConflicts(entries,using:.current,backend:selected);XCTFail("Current silently accepted stale conflict")}catch ResolveFailure.stale{}
        }
    }
    func testMissingConflictSkipDoesNotPreventLaterLiveResolution() async throws {
        let(root,repo,path)=try await ConflictResolutionTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let entries=try await repo.conflicts(),first=try XCTUnwrap(entries.first)
        let secondPath="second\t雪\nfile"
        let packet=first.stages.map { $0.mode+" "+$0.object+" "+String($0.number)+"\t"+secondPath+"\0" }.joined()
        _ = try await repo.run(["update-index","-z","--index-info"],input:Data(packet.utf8))
        try Data("second working\n".utf8).write(to:root.appendingPathComponent(secondPath))
        let checked=[first,ConflictEntry(path:secondPath,stages:first.stages)]
        _ = try await repo.run(["add","-f","--",path])
        let preserved=try await repo.run(["show",":"+path]).stdout
        let output=try await repo.resolveConflicts(checked,using:.mine,backend:engine([.getConflictInfo]))
        XCTAssertTrue(output.contains("Skip: "+path));XCTAssertTrue(output.contains("Resolved: "+secondPath))
        let actual=try await repo.run(["show",":"+secondPath]).stdout,original=try await repo.run(["show",":"+path]).stdout
        let mine=try XCTUnwrap(first.stages.first{$0.number==2}),expected=try await repo.run(["cat-file","blob",mine.object]).stdout
        XCTAssertEqual(actual,expected);XCTAssertEqual(original,preserved)
    }
    func testChangedNonmissingConflictRejectsWholeBatchBeforeMutation() async throws {
        let(root,repo,path)=try await ConflictResolutionTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let entries=try await repo.conflicts(),entry=try XCTUnwrap(entries.first)
        let blob=try await repo.run(["hash-object","-w","--stdin"],input:Data("changed stage\n".utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-index","-z","--index-info"],input:Data(("100644 "+blob+" 2\t"+path+"\0").utf8))
        let before=try Data(contentsOf:root.appendingPathComponent(".git/index")),file=try Data(contentsOf:root.appendingPathComponent(path))
        do {_ = try await repo.resolveConflicts([entry],using:.theirs,backend:engine([.getConflictInfo]));XCTFail("changed stage accepted")}catch ResolveFailure.stale{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),before);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),file)
    }
    func testMissingSelectedStageResolvesDeletionAndMissingHelperDoesNotAffectCurrent() async throws {
        let(root,repo,path)=try await ConflictResolutionTests().fixture(deletedMine:true);defer{try? FileManager.default.removeItem(at:root)}
        let entries=try await repo.conflicts();_ = try await repo.resolveConflicts(entries,using:.mine,backend:engine([.getConflictInfo]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path));let remaining=try await repo.conflicts();XCTAssertTrue(remaining.isEmpty)
        let(root2,repo2,_)=try await ConflictResolutionTests().fixture();defer{try? FileManager.default.removeItem(at:root2)}
        let current=try await repo2.conflicts();_ = try await repo2.resolveConflicts(current,using:.current,backend:engine([.getConflictInfo],helper:root2.appendingPathComponent("missing-helper")))
        let done=try await repo2.conflicts();XCTAssertTrue(done.isEmpty)
    }
    func testSelectedGitlinkStageModesAndDirtySubmoduleExclusion() async throws {
        let(root,source,repo,optionalChild,path)=try await ConflictResolutionTests().submoduleFixture(initialized:true)
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:source)}
        let child=try XCTUnwrap(optionalChild),entries=try await repo.conflicts(),entry=try XCTUnwrap(entries.first{$0.path==path}),mine=try XCTUnwrap(entry.stages.first{$0.number==2})
        let inspected=try await repo.requestedConflictStages(paths:[path],backend:engine([.getConflictInfo]),cancellation:nil)
        XCTAssertEqual(inspected,[entry]);XCTAssertTrue(inspected[0].stages.allSatisfy{$0.mode=="160000"})
        _ = try await repo.resolveConflicts([entry],using:.mine,backend:engine([.getConflictInfo]))
        let indexed=try await repo.run(["ls-files","--stage","-z","--",path]).stdout
        XCTAssertEqual(indexed,Data(("160000 "+mine.object+" 0\t"+path+"\0").utf8))
        try Data("dirty child\n".utf8).write(to:child.root.appendingPathComponent("file.txt"))
        let clean=try await repo.replayWorktreeIsClean(backend:engine([.checkCleanWorktree]))
        XCTAssertTrue(clean)
    }
    func testExplicitComparisonCommonAncestorUsesSelectedSingleBaseOnly() async throws {
        let(root,baseRepo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let base=try await baseRepo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("changed comparison\n".utf8).write(to:root.appendingPathComponent(path));_ = try await baseRepo.run(["add","--",path]);_ = try await baseRepo.run(["commit","-m","tip"])
        let tip=try await baseRepo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let repo=clone(baseRepo,engine([.mergeBase]));var options=RevisionDiffOptions();options.commonAncestor=true
        let forward=try await repo.revisionComparison(from:.revision(base),to:.revision(tip),options:options)
        XCTAssertEqual(forward.from,.revision(base));XCTAssertEqual(forward.to,.revision(tip));XCTAssertEqual(forward.files.map(\.path),[path])
        let sibling=try await baseRepo.run(["commit-tree",tip+"^{tree}","-p",base],input:Data("sibling\n".utf8)).text.trimmingCharacters(in:.newlines)
        let divergent=try await repo.revisionComparison(from:.revision(tip),to:.revision(sibling),options:options)
        XCTAssertEqual(divergent.from,.revision(tip));XCTAssertEqual(divergent.to,.revision(sibling))
        let missing=clone(baseRepo,engine([.mergeBase],helper:root.appendingPathComponent("missing-helper")))
        do {_ = try await missing.revisionComparison(from:.revision(base),to:.revision(tip),options:options);XCTFail("explicit common-base silently used CLI")}catch GitLibGit2Failure.runtimeMissing{}
        let direct=try await missing.revisionComparison(from:.revision(base),to:.revision(tip))
        XCTAssertEqual(direct.files.map(\.path),[path])
        let working=try await missing.revisionComparison(from:.revision(tip),to:.workingTree,options:options)
        XCTAssertEqual(working.from,.revision(tip));XCTAssertEqual(working.to,.workingTree)
        let tree=try await baseRepo.run(["rev-parse",tip+"^{tree}"]).text.trimmingCharacters(in:.newlines)
        let trees=try await missing.revisionComparison(from:.revision(tree),to:.revision(tree),options:options)
        XCTAssertEqual(trees.from,.revision(tree));XCTAssertTrue(trees.files.isEmpty)
    }
    func testEditContinuationUsesStagedOKOnlyOutsideNextSquashAndStructuralReplay() async throws {
        for mode in ["staged","unstaged","next-squash","structural"] {
            let root:URL,original:GitRepository
            if mode=="next-squash" {
                let fixture=try await RebaseTests().fixture();root=fixture.0;original=fixture.1
                var plan=try await original.rebasePlan(RebaseTests().options());plan.entries[0].action = .edit;plan.entries[1].action = .squash
                let paused=try await original.startRebase(plan,editorExecutable:RebaseTests().editor);XCTAssertTrue(paused.state.isEditPause)
            } else {
                let fixture=try await RebasePendingActionTests().paused(structural:mode=="structural");root=fixture.0;original=fixture.1
            }
            defer{try? FileManager.default.removeItem(at:root)}
            let repo=clone(original,engine([.checkCleanWorktree]))
            let state=try await repo.rebaseState(),head=try await repo.rebaseCommit("HEAD")
            let text="approved "+mode+"\n"
            try Data(text.utf8).write(to:root.appendingPathComponent("first.txt"))
            if mode != "unstaged" {_ = try await repo.run(["add","--","first.txt"])}
            let before=try await repo.run(["ls-files","--stage","-z"]).stdout
            let selection=try await repo.beginRebaseEditSelection(expected:state,expectedHead:head.hash)
            XCTAssertEqual(selection != nil,mode != "staged",mode)
            let after=try await repo.run(["ls-files","--stage","-z"]).stdout,current=try await repo.rebaseCommit("HEAD")
            XCTAssertEqual(before,after);XCTAssertEqual(current.hash,head.hash);XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("first.txt")),text)
            if mode=="staged" {
                let completed=try await repo.continueRebase(editMessage:"accepted staged Edit")
                XCTAssertEqual(completed.exitCode,0,completed.output);XCTAssertFalse(completed.state.active)
                let bytes=try await repo.run(["show","HEAD:first.txt"]).stdout
                XCTAssertEqual(bytes,Data(text.utf8))
            } else {_ = try await repo.abortRebase()}
        }
    }
    func testSelectedMissingRuntimeAndCancellationNeverFallBack() async throws {
        let(root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let selected=engine([.mergeBase,.checkCleanWorktree,.checkConflicts],helper:root.appendingPathComponent("missing-helper"))
        do {_ = try await repo.replayMergeBase(from:"HEAD",to:"HEAD",backend:selected);XCTFail("missing7 fell back")}catch GitLibGit2Failure.runtimeMissing{}
        do {_ = try await repo.replayWorktreeIsClean(backend:selected);XCTFail("missing12 fell back")}catch GitLibGit2Failure.runtimeMissing{}
        do {_ = try await repo.hasWorkingTreeConflicts(backend:selected);XCTFail("missing13 fell back")}catch GitLibGit2Failure.runtimeMissing{}
        let token=OperationCancellation();token.cancel();do {_ = try await repo.replayWorktreeIsClean(cancellation:token,backend:selected);XCTFail("cancel ignored")}catch{}
    }
}
