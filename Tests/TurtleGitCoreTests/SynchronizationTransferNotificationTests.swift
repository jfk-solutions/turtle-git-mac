// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class SynchronizationTransferNotificationTests:XCTestCase {
    private final class Receipts:@unchecked Sendable {
        private let lock=NSLock()
        private var stored:[GitTransferNotification]=[],settled:[SynchronizationCommandCompletion]=[],presented:[SynchronizationCommandPresentation]=[],sequence:[String]=[],output=Data()
        func presentation(_ value:SynchronizationCommandPresentation){lock.lock();defer{lock.unlock()};presented.append(value);sequence.append("presentation")}
        var presentations:[SynchronizationCommandPresentation]{lock.lock();defer{lock.unlock()};return presented}
        func notification(_ value:GitTransferNotification){lock.lock();defer{lock.unlock()};stored.append(value);sequence.append("notification")}
        func completion(_ value:SynchronizationCommandCompletion){lock.lock();defer{lock.unlock()};settled.append(value);sequence.append("completion")}
        func chunk(_ value:GitOutputChunk){lock.lock();defer{lock.unlock()};output.append(value.data)}
        var notifications:[GitTransferNotification]{lock.lock();defer{lock.unlock()};return stored}
        var completions:[SynchronizationCommandCompletion]{lock.lock();defer{lock.unlock()};return settled}
        var order:[String]{lock.lock();defer{lock.unlock()};return sequence}
        var bytes:Data{lock.lock();defer{lock.unlock()};return output}
        var references:[GitTransferReferenceUpdate]{notifications.compactMap{if case .reference(let value)=$0{return value};return nil}}
    }
    private struct Fixture {
        let root:URL,author:GitRepository,client:GitRepository,server:URL,git:URL,helper:URL,base:String
        var backend:GitLibGit2Configuration {.init(mask:4,helperURL:helper)}
    }
    private var git:URL {URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")}
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    private func executable(_ url:URL,_ source:String)throws {
        try Data(source.utf8).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)
    }
    private func hash(_ repo:GitRepository,_ revision:String="HEAD")async throws->String {
        try await repo.run(["rev-parse","--verify","--end-of-options",revision]).text.trimmingCharacters(in:.newlines)
    }
    private func fixture()async throws->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("sync notification 雪-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            let config=root.appendingPathComponent("global.config"),command=root.appendingPathComponent("private-git"),helper=root.appendingPathComponent("private-libgit2")
            try Data().write(to:config)
            let environment="unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="+quote(config.path)+" XDG_CONFIG_HOME="+quote(root.path)+"\n"
            try executable(command,"#!/bin/sh\n"+environment+"exec "+quote(git.path)+" \"$@\"\n")
            // Real-helper tests resolve this wrapper lazily; CLI and injected
            // failure/cancellation checks do not require a bundled helper.
            let resolved=try? GitLibGit2Configuration(mask:4).executor(for:.fetch)
            if let actual=resolved {
                try executable(helper,"#!/bin/sh\n"+environment+"exec "+quote(actual.path)+" \"$@\"\n")
            }
            let author=GitRepository(root:root.appendingPathComponent("author"),executable:command,askpass:nil,libgit2Configuration:.init(enabled:false))
            try FileManager.default.createDirectory(at:author.root,withIntermediateDirectories:true)
            _=try await author.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Sync notification QA"),("user.email","sync@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("protocol.file.allow","always")] {_=try await author.run(["config",key,value])}
            try Data("base\n".utf8).write(to:author.root.appendingPathComponent("file"));try await author.stage(["file"]);_=try await author.commit(message:"base")
            let base=try await hash(author),server=root.appendingPathComponent("server 雪.git")
            _=try await author.run(["clone","--template=","--bare","--",author.root.path,server.path])
            _=try await author.run(["remote","add","origin",server.path])
            let client=GitRepository(root:root.appendingPathComponent("client"),executable:command,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await author.run(["clone","--template=","--",server.path,client.root.path])
            for(key,value)in[("core.hooksPath","/dev/null"),("pull.rebase","false"),("pull.ff","only")] {_=try await client.run(["config",key,value])}
            return Fixture(root:root,author:author,client:client,server:server,git:command,helper:helper,base:base)
        }catch{try? FileManager.default.removeItem(at:root);throw error}
    }
    private func options(_ action:SynchronizationTransportAction = .fetch)->SynchronizationTransportOptions {
        var value=SynchronizationTransportOptions(action:action);value.localBranch="main";value.remote="origin";value.remoteBranch="main";return value
    }
    private func advance(_ fixture:Fixture,serial:Int=1)async throws->String {
        try Data("incoming \(serial)\n".utf8).write(to:fixture.author.root.appendingPathComponent("incoming 雪"))
        try await fixture.author.stage(["incoming 雪"]);_=try await fixture.author.commit(message:"incoming \(serial)")
        _=try await fixture.author.run(["push","origin","main"]);return try await hash(fixture.author)
    }
    func testSelectedSyncFetchFamilyDeliversRealReferenceRowsBeforeCompletionWithoutTouchingIndexOrHead()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        guard FileManager.default.isExecutableFile(atPath:f.helper.path) else{throw GitLibGit2Failure.runtimeMissing}
        let next=try await advance(f),index=try Data(contentsOf:f.client.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:f.client.root.appendingPathComponent(".git/config"))
        var expectedNew=next
        for action in [SynchronizationTransportAction.fetch,.fetchAllBranches,.fetchAndRebase] {
            // Explicit libgit2 refspecs omit unchanged callbacks; exercise a
            // genuine second update for Fetch & Rebase. Configured Fetch All
            // above retains the source Same notification coverage.
            if action == .fetchAndRebase {expectedNew=try await advance(f,serial:2)}
            let plan=try await f.client.synchronizationTransportPlan(options(action)),receipts=Receipts()
            let result=try await f.client.synchronize(plan,onOutput:receipts.chunk,onCommandFinished:receipts.completion,backend:f.backend,onNotification:receipts.notification,onCommandPresentation:receipts.presentation)
            let main=try XCTUnwrap(receipts.references.first{$0.reference=="refs/remotes/origin/main"})
            XCTAssertEqual(main.repositoryPath,"");XCTAssertEqual(main.newHash,expectedNew)
            XCTAssertEqual(main.oldHash,action == .fetch ? f.base:next)
            XCTAssertEqual(main.change,action == .fetchAllBranches ? .same:.forward)
            XCTAssertEqual(main.count,action == .fetchAllBranches ? nil:1)
            XCTAssertEqual(receipts.completions.count,1);XCTAssertTrue(try XCTUnwrap(receipts.completions.first).success)
            XCTAssertEqual(receipts.presentations,[.transferNotifications]);XCTAssertEqual(receipts.order.first,"presentation")
            XCTAssertEqual(receipts.order.last,"completion");XCTAssertFalse(receipts.order.dropLast().contains("completion"))
            XCTAssertNil(receipts.bytes.range(of:GitTransferNotificationDecoder.prefix))
            XCTAssertNil(result.command.stdout.range(of:GitTransferNotificationDecoder.prefix))
            if action == .fetchAndRebase {XCTAssertEqual(result.rebaseTarget,expectedNew)}
        }
        XCTAssertEqual(try Data(contentsOf:f.client.root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:f.client.root.appendingPathComponent(".git/config")),config)
        let head=try await hash(f.client);XCTAssertEqual(head,f.base)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.client.root.appendingPathComponent("incoming 雪").path))
    }
    func testSyncCLINeverRequestsOrInventsTransferMetadata()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let next=try await advance(f),plan=try await f.client.synchronizationTransportPlan(options()),receipts=Receipts()
        let result=try await f.client.synchronize(plan,onOutput:receipts.chunk,onCommandFinished:receipts.completion,backend:.init(enabled:false,helperURL:f.root.appendingPathComponent("missing-helper")),onNotification:receipts.notification,onCommandPresentation:receipts.presentation)
        XCTAssertEqual(receipts.presentations,[.text]);XCTAssertEqual(receipts.order,["presentation","completion"])
        XCTAssertTrue(receipts.notifications.isEmpty);XCTAssertEqual(receipts.completions.count,1)
        XCTAssertTrue(try XCTUnwrap(receipts.completions.first).success)
        XCTAssertFalse(receipts.bytes.isEmpty);XCTAssertNil(receipts.bytes.range(of:GitTransferNotificationDecoder.prefix))
        XCTAssertEqual(result.executedArguments,plan.arguments)
        let fetched=try await hash(f.client,"refs/remotes/origin/main");XCTAssertEqual(fetched,next)
    }
    func testApprovedCheckoutContinuationRetainsCLIPullWithoutFetchMetadata()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let next=try await advance(f),plan=try await f.client.synchronizationTransportPlan(options(.pull))
        let checkout=try await f.client.synchronizationPullCheckout(plan),receipts=Receipts()
        let result=try await f.client.synchronize(checkout,onOutput:receipts.chunk,onCommandFinished:receipts.completion,backend:.init(mask:4,helperURL:f.root.appendingPathComponent("unused-helper")),onNotification:receipts.notification)
        XCTAssertEqual(result.executedArguments.first,"pull");XCTAssertTrue(receipts.notifications.isEmpty)
        XCTAssertEqual(receipts.completions.count,1);XCTAssertTrue(try XCTUnwrap(receipts.completions.first).success)
        let head=try await hash(f.client);XCTAssertEqual(head,next)
    }
    func testActualCommandPresentationFollowsPostCheckoutRebaseConfigurationRatherThanInitialPullPlan()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        guard FileManager.default.isExecutableFile(atPath:f.helper.path) else{throw GitLibGit2Failure.runtimeMissing}
        let next=try await advance(f),plan=try await f.client.synchronizationTransportPlan(options(.pull))
        XCTAssertEqual(plan.arguments.first,"pull");XCTAssertEqual(plan.rebaseMode,.none)
        let checkout=try await f.client.synchronizationPullCheckout(plan),receipts=Receipts()
        let result=try await f.client.synchronize(checkout,prepareTransport:{_,token in
            _=try await f.client.run(["config","branch.main.rebase","merges"],cancellation:token)
            return nil
        },onCommandFinished:receipts.completion,backend:f.backend,onNotification:receipts.notification,onCommandPresentation:receipts.presentation)
        XCTAssertEqual(result.executedArguments.first,"fetch");XCTAssertEqual(result.rebaseMode,.preserveMerges);XCTAssertEqual(result.rebaseTarget,next)
        XCTAssertEqual(receipts.presentations,[.transferNotifications]);XCTAssertEqual(receipts.order.first,"presentation");XCTAssertEqual(receipts.order.last,"completion")
        XCTAssertTrue(receipts.references.contains{$0.reference=="refs/remotes/origin/main" && $0.oldHash==f.base && $0.newHash==next})
        // A later actual command announces text explicitly even when its
        // original action/captured helper mask could suggest a structured log.
        let reversePlan=try await f.client.synchronizationTransportPlan(options(.pull)),reverse=Receipts()
        XCTAssertEqual(reversePlan.arguments.first,"fetch")
        _=try await f.client.synchronize(reversePlan,prepareTransport:{_,token in
            _=try await f.client.run(["config","branch.main.rebase","false"],cancellation:token)
            return nil
        },onCommandFinished:reverse.completion,backend:f.backend,onNotification:reverse.notification,onCommandPresentation:reverse.presentation)
        XCTAssertEqual(reverse.presentations,[.text]);XCTAssertTrue(reverse.notifications.isEmpty);XCTAssertEqual(reverse.order,["presentation","completion"])
    }
    func testSyncUnavailableRemoteReportsRealFailureWithoutInventedRows()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        guard FileManager.default.isExecutableFile(atPath:f.helper.path) else{throw GitLibGit2Failure.runtimeMissing}
        var input=options();input.remote=f.root.appendingPathComponent("unavailable.git").path
        let plan=try await f.client.synchronizationTransportPlan(input),receipts=Receipts(),before=try await f.client.run(["show-ref"]).stdout
        do {_=try await f.client.synchronize(plan,onOutput:receipts.chunk,onCommandFinished:receipts.completion,backend:f.backend,onNotification:receipts.notification);XCTFail("Unavailable remote succeeded")}
        catch let error as GitFailure {XCTAssertNotEqual(error.code,0);XCTAssertEqual(receipts.completions.first?.exitCode,error.code)}
        XCTAssertTrue(receipts.references.isEmpty);XCTAssertEqual(receipts.completions.count,1)
        XCTAssertFalse(try XCTUnwrap(receipts.completions.first).success)
        let after=try await f.client.run(["show-ref"]).stdout;XCTAssertEqual(before,after)
    }
    func testSyncMissingLiteralBranchRetainsActualHelperNoMatchOutcomeWithoutInventedRows()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        guard FileManager.default.isExecutableFile(atPath:f.helper.path) else{throw GitLibGit2Failure.runtimeMissing}
        var input=options();input.remoteBranch="does-not-exist"
        let plan=try await f.client.synchronizationTransportPlan(input),receipts=Receipts()
        let before=try await f.client.run(["show-ref"]).stdout,config=try Data(contentsOf:f.client.root.appendingPathComponent(".git/config"))
        // libgit2 accepts an unmatched explicit refspec with no callback. Sync
        // retains that real outcome rather than manufacturing rows/failures.
        // The Mac per-operation spec deliberately does not persist the source
        // FetchProgressCommand's remote_add_fetch configuration mutation.
        let result=try await f.client.synchronize(plan,onCommandFinished:receipts.completion,backend:f.backend,onNotification:receipts.notification,onCommandPresentation:receipts.presentation)
        XCTAssertEqual(result.command.exitCode,0);XCTAssertEqual(result.executedArguments,plan.arguments)
        XCTAssertTrue(receipts.notifications.isEmpty);XCTAssertEqual(receipts.presentations,[.transferNotifications])
        XCTAssertEqual(receipts.order,["presentation","completion"]);XCTAssertEqual(receipts.completions.first?.success,true)
        let after=try await f.client.run(["show-ref"]).stdout;XCTAssertEqual(before,after)
        XCTAssertEqual(try Data(contentsOf:f.client.root.appendingPathComponent(".git/config")),config)
    }
    private func referenceFrame(old:String,new:String)throws->Data {
        let body:[String:Any]=["kind":"reference","repositoryPath":"","reference":"refs/remotes/origin/main","oldHash":old,"newHash":new,"change":"forward","count":1]
        return GitTransferNotificationDecoder.prefix+(try JSONSerialization.data(withJSONObject:body,options:.sortedKeys)).base64EncodedData()+Data([10])
    }
    func testSyncMetadataWarningPreservesPartialRowsAndRealExitBeforeCompletion()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let plan=try await f.client.synchronizationTransportPlan(options()),metadata=try referenceFrame(old:f.base,new:String(repeating:"1",count:40))
        let injected=f.root.appendingPathComponent("metadata-helper"),diagnostic="private Sync diagnostic 雪\n"
        for code in [0,7] {
            try executable(injected,"#!/bin/sh\nprintf '%s' "+quote(String(decoding:metadata,as:UTF8.self))+"\nprintf '%s\\n' 'invalid result frame'\nprintf '%s' "+quote(diagnostic)+" >&2\nexit \(code)\n")
            let receipts=Receipts()
            do {let result=try await f.client.synchronize(plan,onOutput:receipts.chunk,onCommandFinished:receipts.completion,backend:.init(mask:4,helperURL:injected),onNotification:receipts.notification);XCTAssertEqual(code,0);XCTAssertEqual(result.command.text,diagnostic)}
            catch let error as GitFailure {XCTAssertEqual(code,7);XCTAssertEqual(error.code,Int32(code));XCTAssertEqual(error.message,diagnostic);XCTAssertEqual(error.arguments,plan.arguments)}
            XCTAssertEqual(receipts.bytes,Data(diagnostic.utf8));XCTAssertEqual(receipts.references.count,1)
            guard case .issue(let issue)?=receipts.notifications.last else{return XCTFail("Drained metadata warning missing")}
            XCTAssertEqual(issue.commandSucceeded,code==0);XCTAssertEqual(receipts.order,["notification","notification","completion"])
            XCTAssertEqual(receipts.completions.count,1);XCTAssertEqual(receipts.completions.first?.success,code==0)
        }
    }
    func testSyncCancellationRetainsAcceptedRowsAndSettlesOnceAfterHelperExit()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let plan=try await f.client.synchronizationTransportPlan(options()),metadata=try referenceFrame(old:f.base,new:String(repeating:"1",count:40))
        let injected=f.root.appendingPathComponent("held-helper"),ready=f.root.appendingPathComponent("ready")
        try executable(injected,"#!/bin/sh\nprintf '%s' "+quote(String(decoding:metadata,as:UTF8.self))+"\n: > "+quote(ready.path)+"\nwhile :; do /bin/sleep 1; done\n")
        let receipts=Receipts(),token=OperationCancellation()
        let operation=Task {try await f.client.synchronize(plan,cancellation:token,onOutput:receipts.chunk,onCommandFinished:receipts.completion,backend:.init(mask:4,helperURL:injected),onNotification:receipts.notification)}
        do {
            for _ in 0..<1000 {if FileManager.default.fileExists(atPath:ready.path) && !receipts.references.isEmpty {break};try await Task.sleep(nanoseconds:5_000_000)}
            XCTAssertTrue(FileManager.default.fileExists(atPath:ready.path));XCTAssertEqual(receipts.references.count,1);XCTAssertTrue(receipts.completions.isEmpty)
            token.cancel()
            do {_=try await operation.value;XCTFail("Cancelled Sync fetch succeeded")}catch {}
        }catch{token.cancel();_=await operation.result;throw error}
        XCTAssertEqual(receipts.references.count,1);XCTAssertEqual(receipts.completions.count,1)
        XCTAssertTrue(try XCTUnwrap(receipts.completions.first).cancelled);XCTAssertEqual(receipts.order,["notification","completion"])
        let before=Receipts(),cancelled=OperationCancellation();cancelled.cancel()
        do {_=try await f.client.synchronize(plan,cancellation:cancelled,onCommandFinished:before.completion,backend:.init(mask:4,helperURL:injected),onNotification:before.notification);XCTFail("Pre-cancelled Sync started")}
        catch {}
        XCTAssertTrue(before.notifications.isEmpty);XCTAssertTrue(before.completions.isEmpty)
    }
}
