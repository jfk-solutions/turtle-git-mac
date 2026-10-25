import XCTest
@testable import TurtleGitCore

final class RepositoryBrowserNamespaceTransferTests:XCTestCase {
    private struct Fixture {
        let root:URL,repo:GitRepository,snapshot:RepositoryBrowserSnapshot,bytes:Data
    }
    private func fixture()async throws->Fixture {
        let(root,repo,_)=try await GitPatchTests().fixture()
        do {
            let bytes=Data([0,0xff,0x41,0x0a])
            func oid(_ arguments:[String],input:Data)async throws->String {
                try await repo.run(arguments,input:input).text.trimmingCharacters(in:.newlines)
            }
            let blob=try await oid(["hash-object","-w","--stdin"],input:bytes)
            func tree(_ records:[(String,String,String,Data)])async throws->String {
                var data=Data()
                for(mode,type,oid,name)in records {data.append(Data("\(mode) \(type) \(oid)\t".utf8));data.append(name);data.append(0)}
                return try await oid(["mktree","-z"],input:data)
            }
            let good=try await tree([("100644","blob",blob,Data("literal\tline\n雪.txt".utf8))])
            let bad=try await tree([("100644","blob",blob,Data("first-valid.txt".utf8)),("100644","blob",blob,Data([0xff,0x2e,0x74,0x78,0x74]))])
            let empty=try await tree([])
            let top=try await tree([("100644","blob",blob,Data("valid.txt".utf8)),("100644","blob",blob,Data("�.txt".utf8)),("100644","blob",blob,Data("\\xFF.txt".utf8)),("040000","tree",good,Data("good".utf8)),("040000","tree",bad,Data("bad".utf8)),("040000","tree",empty,Data([0xfe]))])
            return Fixture(root:root,repo:repo,snapshot:try await repo.browseRepository(revision:top),bytes:bytes)
        } catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    func testValidSiblingAndLiteralDisplayLookingNamesDeliverOriginalBytes()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let head=try await f.repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        let inventory=try await f.repo.repositoryBrowserTransferInventory(f.snapshot)
        XCTAssertTrue(inventory.contains{!$0.isPathRepresentable})
        for name in ["valid.txt","�.txt","\\xFF.txt"] {
            let entry=try XCTUnwrap(f.snapshot.entries.first{$0.rawName==Data(name.utf8)})
            try RepositoryBrowserTransferPolicy.validateSelection(f.snapshot,selected:[entry],inventory:inventory)
            let export=try await f.repo.exportRepositoryBrowser(f.snapshot,entry:entry)
            defer{export.discard()}
            XCTAssertEqual(Data(export.item.lastPathComponent.utf8),Data(name.utf8))
            XCTAssertEqual(try Data(contentsOf:export.item),f.bytes)
            XCTAssertEqual(export.fileCount,1)
        }
        let after=try await f.repo.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(after,head);XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
    }
    func testFolderPreflightRejectsRawDescendantAndEntireMixedSelection()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let bad=try XCTUnwrap(f.snapshot.entries.first{$0.path=="bad"}),good=try XCTUnwrap(f.snapshot.entries.first{$0.path=="valid.txt"})
        let inventory=try await f.repo.repositoryBrowserTransferInventory(f.snapshot)
        XCTAssertThrowsError(try RepositoryBrowserTransferPolicy.validateSelection(f.snapshot,selected:[bad,good],inventory:inventory)) {error in
            guard case RepositoryBrowserTransferFailure.unrepresentablePath(let display)=error else{return XCTFail("Wrong refusal: \(error)")}
            XCTAssertTrue(display.hasPrefix("bad/"));XCTAssertFalse(display.contains("\0"))
        }
        XCTAssertThrowsError(try RepositoryBrowserTransferPolicy.validateSelection(f.snapshot,selected:[bad],inventory:nil)) {error in
            guard case RepositoryBrowserTransferFailure.incompleteInventory=error else{return XCTFail("Wrong inventory refusal: \(error)")}
        }
        // Rejection happens before creating the export container or reading any
        // valid earlier child; there is no partial folder receipt to publish.
        let temporary=try TurtleGitTemporaryStorage.root
        let before=Set(try FileManager.default.contentsOfDirectory(atPath:temporary.path).filter{$0.hasPrefix("TurtleGitBrowserExport-")})
        let selections:[RepositoryBrowserEntry?]=[bad,nil]
        for entry in selections {
            do{_=try await f.repo.exportRepositoryBrowser(f.snapshot,entry:entry);XCTFail("Partial raw namespace exported")}
            catch RepositoryBrowserTransferFailure.unrepresentablePath {}
        }
        let after=Set(try FileManager.default.contentsOfDirectory(atPath:temporary.path).filter{$0.hasPrefix("TurtleGitBrowserExport-")})
        XCTAssertEqual(after,before)
    }
    func testGoodSubtreeIgnoresUnrelatedRawInventoryAndPreservesLiteralUnicode()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let good=try XCTUnwrap(f.snapshot.entries.first{$0.path=="good"})
        let inventory=try await f.repo.repositoryBrowserTransferInventory(f.snapshot)
        try RepositoryBrowserTransferPolicy.validateSelection(f.snapshot,selected:[good],inventory:inventory)
        let export=try await f.repo.exportRepositoryBrowser(f.snapshot,entry:good);defer{export.discard()}
        let names=try FileManager.default.contentsOfDirectory(atPath:export.item.path)
        XCTAssertEqual(names.count,1);XCTAssertEqual(Data(names[0].utf8),Data("literal\tline\n雪.txt".utf8))
        XCTAssertEqual(try Data(contentsOf:export.item.appendingPathComponent(names[0])),f.bytes)
        let token=OperationCancellation();token.cancel()
        do{_=try await f.repo.exportRepositoryBrowser(f.snapshot,entry:good,cancellation:token);XCTFail("Cancelled export delivered")}
        catch is OperationCancellationFailure {}
    }
    func testRawEmptyDirectoryAndValidLeafUnderRawParentCannotBecomeNativePaths()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let raw=try XCTUnwrap(f.snapshot.entries.first{!$0.isPathRepresentable})
        XCTAssertEqual(raw.kind,.directory)
        XCTAssertThrowsError(try RepositoryBrowserTransferPolicy.validateDirectory(raw.path)) {error in
            guard case RepositoryBrowserTransferFailure.unrepresentablePath=error else{return XCTFail("Wrong raw key refusal: \(error)")}
        }
        do{_=try await f.repo.exportRepositoryBrowser(f.snapshot,entry:raw);XCTFail("Raw empty directory exported")}
        catch RepositoryBrowserTransferFailure.unrepresentablePath {}
        let path=try RepositoryBrowserGitPath(rawData:raw.rawPath+Data("/valid.txt".utf8))
        let child=RepositoryBrowserEntry(path:path.key,name:"valid.txt",mode:"100644",objectID:String(repeating:"a",count:40),size:1)
        XCTAssertFalse(child.isPathRepresentable)
        XCTAssertFalse(RepositoryBrowserListing.validPath(path.key,allowRoot:false))
        let missing=GitLibGit2Configuration(enabled:true,helperURL:f.root.appendingPathComponent("missing-helper"))
        do{_=try await f.repo.materializedHistoricalFile(revision:"not-a-revision",path:path.key,backend:missing);XCTFail("Opaque key reached historical lookup")}
        catch RevisionComparisonFailure.selection {}
        do{_=try await f.repo.materializedBlob(objectID:child.objectID,path:path.key,revision:child.objectID,mode:"100644",cancellation:OperationCancellation(),backend:missing);XCTFail("Opaque key reached checkout filter")}
        catch RevisionComparisonFailure.selection {}
        XCTAssertThrowsError(try RepositoryBrowserTransferPolicy.validate(f.snapshot,entries:[child]))
        try RepositoryBrowserTransferPolicy.validateDirectory("good")
        try RepositoryBrowserTransferPolicy.validateDirectory("")
    }
}
