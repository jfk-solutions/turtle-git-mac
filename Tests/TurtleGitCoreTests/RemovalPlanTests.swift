import XCTest
@testable import TurtleGitCore
final class RemovalPlanTests:XCTestCase {
    func testConfirmedPlanRefusesChangedStagingWorkingContentsAndHead()async throws{
        let (root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let plan=try await repo.prepareRemoval(path,keepLocal:false)
        try Data("replaced".utf8).write(to:root.appendingPathComponent(path),options:.atomic)
        do{_ = try await repo.executeRemoval(plan);XCTFail("Deleted replaced file")}catch RemovalFailure.changed{}
        let fresh=try await repo.prepareRemoval(path,keepLocal:true);try await repo.stage([path])
        do{_ = try await repo.executeRemoval(fresh);XCTFail("Deleted changed staged data")}catch RemovalFailure.changed{}
        let next=try await repo.prepareRemoval(path,keepLocal:false);_ = try await repo.run(["commit","--allow-empty","-m","other head"])
        do{_ = try await repo.executeRemoval(next);XCTFail("Deleted under new HEAD")}catch RemovalFailure.changed{}
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))
    }
    final class Chunks:@unchecked Sendable {let lock=NSLock();var data=Data();func add(_ value:GitOutputChunk){lock.lock();data.append(value.data);lock.unlock()}}
    func testActualLiteralRemovalStreamsAndKeepLocalRetainsWorkingBytes()async throws{
        let (root,repo,_)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let path="-雪\n[*].txt";try Data("staged".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);try Data("working".utf8).write(to:root.appendingPathComponent(path))
        let plan=try await repo.prepareRemoval(path,keepLocal:true),chunks=Chunks(),head=try await repo.run(["rev-parse","HEAD"]).stdout
        _ = try await repo.executeRemoval(plan,onOutput:chunks.add)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(path)),"working");XCTAssertFalse(chunks.data.isEmpty)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(head,after)
    }
    func testCancelledPlanExecutionAndPreparationDoNotModifyIndex()async throws{
        let (root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let plan=try await repo.prepareRemoval(path,keepLocal:false),index=try Data(contentsOf:root.appendingPathComponent(".git/index")),token=OperationCancellation();token.cancel()
        do{_ = try await repo.executeRemoval(plan,cancellation:token);XCTFail("Cancelled deletion ran")}catch OperationCancellationFailure.cancelled{}
        do{_ = try await repo.prepareRemoval(path,keepLocal:true,cancellation:token);XCTFail("Cancelled plan prepared")}catch OperationCancellationFailure.cancelled{}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }
}
