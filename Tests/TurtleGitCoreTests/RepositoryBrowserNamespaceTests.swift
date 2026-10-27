import XCTest
@testable import TurtleGitCore

final class RepositoryBrowserNamespaceTests:XCTestCase {
    struct Fixture {
        let root:URL,repository:GitRepository,tree:String,blob:String,contents:Data,head:String
        let rawDirectory=Data([114,97,119,45,128])
    }
    private func tree(_ repository:GitRepository,_ values:[(String,String,String,Data)])async throws->String {
        var packet=Data()
        for (mode,type,oid,name) in values {
            packet.append(Data((mode+" "+type+" "+oid+"\t").utf8));packet.append(name);packet.append(0)
        }
        return try await repository.run(["mktree","-z"],input:packet).text.trimmingCharacters(in:.newlines)
    }
    private func fixture()async throws->Fixture {
        let(root,repository,_)=try await GitPatchTests().fixture()
        do {
        let head=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let contents=Data([0,255,10,13,65,0,66])
        let blob=try await repository.run(["hash-object","-w","--stdin"],input:contents).text.trimmingCharacters(in:.newlines)
        let child=try await tree(repository,[("100644","blob",blob,Data("leaf.txt".utf8)),("100644","blob",blob,Data([254]))])
        let rows:[(String,String,String,Data)]=[
            ("100644","blob",blob,Data("valid.txt".utf8)),
            ("100644","blob",blob,Data([255])),("100644","blob",blob,Data([254])),
            ("040000","tree",child,Data([114,97,119,45,128])),
            ("100644","blob",blob,Data("\u{FFFD}".utf8)),
            ("100644","blob",blob,Data("é.txt".utf8)),("100644","blob",blob,Data("e\u{301}.txt".utf8)),
            ("100644","blob",blob,Data("line\nbreak\t.txt".utf8)),
            ("160000","commit",head,Data([109,111,100,45,255])),
            ("120000","blob",blob,Data([108,105,110,107,45,254]))
        ]
        let oid=try await tree(repository,rows)
        return .init(root:root,repository:repository,tree:oid,blob:blob,contents:contents,head:head)
        } catch {
            try? FileManager.default.removeItem(at:root)
            throw error
        }
    }
    func testRawPathKeysRemainLosslessAndNeverBecomeSharedPathspecs()throws {
        let valid=["","valid.txt","é.txt","e\u{301}.txt","line\nbreak\t.txt","literal ⟦FF⟧"]
        for text in valid {
            let path=try RepositoryBrowserGitPath(rawData:Data(text.utf8))
            XCTAssertTrue(path.isRepresentable);XCTAssertTrue(path.key.utf8.elementsEqual(text.utf8));XCTAssertTrue(path.display.utf8.elementsEqual(text.utf8))
            XCTAssertEqual(try RepositoryBrowserGitPath(key:path.key).rawData,Data(text.utf8))
        }
        let a=try RepositoryBrowserGitPath(rawData:Data([255])),b=try RepositoryBrowserGitPath(rawData:Data([254]))
        XCTAssertNotEqual(a.key,b.key);XCTAssertNotEqual(a.display,b.display)
        XCTAssertFalse(a.isRepresentable);XCTAssertTrue(a.key.utf8.contains(0));XCTAssertFalse(a.display.utf8.contains(0))
        XCTAssertEqual(try RepositoryBrowserGitPath(key:a.key).rawData,Data([255]))
        XCTAssertFalse(RepositoryBrowserListing.validPath(a.key,allowRoot:false));XCTAssertTrue(RepositoryBrowserListing.validNamespaceKey(a.key,allowRoot:false))
        let child=try RepositoryBrowserGitPath(rawData:Data([255,47])+Data("leaf".utf8))
        XCTAssertEqual(child.parentKey,a.key);XCTAssertEqual(child.ancestorKeys,[a.key,child.key]);XCTAssertEqual(child.lastComponentDisplay,"leaf")
        XCTAssertEqual(try RepositoryBrowserGitPath(rawData:Data()).parentKey,nil)
        for invalid in [Data([0]),Data([47,65]),Data("a//b".utf8),Data("a/../b".utf8),Data("./a".utf8)] {XCTAssertThrowsError(try RepositoryBrowserGitPath(rawData:invalid))}
        XCTAssertThrowsError(try RepositoryBrowserGitPath(key:"\0TurtleGitBrowserPath:YQ=="))
    }
    func testMixedRawNamespacePreservesSiblingsAndNavigatesDirectoriesByObjectID()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let index=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        for backend in [GitLibGit2Configuration(enabled:true),GitLibGit2Configuration(enabled:false)] {
            let snapshot=try await f.repository.browseRepository(revision:f.tree,backend:backend)
            XCTAssertEqual(snapshot.entries.count,10);XCTAssertEqual(Set(snapshot.entries.map(\.id)).count,10)
            XCTAssertEqual(snapshot.entries.filter(\.isPathRepresentable).count,5)
            let first=try XCTUnwrap(snapshot.entries.first{$0.rawPath==Data([255])}),second=try XCTUnwrap(snapshot.entries.first{$0.rawPath==Data([254])})
            XCTAssertNotEqual(first.id,second.id);XCTAssertNotEqual(first.name,second.name);XCTAssertEqual(first.id,Data([255]).base64EncodedString())
            XCTAssertNotNil(snapshot.entries.first{$0.path.utf8.elementsEqual("é.txt".utf8)})
            XCTAssertNotNil(snapshot.entries.first{$0.path.utf8.elementsEqual("e\u{301}.txt".utf8)})
            let raw=try XCTUnwrap(snapshot.entries.first{$0.rawPath==f.rawDirectory})
            let listing=try await f.repository.browseRepositoryDirectory(snapshot,directory:raw.path)
            XCTAssertEqual(listing.treeID,f.tree);XCTAssertEqual(listing.objectID,f.tree)
            XCTAssertFalse(listing.isDirectoryRepresentable);XCTAssertFalse(listing.displayDirectory.utf8.contains(0))
            XCTAssertEqual(listing.entries.count,2);XCTAssertTrue(listing.entries.allSatisfy{!$0.isPathRepresentable})
            let leaf=try XCTUnwrap(listing.entries.first{$0.rawName==Data("leaf.txt".utf8)})
            XCTAssertEqual(leaf.rawPath,f.rawDirectory+Data([47])+Data("leaf.txt".utf8));XCTAssertEqual(leaf.parentPathKey,raw.path)
            let bytes=try await f.repository.storedRepositoryBrowserBlob(listing,entry:leaf);XCTAssertEqual(bytes,f.contents)
            let root=try await f.repository.browseRepositoryDirectory(listing,directory:"")
            XCTAssertEqual(root.entries,snapshot.entries)
            let inventory=try await f.repository.repositoryBrowserTransferInventory(snapshot,directory:raw.path)
            XCTAssertEqual(inventory.count,2);XCTAssertTrue(inventory.allSatisfy{$0.rawPath.starts(with:f.rawDirectory+Data([47]))})
        }
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
        let head=try await f.repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(head,f.head)
    }
    func testHistoricalDeliveryIsPinnedAndFilesystemActionsRefuseRawNames()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let snapshot=try await f.repository.browseRepository(revision:f.tree)
        let raw=try XCTUnwrap(snapshot.entries.first{$0.rawPath==Data([255])})
        let index=try Data(contentsOf:f.root.appendingPathComponent(".git/index")),config=try Data(contentsOf:f.root.appendingPathComponent(".git/config"))
        let contents=try await f.repository.storedRepositoryBrowserBlob(snapshot,entry:raw);XCTAssertEqual(contents,f.contents)
        let view=try await f.repository.repositoryBrowserFile(snapshot,entry:raw)
        XCTAssertEqual(view.path,raw.path);XCTAssertEqual(view.objectID,raw.objectID);XCTAssertEqual(view.bytes,f.contents)
        let delivered=try await f.repository.materializedRepositoryBrowserFile(snapshot,entry:raw,backend:.init(mask:0));XCTAssertEqual(delivered.bytes,f.contents);XCTAssertEqual(delivered.path,raw.path);XCTAssertEqual(delivered.objectID,raw.objectID)
        do {try await f.repository.validateRepositoryBrowserWorkingPath(snapshot,entry:raw);XCTFail("Opaque key entered filesystem lookup")}catch is RepositoryBrowserTransferFailure{}
        do {try await f.repository.revertRepositoryBrowserFile(snapshot,entry:raw);XCTFail("Opaque key entered checkout")}catch is RepositoryBrowserTransferFailure{}
        let gitlink=try XCTUnwrap(snapshot.entries.first{$0.kind == .submodule})
        do {_ = try await f.repository.repositoryBrowserSubmodule(snapshot,entry:gitlink);XCTFail("Opaque key entered submodule lookup")}catch is RepositoryBrowserTransferFailure{}
        do {_ = try await f.repository.storedRepositoryBrowserBlob(snapshot,entry:gitlink);XCTFail("Gitlink became a stored blob")}catch RepositoryBrowserFailure.selection{}
        let forged=RepositoryBrowserEntry(path:raw.path,name:raw.name,mode:raw.mode,objectID:String(repeating:"a",count:40),size:raw.size)
        do {_ = try await f.repository.storedRepositoryBrowserBlob(snapshot,entry:forged);XCTFail("Changed row OID bypassed captured membership")}catch RepositoryBrowserFailure.selection{}
        let token=OperationCancellation();token.cancel()
        do {_ = try await f.repository.storedRepositoryBrowserBlob(snapshot,entry:raw,cancellation:token);XCTFail("Cancelled stored read accepted")}catch is OperationCancellationFailure{}
        let valid=try XCTUnwrap(snapshot.entries.first{$0.path=="valid.txt"})
        let materialized=try await f.repository.materializedRepositoryBrowserFile(snapshot,entry:valid);XCTAssertEqual(materialized.bytes,f.contents)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index);XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/config")),config)
        let head=try await f.repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(head,f.head)
    }
    func testMalformedTreeMetadataAndMissingRawDirectoriesDoNotBecomeRows()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let good=Data(("100644 blob "+f.blob+" 7\tvalid\0").utf8)
        XCTAssertEqual(try RepositoryBrowserListing.parse(Data(),directory:"").count,0)
        for invalid in [Data([0]),good+Data([0]),good+good,Data("100644 tree ".utf8)+Data((f.blob+" 7\tbad\0").utf8),Data(("100644 blob "+f.blob+" -1\tbad\0").utf8)] {
            XCTAssertThrowsError(try RepositoryBrowserListing.parse(invalid,directory:""))
        }
        let snapshot=try await f.repository.browseRepository(revision:f.tree)
        let missing=try RepositoryBrowserGitPath(rawData:Data([253]))
        do {_ = try await f.repository.browseRepositoryDirectory(snapshot,directory:missing.key);XCTFail("Missing raw directory borrowed replacement name")}catch RepositoryBrowserFailure.directory{}
        let invalidTree=RepositoryBrowserSnapshot(root:snapshot.root,revision:snapshot.revision,objectID:snapshot.objectID,treeID:"--help",directory:"",bare:false,entries:snapshot.entries)
        do {_ = try await f.repository.browseRepositoryDirectory(invalidTree,directory:missing.key);XCTFail("Unvalidated tree OID entered argv")}catch RepositoryBrowserFailure.directory{}
    }
    func testNoncanonicalRegularPermissionsRemainCanonicalSourceListingModes()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let oid=Data(stride(from:0,to:f.blob.count,by:2).map{offset -> UInt8 in
            let start=f.blob.index(f.blob.startIndex,offsetBy:offset),end=f.blob.index(start,offsetBy:2)
            return UInt8(f.blob[start..<end],radix:16)!
        })
        var raw=Data("100664 plain\0".utf8);raw.append(oid);raw.append(Data("100775 runnable\0".utf8));raw.append(oid)
        let tree=try await f.repository.run(["hash-object","--literally","-t","tree","-w","--stdin"],input:raw).text.trimmingCharacters(in:.newlines)
        let snapshot=try await f.repository.browseRepository(revision:tree)
        XCTAssertEqual(snapshot.entries.first{$0.path=="plain"}?.mode,"100644")
        XCTAssertEqual(snapshot.entries.first{$0.path=="runnable"}?.mode,"100755")
        XCTAssertEqual(snapshot.entries.first{$0.path=="plain"}?.kind,.file);XCTAssertEqual(snapshot.entries.first{$0.path=="runnable"}?.kind,.executable)
    }
}
