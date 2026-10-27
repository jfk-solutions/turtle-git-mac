import XCTest
@testable import TurtleGitCore

final class RepositoryBrowserStoredFileTests:XCTestCase {
    private func blob(_ repo:GitRepository,_ bytes:Data)async throws->String {
        try await repo.run(["hash-object","-w","--stdin"],input:bytes).text.trimmingCharacters(in:.newlines)
    }
    private func tree(_ repo:GitRepository,_ records:[(String,String,String,Data)])async throws->String {
        var bytes=Data()
        for(mode,type,oid,name)in records {
            bytes.append(Data("\(mode) \(type) \(oid)\t".utf8));bytes.append(name);bytes.append(0)
        }
        return try await repo.run(["mktree","-z"],input:bytes).text.trimmingCharacters(in:.newlines)
    }
    private struct Receipt {
        let head:Data,index:Data,config:Data,status:Data,working:Data
    }
    private func receipt(_ repo:GitRepository,root:URL,path:String)async throws->Receipt {
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        let status=try await repo.run(["status","--porcelain=v1","-z","--untracked-files=all"]).stdout
        return Receipt(head:head,index:try Data(contentsOf:root.appendingPathComponent(".git/index")),
            config:try Data(contentsOf:root.appendingPathComponent(".git/config")),status:status,
            working:try Data(contentsOf:root.appendingPathComponent(path)))
    }
    private func assertPreserved(_ before:Receipt,repo:GitRepository,root:URL,path:String)async throws {
        let after=try await receipt(repo,root:root,path:path)
        XCTAssertEqual(after.head,before.head);XCTAssertEqual(after.index,before.index)
        XCTAssertEqual(after.config,before.config);XCTAssertEqual(after.status,before.status)
        XCTAssertEqual(after.working,before.working)
    }

    func testRawNameAndReplacementSpellingDeliverDistinctStoredObjectsUnderSafeNames()async throws {
        let(root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let rawBytes=Data([0,0xff,65,13,10]),replacementBytes=Data([66,0xfe,0,10])
        let first=try await blob(repo,rawBytes),second=try await blob(repo,replacementBytes)
        let raw=Data([0xff])+Data(".txt".utf8),replacement=Data("\u{fffd}.txt".utf8)
        let oid=try await tree(repo,[("100644","blob",first,raw),("100644","blob",second,replacement),
                                    ("100755","blob",first,Data([0xfe])+Data(".txt".utf8))])
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let commit=try await repo.run(["commit-tree",oid,"-p",head],input:Data("stored receipt\n".utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-ref","refs/heads/stored-file-receipt",commit])
        let snapshot=try await repo.browseRepository(revision:"refs/heads/stored-file-receipt")
        let movedTree=try await tree(repo,[("100644","blob",second,raw)])
        let moved=try await repo.run(["commit-tree",movedTree,"-p",commit],input:Data("moved receipt\n".utf8)).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["update-ref","refs/heads/stored-file-receipt",moved])
        let before=try await receipt(repo,root:root,path:path)
        let rawEntry=try XCTUnwrap(snapshot.entries.first{$0.rawName==raw})
        let replacementEntry=try XCTUnwrap(snapshot.entries.first{$0.rawName==replacement})
        XCTAssertFalse(rawEntry.isPathRepresentable);XCTAssertTrue(replacementEntry.isPathRepresentable)
        let a=try await repo.storedRepositoryBrowserFile(snapshot,entry:rawEntry)
        let b=try await repo.storedRepositoryBrowserFile(snapshot,entry:replacementEntry)
        XCTAssertEqual(a.path,"Git-blob-"+first+".txt");XCTAssertEqual(b.path,"Git-blob-"+second+".txt")
        XCTAssertNotEqual(a.path,b.path);XCTAssertEqual(a.bytes,rawBytes);XCTAssertEqual(b.bytes,replacementBytes)
        XCTAssertEqual(a.mode,"100644");XCTAssertEqual(a.revision,.revision(commit))
        let alias=try XCTUnwrap(snapshot.entries.first{$0.rawName==Data([0xfe])+Data(".txt".utf8)})
        let same=try await repo.storedRepositoryBrowserFile(snapshot,entry:alias)
        // Shared content may propose the same basename; each native preview
        // still owns its own UUID directory. Executable mode is not discarded.
        XCTAssertEqual(same.path,a.path);XCTAssertEqual(same.bytes,a.bytes);XCTAssertEqual(same.mode,"100755")
        XCTAssertTrue([a.path,b.path,same.path].allSatisfy{$0.utf8.allSatisfy{$0<128} && !$0.contains("/") && !$0.contains("\0")})
        try await assertPreserved(before,repo:repo,root:root,path:path)
    }

    func testStoredDeliveryBypassesActiveSmudgeFiltersAndKeepsSymlinkBytes()async throws {
        let(root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let original=Data("original stored bytes\r\n".utf8),target=Data([46,46,47,0xff,10])
        let first=try await blob(repo,original),link=try await blob(repo,target)
        let oid=try await tree(repo,[("100644","blob",first,Data("filtered.txt".utf8)),
                                    ("120000","blob",link,Data([0xff])+Data(".link".utf8))])
        let attributes=Data("*.txt filter=stored-proof\n".utf8)
        try attributes.write(to:root.appendingPathComponent(".gitattributes"))
        _ = try await repo.run(["config","filter.stored-proof.smudge","printf transformed-by-smudge"])
        _ = try await repo.run(["config","filter.stored-proof.clean","cat"])
        _ = try await repo.run(["config","filter.stored-proof.required","true"])
        let snapshot=try await repo.browseRepository(revision:oid)
        let ordinary=try XCTUnwrap(snapshot.entries.first{$0.rawName==Data("filtered.txt".utf8)})
        let symlink=try XCTUnwrap(snapshot.entries.first{$0.kind == .symlink})
        // Prove Git's configured filter genuinely transforms checkout content.
        // The disabled materialization backend deliberately retains raw bytes;
        // it is not an appropriate positive control for smudge execution.
        let filtered=try await repo.run(["cat-file","--filters","--path=filtered.txt",first]).stdout
        XCTAssertEqual(filtered,Data("transformed-by-smudge".utf8))
        let before=try await receipt(repo,root:root,path:path)
        let stored=try await repo.storedRepositoryBrowserFile(snapshot,entry:ordinary)
        let storedLink=try await repo.storedRepositoryBrowserFile(snapshot,entry:symlink)
        XCTAssertEqual(stored.bytes,original);XCTAssertNotEqual(stored.bytes,filtered)
        XCTAssertEqual(storedLink.bytes,target);XCTAssertEqual(storedLink.mode,"120000")
        XCTAssertEqual(storedLink.path,"Git-blob-"+link+".link")
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".gitattributes")),attributes)
        try await assertPreserved(before,repo:repo,root:root,path:path)
    }

