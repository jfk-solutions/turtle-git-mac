// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

private final class TransferReceipts:@unchecked Sendable {
    private let lock=NSLock()
    private var storage:[GitTransferNotification]=[],output=Data()
    func append(_ event:GitTransferNotification){lock.lock();storage.append(event);lock.unlock()}
    func appendOutput(_ chunk:GitOutputChunk){lock.lock();output.append(chunk.data);lock.unlock()}
    var events:[GitTransferNotification]{lock.lock();defer{lock.unlock()};return storage}
    var bytes:Data{lock.lock();defer{lock.unlock()};return output}
    var references:[GitTransferReferenceUpdate]{events.compactMap{if case .reference(let value)=$0{return value};return nil}}
    var files:[GitTransferCheckout]{events.compactMap{if case .checkout(let value)=$0{return value};return nil}}
}
final class GitTransferNotificationTests:XCTestCase {
    private let old=String(repeating:"1",count:40),new=String(repeating:"2",count:40)
    private func frame(_ body:[String:Any])throws->Data {GitTransferNotificationDecoder.prefix+(try JSONSerialization.data(withJSONObject:body,options:.sortedKeys)).base64EncodedData()+Data([10])}
    private func reference(_ change:String="forward",count:Any?=1)->[String:Any] {
        var value:[String:Any]=["kind":"reference","repositoryPath":"","reference":"refs/remotes/origin/main","oldHash":old,"newHash":new,"change":change]
        if let count{value["count"]=count};return value
    }
    private func checkout(_ path:String="file 雪\n\t[*].txt",repository:String="module/inner")->[String:Any] {["kind":"checkout","repositoryPath":repository,"path":path,"completed":1,"total":1000]}
    func testTransferFramesPreserveFullHashesLiteralPathsAndRepeatedPercentages()throws {
        var second=checkout("decomposed-cafe\u{301}.txt");second["completed"]=2
        let bytes=try frame(reference())+frame(checkout("composed-café.txt"))+frame(second)
        for size in [1,7,bytes.count] {
            let decoder=GitTransferNotificationDecoder();var events:[GitTransferNotification]=[]
            for offset in stride(from:0,to:bytes.count,by:size){try decoder.append(bytes.subdata(in:offset..<min(bytes.count,offset+size))){events.append($0)}}
            try decoder.finish();XCTAssertEqual(events.count,3)
            guard case .reference(let ref)=events[0],case .checkout(let first)=events[1],case .checkout(let last)=events[2] else{return XCTFail("Typed result order changed")}
            XCTAssertEqual(ref.oldHash,old);XCTAssertEqual(ref.newHash,new);XCTAssertEqual(ref.count,1)
            XCTAssertEqual(first.repositoryPath,"module/inner");XCTAssertTrue(last.path.utf8.elementsEqual("decomposed-cafe\u{301}.txt".utf8));XCTAssertEqual(last.completed,2)
        }
        for length in [40,64] {
            var zero=reference("unclassified",count:nil);zero["oldHash"]=String(repeating:"0",count:length);zero["newHash"]=String(repeating:"0",count:length)
            var values:[GitTransferNotification]=[];try GitTransferNotificationDecoder().append(frame(zero)){values.append($0)}
            XCTAssertEqual(values.count,1,"Both-zero update should retain empty source classification")
        }
        let decoder=GitTransferNotificationDecoder();var literal:[GitTransferNotification]=[]
        try decoder.append(frame(checkout())){literal.append($0)}
        guard case .checkout(let file)?=literal.first else{return XCTFail("Literal checkout missing")}
        XCTAssertEqual(Array(file.path.utf8),Array("file 雪\n\t[*].txt".utf8))
    }
    func testTransferDecoderRejectsUnsafeAndMalformedRecordsWithoutDiscardingEarlierReceipts()throws {
        var cases:[[String:Any]]=[]
        for path in ["../escape","/absolute","a//b","a/.Git/item",""] {cases.append(checkout(path))}
        cases.append(checkout("file",repository:"../child"))
        var bad=reference();bad["reference"]="refs/heads/a..b";cases.append(bad)
        bad=reference();bad["oldHash"]="12345678";cases.append(bad)
        bad=reference();bad["count"]=0;cases.append(bad)
        bad=reference("same",count:nil);cases.append(bad)
        bad=reference("unclassified",count:1);cases.append(bad)
        bad=reference();bad["count"]=true;cases.append(bad)
        bad=checkout();bad["completed"]=1001;cases.append(bad)
        bad=checkout();bad["total"]=0;cases.append(bad)
        bad=checkout();bad["unexpected"]="ignored";cases.append(bad)
        cases.append(["kind":"issue","repositoryPath":"","message":"forged","commandSucceeded":true])
        for body in cases {
            let decoder=GitTransferNotificationDecoder();var events:[GitTransferNotification]=[]
            XCTAssertThrowsError(try decoder.append(frame(reference())+frame(body)){events.append($0)})
            XCTAssertEqual(events.count,1,"Earlier verified receipt was discarded")
        }
        let incomplete=GitTransferNotificationDecoder();try incomplete.append(Data("TurtleGit Transfer v1:AAAA".utf8)){_ in};XCTAssertThrowsError(try incomplete.finish())
        XCTAssertThrowsError(try GitTransferNotificationDecoder().append(Data("TurtleGit Transfer v2:e30=\n".utf8)){_ in})
        let invalidUTF8=GitTransferNotificationDecoder.prefix+Data([255]).base64EncodedData()+Data([10])
        XCTAssertThrowsError(try GitTransferNotificationDecoder().append(invalidUTF8){_ in})
        XCTAssertThrowsError(try GitTransferNotificationDecoder().append(Data(repeating:65,count:GitTransferNotificationDecoder.maximumFrame+1)){_ in})
    }
    func testTransferReceiverIgnoresStderrAndReportsMetadataIssueWithoutChangingOutcome()throws {
        let values=TransferReceipts(),token=OperationCancellation(),receiver=GitTransferNotificationReceiver(cancellation:token,callback:values.append)
        let valid=try frame(reference())
        receiver.consume(.init(stream:.stderr,data:valid));XCTAssertTrue(values.events.isEmpty)
        receiver.consume(.init(stream:.stdout,data:valid+Data("secret remote diagnostic\n".utf8)+valid));receiver.finish(commandSucceeded:true);receiver.finish(commandSucceeded:false)
        XCTAssertEqual(values.events.count,2)
        guard case .issue(let issue)?=values.events.last else{return XCTFail("Metadata warning missing")}
        XCTAssertTrue(issue.commandSucceeded);XCTAssertFalse(issue.message.contains("secret"))
        let cancelled=TransferReceipts(),cancelToken=OperationCancellation(),late=GitTransferNotificationReceiver(cancellation:cancelToken,callback:cancelled.append)
        cancelToken.cancel();late.consume(.init(stream:.stdout,data:valid));late.finish(commandSucceeded:false);XCTAssertTrue(cancelled.events.isEmpty)
    }
    private var git:URL {URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")}
    private func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    private func executable(_ url:URL,_ text:String)throws {try Data(text.utf8).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)}
    private struct Fixture {
        let root:URL,source:GitRepository,runner:GitRepository,helper:URL,git:URL
        var backend:GitLibGit2Configuration {.init(mask:6,helperURL:helper)}
    }
    private func fixture()async throws->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("transfer receipts 雪-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            let config=root.appendingPathComponent("global.config");try Data().write(to:config)
            let environment="unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="+quote(config.path)+" XDG_CONFIG_HOME="+quote(root.path)+"\n"
            let command=root.appendingPathComponent("private-git"),helper=root.appendingPathComponent("private-libgit2")
            try executable(command,"#!/bin/sh\n"+environment+"exec "+quote(git.path)+" \"$@\"\n")
            let actual=try XCTUnwrap(GitLibGit2Configuration(mask:6).executor(for:.clone))
            try executable(helper,"#!/bin/sh\n"+environment+"exec "+quote(actual.path)+" \"$@\"\n")
            let source=root.appendingPathComponent("source");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
            let repository=GitRepository(root:source,executable:command,askpass:nil);try await initialize(repository)
            return Fixture(root:root,source:repository,runner:GitRepository(root:root,executable:command,askpass:nil),helper:helper,git:command)
        }catch{try? FileManager.default.removeItem(at:root);throw error}
    }
    private func initialize(_ repo:GitRepository)async throws {
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Transfer QA"),("user.email","transfer@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false"),("protocol.file.allow","always")] {_ = try await repo.run(["config",key,value])}
    }
    @discardableResult private func commit(_ repo:GitRepository,_ text:String,time:Int=1_000_000_000)async throws->String {
        try Data((text+"\n").utf8).write(to:repo.root.appendingPathComponent("file"));try await repo.stage(["file"])
        _ = try await repo.run(["commit","-m",text],environmentOverrides:["GIT_AUTHOR_DATE":"@\(time) +0000","GIT_COMMITTER_DATE":"@\(time) +0000"])
        return try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
    }
    func testTransferMetadataFailureKeepsRealExitStatusAndOriginalDiagnostics()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _ = try await commit(f.source,"base");_ = try await f.source.run(["remote","add","origin",f.source.root.absoluteString])
        var options=FetchOptions();options.remote="origin"
        let metadata=String(decoding:try frame(reference()),as:UTF8.self),diagnostic="literal transport stderr 雪\n",fake=f.root.appendingPathComponent("result-metadata-helper")
        for code in [0,7] {
            try executable(fake,"#!/bin/sh\nprintf '%s' "+quote(metadata)+"\nprintf '%s\\n' 'unsupported notification metadata'\nprintf '%s' "+quote(diagnostic)+" >&2\nexit \(code)\n")
            let receipts=TransferReceipts()
            do {
                let text=try await f.source.fetch(options,onOutput:receipts.appendOutput,backend:.init(mask:4,helperURL:fake),onNotification:receipts.append)
                XCTAssertEqual(code,0);XCTAssertEqual(text,diagnostic)
            } catch let error as GitFailure {
                XCTAssertEqual(error.code,Int32(code));XCTAssertEqual(code,7)
                XCTAssertEqual(error.message,diagnostic);XCTAssertEqual(error.standardError,Data(diagnostic.utf8))
            }
            XCTAssertEqual(receipts.bytes,Data(diagnostic.utf8));XCTAssertEqual(receipts.references.count,1)
            guard case .issue(let issue)?=receipts.events.last else{return XCTFail("Completed-command metadata issue missing")}
            XCTAssertEqual(issue.commandSucceeded,code==0);XCTAssertEqual(receipts.events.count,2)
        }
    }
    func testLibgit2FetchNotificationsCaptureRealNewSameForwardRewindDivergenceAndGraphFailure()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let base=try await commit(f.source,"base")
        _ = try await f.source.run(["branch","gone"])
        var options=CloneOptions();options.source=f.source.root.absoluteString
        let destination=f.root.appendingPathComponent("clone"),clone=TransferReceipts()
        _ = try await f.runner.clone(options,to:destination,onOutput:clone.appendOutput,backend:f.backend,onNotification:clone.append)
        XCTAssertTrue(clone.references.contains{$0.reference=="refs/remotes/origin/main" && $0.change == .new && $0.newHash==base})
        let repository=GitRepository(root:destination,executable:f.git,askpass:nil)
        var fetch=FetchOptions();fetch.remote="origin"
        let same=TransferReceipts();_ = try await repository.fetch(fetch,backend:f.backend,onNotification:same.append)
        XCTAssertTrue(same.references.contains{$0.reference=="refs/remotes/origin/main" && $0.change == .same && $0.oldHash==base && $0.newHash==base})
        let advanced=try await commit(f.source,"advanced",time:1_000_000_100),forward=TransferReceipts()
        _ = try await repository.fetch(fetch,backend:f.backend,onNotification:forward.append)
        XCTAssertTrue(forward.references.contains{$0.reference=="refs/remotes/origin/main" && $0.oldHash==base && $0.newHash==advanced && $0.change == .forward && $0.count==1})
        _ = try await f.source.run(["reset","--hard",base]);let divergent=try await commit(f.source,"divergent",time:1_000_000_200),newer=TransferReceipts()
        _ = try await repository.fetch(fetch,backend:f.backend,onNotification:newer.append)
        XCTAssertTrue(newer.references.contains{$0.reference=="refs/remotes/origin/main" && $0.oldHash==advanced && $0.newHash==divergent && $0.change == .newerTime})
        _ = try await f.source.run(["reset","--hard",advanced]);let older=TransferReceipts();_ = try await repository.fetch(fetch,backend:f.backend,onNotification:older.append)
        XCTAssertTrue(older.references.contains{$0.reference=="refs/remotes/origin/main" && $0.change == .olderTime})
        _ = try await f.source.run(["reset","--hard",base]);_ = try await commit(f.source,"equal date divergent",time:1_000_000_100)
        let equal=TransferReceipts();_ = try await repository.fetch(fetch,backend:f.backend,onNotification:equal.append)
        XCTAssertTrue(equal.references.contains{$0.reference=="refs/remotes/origin/main" && $0.change == .sameTime})
        _ = try await f.source.run(["reset","--hard",base]);let rewind=TransferReceipts();_ = try await repository.fetch(fetch,backend:f.backend,onNotification:rewind.append)
        XCTAssertTrue(rewind.references.contains{$0.reference=="refs/remotes/origin/main" && $0.change == .rewind && $0.count==1})
        // A locally stored noncommit old tag makes classification fail while
        // the fetched NEW object remains a valid committish for FETCH_HEAD.
        _ = try await repository.run(["config","--add","remote.origin.fetch","+refs/tags/*:refs/tags/*"])
        let oldBlob=try await repository.run(["hash-object","-w","--stdin"],input:Data("local old tag object".utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await repository.run(["update-ref","refs/tags/graph",oldBlob])
        _ = try await f.source.run(["update-ref","refs/tags/graph",advanced])
        // Disable implicit AUTO tag following: libgit2 otherwise refuses to
        // overwrite an existing tag even when an explicit forced refspec exists.
        // The explicit tag refspec still fetches the valid new commit.
        fetch.tags = .disabled
        let beforeGraph=try await repository.run(["rev-parse","refs/tags/graph"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(beforeGraph,oldBlob)
        let graphFailure=TransferReceipts();_ = try await repository.fetch(fetch,backend:f.backend,onNotification:graphFailure.append)
        let afterGraph=try await repository.run(["rev-parse","refs/tags/graph"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(afterGraph,advanced)
        XCTAssertTrue(graphFailure.references.contains{$0.reference=="refs/tags/graph" && $0.oldHash==oldBlob && $0.newHash==advanced && $0.change == .unclassified && $0.count==nil},"Actual references: \(graphFailure.references)")
        _ = try await f.source.run(["branch","-D","gone"]);fetch.prune = .enabled
        let deleted=TransferReceipts();_ = try await repository.fetch(fetch,backend:f.backend,onNotification:deleted.append)
        XCTAssertTrue(deleted.references.contains{$0.reference=="refs/remotes/origin/gone" && $0.change == .deleted && $0.newHash.allSatisfy{$0=="0"}})
        XCTAssertFalse(String(decoding:clone.bytes,as:UTF8.self).contains("TurtleGit Transfer"))
    }
    func testSelectedHelperDirectFetchAndConsumerlessOperationsRetainLegacyDiagnostics()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _ = try await commit(f.source,"base")
        var options=CloneOptions();options.source=f.source.root.absoluteString
        let destination=f.root.appendingPathComponent("legacy"),clone=TransferReceipts()
        let cloneText=try await f.runner.clone(options,to:destination,onOutput:clone.appendOutput,backend:f.backend)
        XCTAssertFalse(cloneText.contains("TurtleGit Transfer"));XCTAssertFalse(String(decoding:clone.bytes,as:UTF8.self).contains("TurtleGit Transfer"))
        let repository=GitRepository(root:destination,executable:f.git,askpass:nil)
        let hash=try await commit(f.source,"legacy forward")
        // Sync transport/tagfetch still use this generic selected-executor path.
        let direct=try await repository.run(["fetch","--progress","--","origin"],executorOverride:f.helper)
        XCTAssertTrue(direct.stdout.isEmpty);XCTAssertTrue(direct.text.contains(String(hash.prefix(8))));XCTAssertTrue(direct.text.contains("refs/remotes/origin/main"));XCTAssertFalse(direct.text.contains("TurtleGit Transfer"))
        _ = try await commit(f.source,"consumerless fetch")
        var fetch=FetchOptions();fetch.remote="origin";let plain=TransferReceipts()
        let text=try await repository.fetch(fetch,onOutput:plain.appendOutput,backend:f.backend)
        XCTAssertTrue(text.contains("refs/remotes/origin/main"));XCTAssertFalse(String(decoding:plain.bytes,as:UTF8.self).contains("TurtleGit Transfer"))
    }
    func testLibgit2CloneCheckoutNotificationsPreserveLiteralPathsAndRecursiveRepositoryPrefixes()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let literal="file 雪\n\t[*].txt",decomposed="decomposed-cafe\u{301}.txt"
        try Data("literal\n".utf8).write(to:f.source.root.appendingPathComponent(literal));try Data("accent\n".utf8).write(to:f.source.root.appendingPathComponent(decomposed));try await f.source.stage([literal,decomposed]);_ = try await commit(f.source,"parent")
        func child(_ name:String)async throws->GitRepository {let url=f.root.appendingPathComponent(name);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);let repo=GitRepository(root:url,executable:f.git,askpass:nil);try await initialize(repo);_ = try await commit(repo,name);return repo}
        let grandchild=try await child("grandchild-source"),module=try await child("module-source")
        _ = try await module.run(["-c","protocol.file.allow=always","submodule","add","--",grandchild.root.absoluteString,"inner space"]);_ = try await module.commit(message:"nested")
        for path in ["module 雪","sibling"] {_ = try await f.source.run(["-c","protocol.file.allow=always","submodule","add","--",module.root.absoluteString,path])}
        _ = try await f.source.commit(message:"recursive modules")
        var options=CloneOptions();options.source=f.source.root.absoluteString;options.recursive=true
        let values=TransferReceipts();_ = try await f.runner.clone(options,to:f.root.appendingPathComponent("recursive"),backend:f.backend,onNotification:values.append)
        XCTAssertTrue(values.files.contains{$0.repositoryPath.isEmpty && $0.path.utf8.elementsEqual(literal.utf8)})
        XCTAssertTrue(values.files.contains{$0.repositoryPath.isEmpty && $0.path.utf8.elementsEqual(decomposed.utf8)})
        for prefix in ["module 雪","module 雪/inner space","sibling","sibling/inner space"] {XCTAssertTrue(values.files.contains{$0.repositoryPath==prefix && $0.path=="file"},prefix)}
        XCTAssertFalse(values.files.contains{$0.repositoryPath.contains("inner space/sibling")})
        for (name,bare,noCheckout) in [("bare",true,false),("no-checkout",false,true)] {
            options.recursive=false;options.bare=bare;options.noCheckout=noCheckout;let rows=TransferReceipts()
            _ = try await f.runner.clone(options,to:f.root.appendingPathComponent(name),backend:f.backend,onNotification:rows.append)
            XCTAssertTrue(rows.files.isEmpty,name)
        }
        options.bare=false;options.noCheckout=false;let cli=TransferReceipts()
        _ = try await f.runner.clone(options,to:f.root.appendingPathComponent("cli"),backend:.init(enabled:false),onNotification:cli.append)
        XCTAssertTrue(cli.events.isEmpty,"CLI diagnostics became typed results")
        // A raw Git tree can contain names that macOS refuses to create.
        // Preserve the real checkout failure and never retarget a receipt to
        // Unicode replacement characters. No invalid OS filename is assumed.
        let blob=try await f.source.run(["hash-object","-w","--stdin"],input:Data("raw tree entry".utf8)).text.trimmingCharacters(in:.newlines)
        let rawIndex=Data(("100644 "+blob+"\t").utf8)+Data([255,0])
        _ = try await f.source.run(["update-index","-z","--index-info"],input:rawIndex)
        let tree=try await f.source.run(["write-tree"]).text.trimmingCharacters(in:.newlines),parent=try await f.source.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let invalidCommit=try await f.source.run(["commit-tree",tree,"-p",parent],input:Data("raw filename tree\n".utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await f.source.run(["update-ref","refs/heads/main",invalidCommit])
        let unsupported=TransferReceipts(),invalidDestination=f.root.appendingPathComponent("invalid-name")
        do {_ = try await f.runner.clone(options,to:invalidDestination,backend:f.backend,onNotification:unsupported.append);XCTFail("macOS checkout unexpectedly accepted an invalid UTF8 path")}
        catch let failure as GitFailure {XCTAssertNotEqual(failure.code,0);XCTAssertNotNil(failure.standardError)}
        XCTAssertFalse(unsupported.files.contains{$0.path.contains("\u{fffd}")})
        XCTAssertTrue(unsupported.references.contains{$0.newHash==invalidCommit},"Earlier real ref receipt was lost on checkout failure")
        for event in unsupported.events {if case .issue(let issue)=event {XCTAssertFalse(issue.commandSucceeded)}}
    }
}
