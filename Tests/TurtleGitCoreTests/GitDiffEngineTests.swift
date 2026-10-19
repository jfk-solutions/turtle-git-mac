// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class GitDiffEngineTests:XCTestCase {
    private let old=String(repeating:"1",count:40),new=String(repeating:"2",count:40)
    private struct Fixture {
        let root:URL,repo:GitRepository,helper:URL,trace:URL
        var backend:GitLibGit2Configuration{.init(mask:(1<<4)|(1<<15),helperURL:helper)}
    }
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    private func executable(_ url:URL,_ text:String)throws {try Data(text.utf8).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)}
    private func fixture()async throws->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("diff engine 雪-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            let git=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"),config=root.appendingPathComponent("global.config"),trace=root.appendingPathComponent("helper.trace")
            try Data().write(to:config)
            let environment="unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="+quote(config.path)+" XDG_CONFIG_HOME="+quote(root.path)+"\n"
            let command=root.appendingPathComponent("private-git"),helper=root.appendingPathComponent("private-libgit2")
            try executable(command,"#!/bin/sh\n"+environment+"exec "+quote(git.path)+" \"$@\"\n")
            let actual=try XCTUnwrap(GitLibGit2Configuration(mask:1<<4).executor(for:.diff))
            try executable(helper,"#!/bin/sh\n"+environment+"printf '%s\\n' \"$@\" >> "+quote(trace.path)+"\nexec "+quote(actual.path)+" \"$@\"\n")
            let work=root.appendingPathComponent("work");try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
            let repo=GitRepository(root:work,executable:command,askpass:nil)
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Diff QA"),("user.email","diff@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_ = try await repo.run(["config",key,value])}
            return Fixture(root:root,repo:repo,helper:helper,trace:trace)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func write(_ repo:GitRepository,_ path:String,_ text:String)throws {try Data(text.utf8).write(to:repo.root.appendingPathComponent(path))}
    private func commit(_ repo:GitRepository,_ message:String,stage:Bool=true)async throws->LogEntry {
        if stage {_ = try await repo.run(["add","-A"])}
        _ = try await repo.run(["commit","-m",message]);return try await repo.rebaseCommit("HEAD")
    }
    private func frame(_ object:[String:Any])throws->Data {GitHistoryDiffDecoder.prefix+(try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)).base64EncodedData()+Data([10])}
    private func header(_ parents:[String]=[])throws->Data {try frame(["kind":"header","revision":new,"parents":parents])}
    private func delta(path:String="file",parent:Int=0)->[String:Any] {["kind":"delta","parentIndex":parent,"status":"M","path":path,"oldPath":NSNull(),"oldOID":old,"newOID":new,"oldMode":0o100644,"newMode":0o100755,"binary":false,"added":2,"deleted":1]}
    func testHistoryTransactionPreservesLiteralIdentityProvenanceAndEmptyParentGroups()throws {
        let path="cafe\u{301}\t\n[*]雪",bytes=try header([old,String(repeating:"3",count:40)])+frame(delta(path:path))+frame(["kind":"end","count":1])
        for size in [1,19,bytes.count] {
            let decoder=GitHistoryDiffDecoder(revision:new,simple:false)
            for offset in stride(from:0,to:bytes.count,by:size){try decoder.append(bytes.subdata(in:offset..<min(offset+size,bytes.count)))}
            let result=try decoder.finish();XCTAssertEqual(result.groups.count,2);XCTAssertTrue(result.groups[1].isEmpty)
            let file=try XCTUnwrap(result.groups[0].first)
            XCTAssertEqual(Array(file.path.utf8),Array(path.utf8));XCTAssertEqual(file.oldObjectID,old);XCTAssertEqual(file.newObjectID,new);XCTAssertEqual(file.oldMode,0o100644);XCTAssertEqual(file.newMode,0o100755)
            let grouped=file.inParentGroup(1);XCTAssertEqual(grouped.oldObjectID,old);XCTAssertEqual(grouped.parentIndex,1)
        }
        let a="café",b="cafe\u{301}",decoder=GitHistoryDiffDecoder(revision:new,simple:true)
        try decoder.append(header()+frame(["kind":"path","path":a])+frame(["kind":"path","path":b])+frame(["kind":"end","count":2]))
        XCTAssertEqual(try decoder.finish().paths.map{Data($0.utf8)},[Data(a.utf8),Data(b.utf8)])
    }
    func testHistoryDecoderRefusesMalformedOrIncompleteMetadataWithoutPublishingRows()throws {
        var cases:[[String:Any]]=[]
        let mutations:[(String,Any)]=[("parentIndex",true),("parentIndex",3),("path","../escape"),("oldOID","12345678"),("oldMode",7),("status","?"),("added",true),("binary",true),("extra",1)]
        for (key,value) in mutations {var item=delta();item[key]=value;cases.append(item)}
        for item in cases {
            let decoder=GitHistoryDiffDecoder(revision:new,simple:false)
            XCTAssertThrowsError(try decoder.append(header()+frame(item)+frame(["kind":"end","count":1])))
            XCTAssertThrowsError(try decoder.finish())
        }
        for suffix in [Data(),try frame(["kind":"end","count":2]),try frame(["kind":"end","count":1])+frame(delta())] {
            let decoder=GitHistoryDiffDecoder(revision:new,simple:false)
            do {try decoder.append(header()+frame(delta())+suffix);XCTAssertThrowsError(try decoder.finish())}catch{}
        }
        let decoder=GitHistoryDiffDecoder(revision:new,simple:true)
        XCTAssertThrowsError(try decoder.append(header()+frame(["kind":"path","path":"safe","extra":"spoof"])));XCTAssertThrowsError(try decoder.finish())
    }
    func testSelectedHistoryRootBinaryModesAndCanonicalRenameThresholds()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let nfd="cafe\u{301}.txt",nfc="café.txt"
        try write(f.repo,nfd,"one\ntwo\n");try Data([0,1,0]).write(to:f.repo.root.appendingPathComponent("binary"))
        let root=try await commit(f.repo,"root")
        let rootGroups=try await f.repo.logFileGroups(in:root,backend:f.backend)
        XCTAssertEqual(rootGroups.count,1);XCTAssertNil(rootGroups[0].parent)
        XCTAssertTrue(rootGroups[0].files.allSatisfy{$0.action=="A" && $0.oldMode==0 && $0.oldObjectID?.allSatisfy{$0=="0"}==true})
        let blob=try await f.repo.run(["rev-parse",":"+nfd]).text.trimmingCharacters(in:.newlines)
        _ = try await f.repo.run(["update-index","--force-remove","--",nfd])
        _ = try await f.repo.run(["update-index","--add","--cacheinfo","100644",blob,nfc])
        try Data([0,2,0]).write(to:f.repo.root.appendingPathComponent("binary"));_ = try await f.repo.run(["add","--","binary"])
        let renamed=try await commit(f.repo,"rename and binary",stage:false)
        let files=try await f.repo.files(in:renamed,backend:f.backend)
        let rename=try XCTUnwrap(files.first{$0.action=="R"})
        XCTAssertEqual(Array(rename.path.utf8),Array(nfc.utf8));XCTAssertEqual(rename.oldPath.map{Array($0.utf8)},Array(nfd.utf8));XCTAssertEqual(rename.oldObjectID,blob);XCTAssertEqual(rename.newObjectID,blob)
        let binary=try XCTUnwrap(files.first{$0.path=="binary"});XCTAssertNil(binary.added);XCTAssertNil(binary.removed);XCTAssertTrue(binary.hasStatistics)
        let noFind=GitRepository(root:f.repo.root,executable:f.repo.executable,askpass:nil,diffDetection:.init(percentage:0),libgit2Configuration:f.backend)
        let split=try await noFind.files(in:renamed)
        XCTAssertFalse(split.contains{$0.action=="R"});XCTAssertTrue(split.contains{$0.action=="D" && $0.path.utf8.elementsEqual(nfd.utf8)});XCTAssertTrue(split.contains{$0.action=="A" && $0.path.utf8.elementsEqual(nfc.utf8)})
    }
    func testActualParentGroupsAndSimpleFindUnionPreserveEmptyMergeParent()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"common","base");_ = try await commit(f.repo,"base")
        _ = try await f.repo.run(["switch","-c","side"]);try write(f.repo,"side-only 雪","side");_ = try await commit(f.repo,"side")
        _ = try await f.repo.run(["switch","main"]);try write(f.repo,"main-only","main");_ = try await commit(f.repo,"main")
        _ = try await f.repo.run(["merge","--no-ff","-s","ours","-m","merge","side"])
        var merge=try await f.repo.rebaseCommit("HEAD");merge.parents=[] // actual immutable object, not stale caller metadata
        let groups=try await f.repo.logFileGroups(in:merge,backend:f.backend)
        XCTAssertEqual(groups.count,2);XCTAssertTrue(groups[0].files.isEmpty);XCTAssertFalse(groups[1].files.isEmpty)
        XCTAssertTrue(groups[1].files.contains{$0.path=="side-only 雪" && $0.action=="D"})
        let matches=try await f.repo.findHistoryMatches(in:[merge],query:"side-only 雪",backend:f.backend)
        XCTAssertEqual(matches,[true])
        let simple=try await f.repo.historyDiff(revision:merge.hash,simple:true,backend:f.backend,cancellation:nil)
        XCTAssertEqual(Set(simple.paths),Set(["main-only","side-only 雪"]))
    }
    func testHistoryCacheSeparatesEnginesRetainsProvenanceAndInvalidatesHelperIdentity()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"file","base\n");_ = try await commit(f.repo,"base");try write(f.repo,"file","changed\n");let entry=try await commit(f.repo,"changed")
        let cache=HistoryFileCache(root:f.root.appendingPathComponent("cache")),cli=GitLibGit2Configuration(enabled:false,mask:0,helperURL:f.helper)
        let cliFiles=try await f.repo.files(in:entry,cache:cache,backend:cli)
        XCTAssertTrue(cliFiles.allSatisfy{$0.newObjectID==nil});XCTAssertFalse(FileManager.default.fileExists(atPath:f.trace.path))
        let selected=try await f.repo.files(in:entry,cache:cache,backend:f.backend)
        XCTAssertTrue(selected.allSatisfy{$0.newObjectID?.count==40})
        let first=try Data(contentsOf:f.trace),again=try await f.repo.files(in:entry,cache:cache,backend:f.backend)
        XCTAssertEqual(selected,again);XCTAssertEqual(try Data(contentsOf:f.trace),first,"Valid selected-engine cache should avoid another helper read")
        let cliContext=try await f.repo.historyFileCacheContext(entry,cancellation:nil,backend:cli),selectedContext=try await f.repo.historyFileCacheContext(entry,cancellation:nil,backend:f.backend)
        XCTAssertNotEqual(cliContext.key,selectedContext.key)
        let current=try String(contentsOf:f.helper,encoding:.utf8);try executable(f.helper,current+"\n# changed helper identity\n")
        _ = try await f.repo.files(in:entry,cache:cache,backend:f.backend)
        XCTAssertGreaterThan(try Data(contentsOf:f.trace).count,first.count)
    }
    func testUnifiedSelectedBytesContainSourceStatsDefaultContextAndIgnoreRenameFind()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"old","one\ntwo\nthree\nfour\nfive\nsix\nseven\n");let base=try await commit(f.repo,"base")
        _ = try await f.repo.run(["mv","--","old","new"]);let entry=try await commit(f.repo,"renamed")
        let bytes=try await f.repo.revisionDiffData(entry,backend:f.backend),text=String(decoding:bytes,as:UTF8.self)
        XCTAssertTrue(text.contains("2 files changed"));XCTAssertTrue(text.contains("deleted file mode"));XCTAssertTrue(text.contains("new file mode"));XCTAssertFalse(text.contains("rename from"))
        let lists=try await f.repo.files(in:entry,backend:f.backend);XCTAssertTrue(lists.contains{$0.action=="R"},"Selected15 has rename-find while selected4 does not")
        let direct=try await f.repo.unifiedDiffData(arguments:["diff","-U0","-M100%","--no-prefix",base.hash,entry.hash,"--"],backend:f.backend)
        XCTAssertTrue(String(decoding:direct,as:UTF8.self).contains("diff --git old old"));XCTAssertFalse(String(decoding:direct,as:UTF8.self).contains("diff --git a/"))
    }
    func testUnifiedWorkingTreeMergesIndexAndWorktreeWithoutMutatingEither()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let path="file[*]\n雪.txt";try write(f.repo,path,"one\ntwo\nthree\nfour\nfive\n");let base=try await commit(f.repo,"base")
        try write(f.repo,path,"one\nstaged\nthree\nfour\nfive\n");_ = try await f.repo.run(["add","--",path]);try write(f.repo,path,"one\nworking\nthree\nfour\nfive\n")
        try write(f.repo,"staged-only","new staged\n");_ = try await f.repo.run(["add","--","staged-only"])
        let before=try await f.repo.run(["write-tree"]).stdout
        let actor=GitRepository(root:f.repo.root,executable:f.repo.executable,askpass:nil,libgit2Configuration:f.backend)
        let bytes=try await actor.workingTreeDiffData(paths:[]),text=String(decoding:bytes,as:UTF8.self)
        XCTAssertTrue(text.contains("+working"));XCTAssertTrue(text.contains("staged-only"));XCTAssertFalse(text.contains("+staged\n"))
        _ = try await f.repo.run(["apply","--check","--reverse","-"],input:bytes)
        let after=try await f.repo.run(["write-tree"]).stdout;XCTAssertEqual(after,before)
        let entry=base,selected=try await actor.revisionDiffData(entry,path:path,workingTree:true)
        XCTAssertFalse(String(decoding:selected,as:UTF8.self).contains("staged-only"))
        XCTAssertEqual(try String(contentsOf:f.repo.root.appendingPathComponent(path),encoding:.utf8),"one\nworking\nthree\nfour\nfive\n")
    }
    func testSourceMergeModesUseFirstParentAndLiteralPathScopeWithoutAffectingCLI()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"literal[?] 雪","base\n");_ = try await commit(f.repo,"base")
        _ = try await f.repo.run(["switch","-c","side"]);try write(f.repo,"side","side\n");_ = try await commit(f.repo,"side")
        _ = try await f.repo.run(["switch","main"]);try write(f.repo,"literal[?] 雪","main\n");_ = try await commit(f.repo,"main")
        _ = try await f.repo.run(["merge","--no-ff","-m","merge","side"]);let merge=try await f.repo.rebaseCommit("HEAD")
        let first=try await f.repo.revisionDiffData(merge,backend:f.backend)
        for mode:LogRevisionDiffMode in [.allParents,.combined,.extraMergeChanges] {let bytes=try await f.repo.revisionDiffData(merge,mode:mode,backend:f.backend);XCTAssertEqual(bytes,first)}
        let cli=GitLibGit2Configuration(enabled:false,mask:0)
        let ordinary=try await f.repo.revisionDiffData(merge,mode:.combined,backend:cli)
        let expected=try await f.repo.run(["diff-tree","-r","-p","-c","--stat","--no-ext-diff","--no-color"]+f.repo.diffDetection.historyArguments+[merge.hash,"--"]).stdout
        XCTAssertEqual(ordinary,expected)
    }
    func testPublicComparisonPatchAndHistoryPreviewUseCapturedEngineButStagingPayloadStaysCLI()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"file","base\n");let base=try await commit(f.repo,"base");try write(f.repo,"file","changed\n");let changed=try await commit(f.repo,"changed")
        let actor=GitRepository(root:f.repo.root,executable:f.repo.executable,askpass:nil,libgit2Configuration:f.backend)
        let snapshot=try await actor.revisionComparison(from:.revision(base.hash),to:.revision(changed.hash))
        let bytes=try await actor.revisionComparisonPatchData(snapshot),preview=try await actor.logPatchPreviewData(changed)
        XCTAssertTrue(String(decoding:bytes,as:UTF8.self).contains("1 file changed"));XCTAssertTrue(String(decoding:preview,as:UTF8.self).contains("1 file changed"))
        let selected=try await actor.revisionFileDiffData(changed,files:[CommitFile(path:"file",oldPath:nil,action:"M",added:1,removed:1,hasStatistics:true,isSubmodule:false)])
        XCTAssertEqual(selected,bytes)
        try write(f.repo,"file","staged\n");_ = try await f.repo.run(["add","--","file"])
        let trace=try Data(contentsOf:f.trace),staged=try await actor.patchData(paths:["file"],staged:true)
        XCTAssertFalse(String(decoding:staged,as:UTF8.self).contains("1 file changed"));XCTAssertEqual(try Data(contentsOf:f.trace),trace)
        let explicit=try await actor.unifiedDiffData(arguments:["diff","--cached","--no-color","--","file"])
        let expected=try await f.repo.run(["diff","--cached","--no-color","--","file"]).stdout;XCTAssertEqual(explicit,expected)
    }
    func testUnbornSourceDiffIsEmptyWhileExplicitIndexPreviewRetainsCLI()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"new","new\n");_ = try await f.repo.run(["add","--","new"])
        let actor=GitRepository(root:f.repo.root,executable:f.repo.executable,askpass:nil,libgit2Configuration:f.backend)
        let unified=try await actor.workingTreeDiffData(paths:[]);XCTAssertTrue(unified.isEmpty)
        let staged=try await actor.patchData(paths:["new"],staged:true);XCTAssertFalse(staged.isEmpty)
    }
    func testMalformedSelectedHistoryCannotPublishPartialFilesAndCancellationDrainsHelper()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"file","base");let entry=try await commit(f.repo,"base")
        let fake=f.root.appendingPathComponent("partial-helper"),valid=String(decoding:try frame(["kind":"header","revision":entry.hash,"parents":[]])+frame(["kind":"path","path":"spoofed"]),as:UTF8.self)
        try executable(fake,"#!/bin/sh\ncat >/dev/null\nprintf '%s' "+quote(valid)+"\nexit 0\n")
        do {_ = try await f.repo.logFileGroups(in:entry,backend:.init(mask:1<<15,helperURL:fake));XCTFail("Incomplete/incorrect transaction published rows")}catch is GitDiffEngineFailure {}
        let held=f.root.appendingPathComponent("held-helper"),marker=f.root.appendingPathComponent("held.pid")
        try executable(held,"#!/bin/sh\ncat >/dev/null\nprintf '%s' \"$$\" > "+quote(marker.path)+"\nsleep 60\n")
        let token=OperationCancellation()
        let worker=Task {try await f.repo.logFileGroups(in:entry,cancellation:token,backend:.init(mask:1<<15,helperURL:held))}
        let watcher=Task.detached {()->Bool in
            let deadline=Date().addingTimeInterval(5)
            while Date()<deadline {if FileManager.default.fileExists(atPath:marker.path){token.cancel();return true};try? await Task.sleep(nanoseconds:20_000_000)}
            token.cancel();return false
        }
        do {_ = try await worker.value;XCTFail("Cancelled history read succeeded")}catch is GitCommandCancellationFailure {} catch is OperationCancellationFailure {}
        let observed=await watcher.value;XCTAssertTrue(observed)
        if let text=try? String(contentsOf:marker,encoding:.utf8),let pid=Int32(text){XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)}
    }
}
