import XCTest
@testable import TurtleGitCore

final class CommitFileListSupplementaryTests:XCTestCase {
    private func fixture()async throws->(URL,GitRepository,String) {try await GitPatchTests().fixture()}
    func testScopedDisplayRetainsExactNameCatalogAndRequestedDirectoryFacts()async throws {
        let(root,repo,path)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let a="café/missing",b="cafe\u{301}/missing",first="réview",second="re\u{301}view"
        try FileManager.default.createDirectory(at:root.appendingPathComponent("directory"),withIntermediateDirectories:true)
        _=try await repo.assignChangelist(paths:[path,a],name:first)
        _=try await repo.assignChangelist(paths:[b],name:second)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),lists=try Data(contentsOf:root.appendingPathComponent(".git/turtlegit-changelists.json"))
        let read=try await repo.commitFileListSupplementary(paths:[path,"directory",a,b],columns:[.fileExtension])
        XCTAssertEqual(read.metadata["directory"]?.isDirectory,true)
        XCTAssertNil(read.metadata[path]?.size);XCTAssertNil(read.metadata[path]?.modificationDate)
        XCTAssertEqual(read.changelists.exactAssignments.count,3);XCTAssertEqual(read.changelistNames.count,2)
        XCTAssertTrue(GitReferenceName.equal(try XCTUnwrap(read.changelists.name(for:a)),first))
        XCTAssertTrue(GitReferenceName.equal(try XCTUnwrap(read.changelists.name(for:b)),second))
        let scoped=try await repo.commitFileListSupplementary(paths:[path],columns:[])
        XCTAssertTrue(scoped.metadata.isEmpty,"No filesystem metadata columns requested")
        XCTAssertEqual(scoped.changelists.exactAssignments.count,1);XCTAssertEqual(scoped.changelistNames.count,2)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/turtlegit-changelists.json")),lists)
    }
    func testScopedDisplaySkipsOnlyUnrelatedFilesystemContainmentAndRevalidatesNextOperation()async throws {
        let(root,repo,path)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let outside=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:outside)}
        let parent=root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        _=try await repo.assignChangelist(paths:[path,"parent/other"],name:"Preserved")
        let initial=try await repo.commitFileListSupplementary(paths:["parent/other"],columns:[])
        XCTAssertEqual(initial.changelists.name(for:"parent/other"),"Preserved")
        try FileManager.default.removeItem(at:parent);try FileManager.default.createSymbolicLink(at:parent,withDestinationURL:outside)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),file=root.appendingPathComponent(".git/turtlegit-changelists.json"),before=try Data(contentsOf:file)
        let scoped=try await repo.commitFileListSupplementary(paths:[path],columns:[])
        XCTAssertNil(scoped.changelists.name(for:"parent/other"));XCTAssertEqual(scoped.changelistNames.map(\.rawValue),["Preserved"])
        do {_=try await repo.commitFileListSupplementary(paths:["parent/other"],columns:[]);XCTFail("New operation trusted old safe parent")}catch is WorkingFileRestoreFailure {}
        do {_=try await repo.changelists();XCTFail("Full API skipped unrelated containment")}catch is WorkingFileRestoreFailure {}
        do {_=try await repo.assignChangelist(paths:[path],name:"Changed");XCTFail("Mutation used display projection as authority")}catch is WorkingFileRestoreFailure {}
        XCTAssertEqual(try Data(contentsOf:file),before);XCTAssertFalse(FileManager.default.fileExists(atPath:file.path+".lock"))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
    func testScopedDisplayRefusesHostileOutOfScopePathsNamesAndDuplicateRows()async throws {
        let(root,repo,path)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent(".git/turtlegit-changelists.json")
        let rows:[[[String:String]]]=[
            [["path":"../outside","name":"X"]],[["path":"/absolute","name":"X"]],[["path":".GiT/index","name":"X"]],[["path":"nested/../bad","name":"X"]],[["path":"bad\0path","name":"X"]],
            [["path":"other","name":""]],[["path":"other","name":"bad\0name"]],[["path":"other","name":"A"],["path":"other","name":"B"]]
        ]
        for assignments in rows {
            let bytes=try JSONSerialization.data(withJSONObject:["version":2,"assignments":assignments]);try bytes.write(to:file)
            do {_=try await repo.commitFileListSupplementary(paths:[path],columns:[]);XCTFail("Scoped display accepted hostile unrelated row: \(assignments)")}catch {}
            XCTAssertEqual(try Data(contentsOf:file),bytes)
        }
    }
    func testCancellableColumnMetadataPreservesMissingAndFinalSymlinkSemantics()async throws {
        let(root,repo,path)=try await fixture();defer{try? FileManager.default.removeItem(at:root)}
        let final="literal-link",target="/missing/external"
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent(final).path,withDestinationPath:target)
        let metadata=try await repo.statusListMetadata(paths:[path,final,"missing","../outside"],columns:[.fileSize])
        XCTAssertEqual(metadata[final]?.size,Int64(target.utf8.count));XCTAssertEqual(metadata[final]?.isDirectory,false)
        XCTAssertNil(metadata[path]?.modificationDate);XCTAssertNil(metadata["missing"]?.size);XCTAssertNil(metadata["../outside"]?.size)
        let token=OperationCancellation();token.cancel()
        do {_=try await repo.statusListMetadata(paths:[path],columns:[.fileSize],cancellation:token);XCTFail("Cancelled metadata read succeeded")}catch is OperationCancellationFailure {}
        do {_=try await repo.commitFileListSupplementary(paths:[path],columns:[],cancellation:token);XCTFail("Cancelled supplementary read succeeded")}catch is OperationCancellationFailure {}
    }
}