    func testStoredNamesLimitExtensionsAndRejectStaleRowsKindsForeignOwnersAndCancellation()async throws {
        let(root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let first=try await blob(repo,Data([0,255,10])),second=try await blob(repo,Data([1,254,13,10]))
        let head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let empty=try await tree(repo,[])
        let names:[(Data,String)]=[
            (Data([0xff])+Data(".PDF".utf8),".PDF"),
            (Data([0xfe])+Data(".a123456789012345".utf8),".a123456789012345"),
            (Data([0xfd])+Data(".a1234567890123456".utf8),""),
            (Data([0xfc])+Data(".a-b".utf8),""),
            (Data([0xfb])+Data(".a_b".utf8),""),
            (Data([0xfa])+Data(".é".utf8),""),
            (Data([0xf9])+Data(".".utf8),""),
            (Data([0xf8]),"")]
        var records=names.map{("100644","blob",first,$0.0)}
        records.append(("040000","tree",empty,Data("folder".utf8)))
        records.append(("160000","commit",head,Data("module".utf8)))
        let oid=try await tree(repo,records),snapshot=try await repo.browseRepository(revision:oid)
        let before=try await receipt(repo,root:root,path:path)
        for(name,suffix)in names {
            let entry=try XCTUnwrap(snapshot.entries.first{$0.rawName==name})
            let value=try await repo.storedRepositoryBrowserFile(snapshot,entry:entry)
            XCTAssertEqual(value.path,"Git-blob-"+first+suffix);XCTAssertEqual(value.bytes,Data([0,255,10]))
        }
        let selected=try XCTUnwrap(snapshot.entries.first{$0.rawName==names[0].0})
        let changedTree=try await tree(repo,[("100644","blob",second,names[0].0)])
        let replacement=try await repo.browseRepository(revision:changedTree)
        do {_ = try await repo.storedRepositoryBrowserFile(replacement,entry:selected);XCTFail("Stale row borrowed a new tree receipt")}catch RepositoryBrowserFailure.selection{}
        let forged=RepositoryBrowserEntry(path:selected.path,name:selected.name,mode:"100755",objectID:selected.objectID,size:selected.size)
        do {_ = try await repo.storedRepositoryBrowserFile(snapshot,entry:forged);XCTFail("Forged mode bypassed exact row membership")}catch RepositoryBrowserFailure.selection{}
        for entry in snapshot.entries where entry.kind == .directory || entry.kind == .submodule {
            do {_ = try await repo.storedRepositoryBrowserFile(snapshot,entry:entry);XCTFail("Nonblob kind accepted")}catch RepositoryBrowserFailure.selection{}
        }
        let foreign=GitRepository(root:root.appendingPathComponent("different-owner"))
        do {_ = try await foreign.storedRepositoryBrowserFile(snapshot,entry:selected);XCTFail("Foreign owner accepted snapshot")}catch RepositoryBrowserFailure.selection{}
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.storedRepositoryBrowserFile(snapshot,entry:selected,cancellation:token);XCTFail("Cancelled stored delivery accepted")}catch is OperationCancellationFailure{}
        let pinned=try await repo.storedRepositoryBrowserFile(snapshot,entry:selected)
        XCTAssertEqual(pinned.bytes,Data([0,255,10]));XCTAssertEqual(pinned.revision,.revision(oid))
        try await assertPreserved(before,repo:repo,root:root,path:path)
    }
}
