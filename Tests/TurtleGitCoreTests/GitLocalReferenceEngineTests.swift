import XCTest
@testable import TurtleGitCore

final class GitLocalReferenceEngineTests: XCTestCase {
    private let sampleOID=String(repeating:"a",count:40)
    private func frame(_ value:[String:Any]) throws -> Data {
        Data("TurtleGit LocalRefs v1:".utf8) + (try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])).base64EncodedData() + Data([10])
    }
    private func response(_ operation:String,_ rows:[[String:Any]],count:Int?=nil) throws -> Data {
        try frame(["kind":"header","operation":operation]) + rows.reduce(into:Data()) {$0.append(try! frame($1))} + frame(["kind":"end","count":count ?? rows.count])
    }
    private func row(_ name:String,oid:String?=nil) -> [String:Any] {
        ["kind":"reference","name":name,"oid":oid ?? sampleOID,"objectType":"commit","symbolicTarget":NSNull(),"upstream":NSNull(),"subject":"literal\t雪","authorName":"A","authorEmail":"a@example.invalid","authorTime":123,"committerName":"C","committerEmail":"c@example.invalid","committerTime":NSNull()]
    }
    private func engine(_ operations:[GitLibGit2Operation],enabled:Bool=true,helper:URL?=nil) -> GitLibGit2Configuration {
        .init(enabled:enabled,mask:operations.reduce(0){$0 | $1.mask},helperURL:helper)
    }
    private func fixture() async throws -> (URL,GitRepository,String) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitLocalRefs-"+UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        do {
            let repo=GitRepository(root:root)
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Private Refs"),("user.email","refs@example.invalid"),("core.precomposeunicode","false")] {_ = try await repo.run(["config",key,value])}
            try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));_ = try await repo.run(["add","--","file"])
            _ = try await repo.run(["commit","-m","base"])
            let hash=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            return(root,repo,hash)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    func testTypedInventoryPreservesCanonicalPeersTagObjectsAndNullMetadata() throws {
        var tag=row("refs/tags/annotated");tag["objectType"]="tag";tag["symbolicTarget"]="refs/tags/target"
        let bytes=try response("inventory",[row("refs/heads/é"),row("refs/heads/e\u{301}"),tag])
        let value=try GitLocalReferenceProtocol.decode(bytes,operation:"inventory")
        XCTAssertEqual(value.references.count,3)
        XCTAssertNotEqual(Data(value.references[0].name.utf8),Data(value.references[1].name.utf8))
        XCTAssertEqual(value.references[2].oid,sampleOID);XCTAssertEqual(value.references[2].objectType,"tag")
        XCTAssertEqual(value.references[0].authorTime,123);XCTAssertNil(value.references[0].committerTime)
        XCTAssertEqual(value.references[0].subject,"literal\t雪")
    }
    func testTypedTransactionsRefuseMalformedNamesMissingFieldsCountsAndOrdering() throws {
        for name in ["HEAD","refs/heads/..x","refs/heads/x.lock","refs//x","refs/.x","refs/heads/x/","refs/heads/x.","refs/heads/x@{y","refs/heads/a?","refs/heads/a\\b","refs/heads/a\nb"] {
            XCTAssertThrowsError(try GitLocalReferenceProtocol.decode(response("inventory",[row(name)]),operation:"inventory"),name)
        }
        var incomplete=row("refs/heads/a");incomplete.removeValue(forKey:"authorTime")
        var invalid=row("refs/heads/a");invalid["authorTime"]=true
        var oid=row("refs/heads/a");oid["oid"]="short"
        for rows in [[incomplete],[invalid],[oid],[row("refs/heads/a"),row("refs/heads/a")]] {
            XCTAssertThrowsError(try GitLocalReferenceProtocol.decode(response("inventory",rows),operation:"inventory"))
        }
        XCTAssertThrowsError(try GitLocalReferenceProtocol.decode(response("inventory",[row("refs/heads/a")],count:0),operation:"inventory"))
        let valid=try response("inventory",[])
        XCTAssertThrowsError(try GitLocalReferenceProtocol.decode(valid+frame(["kind":"end","count":0]),operation:"inventory"))
        XCTAssertThrowsError(try GitLocalReferenceProtocol.decode(frame(row("refs/heads/a")),operation:"inventory"))
        XCTAssertThrowsError(try GitLocalReferenceProtocol.decode(valid.dropLast(),operation:"inventory"))
        let names=try GitLocalReferenceProtocol.decode(response("names",[["kind":"contains","name":"refs/heads/name"]]),operation:"names")
        XCTAssertEqual(names.names,["refs/heads/name"])
        let deletion=try GitLocalReferenceProtocol.decode(response("delete",[["kind":"deleted","name":"refs/tags/name","oid":sampleOID,"symbolicTarget":NSNull()]]),operation:"delete")
        XCTAssertEqual(deletion.deleted?.oid,sampleOID)
        XCTAssertThrowsError(try GitLocalReferenceProtocol.decode(response("delete",[]),operation:"delete"))
        let token=OperationCancellation();token.cancel();XCTAssertThrowsError(try GitLocalReferenceProtocol.decode(valid,operation:"inventory",cancellation:token))
    }
    func testSelectedCatalogReadsTagsSymbolicsDescriptionsUpstreamAndMailmap() async throws {
        let(root,repo,head)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["branch","topic"])
        _ = try await repo.run(["tag","-a","annotated","-m","tag subject\n\nbody"])
        _ = try await repo.run(["remote","add","origin","https://example.invalid/private"])
        _ = try await repo.run(["update-ref","refs/remotes/origin/topic",head])
        _ = try await repo.run(["symbolic-ref","refs/remotes/origin/HEAD","refs/remotes/origin/topic"])
        _ = try await repo.run(["config","branch.topic.remote","origin"]);_ = try await repo.run(["config","branch.topic.merge","refs/heads/topic"])
        _ = try await repo.run(["config","branch.topic.description","topic description"])
        try Data("Mapped Person <mapped@example.invalid> Private Refs <refs@example.invalid>\n".utf8).write(to:root.appendingPathComponent(".mailmap"))
        let result=try await repo.referenceBrowser(backend:engine([.forEachRef]))
        let topic=try XCTUnwrap(result.references.first{$0.name.rawValue=="refs/heads/topic"})
        XCTAssertEqual(topic.description,"topic description");XCTAssertEqual(topic.upstream,"origin/topic");XCTAssertEqual(topic.author,"Mapped Person")
        let tag=try XCTUnwrap(result.references.first{$0.name.rawValue=="refs/tags/annotated"})
        let tagOID=try await repo.run(["rev-parse","refs/tags/annotated"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(tag.hash,tagOID);XCTAssertNotEqual(tag.hash,head);XCTAssertEqual(tag.subject,"tag subject");XCTAssertEqual(tag.objectType,"tag")
        XCTAssertEqual(result.references.first{$0.name.rawValue=="refs/remotes/origin/HEAD"}?.symbolicTarget,"refs/remotes/origin/topic")
    }
    func testMergedFiltersRetainCLIWhileUnfilteredSelectionRequiresHelper() async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let selected=engine([.forEachRef],helper:root.appendingPathComponent("missing-helper"))
        let merged=try await repo.referenceBrowser(filter:.merged,backend:selected)
        XCTAssertTrue(merged.references.contains{$0.name.rawValue=="refs/heads/main"})
        let unmerged=try await repo.referenceBrowser(filter:.unmerged,backend:selected);XCTAssertTrue(unmerged.references.isEmpty)
        do {_ = try await repo.referenceBrowser(backend:selected);XCTFail("selected missing helper silently fell back")}catch GitLibGit2Failure.runtimeMissing{}
    }
    func testContainsFindsEqualDescendantAnnotatedTagsAndSymbolicsOnlyInSourceNamespaces() async throws {
        let(root,repo,base)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["branch","equal",base]);_ = try await repo.run(["tag","-a","nested1","-m","first",base]);_ = try await repo.run(["tag","-a","nested2","-m","nested","nested1"])
        _ = try await repo.run(["commit","--allow-empty","-m","descendant"])
        let tip=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-ref","refs/remotes/origin/topic",tip]);_ = try await repo.run(["symbolic-ref","refs/remotes/origin/HEAD","refs/remotes/origin/topic"])
        _ = try await repo.run(["update-ref","refs/custom/hidden",tip])
        let blob=try await repo.run(["hash-object","-w","--stdin"],input:Data("blob".utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-ref","refs/tags/blob",blob])
        let value=try await repo.commitContainingReferences(base,includeCompletion:false,backend:engine([.branchContains]))
        let names=Set(value.references.map(\.rawValue))
        for name in ["refs/heads/main","refs/heads/equal","refs/tags/nested1","refs/tags/nested2","refs/remotes/origin/topic","refs/remotes/origin/HEAD"] {XCTAssertTrue(names.contains(name),name)}
        XCTAssertFalse(names.contains("refs/custom/hidden"));XCTAssertFalse(names.contains("refs/tags/blob"))
    }
    func testCompletionUsesMasterSwitchWithZeroMaskAndDoesNotResolveBrokenAliases() async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["tag","-a","tag","-m","tag"])
        let cli=try await repo.commitContainingReferenceCompletion(backend:engine([],enabled:false))
        XCTAssertEqual(cli.filter{$0.rawValue=="refs/tags/tag"}.count,1)
        _ = try await repo.run(["symbolic-ref","refs/remotes/broken/HEAD","refs/remotes/broken/absent"])
        let names=try await repo.commitContainingReferenceCompletion(backend:engine([]))
        XCTAssertTrue(names.contains{$0.rawValue=="refs/remotes/broken/HEAD"})
        do {_ = try await repo.referenceBrowser(backend:engine([.forEachRef]));XCTFail("inventory silently accepted broken resolved alias")}catch{}
        let heads=try await repo.referenceBrowser(scope:.heads,backend:engine([.forEachRef]));XCTAssertEqual(heads.references.map(\.name.rawValue),["refs/heads/main"])
    }
    func testSelectedDeletionCleansBranchConfigAndDeletesTagObjectWithoutMovingTarget() async throws {
        let(root,repo,head)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["branch","topic"]);_ = try await repo.run(["config","branch.topic.description","kept until deletion"])
        _ = try await repo.run(["tag","-a","tag","-m","tag"])
        for name in ["refs/heads/topic","refs/tags/tag"] {
            let plan=try await repo.prepareHistoryReferenceDeletion(name)
            _ = try await repo.deleteHistoryReference(plan,choice:.delete,backend:engine([.deleteTagBranch]))
        }
        let branchConfig=try await repo.run(["config","--get-regexp","^branch\\.topic\\."],successfulExitCodes:0...1)
        XCTAssertEqual(branchConfig.exitCode,1)
        let actual=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(actual,head)
        let names=try await repo.run(["for-each-ref","--format=%(refname)"]).text;XCTAssertFalse(names.contains("topic"));XCTAssertFalse(names.contains("refs/tags/tag"))
    }
    func testSymbolicDeletionCapturesExactAliasTargetAndNeverDeletesResolvedReference() async throws {
        let(root,repo,head)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        for name in ["a","b"] {_ = try await repo.run(["update-ref","refs/remotes/origin/"+name,head])}
        _ = try await repo.run(["symbolic-ref","refs/remotes/origin/HEAD","refs/remotes/origin/a"])
        let stale=try await repo.prepareHistoryReferenceDeletion("refs/remotes/origin/HEAD")
        XCTAssertEqual(stale.symbolicTarget,"refs/remotes/origin/a")
        _ = try await repo.run(["symbolic-ref","refs/remotes/origin/HEAD","refs/remotes/origin/b"])
        do {_ = try await repo.deleteHistoryReference(stale,choice:.remoteLocal,backend:engine([.deleteTagBranch]));XCTFail("sameOID alias changed target accepted")}catch HistoryReferenceDeletionFailure.changed{}
        let fresh=try await repo.prepareHistoryReferenceDeletion("refs/remotes/origin/HEAD")
        _ = try await repo.deleteHistoryReference(fresh,choice:.remoteLocal,backend:engine([.deleteTagBranch]))
        let target=try await repo.run(["rev-parse","refs/remotes/origin/b"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(target,head)
        let alias=try await repo.run(["symbolic-ref","--quiet","refs/remotes/origin/HEAD"],successfulExitCodes:0...1);XCTAssertEqual(alias.exitCode,1)
    }
    func testDeletionBatchKeepsEarlierCompletionAndRejectsCheckedOutLinkedBranch() async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["branch","first"]);_ = try await repo.run(["branch","linked"])
        let linked=root.deletingLastPathComponent().appendingPathComponent("TurtleGitRefLinked-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:linked)}
        _ = try await repo.run(["worktree","add",linked.path,"linked"])
        do {try await repo.deleteBrowserReferences(["refs/heads/first","refs/heads/linked"],backend:engine([.deleteTagBranch]));XCTFail("checkedout linked branch deleted")}catch{}
        let first=try await repo.run(["rev-parse","--verify","--quiet","refs/heads/first"],successfulExitCodes:0...1);XCTAssertEqual(first.exitCode,1)
        let kept=try await repo.run(["rev-parse","--verify","--quiet","refs/heads/linked"],successfulExitCodes:0...1);XCTAssertEqual(kept.exitCode,0)
    }
    func testSelectedHelperFailuresNeverPublishPartialCatalogOrFallBack() async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("private-ref-helper")
        let partial=try frame(["kind":"header","operation":"inventory"])+frame(row("refs/heads/untrusted"))
        let literal=String(decoding:partial,as:UTF8.self)
        for exitCode in [0,17] {
            let script="#!/bin/sh\nprintf '%s' '"+literal+"'\nprintf '%s' 'private diagnostic' >&2\nexit \(exitCode)\n"
            try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
            do { _ = try await repo.referenceBrowser(backend:engine([.forEachRef],helper:helper));XCTFail("published incomplete helper output or silently fell back") }
            catch let failure as GitFailure {
                XCTAssertEqual(exitCode,17);XCTAssertEqual(failure.code,17);XCTAssertTrue(failure.message.contains("private diagnostic"))
            } catch GitLocalReferenceEngineFailure.output {XCTAssertEqual(exitCode,0)}
        }
        let live=try await repo.referenceBrowser(backend:engine([],enabled:false))
        XCTAssertTrue(live.references.contains{$0.name.rawValue=="refs/heads/main"})
    }
    func testBrowserConfirmationRejectsSameOIDAliasRetargetBeforeDeletingAnything() async throws {
        let(root,repo,head)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        for name in ["a","b"] {_ = try await repo.run(["tag",name,head])}
        _ = try await repo.run(["symbolic-ref","refs/tags/alias","refs/tags/a"])
        let confirmation=try await repo.browserDeletionConfirmation("refs/tags/alias")
        _ = try await repo.run(["symbolic-ref","refs/tags/alias","refs/tags/b"])
        do {
            try await repo.deleteBrowserReferences(["refs/tags/alias"],expectedHashes:["refs/tags/alias":head],backend:engine([.deleteTagBranch]),expectedSymbolicTargets:confirmation.symbolicTargets)
            XCTFail("accepted alias changed during warning")
        } catch ReferenceBrowserRenameFailure.changed { }
        let alias=try await repo.run(["symbolic-ref","refs/tags/alias"]).text
        XCTAssertEqual(alias,"refs/tags/b\n")
        for name in ["a","b"] {let actual=try await repo.run(["rev-parse","refs/tags/"+name]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(actual,head)}
    }
    func testStaleOIDAndCancellationRefuseDeletionAndIdentityTracksMissingRuntime() async throws {
        let(root,repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await repo.run(["branch","topic"]);let plan=try await repo.prepareHistoryReferenceDeletion("refs/heads/topic")
        _ = try await repo.run(["commit","--allow-empty","-m","new"])
        _ = try await repo.run(["update-ref","refs/heads/topic","HEAD"])
        do {_ = try await repo.deleteHistoryReference(plan,choice:.delete,backend:engine([.deleteTagBranch]));XCTFail("staleOID accepted")}catch HistoryReferenceDeletionFailure.changed{}
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.referenceBrowser(cancellation:token,backend:engine([.forEachRef]));XCTFail("cancel ignored")}catch{}
        let unavailable=engine([],helper:root.appendingPathComponent("missing"))
        let identity=try await repo.localReferenceBackendIdentity(backend:unavailable);XCTAssertTrue(identity.contains("missing"))
        let disabled=try await repo.localReferenceBackendIdentity(backend:engine([],enabled:false));XCTAssertNotEqual(identity,disabled)
    }
}
