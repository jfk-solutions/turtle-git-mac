// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

private final class ResetEngineEvents:@unchecked Sendable {
    private let lock=NSLock()
    private var values:[GitResetNotification]=[],output=Data(),commands:[GitCommandInvocation]=[]
    func append(_ event:GitResetNotification){lock.lock();values.append(event);lock.unlock()}
    func appendOutput(_ chunk:GitOutputChunk){lock.lock();output.append(chunk.data);lock.unlock()}
    func appendCommand(_ command:GitCommandInvocation){lock.lock();commands.append(command);lock.unlock()}
    var events:[GitResetNotification]{lock.lock();defer{lock.unlock()};return values}
    var bytes:Data{lock.lock();defer{lock.unlock()};return output}
    var invocations:[GitCommandInvocation]{lock.lock();defer{lock.unlock()};return commands}
    var paths:[String]{events.compactMap {if case .file(let path)=$0{return path};return nil}}
}
final class ResetMutationEngineTests:XCTestCase {
    private struct Fixture {
        let root:URL,repo:GitRepository,helper:URL
        var backend:GitLibGit2Configuration{.init(mask:(1<<5)|(1<<6),helperURL:helper)}
    }
    private func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    private func executable(_ url:URL,_ text:String)throws {try Data(text.utf8).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)}
    private func fixture()async throws->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("reset mutation 雪-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            let git=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
            let config=root.appendingPathComponent("global.config");try Data().write(to:config)
            let environment="unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="+quote(config.path)+" XDG_CONFIG_HOME="+quote(root.path)+"\n"
            let command=root.appendingPathComponent("private-git"),helper=root.appendingPathComponent("private-libgit2")
            try executable(command,"#!/bin/sh\n"+environment+"exec "+quote(git.path)+" \"$@\"\n")
            let actual=try XCTUnwrap(GitLibGit2Configuration(mask:1<<5).executor(for:.reset))
            try executable(helper,"#!/bin/sh\n"+environment+"exec "+quote(actual.path)+" \"$@\"\n")
            let work=root.appendingPathComponent("work");try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
            let repo=GitRepository(root:work,executable:command,askpass:nil)
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Reset QA"),("user.email","reset@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_ = try await repo.run(["config",key,value])}
            return Fixture(root:root,repo:repo,helper:helper)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func write(_ repo:GitRepository,_ path:String,_ text:String)throws {try Data(text.utf8).write(to:repo.root.appendingPathComponent(path))}
    private func commit(_ repo:GitRepository,_ message:String)async throws->String {
        _ = try await repo.run(["add","-A"]);_ = try await repo.run(["commit","-m",message])
        return try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
    }
    private func privateRecycle(_ root:URL)throws->(URL)throws->URL? {
        let destination=root.appendingPathComponent("private-recycled");try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        return {location in let saved=destination.appendingPathComponent(UUID().uuidString);try FileManager.default.moveItem(at:location,to:saved);return saved}
    }
    private func frame(_ object:[String:Any])throws->Data {GitResetNotificationDecoder.prefix+(try JSONSerialization.data(withJSONObject:object,options:.sortedKeys)).base64EncodedData()+Data([10])}
    private func witness(_ url:URL,id:UInt64=1,path:String)->GitResetRecycleRequest {
        var info=stat();let exists=lstat(url.path,&info)==0
        return .init(id:id,path:path,exists:exists,device:exists ? UInt64(UInt32(bitPattern:info.st_dev)):nil,inode:exists ? UInt64(info.st_ino):nil,mode:exists ? UInt32(info.st_mode):nil)
    }
    func testResetFramesPreserveLiteralPathsAndIndependentProgressIncludingStartup()throws {
        let path="cafe\u{301} 雪\t\n[*].txt"
        let data=try frame(["kind":"progress","completed":0,"total":0])+frame(["kind":"file","path":path])+frame(["kind":"progress","completed":1,"total":1000])+frame(["kind":"progress","completed":2,"total":1000])
        for size in [1,13,data.count] {
            let decoder=GitResetNotificationDecoder();var events:[GitResetNotification]=[]
            for offset in stride(from:0,to:data.count,by:size){try decoder.append(data.subdata(in:offset..<min(offset+size,data.count))){if case .notification(let value)=$0{events.append(value)}}}
            try decoder.finish();XCTAssertEqual(events.count,4)
            guard case .file(let actual)=events[1] else{return XCTFail("Literal file notification missing")}
            XCTAssertEqual(Array(actual.utf8),Array(path.utf8));XCTAssertEqual(events[0],.progress(completed:0,total:0));XCTAssertEqual(events[3],.progress(completed:2,total:1000))
        }
    }
    func testResetDecoderRejectsUnsafeShapesAndRetainsEarlierValidatedNotifications()throws {
        let cases:[[String:Any]]=[
            ["kind":"file","path":"../outside"],["kind":"file","path":"a/.git/config"],["kind":"file","path":"file","extra":1],
            ["kind":"progress","completed":true,"total":1],["kind":"progress","completed":2,"total":1],
            ["kind":"recycle","id":0,"path":"a","exists":false],["kind":"recycle","id":1,"path":"a","exists":true],
            ["kind":"recycle","id":1,"path":"a","exists":false,"mode":0],
            ["kind":"issue","message":"spoofed","commandSucceeded":true]]
        for value in cases {
            let decoder=GitResetNotificationDecoder();var count=0
            XCTAssertThrowsError(try decoder.append(frame(["kind":"file","path":"safe"])+frame(value)){_ in count+=1})
            XCTAssertEqual(count,1)
        }
        let decoder=GitResetNotificationDecoder();try decoder.append(Data("TurtleGit Reset v1:AAAA".utf8)){_ in};XCTAssertThrowsError(try decoder.finish())
    }
    func testResetRecycleExchangeAcknowledgesOnlyCompletedOwnedRequests()throws {
        let exchange=try GitResetRecycleExchange(),request=GitResetRecycleRequest(id:1,path:"a",exists:false,device:nil,inode:nil,mode:nil)
        let ack=exchange.directory.appendingPathComponent("1.ack")
        try exchange.serve(request){XCTAssertFalse(FileManager.default.fileExists(atPath:ack.path))}
        let fields=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:ack)) as? [String:Any])
        XCTAssertEqual(fields["accepted"] as? Bool,true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:ack.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertThrowsError(try exchange.serve(request){XCTFail("Repeated request invoked recycler")})
        exchange.abort();XCTAssertTrue(FileManager.default.fileExists(atPath:exchange.directory.appendingPathComponent("abort").path))
    }
    func testSelectedResetModesKeepSourceIndexWorktreeAndDefaultCLIContracts()async throws {
        for mode in ResetMode.allCases {
            let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
            try write(f.repo,"file","base\n");let base=try await commit(f.repo,"base")
            try write(f.repo,"file","later\n");_ = try await commit(f.repo,"later")
            let plan=try await f.repo.prepareReset(to:base,mode:mode),events=ResetEngineEvents()
            _ = try await f.repo.reset(plan,onOutput:events.appendOutput,onCommand:events.appendCommand,backend:f.backend,recycle:false,onNotification:events.append)
            let head=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            let staged=try await f.repo.run(["show",":file"]).text
            XCTAssertEqual(head,base);XCTAssertEqual(staged,mode == .soft ? "later\n":"base\n")
            XCTAssertEqual(try String(contentsOf:f.repo.root.appendingPathComponent("file"),encoding:.utf8),mode == .hard ? "base\n":"later\n")
            XCTAssertEqual(events.paths,mode == .hard ? ["file"]:[])
            XCTAssertFalse(String(decoding:events.bytes,as:UTF8.self).contains("TurtleGit Reset"))
            XCTAssertEqual(events.invocations.count,1);XCTAssertFalse(events.invocations[0].arguments.contains("--turtlegit-reset-notifications"))
        }
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"file","base\n");let base=try await commit(f.repo,"base")
        try write(f.repo,"file","later\n");_ = try await commit(f.repo,"later")
        let plan=try await f.repo.prepareReset(to:base,mode:.hard),events=ResetEngineEvents()
        _ = try await f.repo.reset(plan,backend:.init(mask:GitLibGit2Configuration.defaultMask,helperURL:f.root.appendingPathComponent("absent")),onNotification:events.append,recycler:{_ in XCTFail("CLI reset used parent recycle protocol");return nil})
        XCTAssertTrue(events.events.isEmpty);XCTAssertEqual(try String(contentsOf:f.repo.root.appendingPathComponent("file"),encoding:.utf8),"base\n")
    }
    func testHardResetRecyclesLiteralTargetsBeforeSourceFileNotificationAndWrite()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let paths=["a\t\n[*].txt","cafe\u{301} 雪.txt"]
        for path in paths{try write(f.repo,path,"base "+path)};let base=try await commit(f.repo,"base")
        for path in paths{try write(f.repo,path,"later "+path)};_ = try await commit(f.repo,"later")
        let events=ResetEngineEvents(),recycle=try privateRecycle(f.root)
        let plan=try await f.repo.prepareReset(to:base,mode:.hard)
        var saved:[Data]=[]
        _ = try await f.repo.reset(plan,backend:f.backend,onNotification:events.append,recycler:{location in
            XCTAssertTrue(events.paths.allSatisfy{$0 != location.lastPathComponent},"Source notify must follow recycling")
            saved.append(try Data(contentsOf:location));return try recycle(location)
        })
        XCTAssertEqual(Set(saved),Set(paths.map{Data(("later "+$0).utf8)}))
        XCTAssertEqual(Set(events.paths.map{Data($0.utf8)}),Set(paths.map{Data($0.utf8)}))
        for path in paths{XCTAssertEqual(try Data(contentsOf:f.repo.root.appendingPathComponent(path)),Data(("base "+path).utf8))}
    }
    func testFailedRecycleRetainsEarlierRecoverableItemsAndActualFailedResetOutcome()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        for path in ["a","b"]{try write(f.repo,path,"base "+path)};let base=try await commit(f.repo,"base")
        for path in ["a","b"]{try write(f.repo,path,"later "+path)};let original=try await commit(f.repo,"later")
        let plan=try await f.repo.prepareReset(to:base,mode:.hard),events=ResetEngineEvents(),recycle=try privateRecycle(f.root)
        var saved:URL?,count=0
        do {_ = try await f.repo.reset(plan,backend:f.backend,onNotification:events.append,recycler:{location in
            count+=1;if count==2{throw NSError(domain:"Private recycle refusal",code:17,userInfo:[NSLocalizedDescriptionKey:"private permission failure"])}
            saved=try recycle(location);return saved
        });XCTFail("Refused recycling became a successful Reset")}
        catch let failure as GitFailure {XCTAssertNotEqual(failure.code,0);XCTAssertEqual(failure.arguments,["reset","--hard",base,"--"]);XCTAssertNotNil(failure.standardError)}
        XCTAssertEqual(events.paths,["a"]);XCTAssertEqual(try Data(contentsOf:XCTUnwrap(saved)),Data("later a".utf8))
        XCTAssertEqual(try String(contentsOf:f.repo.root.appendingPathComponent("b"),encoding:.utf8),"later b")
        let head=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(head,original)
        guard case .issue(let issue)?=events.events.last else{return XCTFail("Precise parent recycle error missing")}
        XCTAssertFalse(issue.commandSucceeded);XCTAssertTrue(issue.message.contains("b"));XCTAssertTrue(issue.message.contains("private permission failure"))
    }
    func testMissingAndRemovedTargetsFollowUpdatedCallbackRatherThanStatusDiff()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"kept","base");let base=try await commit(f.repo,"base")
        try write(f.repo,"deleted-by-reset","later");_ = try await commit(f.repo,"later")
        try FileManager.default.removeItem(at:f.repo.root.appendingPathComponent("kept"))
        let plan=try await f.repo.prepareReset(to:base,mode:.hard),events=ResetEngineEvents()
        _ = try await f.repo.reset(plan,backend:f.backend,onNotification:events.append,recycler:{_ in XCTFail("Missing or pure-remove path was recycled");return nil})
        XCTAssertEqual(events.paths,["kept"])
        XCTAssertEqual(try String(contentsOf:f.repo.root.appendingPathComponent("kept"),encoding:.utf8),"base")
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.repo.root.appendingPathComponent("deleted-by-reset").path))
    }
    func testDirectoryAndSymbolicLinkRecyclingMovesLeafWithoutFollowingTarget()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let node="node[*]\n雪",link="link?\t雪"
        try write(f.repo,node,"file base");try write(f.repo,link,"plain base");let base=try await commit(f.repo,"base")
        try FileManager.default.removeItem(at:f.repo.root.appendingPathComponent(node))
        try FileManager.default.createDirectory(at:f.repo.root.appendingPathComponent(node),withIntermediateDirectories:true)
        try write(f.repo,node+"/child","tracked child")
        let external=f.root.appendingPathComponent("external");try Data("outside untouched".utf8).write(to:external)
        try FileManager.default.removeItem(at:f.repo.root.appendingPathComponent(link));try FileManager.default.createSymbolicLink(at:f.repo.root.appendingPathComponent(link),withDestinationURL:external)
        _ = try await commit(f.repo,"directory and link")
        let plan=try await f.repo.prepareReset(to:base,mode:.hard),recycle=try privateRecycle(f.root),events=ResetEngineEvents()
        var directoryCopy:URL?,linkCopy:URL?
        // The source callback moves the directory while libgit2's planning
        // iterator still needs to descend it. Preserve this real partial
        // failure, not an invented first-attempt transactional success.
        do {_ = try await f.repo.reset(plan,backend:f.backend,onNotification:events.append,recycler:{location in
            let saved=try recycle(location);if location.lastPathComponent==node{directoryCopy=saved};if location.lastPathComponent==link{linkCopy=saved};return saved
        });XCTFail("Directory iterator unexpectedly survived removal of its current directory")}
        catch let failure as GitFailure {XCTAssertNotEqual(failure.code,0);XCTAssertTrue(failure.message.contains("failed to open directory"));XCTAssertNotNil(failure.standardError)}
        XCTAssertEqual(try String(contentsOf:XCTUnwrap(directoryCopy).appendingPathComponent("child"),encoding:.utf8),"tracked child")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:XCTUnwrap(linkCopy).path),external.path)
        XCTAssertEqual(try String(contentsOf:external,encoding:.utf8),"outside untouched")
        XCTAssertEqual(Set(events.paths),Set([link,node]),"Source notifications survive even though later checkout planning failed")
        let unchangedHead=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(unchangedHead,plan.originalHead)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.repo.root.appendingPathComponent(node).path))
        let retry=try await f.repo.prepareReset(to:base,mode:.hard)
        _ = try await f.repo.reset(retry,backend:f.backend,recycler:{_ in XCTFail("Retry recycled an already preserved source item again");return nil})
        XCTAssertEqual(try String(contentsOf:f.repo.root.appendingPathComponent(node),encoding:.utf8),"file base")
        XCTAssertEqual(try String(contentsOf:f.repo.root.appendingPathComponent(link),encoding:.utf8),"plain base")
        let finalHead=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(finalHead,base)
        let stagedNode=try await f.repo.run(["show",":"+node]).stdout,stagedLink=try await f.repo.run(["show",":"+link]).stdout
        XCTAssertEqual(stagedNode,Data("file base".utf8));XCTAssertEqual(stagedLink,Data("plain base".utf8))
        XCTAssertEqual(try String(contentsOf:XCTUnwrap(directoryCopy).appendingPathComponent("child"),encoding:.utf8),"tracked child")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:XCTUnwrap(linkCopy).path),external.path)
        XCTAssertEqual(try String(contentsOf:external,encoding:.utf8),"outside untouched")
    }
    func testParentRecycleRefusesReplacedTargetsEscapingParentsAndMetadata()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"file","original");let location=f.repo.root.appendingPathComponent("file"),request=witness(location,path:"file")
        try FileManager.default.moveItem(at:location,to:f.root.appendingPathComponent("retained-original"));try write(f.repo,"file","replacement")
        do {try await f.repo.recycleResetPath(request,cancellation:OperationCancellation(),recycler:{_ in XCTFail("Changed inode was recycled");return nil});XCTFail("Replaced target admitted")}catch{}
        let external=f.root.appendingPathComponent("outside");try FileManager.default.createDirectory(at:external,withIntermediateDirectories:true);try Data("outside".utf8).write(to:external.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at:f.repo.root.appendingPathComponent("escape"),withDestinationURL:external)
        for path in ["escape/file",".git/config","../outside/file"] {
            let request=witness(f.repo.root.appendingPathComponent(path),path:path)
            do {try await f.repo.recycleResetPath(request,cancellation:OperationCancellation(),recycler:{_ in XCTFail("Unconfined path was recycled");return nil});XCTFail("Unsafe path admitted: \(path)")}catch{}
        }
        XCTAssertEqual(try String(contentsOf:location,encoding:.utf8),"replacement")
    }
    func testCancellationDuringRecyclePreservesSavedFileAndDrainsWithoutLateFileNotification()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"file","base");let base=try await commit(f.repo,"base")
        try write(f.repo,"file","later");let original=try await commit(f.repo,"later")
        let plan=try await f.repo.prepareReset(to:base,mode:.hard),token=OperationCancellation(),events=ResetEngineEvents(),recycle=try privateRecycle(f.root)
        var saved:URL?
        do {_ = try await f.repo.reset(plan,cancellation:token,backend:f.backend,onNotification:events.append,recycler:{location in saved=try recycle(location);token.cancel();return saved});XCTFail("Cancelled Reset succeeded")}
        catch is GitCommandCancellationFailure {} catch is OperationCancellationFailure {}
        XCTAssertTrue(events.paths.isEmpty);XCTAssertEqual(try String(contentsOf:XCTUnwrap(saved),encoding:.utf8),"later")
        let head=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(head,original)
    }
    func testResetMetadataFailurePreservesRealSuccessOrFailureAndCannotSpoofFromStderr()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"file","base");let base=try await commit(f.repo,"base")
        let plan=try await f.repo.prepareReset(to:base,mode:.mixed)
        let valid=String(decoding:try frame(["kind":"file","path":"literal\t\nfile"]),as:UTF8.self)
        for code in [0,1] {
            let fake=f.root.appendingPathComponent("metadata-helper-"+String(code)),events=ResetEngineEvents()
            let diagnostic="literal diagnostic "+String(code)+"\n"+valid
            try executable(fake,"#!/bin/sh\nprintf '%s' "+quote(diagnostic)+" >&2\nprintf '%s' "+quote(valid+"broken metadata\n")+"\nexit "+String(code)+"\n")
            do {
                let text=try await f.repo.reset(plan,onOutput:events.appendOutput,backend:.init(mask:1<<5,helperURL:fake),recycle:false,onNotification:events.append)
                XCTAssertEqual(code,0);XCTAssertEqual(text,diagnostic)
            } catch let failure as GitFailure {XCTAssertEqual(failure.code,Int32(code));XCTAssertEqual(failure.standardError,Data(diagnostic.utf8));XCTAssertEqual(failure.arguments,["reset","--mixed",base,"--"])}
            XCTAssertEqual(events.paths,["literal\t\nfile"],"stderr lookalike must not become a second file record")
            XCTAssertEqual(events.bytes,Data(diagnostic.utf8))
            guard case .issue(let issue)?=events.events.last else{return XCTFail("Metadata warning missing after actual outcome")}
            XCTAssertEqual(issue.commandSucceeded,code==0)
        }
    }
    func testSelectedRevertHonorsMergeMainlineAndExplicitRootAllowance()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"base","base");let base=try await commit(f.repo,"base")
        do {_ = try await f.repo.revertLogRevision(revision:base,backend:f.backend);XCTFail("Single-row root policy bypassed")}catch LogRevertFailure.root {}
        _ = try await f.repo.run(["switch","-c","side"]);try write(f.repo,"side","side");_ = try await commit(f.repo,"side")
        _ = try await f.repo.run(["switch","main"]);try write(f.repo,"main","main");_ = try await commit(f.repo,"main")
        _ = try await f.repo.run(["merge","--no-ff","-m","merge side","side"])
        let merge=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let result=try await f.repo.revertLogRevision(revision:merge,mainline:1,backend:f.backend)
        XCTAssertEqual(result.exitCode,0);XCTAssertFalse(FileManager.default.fileExists(atPath:f.repo.root.appendingPathComponent("side").path));XCTAssertTrue(FileManager.default.fileExists(atPath:f.repo.root.appendingPathComponent("main").path))
        let head=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(head,merge)
        _ = try await f.repo.run(["reset","--hard",base]);_ = try await f.repo.run(["revert","--quit"],successfulExitCodes:0...1)
        let rootResult=try await f.repo.revertLogRevision(revision:base,allowRoot:true,backend:f.backend)
        XCTAssertEqual(rootResult.exitCode,0)
        let staged=try await f.repo.run(["ls-files","-z"]).stdout;XCTAssertTrue(staged.isEmpty)
        let rootHead=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(rootHead,base)
    }
    func testSelectedRevertPreservesNoCommitAndSourceZeroReturnConflictState()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try write(f.repo,"file","base\n");let base=try await commit(f.repo,"base")
        try write(f.repo,"file","change\n");let changed=try await commit(f.repo,"change")
        let result=try await f.repo.revertLogRevision(revision:changed,backend:f.backend)
        XCTAssertEqual(result.exitCode,0)
        let head=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(head,changed)
        XCTAssertEqual(try String(contentsOf:f.repo.root.appendingPathComponent("file"),encoding:.utf8),"base\n")
        _ = try await f.repo.run(["reset","--hard",changed]);_ = try await f.repo.run(["revert","--quit"],successfulExitCodes:0...1)
        try write(f.repo,"file","later incompatible\n");let later=try await commit(f.repo,"later")
        let conflict=try await f.repo.revertLogRevision(revision:changed,backend:f.backend)
        XCTAssertEqual(conflict.exitCode,0,"Pinned git_revert succeeds while publishing conflict stages")
        let conflicts=try await f.repo.conflicts();XCTAssertEqual(conflicts.map(\.path),["file"])
        let after=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(after,later)
        let revertHead=try await f.repo.run(["rev-parse","REVERT_HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(revertHead,changed)
        let message=try String(contentsOf:f.repo.root.appendingPathComponent(".git/MERGE_MSG"),encoding:.utf8);XCTAssertTrue(message.contains("change"));XCTAssertFalse(base.isEmpty)
    }
}
