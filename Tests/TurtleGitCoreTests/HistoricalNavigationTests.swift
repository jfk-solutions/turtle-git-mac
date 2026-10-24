// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class HistoricalNavigationTests:XCTestCase {
    private struct Fixture {let root:URL,cli:GitRepository,first:String,tip:String,tree:String,blob:String,tag:String}
    private func repository(_ root:URL,enabled:Bool=true,helper:URL?=nil)->GitRepository {
        GitRepository(root:root,libgit2Configuration:.init(enabled:enabled,mask:0,helperURL:helper))
    }
    private func initial()async throws->(URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitHistoricalNavigation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let cli=repository(root,enabled:false)
        _=try await cli.run(["init","-b","main"])
        for(key,value)in[("user.name","Historical navigation QA"),("user.email","history@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true")] {_=try await cli.run(["config",key,value])}
        return(root,cli)
    }
    private func oid(_ repo:GitRepository,_ revision:String)async throws->String {
        try await repo.run(["-c","core.precomposeunicode=false","rev-parse","--verify","--end-of-options",revision]).stdoutString
    }
    private func fixture()async throws->Fixture {
        let(root,cli)=try await initial()
        try Data("first\n".utf8).write(to:root.appendingPathComponent("payload"));try await cli.stage(["payload"]);_=try await cli.commit(message:"first")
        let first=try await oid(cli,"HEAD")
        try Data("second\n".utf8).write(to:root.appendingPathComponent("payload"));try await cli.stage(["payload"]);_=try await cli.commit(message:"second")
        let tip=try await oid(cli,"HEAD"),tree=try await oid(cli,"HEAD^{tree}"),blob=try await oid(cli,"HEAD:payload")
        _=try await cli.run(["tag","-a","release","-m","annotated",tip])
        return Fixture(root:root,cli:cli,first:first,tip:tip,tree:tree,blob:blob,tag:try await oid(cli,"refs/tags/release"))
    }
    private func packed(_ f:Fixture,_ refs:[(String,String)])async throws {
        _=try await f.cli.run(["pack-refs","--all","--prune"])
        let file=f.root.appendingPathComponent(".git/packed-refs")
        var text=try String(contentsOf:file,encoding:.utf8).replacingOccurrences(of:" sorted",with:"")
        for(name,hash)in refs{text += hash+" "+name+"\n"}
        try Data(text.utf8).write(to:file)
    }
    private func script(_ root:URL,_ name:String,_ body:String)throws->URL {
        let url=root.appendingPathComponent(name);try Data(("#!/bin/sh\n"+body).utf8).write(to:url)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path);return url
    }
    private func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func witness(_ f:Fixture)async throws->[Data] {
        [try await f.cli.run(["rev-parse","HEAD"]).stdout,try Data(contentsOf:f.root.appendingPathComponent(".git/index")),try Data(contentsOf:f.root.appendingPathComponent("payload"))]
    }

    func testBrowserAcceptsNamedCommitTreeAndRawAnnotatedTagWithoutMutatingRepository()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let before=try await witness(f)
        for enabled in [false,true] {
            let repo=repository(f.root,enabled:enabled)
            for(revision,object)in[("HEAD",f.tip),("refs/tags/release",f.tip),(f.tag,f.tip),(f.tree,f.tree)] {
                let view=try await repo.browseRepository(revision:revision)
                XCTAssertEqual(view.objectID,object);XCTAssertEqual(view.treeID,f.tree)
                let file=try XCTUnwrap(view.entries.first{$0.path=="payload"})
                let content=try await repo.repositoryBrowserFile(view,entry:file)
                XCTAssertEqual(content.bytes,Data("second\n".utf8))
            }
        }
        let after=try await witness(f);XCTAssertEqual(after,before)
    }
    func testBrowserRejectsBlobAndMissingObjectRatherThanInventingEmptyTree()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        for revision in [f.blob,String(repeating:"a",count:40),"refs/heads/missing"] {
            do{_=try await repository(f.root).browseRepository(revision:revision);XCTFail("Invalid Browser object accepted: "+revision)}catch RepositoryBrowserFailure.revision{}
        }
    }
    func testUnbornBrowserIsEmptyButMissingRevisionRemainsAnError()async throws {
        let(root,_)=try await initial();defer{try? FileManager.default.removeItem(at:root)}
        for enabled in [false,true] {
            let repo=repository(root,enabled:enabled),view=try await repo.browseRepository()
            XCTAssertNil(view.objectID);XCTAssertNil(view.treeID);XCTAssertTrue(view.entries.isEmpty)
            do{_=try await repo.browseRepository(revision:"refs/heads/missing");XCTFail("Missing ref became unborn HEAD")}catch RepositoryBrowserFailure.revision{}
        }
    }
    func testBrowserPackedCanonicalAliasesRemainDistinctWithStoredNormalizationEnabled()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let nfc="refs/heads/Café",nfd="refs/heads/Cafe\u{301}"
        try await packed(f,[(nfc,f.first),(nfd,f.tip)])
        for enabled in [false,true] {
            let repo=repository(f.root,enabled:enabled)
            for(name,hash,bytes)in[(nfc,f.first,"first\n"),(nfd,f.tip,"second\n")] {
                let view=try await repo.browseRepository(revision:name)
                XCTAssertTrue(view.revision.utf8.elementsEqual(name.utf8));XCTAssertEqual(view.objectID,hash)
                let content=try await repo.repositoryBrowserFile(view,entry:try XCTUnwrap(view.entries.first{$0.path=="payload"}))
                XCTAssertEqual(content.bytes,Data(bytes.utf8))
            }
        }
        let stored=try await f.cli.run(["config","--local","--get","core.precomposeunicode"]).stdout
        XCTAssertEqual(stored,Data("true\n".utf8))
    }
    func testPinnedBrowserDirectoryAndFileSurviveMovingDisplayedReference()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _=try await f.cli.run(["update-ref","refs/heads/view",f.first])
        let repo=repository(f.root),view=try await repo.browseRepository(revision:"refs/heads/view")
        _=try await f.cli.run(["update-ref","refs/heads/view",f.tip])
        let replacement=repository(f.root,enabled:false,helper:f.root.appendingPathComponent("unavailable-after-acceptance"))
        let listing=try await replacement.browseRepositoryDirectory(view,directory:"")
        XCTAssertEqual(listing.objectID,f.first)
        let content=try await repo.repositoryBrowserFile(listing,entry:try XCTUnwrap(listing.entries.first{$0.path=="payload"}))
        XCTAssertEqual(content.bytes,Data("first\n".utf8))
    }
    func testInitialBrowserRequiresStaticHelperEvenWhenMasterOffWhileSubsequentReadUsesCLI()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let missing=f.root.appendingPathComponent("absent-helper"),repo=repository(f.root,enabled:false,helper:missing)
        let subsequent=try await repo.repositoryBrowserRevision("refs/tags/release",initialization:false)
        XCTAssertEqual(subsequent.objectID,f.tip);XCTAssertEqual(subsequent.treeID,f.tree)
        do{_=try await repo.repositoryBrowserRevision("HEAD",initialization:true);XCTFail("Static Browser read fell back to CLI")}catch GitLibGit2Failure.runtimeMissing{}
        do{_=try await repository(f.root,helper:missing).repositoryBrowserRevision("HEAD");XCTFail("Master-selected read fell back to CLI")}catch GitLibGit2Failure.runtimeMissing{}
    }
    func testMalformedOrFailedHistoricalHelpersNeverBecomeEmptySuccessfulViews()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let before=try await witness(f)
        for body in ["cat >/dev/null\nprintf 'not-a-receipt\\n'\n","cat >/dev/null\nprintf 'controlled historical failure\\n' >&2\nexit 73\n"] {
            let helper=try script(f.root,"invalid-helper",body),repo=repository(f.root,helper:helper)
            do{_=try await repo.repositoryBrowserRevision("HEAD",initialization:true);XCTFail("Bad Browser helper became empty view")}
            catch let failure as GitFailure {XCTAssertEqual(failure.code,73);XCTAssertTrue(failure.message.contains("controlled historical failure"))}
            catch GitRevisionLookupFailure.output {XCTAssertTrue(body.contains("not-a-receipt"))}
            do{_=try await repo.historicalGitlink(path:"payload",revision:"HEAD");XCTFail("Bad gitlink helper became missing")}
            catch let failure as GitFailure {XCTAssertEqual(failure.code,73)}
            catch GitRevisionLookupFailure.output {XCTAssertTrue(body.contains("not-a-receipt"))}
        }
        let after=try await witness(f);XCTAssertEqual(after,before)
    }
    func testHistoricalGitlinkMalformedFramingAndSchemaAreRejectedAfterValidResolution()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let resolver=try JSONSerialization.data(withJSONObject:["operation":"revision","oid":f.tree,"unbornHead":false]).base64EncodedString()
        let badReplies=["garbage\n","TurtleGit HistoricalGitlink v1:"+Data("{\"status\":\"missing\",\"oid\":null,\"extra\":1}".utf8).base64EncodedString()+"\n",
                        "TurtleGit HistoricalGitlink v1:"+Data("{\"status\":\"gitlink\",\"oid\":\"bad\"}".utf8).base64EncodedString()+"\n",String(repeating:"x",count:4097)+"\n"]
        for reply in badReplies {
            let body="cat >/dev/null\nfor arg in \"$@\"; do verb=$arg; done\ncase \"$verb\" in\n turtlegit-revision-lookup) printf '%s\\n' "+quote("TurtleGit RevisionLookup v1:"+resolver)+";;\n turtlegit-historical-gitlink) printf '%s' "+quote(reply)+";;\n *) exit 74;;\nesac\n"
            let helper=try script(f.root,"bad-gitlink-reply",body)
            do{_=try await repository(f.root,helper:helper).historicalGitlink(path:"payload",revision:f.tip);XCTFail("Malformed historical receipt accepted")}catch GitHistoricalLookupFailure.output{}
        }
    }
    func testPrecancelledHistoricalReadsNeverLaunchHelper()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let marker=f.root.appendingPathComponent("unexpected-launch"),helper=try script(f.root,"cancelled-helper","touch "+quote(marker.path)+"\nexit 71\n")
        let repo=repository(f.root,helper:helper),token=OperationCancellation();token.cancel()
        do{_=try await repo.repositoryBrowserRevision("HEAD",initialization:true,cancellation:token);XCTFail("Cancelled initial Browser read accepted")}catch is OperationCancellationFailure{}
        do{_=try await repo.historicalGitlink(path:"payload",revision:"HEAD",cancellation:token);XCTFail("Cancelled gitlink read accepted")}catch is OperationCancellationFailure{}
        do{_=try await repo.submoduleLogRevision(path:"payload",revision:"HEAD",cancellation:token);XCTFail("Cancelled source pin accepted")}catch is OperationCancellationFailure{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }
    func testLiveHistoricalCancellationReapsOwnedSelectedHelper()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let marker=f.root.appendingPathComponent("held-helper.pid"),helper=try script(f.root,"held-helper","cat >/dev/null\nprintf '%s\\n' $$ > "+quote(marker.path)+"\nexec /bin/sleep 30\n")
        let token=OperationCancellation(),repo=repository(f.root,helper:helper)
        let pending=Task{try await repo.historicalGitlink(path:"payload",revision:f.tip,cancellation:token)}
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath:marker.path){break}
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        let started=FileManager.default.fileExists(atPath:marker.path)
        token.cancel()
        do{_=try await pending.value;XCTFail("Cancelled historical helper completed successfully")}
        catch is OperationCancellationFailure {XCTAssertTrue(token.isCancelled)}
        catch is GitCommandCancellationFailure {XCTAssertTrue(token.isCancelled)}
        XCTAssertTrue(started,"Held helper did not reach actual process boundary")
        if started {
            let pid=try XCTUnwrap(Int32(String(contentsOf:marker,encoding:.utf8).trimmingCharacters(in:.newlines)))
            errno=0;XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH,"Owned helper survived the cancelled read")
        }
    }
    func testMissingSelectedGitlinkRuntimeAndInvalidPathsRemainDistinctFromAbsentEntry()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let repo=repository(f.root,helper:f.root.appendingPathComponent("absent-helper"))
        do{_=try await repo.historicalGitlink(path:"payload",revision:f.tip);XCTFail("Missing selected runtime became absent entry")}catch GitLibGit2Failure.runtimeMissing{}
        for path in ["","/absolute","a/../b","a//b","nul\u{0}path"] {
            do{_=try await repo.historicalGitlink(path:path,revision:f.tip);XCTFail("Unsafe historical path reached runtime")}catch GitHistoricalLookupFailure.input{}
        }
    }
    func testHistoricalGitlinkDistinguishesAbsentAndOrdinaryEntryAndPinsActualTree()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let path="module-é",records="160000 commit "+f.first+"\t"+path+"\u{0}"
        let tree=try await f.cli.run(["mktree","-z"],input:Data(records.utf8)).stdoutString
        let historical=try await f.cli.run(["commit-tree",tree,"-p",f.tip],input:Data("historical gitlink\n".utf8)).stdoutString
        let before=try await witness(f)
        for enabled in [false,true] {
            let repo=repository(f.root,enabled:enabled)
            let link=try await repo.historicalGitlink(path:path,revision:historical),fromTree=try await repo.historicalGitlink(path:path,revision:tree)
            let missing=try await repo.historicalGitlink(path:"absent",revision:historical),ordinary=try await repo.historicalGitlink(path:"payload",revision:f.tip)
            XCTAssertEqual(link,.gitlink(f.first));XCTAssertEqual(fromTree,.gitlink(f.first));XCTAssertEqual(missing,.missing);XCTAssertEqual(ordinary,.other)
        }
        let after=try await witness(f);XCTAssertEqual(after,before)
    }
    func testSourceHistoricalLogPinRequiresCommitAndGitlinkOnlyWhenMasterEnabled()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let path="module",tree=try await f.cli.run(["mktree","-z"],input:Data(("160000 commit "+f.first+"\t"+path+"\u{0}").utf8)).stdoutString
        let commit=try await f.cli.run(["commit-tree",tree,"-p",f.tip],input:Data("gitlink pin\n".utf8)).stdoutString
        let selected=repository(f.root),pin=try await selected.submoduleLogRevision(path:path,revision:commit)
        XCTAssertEqual(pin,f.first)
        for(revision,missingPath)in [(commit,"absent"),(f.tip,"payload")] {
            do{_=try await selected.submoduleLogRevision(path:missingPath,revision:revision);XCTFail("Source pin invented absent/non-gitlink target")}catch GitHistoricalLookupFailure.path {XCTAssertEqual(missingPath,"absent")}
            catch GitHistoricalLookupFailure.notSubmodule {XCTAssertEqual(missingPath,"payload")}
        }
        do{_=try await selected.submoduleLogRevision(path:path,revision:tree);XCTFail("Source commit-only pin accepted raw tree")}catch GitHistoricalLookupFailure.revision{}
        let off=repository(f.root,enabled:false,helper:f.root.appendingPathComponent("absent-helper"))
        let omitted=try await off.submoduleLogRevision(path:path,revision:"does-not-exist")
        XCTAssertNil(omitted,"Source master-off Show Log does not inspect or invent a historical pin")
    }
    func testHistoricalGitlinkCanonicalPathsRetainByteIdentityUnderStoredNormalization()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let a="Café",b="Cafe\u{301}",records="160000 commit "+f.first+"\t"+a+"\u{0}"+"160000 commit "+f.tip+"\t"+b+"\u{0}"
        let tree=try await f.cli.run(["mktree","-z"],input:Data(records.utf8)).stdoutString
        for enabled in [false,true] {
            let repo=repository(f.root,enabled:enabled),left=try await repo.historicalGitlink(path:a,revision:tree),right=try await repo.historicalGitlink(path:b,revision:tree)
            XCTAssertEqual(left,.gitlink(f.first));XCTAssertEqual(right,.gitlink(f.tip))
        }
    }
    func testLiteralHistoryReferenceDeletionRejectsMovedTargetWithoutDeletingCanonicalSibling()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let a="refs/custom/Café",b="refs/custom/Cafe\u{301}"
        try await packed(f,[(a,f.first),(b,f.tip)])
        for enabled in [false,true] {
            _=try await f.cli.run(["-c","core.precomposeunicode=false","update-ref",a,f.first])
            let repo=repository(f.root,enabled:enabled),request=try await repo.prepareHistoryReferenceDeletion(a)
            XCTAssertEqual(request.objectID,f.first);XCTAssertTrue(request.name.utf8.elementsEqual(a.utf8))
            _=try await f.cli.run(["-c","core.precomposeunicode=false","update-ref",a,f.tip])
            do{_=try await repo.deleteHistoryReference(request,choice:.delete);XCTFail("Moved exact deletion target accepted")}catch HistoryReferenceDeletionFailure.changed{}
            let actual=try await oid(f.cli,a),sibling=try await oid(f.cli,b)
            XCTAssertEqual(actual,f.tip);XCTAssertEqual(sibling,f.tip)
        }
    }
    func testLiteralHistoryReferenceDeletionDeletesOnlyAcceptedName()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let a="refs/custom/Café",b="refs/custom/Cafe\u{301}"
        try await packed(f,[(a,f.first),(b,f.tip)])
        let repo=repository(f.root,enabled:false),request=try await repo.prepareHistoryReferenceDeletion(b)
        XCTAssertEqual(request.objectID,f.tip);XCTAssertEqual(request.acceptedBackend?.enabled,false)
        let replacement=repository(f.root,helper:f.root.appendingPathComponent("unavailable-after-confirmation"))
        _=try await replacement.deleteHistoryReference(request,choice:.delete)
        let sibling=try await oid(f.cli,a),removed=try await f.cli.run(["-c","core.precomposeunicode=false","show-ref","--verify","--quiet",b],successfulExitCodes:0...1)
        XCTAssertEqual(sibling,f.first);XCTAssertEqual(removed.exitCode,1)
    }

}

private extension GitResult {
    var stdoutString:String {String(decoding:stdout,as:UTF8.self).trimmingCharacters(in:.newlines)}
}
