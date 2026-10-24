// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class BackendMetadataReadTests:XCTestCase {
    private func fixture() async throws -> (URL,GitRepository) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMetadata-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,libgit2Configuration:.init(enabled:false))
        _ = try await repo.run(["init","-b","main"])
        for (k,v) in [("user.name","Metadata QA"),("user.email","qa@example.invalid"),("core.precomposeunicode","false")] {_ = try await repo.run(["config",k,v])}
        return(root,repo)
    }
    private func selected(_ root:URL,mask:UInt32=0,helper:URL?=nil)->GitRepository {GitRepository(root:root,libgit2Configuration:.init(enabled:true,mask:mask,helperURL:helper))}
    func testMasterCatalogsIgnoreMaskPreserveExactNamesAndUnbornDetachedSymbolics() async throws {
        let(root,cli)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let repo=selected(root),nfc="caf\u{e9}",nfd="cafe\u{301}"
        let unborn=try await repo.checkoutReferences();XCTAssertTrue(unborn.isEmpty)
        let emptyRemotes=try await repo.remoteNames();XCTAssertTrue(emptyRemotes.isEmpty)
        for name in [nfc,nfd] {_ = try await cli.run(["-c","core.precomposeunicode=false","remote","add",name,"https://example.invalid/"+name])}
        let names=try await repo.remoteNames();XCTAssertEqual(Set(names.map{Data($0.utf8)}),Set([nfc,nfd].map{Data($0.utf8)}))
        _ = try await cli.run(["commit","--allow-empty","-m","base"])
        _ = try await cli.run(["tag","-a","annotated","-m","Tag body"])
        _ = try await cli.run(["tag","-a","outer","annotated","-m","Outer tag"])
        _ = try await cli.run(["symbolic-ref","refs/remotes/origin/HEAD","refs/remotes/origin/missing"])
        let refs=try await repo.checkoutReferences()
        XCTAssertTrue(refs.contains{$0.name=="refs/heads/main"});XCTAssertTrue(refs.contains{$0.name=="refs/tags/annotated"})
        XCTAssertEqual(refs.first{$0.name=="refs/remotes/origin/HEAD"}?.symbolicTarget,"refs/remotes/origin/missing")
        _ = try await cli.run(["checkout","--detach"])
        let detached=try await repo.checkoutReferences();XCTAssertEqual(Set(refs.map{Data($0.name.utf8)}),Set(detached.map{Data($0.name.utf8)}))
        let labels=try await repo.historyReferenceObjects(cancellation:nil)
        XCTAssertFalse(labels.contains{$0.name=="refs/remotes/origin/HEAD"})
        let tag=try XCTUnwrap(labels.first{$0.name=="refs/tags/annotated"});XCTAssertNotNil(tag.peeled);XCTAssertNotEqual(tag.object,tag.peeled)
        let outer=try XCTUnwrap(labels.first{$0.name=="refs/tags/outer"});XCTAssertEqual(outer.peeled,tag.peeled);XCTAssertNotEqual(outer.object,tag.object)
        let bytes=try await repo.historyTagObjects([tag.object],cancellation:nil);XCTAssertTrue(bytes[tag.object]?.contains("Tag body") == true)
    }
    func testMasterMissingRuntimeAndPreCancelledReadsNeverFallBack() async throws {
        let(root,_)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let repo=selected(root,helper:root.appendingPathComponent("absent"))
        do {_ = try await repo.remoteNames();XCTFail("master flag fell back")} catch GitLibGit2Failure.runtimeMissing {}
        do {_ = try await repo.checkoutReferences();XCTFail("master flag fell back")} catch GitLibGit2Failure.runtimeMissing {}
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.remoteNames(cancellation:token);XCTFail("cancelled read ran")}catch OperationCancellationFailure.cancelled{}
    }
    func testBatchedActionsUseSelectedBitAndRetainRootRenameMergeParents() async throws {
        let(root,cli)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("old"));_ = try await cli.run(["add","old"]);_ = try await cli.run(["commit","-m","root"])
        _ = try await cli.run(["branch","side"]);_ = try await cli.run(["mv","old","new"]);_ = try await cli.run(["commit","-m","rename"])
        _ = try await cli.run(["checkout","side"]);_ = try await cli.run(["commit","--allow-empty","-m","side"]);_ = try await cli.run(["checkout","main"]);_ = try await cli.run(["merge","--no-ff","side","-m","merge"])
        let entries=try await cli.history(),repo=selected(root,mask:GitLibGit2Operation.logListDiff.mask)
        let actual=try await repo.revisionChanges(in:entries),expected=try await cli.revisionChanges(in:entries)
        for entry in entries {let individual=try await repo.historyDiff(revision:entry.hash,simple:false,backend:.init(enabled:true,mask:GitLibGit2Operation.logListDiff.mask),cancellation:nil);XCTAssertEqual(actual[entry.hash]?.map{$0.action+":"+$0.path},individual.groups.flatMap{$0}.map{$0.action+":"+$0.path})}
        // CLI names include similarity scores (R100); the pinned helper reports
        // the source action enum R. Compare status, both literal paths and the
        // actual action-column result, retaining per-parent duplicate records.
        for entry in entries {
            func semantic(_ file:CommitFile)->String {String(file.action.prefix(1))+":"+file.path+"\0"+(file.oldPath ?? "")}
            XCTAssertEqual(actual[entry.hash]?.map(semantic).sorted(),expected[entry.hash]?.map(semantic).sorted())
            XCTAssertEqual(LogRevisionActions.classify(actual[entry.hash] ?? []),LogRevisionActions.classify(expected[entry.hash] ?? []))
        }
        let broken=selected(root,mask:GitLibGit2Operation.logListDiff.mask,helper:root.appendingPathComponent("absent"))
        do {_ = try await broken.revisionActions(in:entries);XCTFail("bit15 silently fell back")}catch GitLibGit2Failure.runtimeMissing{}
    }
    func testBoundedBatchUsesTwoHelperProcessesFor129RowsAndAcceptsUppercaseOID() async throws {
        let(root,cli)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        _ = try await cli.run(["commit","--allow-empty","-m","root"])
        let entries=try await cli.history()
        let entry=try XCTUnwrap(entries.first)
        let helper=try GitLibGit2Configuration().runtimeExecutor(),wrapper=root.appendingPathComponent("batch-helper"),trace=root.appendingPathComponent("batch-trace")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="#!/bin/sh\nprintf '%s\\n' \"$@\" >> "+quote(trace.path)+"\nexec "+quote(helper.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let repo=selected(root,mask:GitLibGit2Operation.logListDiff.mask,helper:wrapper)
        let result=try await repo.revisionChanges(in:Array(repeating:entry,count:129));XCTAssertTrue(result[entry.hash]?.isEmpty == true)
        let calls=try String(contentsOf:trace,encoding:.utf8).split(separator:"\n").filter{$0=="turtlegit-history-diff-batch"};XCTAssertEqual(calls.count,2)
        let upperEntry=LogEntry(hash:entry.hash.uppercased(),author:entry.author,date:entry.date,subject:entry.subject,parents:entry.parents.map{$0.uppercased()})
        let upper=try await repo.revisionChanges(in:[upperEntry])
        XCTAssertTrue(upper[upperEntry.hash]?.isEmpty == true)
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.revisionChanges(in:[entry],cancellation:token);XCTFail("cancelled metadata ran")}catch OperationCancellationFailure.cancelled{}
    }

}
