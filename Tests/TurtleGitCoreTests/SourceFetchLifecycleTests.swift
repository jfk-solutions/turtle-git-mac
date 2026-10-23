// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

/// The pinned source loads the named remote BEFORE appending the requested
/// refspec to config, then fetches NULL specs on that already-loaded object.
final class SourceFetchLifecycleTests:XCTestCase {
    private final class Receipt:@unchecked Sendable {
        private let lock=NSLock();private var events:[GitTransferNotification]=[],finished:[SynchronizationCommandCompletion]=[],sequence:[String]=[]
        func event(_ value:GitTransferNotification){lock.lock();defer{lock.unlock()};events.append(value);sequence.append("event")}
        func finish(_ value:SynchronizationCommandCompletion){lock.lock();defer{lock.unlock()};finished.append(value);sequence.append("completion")}
        var refs:[GitTransferReferenceUpdate]{lock.lock();defer{lock.unlock()};return events.compactMap{if case .reference(let v)=$0{return v};return nil}}
        var completions:[SynchronizationCommandCompletion]{lock.lock();defer{lock.unlock()};return finished}
        var order:[String]{lock.lock();defer{lock.unlock()};return sequence}
    }
    private struct Fixture {
        let root:URL,source:GitRepository,client:GitRepository,server:URL,helper:URL,base:String,side:String
        var backend:GitLibGit2Configuration{.init(mask:4,helperURL:helper)}
        var qualified:String{"refs/heads/side:refs/remotes/origin/side"}
        var mainSpec:String{"+refs/heads/main:refs/remotes/origin/main"}
    }
    private func quote(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    private func fixture()async throws->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("source-fetch 雪-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            let realGit=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
            let realHelper=try XCTUnwrap(GitLibGit2Configuration(mask:4).executor(for:.fetch))
            let config=root.appendingPathComponent("global.config"),git=root.appendingPathComponent("private-git"),helper=root.appendingPathComponent("private-helper")
            try Data().write(to:config)
            let env="unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="+quote(config.path)+" HOME="+quote(root.path)+" XDG_CONFIG_HOME="+quote(root.path)+"\n"
            for(path,actual)in[(git,realGit),(helper,realHelper)] {try Data(("#!/bin/sh\n"+env+"exec "+quote(actual.path)+" \"$@\"\n").utf8).write(to:path);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path)}
            let source=GitRepository(root:root.appendingPathComponent("author"),executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            try FileManager.default.createDirectory(at:source.root,withIntermediateDirectories:true)
            _=try await source.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Source fetch QA"),("user.email","source-fetch@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("protocol.file.allow","always")] {_=try await source.run(["config",key,value])}
            try Data("base\n".utf8).write(to:source.root.appendingPathComponent("file"));try await source.stage(["file"]);_=try await source.commit(message:"base")
            let base=try await hash(source,"HEAD"),server=root.appendingPathComponent("origin.git")
            _=try await source.run(["clone","--bare","--template=","--",source.root.path,server.path])
            let client=GitRepository(root:root.appendingPathComponent("client"),executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await source.run(["clone","--template=","--",server.path,client.root.path])
            _=try await source.run(["switch","-c","side"]);try Data("side only\n".utf8).write(to:source.root.appendingPathComponent("side"));try await source.stage(["side"]);_=try await source.commit(message:"side only")
            let side=try await hash(source,"HEAD");_=try await source.run(["push",server.path,"side"])
            _=try await client.run(["config","--replace-all","remote.origin.fetch","+refs/heads/main:refs/remotes/origin/main"])
            return Fixture(root:root,source:source,client:client,server:server,helper:helper,base:base,side:side)
        }catch{try? FileManager.default.removeItem(at:root);throw error}
    }
    private func hash(_ repo:GitRepository,_ revision:String)async throws->String {try await repo.run(["rev-parse","--verify","--end-of-options",revision]).text.trimmingCharacters(in:.newlines)}
    private func specs(_ repo:GitRepository)async throws->[String] {try await repo.run(["config","--get-all","remote.origin.fetch"]).text.split(separator:"\n").map(String.init)}
    private func sync(_ repo:GitRepository,_ backend:GitLibGit2Configuration,branch:String="side",action:SynchronizationTransportAction = .fetch,receipt:Receipt)async throws->SynchronizationTransportResult {
        var options=SynchronizationTransportOptions(action:action);options.localBranch="main";options.remote="origin";options.remoteBranch=branch
        let plan=try await repo.synchronizationTransportPlan(options)
        return try await repo.synchronize(plan,onCommandFinished:{receipt.finish($0)},backend:backend,onNotification:{receipt.event($0)})
    }
    private func absent(_ repo:GitRepository,_ revision:String)async throws->Bool {try await repo.run(["rev-parse","--verify","--end-of-options",revision],successfulExitCodes:0...128).exitCode != 0}
    private func assertCompleted(_ receipt:Receipt,file:StaticString = #filePath,line:UInt = #line)throws {XCTAssertEqual(receipt.completions.count,1,file:file,line:line);XCTAssertEqual(receipt.completions.first?.success,true,file:file,line:line);XCTAssertEqual(receipt.order.last,"completion",file:file,line:line)}

    func testQualifiedSyncSpecPersistsButFirstFetchUsesLoadedNarrowSpecAndNextInvocationActivatesIt()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let head=try await hash(f.client,"HEAD"),index=try Data(contentsOf:f.client.root.appendingPathComponent(".git/index"))
        let first=Receipt();_=try await sync(f.client,f.backend,receipt:first)
        let firstSpecs=try await specs(f.client);XCTAssertEqual(firstSpecs,[f.mainSpec,f.qualified]);try assertCompleted(first)
        XCTAssertTrue(first.refs.contains{$0.reference=="refs/remotes/origin/main" && $0.change == .same && $0.oldHash==f.base && $0.newHash==f.base})
        XCTAssertFalse(first.refs.contains{$0.reference=="refs/remotes/origin/side"});let firstAbsent=try await absent(f.client,"refs/remotes/origin/side");XCTAssertTrue(firstAbsent)
        let second=Receipt();_=try await sync(f.client,f.backend,receipt:second)
        let secondSpecs=try await specs(f.client);XCTAssertEqual(secondSpecs,[f.mainSpec,f.qualified,f.qualified]);try assertCompleted(second)
        XCTAssertTrue(second.refs.contains{$0.reference=="refs/remotes/origin/side" && $0.change == .new && $0.newHash==f.side})
        let side=try await hash(f.client,"refs/remotes/origin/side"),afterHead=try await hash(f.client,"HEAD");XCTAssertEqual(side,f.side);XCTAssertEqual(afterHead,head);XCTAssertEqual(try Data(contentsOf:f.client.root.appendingPathComponent(".git/index")),index)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.client.root.appendingPathComponent("side").path))
    }
    func testFetchAllUsesLoadedConfigurationWithoutAppendingAndReportsWildcardSame()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _=try await f.client.run(["config","--replace-all","remote.origin.fetch","+refs/heads/*:refs/remotes/origin/*"])
        let before=try Data(contentsOf:f.client.root.appendingPathComponent(".git/config")),receipt=Receipt()
        _=try await sync(f.client,f.backend,action:.fetchAllBranches,receipt:receipt);try assertCompleted(receipt)
        XCTAssertTrue(receipt.refs.contains{$0.reference=="refs/remotes/origin/main" && $0.change == .same});XCTAssertTrue(receipt.refs.contains{$0.reference=="refs/remotes/origin/side" && $0.newHash==f.side})
        XCTAssertEqual(try Data(contentsOf:f.client.root.appendingPathComponent(".git/config")),before)
    }
    func testStandaloneRawBranchPersistsVerbatimAndActivatesOnlyOnLaterLoadedRemote()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var options=FetchOptions();options.remote="origin";options.namedRemoteFetchAll=false;options.branch="side"
        let first=Receipt();_=try await f.client.fetch(options,backend:f.backend,onNotification:{first.event($0)})
        let firstSpecs=try await specs(f.client);XCTAssertEqual(firstSpecs,[f.mainSpec,"side"]);XCTAssertFalse(first.refs.contains{$0.newHash==f.side})
        let firstObject=try await f.client.run(["cat-file","-e",f.side],successfulExitCodes:0...128);XCTAssertNotEqual(firstObject.exitCode,0)
        options.namedRemoteFetchAll=true;options.branch=""
        let second=Receipt();_=try await f.client.fetch(options,backend:f.backend,onNotification:{second.event($0)})
        let nextSpecs=try await specs(f.client);XCTAssertEqual(nextSpecs,firstSpecs)
        let object=try await f.client.run(["cat-file","-e",f.side]);XCTAssertEqual(object.exitCode,0)
        let fetchHead=try String(contentsOf:f.client.root.appendingPathComponent(".git/FETCH_HEAD"),encoding:.utf8);XCTAssertTrue(fetchHead.contains(f.side))
        let trackingAbsent=try await absent(f.client,"refs/remotes/origin/side");XCTAssertTrue(trackingAbsent,"Raw source-only branch must not invent a destination ref")
    }
    func testNamedRemoteFailureRetainsPersistedAdditionBeforeRealFailureAndCompletion()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _=try await f.client.run(["config","remote.origin.url",f.root.appendingPathComponent("unavailable.git").path])
        let receipt=Receipt(),head=try await hash(f.client,"HEAD")
        do{_=try await sync(f.client,f.backend,receipt:receipt);XCTFail("Unavailable named remote succeeded")}catch let error as GitFailure{XCTAssertNotEqual(error.code,0);XCTAssertEqual(receipt.completions.first?.exitCode,error.code)}
        let after=try await specs(f.client);XCTAssertEqual(after,[f.mainSpec,f.qualified]);XCTAssertTrue(receipt.refs.isEmpty);XCTAssertEqual(receipt.completions.count,1);XCTAssertEqual(receipt.completions.first?.success,false);XCTAssertEqual(receipt.order.last,"completion")
        let current=try await hash(f.client,"HEAD");XCTAssertEqual(current,head)
    }
    func testLinkedWorktreePersistsCommonRemoteConfigButKeepsIndependentCheckout()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let path=f.root.appendingPathComponent("linked")
        _=try await f.client.run(["worktree","add","--detach","--",path.path,"HEAD"])
        let linked=GitRepository(root:path,executable:f.client.executable,askpass:nil,libgit2Configuration:.init(enabled:false)),receipt=Receipt()
        _=try await sync(linked,f.backend,receipt:receipt);try assertCompleted(receipt)
        let shared=try await specs(f.client),fromLinked=try await specs(linked);XCTAssertEqual(shared,[f.mainSpec,f.qualified]);XCTAssertEqual(fromLinked,shared)
        let head=try await hash(linked,"HEAD");XCTAssertEqual(head,f.base);XCTAssertFalse(FileManager.default.fileExists(atPath:path.appendingPathComponent("side").path))
        let next=Receipt();_=try await sync(f.client,f.backend,action:.fetchAllBranches,receipt:next);try assertCompleted(next)
        XCTAssertTrue(next.refs.contains{$0.reference=="refs/remotes/origin/side" && $0.newHash==f.side})
    }
    func testCLISyncAndStandaloneFetchLeaveConfiguredSpecsUntouched()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let config=try Data(contentsOf:f.client.root.appendingPathComponent(".git/config")),receipt=Receipt(),cli=GitLibGit2Configuration(enabled:false)
        _=try await sync(f.client,cli,receipt:receipt);try assertCompleted(receipt);XCTAssertTrue(receipt.refs.isEmpty)
        var options=FetchOptions();options.remote="origin";options.namedRemoteFetchAll=false;options.branch="side"
        _=try await f.client.fetch(options,backend:cli,onNotification:{receipt.event($0)})
        XCTAssertEqual(try Data(contentsOf:f.client.root.appendingPathComponent(".git/config")),config);let after=try await specs(f.client);XCTAssertEqual(after,[f.mainSpec]);XCTAssertTrue(receipt.refs.isEmpty)
    }
    func testStandaloneSourceRebaseUsesSelectedRemoteBranchInsteadOfConfiguredMainFetchHead()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _=try await f.client.run(["config","--replace-all","remote.origin.fetch","+refs/heads/*:refs/remotes/origin/*"])
        var options=FetchOptions();options.remote="origin";options.branch="side"
        let receipt=Receipt(),result=try await f.client.fetchForRebase(options,backend:f.backend,onNotification:{receipt.event($0)})
        let fetchHead=try await hash(f.client,"FETCH_HEAD"),head=try await hash(f.client,"HEAD")
        XCTAssertEqual(fetchHead,f.base,"Configured merge FETCH_HEAD fixture must discriminate from selected side")
        XCTAssertEqual(result.upstream,f.side);XCTAssertEqual(result.oldUpstream,"");XCTAssertEqual(result.head,f.base);XCTAssertTrue(result.canFastForward);XCTAssertFalse(result.currentIsUpToDate)
        XCTAssertEqual(head,f.base);XCTAssertTrue(receipt.refs.contains{$0.reference=="refs/remotes/origin/side" && $0.newHash==f.side})
        let after=try await specs(f.client);XCTAssertEqual(after,["+refs/heads/*:refs/remotes/origin/*","side"])
        _=try await f.client.run(["update-ref","refs/remotes/origin/side",f.base]);XCTAssertEqual(result.upstream,f.side,"Later reference mutation changed immutable accepted Rebase target")
    }
    func testStandaloneSourceRebaseDoesNotUseUnrelatedFetchHeadWhenSelectedTrackingRefWasNotLoaded()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        var options=FetchOptions();options.remote="origin";options.branch="side"
        let receipt=Receipt()
        do{_=try await f.client.fetchForRebase(options,backend:f.backend,onNotification:{receipt.event($0)});XCTFail("Narrow source fetch rebased toward unrelated configured main")}catch let error as FetchRebaseExecutionFailure{XCTAssertFalse(error.details.isEmpty);XCTAssertNotNil(error.commandFailure)}
        let after=try await specs(f.client),fetchHead=try await hash(f.client,"FETCH_HEAD"),head=try await hash(f.client,"HEAD")
        XCTAssertEqual(after,[f.mainSpec,"side"]);XCTAssertEqual(fetchHead,f.base);XCTAssertEqual(head,f.base)
        XCTAssertTrue(receipt.refs.contains{$0.reference=="refs/remotes/origin/main" && $0.change == .same});XCTAssertFalse(receipt.refs.contains{$0.reference=="refs/remotes/origin/side"})
        let trackingAbsent=try await absent(f.client,"refs/remotes/origin/side");XCTAssertTrue(trackingAbsent)
    }
    func testPreCancelledFetchDoesNotAppendConfigurationOrPublishMetadata()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let before=try Data(contentsOf:f.client.root.appendingPathComponent(".git/config")),token=OperationCancellation(),receipt=Receipt();token.cancel()
        var options=FetchOptions();options.remote="origin";options.branch="side";options.namedRemoteFetchAll=false
        do{_=try await f.client.fetch(options,cancellation:token,backend:f.backend,onNotification:{receipt.event($0)});XCTFail("Pre-cancelled source fetch started")}catch{}
        XCTAssertEqual(try Data(contentsOf:f.client.root.appendingPathComponent(".git/config")),before);XCTAssertTrue(receipt.refs.isEmpty)
    }

}
