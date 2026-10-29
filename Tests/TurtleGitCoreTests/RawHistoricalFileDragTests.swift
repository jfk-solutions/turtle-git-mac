// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class RawHistoricalFileDragTests:XCTestCase {
    private let rawBackend=GitLibGit2Configuration(enabled:false)
    private func row(_ path:String,mode:UInt32?=nil,action:String="M")->CommitFile {
        CommitFile(path:path,oldPath:nil,action:action,added:0,removed:0,hasStatistics:false,isSubmodule:mode==0o160000,newMode:mode)
    }
    private struct Fixture {
        let root:URL,repo:GitRepository,snapshot:RepositoryBrowserSnapshot,bytes:Data
    }
    private func fixture()async throws->Fixture {
        let(root,repo,_)=try await GitPatchTests().fixture()
        do {
            let bytes=Data([0,255,65,10])
            func oid(_ args:[String],_ data:Data)async throws->String {try await repo.run(args,input:data).text.trimmingCharacters(in:.newlines)}
            let blob=try await oid(["hash-object","-w","--stdin"],bytes)
            let link=try await oid(["hash-object","-w","--stdin"],Data("destination".utf8))
            let filtered=try await oid(["hash-object","-w","--stdin"],Data("STORED\n".utf8))
            let attributes=Data("*.filtered filter=drag\n".utf8)
            try attributes.write(to:root.appendingPathComponent(".gitattributes"))
            let attrs=try await oid(["hash-object","-w","--stdin"],attributes)
            func tree(_ rows:[(String,String,String,Data)])async throws->String {
                var data=Data()
                for(mode,type,hash,path)in rows {data.append(Data((mode+" "+type+" "+hash+"\t").utf8));data.append(path);data.append(0)}
                return try await oid(["mktree","-z"],data)
            }
            let child=try await tree([("120000","blob",link,Data("child.txt".utf8))])
            let object=try await tree([
                ("100644","blob",blob,Data([255])+Data(".bin".utf8)),
                ("100755","blob",blob,Data([254])+Data(".bin".utf8)),
                ("040000","tree",child,Data([253])),
                ("100644","blob",filtered,Data([252])+Data(".filtered".utf8)),
                ("100644","blob",blob,Data("ordinary.bin".utf8)),
                ("100644","blob",attrs,Data(".gitattributes".utf8))])
            let snapshot=try await repo.browseRepository(revision:object,backend:rawBackend)
            return Fixture(root:root,repo:repo,snapshot:snapshot,bytes:bytes)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    func testSynchronousNamesUseExactPathIdentityAndLeaveOrdinaryOpenSaveNamingAlone()throws {
        let a=try RepositoryBrowserGitPath(rawData:Data([255])+Data(".bin".utf8)),b=try RepositoryBrowserGitPath(rawData:Data([254])+Data(".bin".utf8))
        // Independent SHA-256 fixture constants for ff2e62696e and fe2e62696e.
        XCTAssertEqual(try HistoricalFileDeliveryName.transferLeaf(path:a.key),"Git-path-9ae34ecc69f60c55f1d7b3e3bdc3d8703bc71ae6db1ca4a37a2beca1b0e772c6.bin")
        XCTAssertEqual(try HistoricalFileDeliveryName.transferLeaf(path:b.key),"Git-path-6f755f273c19aa8fd7ee8e26ca05fa9aec115a4625602ab3c46c57f3139c0848.bin")
        XCTAssertEqual(try HistoricalFileDeliveryName.transferLeaf(path:"folder/literal\tline\n雪.bin"),"literal\tline\n雪.bin")
        let content=ComparisonFileContent(path:a.key,revision:.revision(String(repeating:"a",count:40)),bytes:Data(),mode:"100644",objectID:String(repeating:"b",count:40))
        XCTAssertEqual(try HistoricalFileDeliveryName.leaf(for:content),"Git-blob-"+String(repeating:"b",count:40)+".bin","Existing Open/Save OID naming must remain independent")
    }
    func testSameBlobRawPathsAndDuplicateOccurrencesMaterializeSeparatelyWithExactBytes()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let entries=f.snapshot.entries.filter{$0.kind != .directory && !$0.isPathRepresentable}
        let a=try XCTUnwrap(entries.first{$0.mode=="100644" && $0.rawName.starts(with:[255])}),b=try XCTUnwrap(entries.first{$0.mode=="100755"})
        XCTAssertEqual(a.objectID,b.objectID)
        let files=[row(a.path,mode:0o100644),row(b.path,mode:0o100755),row(a.path,mode:0o100644)]
        let plan=try FileListDragPlan(root:f.root,revision:.revision(f.snapshot.objectID!),files:files,backend:rawBackend)
        XCTAssertEqual(plan.items.map(\.id),[0,1,2]);XCTAssertEqual(plan.items[0].name,plan.items[2].name);XCTAssertNotEqual(plan.items[0].name,plan.items[1].name)
        let index=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        var exports:[RepositoryBrowserExport]=[];defer{exports.forEach{$0.discard()}}
        for item in plan.items.indices {
            guard case let .historical(value)=try await f.repo.materializeFileListDrag(plan,itemAt:item) else{return XCTFail("Expected historical copy")}
            exports.append(value);XCTAssertEqual(value.item.lastPathComponent,plan.items[item].name);XCTAssertEqual(try Data(contentsOf:value.item),f.bytes)
        }
        XCTAssertNotEqual(exports[0].directory,exports[2].directory)
        let mode=try FileManager.default.attributesOfItem(atPath:exports[1].item.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue,0o755);XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
    }
    func testRawParentSymlinkTextIsDeliveredAsSafeFileButLiteralFoldersStayBlocked()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let directory=try XCTUnwrap(f.snapshot.entries.first{$0.kind == .directory})
        let child=try await f.repo.browseRepositoryDirectory(f.snapshot,directory:directory.path)
        let entry=try XCTUnwrap(child.entries.first)
        try RepositoryBrowserTransferPolicy.validateHistoricalFiles(child,entries:[entry])
        try RepositoryBrowserTransferPolicy.validateSelection(child,selected:[entry],inventory:nil)
        let plan=try FileListDragPlan(root:f.root,revision:.revision(f.snapshot.objectID!),files:[row(entry.path,mode:0o120000)],backend:rawBackend)
        guard case let .historical(export)=try await f.repo.materializeFileListDrag(plan,itemAt:0) else{return XCTFail("Expected link text")}
        defer{export.discard()}
        XCTAssertEqual(export.item.lastPathComponent,"Git-path-fab48a54b9e29a31f07d861b26fb3fb111188018037b9f723e755040ca31a4b1.txt")
        XCTAssertEqual(try Data(contentsOf:export.item),Data("destination".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:export.item.path)[.type] as? FileAttributeType,.typeRegular)
        XCTAssertThrowsError(try RepositoryBrowserTransferPolicy.validateHistoricalFiles(f.snapshot,entries:[directory]))
        XCTAssertThrowsError(try RepositoryBrowserTransferPolicy.validateSelection(f.snapshot,selected:[directory],inventory:child.entries))
        XCTAssertThrowsError(try RepositoryBrowserTransferPolicy.validate(child,entries:[entry]),"Literal export policy remains strict")
    }
    func testWorkingTreeRawAndMalformedOrMetadataKeysRemainRefused()throws {
        let root=URL(fileURLWithPath:"/private/fixture"),hash=String(repeating:"a",count:40)
        let raw=try RepositoryBrowserGitPath(rawData:Data([255])+Data(".bin".utf8))
        XCTAssertThrowsError(try FileListDragPlan(root:root,revision:.workingTree,files:[row(raw.key)],backend:rawBackend))
        for key in ["","../bad","/absolute","a//bad","a/./bad","a\0b",".GIT/config",try RepositoryBrowserGitPath(rawData:Data(".git/".utf8)+Data([255])).key] {
            XCTAssertThrowsError(try HistoricalFileDeliveryName.transferLeaf(path:key))
            XCTAssertThrowsError(try FileListDragPlan(root:root,revision:.revision(hash),files:[row(key)],backend:rawBackend))
        }
        let omitted=try FileListDragPlan(root:root,revision:.revision(hash),files:[row(raw.key,action:"D"),row(raw.key,mode:0o160000)],backend:rawBackend)
        XCTAssertTrue(omitted.items.isEmpty)
    }
    func testRawPromiseMaterializationHonorsCapturedFilterBackendAndRequiredFailure()async throws {
        let backend=GitLibGit2Configuration(mask:0x200)
        do {_ = try backend.executor(for:.getOneFile)} catch {throw XCTSkip("Historical filter helper unavailable: \(error)")}
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let entry=try XCTUnwrap(f.snapshot.entries.first{$0.rawName.starts(with:[252])})
        _ = try await f.repo.run(["config","filter.drag.clean","cat"])
        _ = try await f.repo.run(["config","filter.drag.smudge","sed 's/STORED/SMUDGED/g'"])
        _ = try await f.repo.run(["config","filter.drag.required","true"])
        let plan=try FileListDragPlan(root:f.root,revision:.revision(f.snapshot.objectID!),files:[row(entry.path,mode:0o100644)],backend:backend)
        guard case let .historical(export)=try await f.repo.materializeFileListDrag(plan,itemAt:0) else{return XCTFail("Expected filtered delivery")}
        defer{export.discard()};XCTAssertEqual(try Data(contentsOf:export.item),Data("SMUDGED\n".utf8))
        _ = try await f.repo.run(["config","filter.drag.smudge","exit 1"])
        do {_ = try await f.repo.materializeFileListDrag(plan,itemAt:0);XCTFail("Required failure silently fell back")} catch {}
    }
    func testCanceledOrMissingSelectedHelperNeverPublishesRawFallback()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let entry=try XCTUnwrap(f.snapshot.entries.first{$0.rawName.starts(with:[255])})
        let plan=try FileListDragPlan(root:f.root,revision:.revision(f.snapshot.objectID!),files:[row(entry.path)],backend:rawBackend)
        let token=OperationCancellation();token.cancel()
        do {_ = try await f.repo.materializeFileListDrag(plan,itemAt:0,cancellation:token);XCTFail("Canceled delivery published")} catch OperationCancellationFailure.cancelled {}
        let missing=try FileListDragPlan(root:f.root,revision:.revision(f.snapshot.objectID!),files:[row(entry.path)],backend:.init(enabled:true,mask:0x200,helperURL:f.root.appendingPathComponent("missing-helper")))
        do {_ = try await f.repo.materializeFileListDrag(missing,itemAt:0);XCTFail("Missing selected helper silently fell back")} catch GitLibGit2Failure.runtimeMissing {}
    }
}
