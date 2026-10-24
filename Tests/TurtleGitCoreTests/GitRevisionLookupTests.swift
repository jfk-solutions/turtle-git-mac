// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class GitRevisionLookupTests:XCTestCase {
    private struct Fixture {
        let root:URL,cli:GitRepository,first:String,tip:String,tree:String,blob:String,tag:String,nested:String
    }
    private func backend(_ enabled:Bool,helper:URL?=nil)->GitLibGit2Configuration{.init(enabled:enabled,mask:0,helperURL:helper)}
    private func makeRepository(_ root:URL,_ selected:Bool,helper:URL?=nil,executable:URL=URL(fileURLWithPath:"/usr/bin/git"))->GitRepository{
        GitRepository(root:root,executable:executable,libgit2Configuration:backend(selected,helper:helper))
    }
    private func initial()async throws->(URL,GitRepository){
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitRevisionLookup-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=makeRepository(root,false)
        _ = try await repo.run(["init","-b","main"])
        for(k,v)in[("user.name","Revision lookup QA"),("user.email","lookup@example.invalid"),("commit.gpgsign","false"),("tag.gpgSign","false"),("core.precomposeunicode","true"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",k,v])}
        return(root,repo)
    }
    private func oid(_ repo:GitRepository,_ revision:String)async throws->String{try await repo.run(["-c","core.precomposeunicode=false","rev-parse","--verify","--end-of-options",revision]).text.trimmingCharacters(in:.newlines)}
    private func fixture()async throws->Fixture{
        let(root,cli)=try await initial()
        try Data("first\n".utf8).write(to:root.appendingPathComponent("payload"));try await cli.stage(["payload"]);_ = try await cli.commit(message:"first")
        let first=try await oid(cli,"HEAD")
        try Data("second\n".utf8).write(to:root.appendingPathComponent("payload"));try await cli.stage(["payload"]);_ = try await cli.commit(message:"second")
        let tip=try await oid(cli,"HEAD"),tree=try await oid(cli,"HEAD^{tree}"),blob=try await oid(cli,"HEAD:payload")
        _ = try await cli.run(["tag","--annotate","release","--message","release",tip])
        _ = try await cli.run(["-c","advice.nestedTag=false","tag","--annotate","nested","--message","nested","refs/tags/release"])
        return Fixture(root:root,cli:cli,first:first,tip:tip,tree:tree,blob:blob,tag:try await oid(cli,"refs/tags/release"),nested:try await oid(cli,"refs/tags/nested"))
    }
    private func script(_ root:URL,_ name:String,_ contents:String)throws->URL{
        let url=root.appendingPathComponent(name);try Data(("#!/bin/sh\n"+contents).utf8).write(to:url)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path);return url
    }
    private func quote(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func packedReferences(_ fixture:Fixture,_ entries:[(String,String)])async throws{
        _ = try await fixture.cli.run(["pack-refs","--all"])
        let file=fixture.root.appendingPathComponent(".git/packed-refs")
        var bytes=try Data(contentsOf:file)
        // The test creates literal packed names directly: a normalization-
        // insensitive filesystem cannot store both spellings as loose files.
        for(name,hash)in entries{bytes.append(Data((hash+" "+name+"\n").utf8))}
        // Do not advertise sorted order after appending to a packed-ref file.
        bytes=Data(String(decoding:bytes,as:UTF8.self).replacingOccurrences(of:" fully-peeled sorted",with:"").replacingOccurrences(of:" sorted",with:"").utf8)
        try bytes.write(to:file)
    }
    func testSourceFortyHexFastPathNeedsNeitherRepositoryNorHelperAndDoesNotProveExistence()async throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitAbsentLookup-"+UUID().uuidString)
        let repo=makeRepository(root,true,helper:root.appendingPathComponent("absent")),upper=String(repeating:"AB",count:20)
        let value=try await repo.revisionLookup(upper),zero=try await repo.revisionLookup(String(repeating:"0",count:40))
        XCTAssertEqual(value.objectID,upper.lowercased());XCTAssertFalse(value.unbornHead)
        XCTAssertEqual(zero.objectID,String(repeating:"0",count:40));XCTAssertFalse(zero.unbornHead)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testTypedRequirementsCheckRealObjectsRatherThanTrustingFullHashText()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        for selected in [false,true]{let repo=makeRepository(f.root,selected)
            for requirement in [GitRevisionRequirement.existingObject,.commit,.tree]{
                let value=try await repo.revisionLookup(String(repeating:"a",count:40),requirement:requirement)
                XCTAssertNil(value.objectID);XCTAssertFalse(value.unbornHead)
            }
            let existing=try await repo.revisionLookup(f.tip,requirement:.existingObject)
            XCTAssertEqual(existing.objectID,f.tip)
        }
    }
    func testUnbornHEADIsDistinctFromMissingRevisionAndNotAnExistingCommit()async throws{
        let(root,_)=try await initial();defer{try? FileManager.default.removeItem(at:root)}
        for selected in [false,true]{let repo=makeRepository(root,selected)
            let head=try await repo.revisionLookup("HEAD"),missing=try await repo.revisionLookup("refs/heads/missing"),commit=try await repo.revisionLookup("HEAD",requirement:.commit),exists=try await repo.revisionLookup("HEAD",requirement:.existingObject)
            XCTAssertNil(head.objectID);XCTAssertTrue(head.unbornHead)
            for value in [missing,commit,exists]{XCTAssertNil(value.objectID);XCTAssertFalse(value.unbornHead)}
        }
    }
    func testRawObjectsRetainAnnotatedTagsWhileTypedRequestsPeelActualTargets()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        for selected in [false,true]{let repo=makeRepository(f.root,selected)
            for(revision,raw)in [("HEAD",f.tip),("HEAD^{tree}",f.tree),("HEAD:payload",f.blob),("refs/tags/release",f.tag),("refs/tags/nested",f.nested)]{
                let value=try await repo.revisionLookup(revision),existing=try await repo.revisionLookup(revision,requirement:.existingObject)
                XCTAssertEqual(value.objectID,raw);XCTAssertEqual(existing.objectID,raw)
            }
            let commit=try await repo.revisionLookup("refs/tags/nested",requirement:.commit),tree=try await repo.revisionLookup("refs/tags/nested",requirement:.tree)
            XCTAssertEqual(commit.objectID,f.tip);XCTAssertEqual(tree.objectID,f.tree)
            for revision in [f.tree,f.blob]{let value=try await repo.revisionLookup(revision,requirement:.commit);XCTAssertNil(value.objectID)}
            let blobAsTree=try await repo.revisionLookup(f.blob,requirement:.tree);XCTAssertNil(blobAsTree.objectID)
        }
    }
    func testRevisionExpressionsAndDetachedHEADResolveWithoutChangingState()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.cli.run(["checkout","--detach",f.tip])
        let index=try Data(contentsOf:f.root.appendingPathComponent(".git/index")),head=try Data(contentsOf:f.root.appendingPathComponent(".git/HEAD")),config=try Data(contentsOf:f.root.appendingPathComponent(".git/config"))
        for selected in [false,true]{let repo=makeRepository(f.root,selected)
            let parent=try await repo.revisionLookup("HEAD~1",requirement:.commit),payload=try await repo.revisionLookup("HEAD:payload",requirement:.existingObject)
            XCTAssertEqual(parent.objectID,f.first);XCTAssertEqual(payload.objectID,f.blob)
        }
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/HEAD")),head)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/config")),config)
    }
    func testLiteralPackedNFCAndNFDReferencesResolveDistinctObjectsWithStoredPrecomposeEnabled()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let nfc="refs/heads/caf\u{e9}",nfd="refs/heads/cafe\u{301}"
        try await packedReferences(f,[(nfc,f.first),(nfd,f.tip)])
        let packed=try Data(contentsOf:f.root.appendingPathComponent(".git/packed-refs")),config=try Data(contentsOf:f.root.appendingPathComponent(".git/config"))
        for selected in [false,true]{let repo=makeRepository(f.root,selected)
            let a=try await repo.revisionLookup(nfc,requirement:.commit),b=try await repo.revisionLookup(nfd,requirement:.commit)
            XCTAssertEqual(a.objectID,f.first);XCTAssertEqual(b.objectID,f.tip);XCTAssertNotEqual(a.objectID,b.objectID)
            let aExists=try await repo.referenceExists(nfc),bExists=try await repo.referenceExists(nfd)
            XCTAssertTrue(aExists);XCTAssertTrue(bExists)
        }
        let stored=try await f.cli.run(["config","--local","--get","core.precomposeunicode"]).text
        XCTAssertEqual(stored,"true\n");XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/config")),config)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/packed-refs")),packed)
    }
    func testExactReferenceExistenceIncludesDanglingSymbolsButNotRevisionExpressions()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.cli.run(["symbolic-ref","refs/heads/alias","refs/heads/missing"])
        for selected in [false,true]{let repo=makeRepository(f.root,selected)
            for name in ["refs/heads/main","refs/tags/release","refs/heads/alias"]{let exists=try await repo.referenceExists(name);XCTAssertTrue(exists,name)}
            for name in ["refs/heads/missing","refs/heads/main~1","refs/tags/release^{commit}"]{let exists=try await repo.referenceExists(name);XCTAssertFalse(exists,name)}
        }
    }
    func testBranchTagCollisionUsesExactNamesRatherThanCanonicalStringEquality()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let nfc="caf\u{e9}",nfd="cafe\u{301}"
        try await packedReferences(f,[("refs/heads/"+nfc,f.first),("refs/tags/"+nfd,f.tip)])
        _ = try await f.cli.run(["tag","collision",f.first]);_ = try await f.cli.run(["branch","collision",f.tip])
        for selected in [false,true]{let repo=makeRepository(f.root,selected)
            for name in [nfc,nfd,"new-name","HEAD~1"]{let unique=try await repo.branchTagNameIsUnique(name);XCTAssertTrue(unique,name)}
            let collision=try await repo.branchTagNameIsUnique("collision");XCTAssertFalse(collision)
        }
    }
    func testMissingSelectedHelperNeverFallsBackForActualReadsButMasterOffDoes()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let absent=f.root.appendingPathComponent("absent-helper"),repo=makeRepository(f.root,true,helper:absent)
        do{_ = try await repo.revisionLookup("HEAD");XCTFail("selected resolver fell back")}catch GitLibGit2Failure.runtimeMissing{}
        do{_ = try await repo.revisionLookup(f.tip,requirement:.existingObject);XCTFail("typed lookup trusted text")}catch GitLibGit2Failure.runtimeMissing{}
        do{_ = try await repo.referenceExists("refs/heads/main");XCTFail("selected existence fell back")}catch GitLibGit2Failure.runtimeMissing{}
        let cli=makeRepository(f.root,false,helper:absent),value=try await cli.revisionLookup("HEAD",requirement:.commit)
        XCTAssertEqual(value.objectID,f.tip)
        do{_ = try await repo.revisionLookup(String(repeating:"a",count:64));XCTFail("64-hex incorrectly became source40 fastpath")}catch GitLibGit2Failure.runtimeMissing{}
    }
    func testPrecancelledLookupExistenceAndUniquenessNeverLaunchOrMutate()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let trace=f.root.appendingPathComponent("launched"),helper=try script(f.root,"cancel-helper","touch "+quote(trace.path)+"\nexit 99\n"),repo=makeRepository(f.root,true,helper:helper),token=OperationCancellation();token.cancel()
        let refs=try await f.cli.run(["show-ref"]).stdout,config=try Data(contentsOf:f.root.appendingPathComponent(".git/config"))
        for revision in ["HEAD",String(repeating:"a",count:40)]{do{_ = try await repo.revisionLookup(revision,cancellation:token);XCTFail("cancelled lookup ran")}catch OperationCancellationFailure.cancelled{}}
        do{_ = try await repo.referenceExists("refs/heads/main",cancellation:token);XCTFail("cancelled existence ran")}catch OperationCancellationFailure.cancelled{}
        do{_ = try await repo.branchTagNameIsUnique("main",cancellation:token);XCTFail("cancelled collision read ran")}catch OperationCancellationFailure.cancelled{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:trace.path));XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/config")),config)
        let after=try await f.cli.run(["show-ref"]).stdout;XCTAssertEqual(after,refs)
    }
    func testInvalidSyntaxReturnsNotFoundWhileNULAndOversizedInputAreStructuralErrors()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        for selected in [false,true]{let repo=makeRepository(f.root,selected)
            for value in ["","--help","HEAD^{","refs/heads/does-not-exist"]{
                let result=try await repo.revisionLookup(value);XCTAssertNil(result.objectID,value);XCTAssertFalse(result.unbornHead,value)
            }
            for value in ["HEAD\0ignored",String(repeating:"x",count:1_048_577)]{
                do{_ = try await repo.revisionLookup(value);XCTFail("invalid input accepted")}catch GitRevisionLookupFailure.input{}
                do{_ = try await repo.referenceExists(value);XCTFail("invalid reference accepted")}catch GitRevisionLookupFailure.input{}
            }
        }
    }
    func testMalformedSelectedRepliesCannotBecomeNotFoundOrCLIFallback()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let fallback=f.root.appendingPathComponent("cli-fallback"),guardGit=try script(f.root,"guard-git","touch "+quote(fallback.path)+"\nexit 94\n")
        let prefix="TurtleGit RevisionLookup v1:"
        let payloads:[Data]=[
            Data("{".utf8),
            try JSONSerialization.data(withJSONObject:["operation":"revision","oid":NSNull(),"unbornHead":0]),
            try JSONSerialization.data(withJSONObject:["operation":"revision","oid":f.tip,"unbornHead":true]),
            try JSONSerialization.data(withJSONObject:["operation":"revision","oid":"not-an-object","unbornHead":false]),
            try JSONSerialization.data(withJSONObject:["operation":"revision","oid":NSNull(),"unbornHead":false,"extra":"untrusted"]),
            try JSONSerialization.data(withJSONObject:["operation":"reference","exists":true])
        ]
        for(index,payload)in payloads.enumerated(){
            let helper=try script(f.root,"bad-reply-\(index)","printf '%s\\n' "+quote(prefix+payload.base64EncodedString())+"\n"),repo=makeRepository(f.root,true,helper:helper,executable:guardGit)
            do{_ = try await repo.revisionLookup("HEAD",requirement:.commit);XCTFail("bad selected metadata became a result")}catch GitRevisionLookupFailure.output{}
        }
        let valid=prefix+(try JSONSerialization.data(withJSONObject:["operation":"revision","oid":f.tip,"unbornHead":false])).base64EncodedString()
        for(index,output)in [(0,valid),(1,valid+"\n"+valid+"\n"),(2,"wrong-prefix:"+valid+"\n")]{
            let helper=try script(f.root,"bad-framing-\(index)","printf '%s' "+quote(output)+"\n"),repo=makeRepository(f.root,true,helper:helper,executable:guardGit)
            do{_ = try await repo.revisionLookup("HEAD");XCTFail("invalid framing accepted")}catch GitRevisionLookupFailure.output{}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:fallback.path))
    }
    func testSelectedProcessFailurePreservesDiagnosticsAndNeverFallsBack()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let trace=f.root.appendingPathComponent("selected-called"),fallback=f.root.appendingPathComponent("fallback-called")
        let helper=try script(f.root,"failing-helper","printf '%s\\n' \"$@\" > "+quote(trace.path)+"\nprintf '%s\\n' 'selected lookup failed deliberately' >&2\nexit 73\n")
        let guardGit=try script(f.root,"unexpected-cli","touch "+quote(fallback.path)+"\nexit 94\n"),repo=makeRepository(f.root,true,helper:helper,executable:guardGit)
        do{_ = try await repo.revisionLookup("HEAD",requirement:.existingObject);XCTFail("engine failure became notfound")}
        catch let failure as GitFailure{XCTAssertEqual(failure.code,73);XCTAssertTrue(failure.message.contains("selected lookup failed deliberately"))}
        XCTAssertTrue(try String(contentsOf:trace,encoding:.utf8).contains("turtlegit-revision-lookup"));XCTAssertFalse(FileManager.default.fileExists(atPath:fallback.path))
    }
    func testCreateTagsCanTargetTreesBlobsAndRawAnnotatedTagsWhileBranchesNeedCommits()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let head=try Data(contentsOf:f.root.appendingPathComponent(".git/HEAD")),index=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        for selected in [false,true]{let repo=makeRepository(f.root,selected),suffix=selected ? "helper":"cli"
            for(label,revision,expected)in [("tree","HEAD^{tree}",f.tree),("blob","HEAD:payload",f.blob),("tag","refs/tags/nested",f.nested)]{
                var options=ReferenceCreationOptions();options.isTag=true;options.name="object-\(label)-\(suffix)";options.revision=revision
                let plan=try await repo.prepareReferenceCreation(options);XCTAssertEqual(plan.resolvedHash,expected)
                _ = try await repo.createReference(plan)
                let actual=try await oid(f.cli,"refs/tags/"+options.name);XCTAssertEqual(actual,expected)
            }
            var options=ReferenceCreationOptions();options.name="invalid-branch-"+suffix;options.revision="HEAD:payload"
            do{_ = try await repo.prepareReferenceCreation(options);XCTFail("branch accepted a blob")}catch ReferenceCreationFailure.invalidRevision{}
            let exists=try await f.cli.run(["show-ref","--verify","--quiet","refs/heads/"+options.name],successfulExitCodes:0...1);XCTAssertEqual(exists.exitCode,1)
        }
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/HEAD")),head)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
    }
    func testActualSwitchUsesExactPackedReferenceAndPreservesStoredNormalizationPolicy()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let nfc="refs/heads/caf\u{e9}",nfd="refs/heads/cafe\u{301}";try await packedReferences(f,[(nfc,f.first),(nfd,f.tip)])
        let config=try Data(contentsOf:f.root.appendingPathComponent(".git/config"))
        for selected in [false,true]{let repo=makeRepository(f.root,selected)
            for(reference,expected,bytes)in [(nfc,f.first,"first\n"),(nfd,f.tip,"second\n")]{
                var options=CheckoutOptions();options.target = .branch;options.revision=reference
                try await repo.validateCheckout(options);_ = try await repo.checkout(options)
                let actual=try await oid(f.cli,"HEAD"),symbolic=try await f.cli.run(["symbolic-ref","HEAD"]).text.trimmingCharacters(in:.newlines)
                XCTAssertEqual(actual,expected);XCTAssertTrue(symbolic.utf8.elementsEqual(reference.utf8))
                XCTAssertEqual(try String(contentsOf:f.root.appendingPathComponent("payload"),encoding:.utf8),bytes)
            }
            var invalid=CheckoutOptions();invalid.target = .commit;invalid.revision=f.tree
            do{try await repo.validateCheckout(invalid);XCTFail("Switch accepted a tree")}catch CheckoutFailure.invalidRevision{}
        }
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/config")),config)
    }
    func testAmbiguousPushSourceIsRejectedWithoutTransportButQualifiedReferenceRemainsValid()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.cli.run(["branch","collision",f.first]);_ = try await f.cli.run(["tag","collision",f.tip])
        let refs=try await f.cli.run(["show-ref"]).stdout,config=try Data(contentsOf:f.root.appendingPathComponent(".git/config")),index=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        for selected in [false,true]{let repo=makeRepository(f.root,selected)
            var options=PushOptions();options.arbitraryURL=true;options.remote="https://example.invalid/never-contacted";options.source="collision";options.destination="refs/heads/result"
            do{try await repo.validatePushOptions(options);XCTFail("ambiguous branch/tag source accepted")}catch PushValidationFailure.source{}
            options.source="refs/heads/collision";try await repo.validatePushOptions(options)
            options.source="refs/tags/collision";try await repo.validatePushOptions(options)
        }
        let after=try await f.cli.run(["show-ref"]).stdout;XCTAssertEqual(after,refs)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/config")),config)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
    }
    func testAcceptedCreationFormRetainsBackendWhenPreparedByDifferentConfiguredActor()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var options=ReferenceCreationOptions();options.name="captured-backend";options.revision="HEAD"
        let form=try await f.cli.prepareReferenceCreationForm(options)
        let newlySelected=makeRepository(f.root,true,helper:f.root.appendingPathComponent("missing-new-helper"))
        let plan=try await newlySelected.prepareReferenceCreation(form)
        XCTAssertEqual(plan.resolvedHash,f.tip);XCTAssertFalse(plan.acceptedBackend.enabled)
        _ = try await newlySelected.createReference(plan)
        let actual=try await oid(f.cli,"refs/heads/captured-backend");XCTAssertEqual(actual,f.tip)
    }
    func testRevisionMetadataCommandsDoNotAcquireMutationStatusActivity() {
        for command in ["turtlegit-revision-lookup","turtlegit-checkout-refs","turtlegit-configured-remotes","turtlegit-tag-object","turtlegit-tag-objects","turtlegit-history-diff-batch"]{
            XCTAssertFalse(FinderStatusOperationLease.isCommandActivity(["-c","core.precomposeunicode=false",command]),command)
        }
        XCTAssertTrue(FinderStatusOperationLease.isCommandActivity(["branch","new","HEAD"]))
    }

    func testSynchronizationSelectedRevisionReadsRetainObjectsAndDoNotManufactureUnknownStateOnFailure()async throws{
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.cli.run(["update-ref","refs/remotes/origin/topic",f.first])
        let refs=try await f.cli.run(["show-ref"]).stdout,index=try Data(contentsOf:f.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:f.root.appendingPathComponent(".git/config"))
        for selected in [false,true]{let repo=makeRepository(f.root,selected)
            let outgoing=try await repo.synchronizationOutgoing(localBranch:"main",remote:"origin",remoteBranch:"topic")
            XCTAssertEqual(outgoing.disposition,.outgoing);XCTAssertEqual(outgoing.localHash,f.tip);XCTAssertEqual(outgoing.remoteHash,f.first)
            XCTAssertEqual(outgoing.commits.map(\.hash),[f.tip]);XCTAssertTrue(outgoing.fastForward)
            let incoming=try await repo.synchronizationIncoming(from:f.first,to:f.tip)
            XCTAssertEqual(incoming.commits.map(\.hash),[f.tip])
        }
        let unavailable=makeRepository(f.root,true,helper:f.root.appendingPathComponent("missing-helper"))
        do{_ = try await unavailable.synchronizationOutgoing(localBranch:"main",remote:"origin",remoteBranch:"topic");XCTFail("selected failure became unknown remote branch")}catch GitLibGit2Failure.runtimeMissing{}
        let after=try await f.cli.run(["show-ref"]).stdout;XCTAssertEqual(after,refs)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/config")),config)
    }

}
