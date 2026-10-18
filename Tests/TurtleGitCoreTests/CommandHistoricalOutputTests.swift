import XCTest
@testable import TurtleGitCore

final class CommandHistoricalOutputTests: XCTestCase {
    func folder() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitCommandOutput-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);return root
    }
    func repository(_ root:URL) async throws -> GitRepository {
        let repo=GitRepository(root:root);_ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Output QA"),("user.email","output@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("core.autocrlf","false")] {_ = try await repo.run(["config",key,value])}
        return repo
    }
    func testBlobCommitTreeExpressionsAndCheckoutFilters() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let repo=try await repository(root),directory=root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let path="folder/雪[*]\n.bin",bytes=Data([0,1,255,10,13,0,128])
        try bytes.write(to:FileTransferPaths.fileURL(root.path+"/"+path))
        try Data("*.text text eol=crlf\n".utf8).write(to:root.appendingPathComponent(".gitattributes"))
        try Data("first\nsecond\n".utf8).write(to:root.appendingPathComponent("line.text"))
        try await repo.stage([path,".gitattributes","line.text"]);_ = try await repo.commit(message:"files")
        let commit=try await repo.rebaseCommit("HEAD"),tree=try await repo.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
        let blob=try await repo.run(["rev-parse","--verify","HEAD:"+path]).text.trimmingCharacters(in:.newlines)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try FileManager.default.removeItem(at:directory)
        for revision in [commit.hash,tree,blob,"HEAD:"+path] {
            let result=try await repo.commandHistoricalFile(revision:revision,path:path,cancellation:OperationCancellation())
            XCTAssertEqual(result,bytes)
        }
        let filtered=try await repo.commandHistoricalFile(revision:commit.hash,path:"line.text",cancellation:OperationCancellation())
        XCTAssertEqual(filtered,Data("first\r\nsecond\r\n".utf8))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let head=try await repo.rebaseCommit("HEAD");XCTAssertEqual(head.hash,commit.hash)
    }
    func testReadFailuresAndCancellationDoNotMutateRepository() async throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let repo=try await repository(root);try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_ = try await repo.commandHistoricalFile(revision:"HEAD",path:"file",cancellation:cancelled);XCTFail("Cancelled Cat read succeeded")}catch is OperationCancellationFailure {}
        for (revision,path) in [("HEAD","missing"),("missing-ref","file"),("HEAD","../file"),("HEAD",".git/config"),("HEAD",".")] {
            do {_ = try await repo.commandHistoricalFile(revision:revision,path:path,cancellation:OperationCancellation());XCTFail("Invalid Cat succeeded: "+path)}catch {}
        }
        let bytes=try Data(contentsOf:root.appendingPathComponent("file"));XCTAssertEqual(bytes,Data("base\n".utf8))
    }
    func testStagingCancellationAtomicReplacementAndDiscard() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("output"),old=Data("old\n".utf8),bytes=Data((0..<200000).map {UInt8(truncatingIfNeeded:$0)})
        try old.write(to:file)
        let token=OperationCancellation(),staged=try PreparedCommandFile.prepare(bytes,to:file,cancellation:token)
        XCTAssertEqual(try Data(contentsOf:file),old);token.cancel()
        XCTAssertThrowsError(try staged.publish(cancellation:token));staged.discard();staged.discard()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["output"])
        XCTAssertEqual(try Data(contentsOf:file),old)
        let accepted=try PreparedCommandFile.prepare(bytes,to:file,cancellation:OperationCancellation())
        try accepted.publish(cancellation:OperationCancellation());accepted.discard()
        XCTAssertEqual(try Data(contentsOf:file),bytes)
        XCTAssertThrowsError(try accepted.publish(cancellation:OperationCancellation()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["output"])
    }
    func testDirectoryDescriptorPublicationAndSymlinkLeaf() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let parent=root.appendingPathComponent("parent"),moved=root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let staged=try PreparedCommandFile.prepare(Data("accepted".utf8),to:parent.appendingPathComponent("file"),cancellation:OperationCancellation())
        try FileManager.default.moveItem(at:parent,to:moved);try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let decoy=parent.appendingPathComponent("file");try Data("decoy".utf8).write(to:decoy)
        try staged.publish(cancellation:OperationCancellation())
        XCTAssertEqual(try Data(contentsOf:decoy),Data("decoy".utf8));XCTAssertEqual(try Data(contentsOf:moved.appendingPathComponent("file")),Data("accepted".utf8))
        let outside=root.appendingPathComponent("outside"),link=parent.appendingPathComponent("link");try Data("outside".utf8).write(to:outside)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        let replacing=try PreparedCommandFile.prepare(Data("file".utf8),to:link,cancellation:OperationCancellation());try replacing.publish(cancellation:OperationCancellation())
        XCTAssertEqual(try Data(contentsOf:outside),Data("outside".utf8));XCTAssertEqual(try Data(contentsOf:link),Data("file".utf8))
    }
    func testFailedPublicationAndPreCancelledStagingPreserveDestination() throws {
        let root=try folder();defer{try? FileManager.default.removeItem(at:root)}
        let target=root.appendingPathComponent("directory");try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let staged=try PreparedCommandFile.prepare(Data("bytes".utf8),to:target,cancellation:OperationCancellation())
        XCTAssertThrowsError(try staged.publish(cancellation:OperationCancellation()));staged.discard()
        let token=OperationCancellation();token.cancel();XCTAssertThrowsError(try PreparedCommandFile.prepare(Data(),to:root.appendingPathComponent("cancelled"),cancellation:token))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),["directory"])
    }
}
