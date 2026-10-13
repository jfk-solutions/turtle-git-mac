import XCTest
import Darwin
@testable import TurtleGitCore

final class FinderPublicationTests:XCTestCase {
    func fixture() throws -> (URL,FinderSnapshotStore) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPublication-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        return (root,FinderSnapshotStore(url:root.appendingPathComponent("status.json")))
    }
    func snapshot(_ root:URL,_ state:FileState) -> FinderSnapshot {
        FinderSnapshot(roots:[root.path],states:[root.path:state,root.appendingPathComponent("file").path:state],repositories:[root.path:FinderRepositoryMetadata()])
    }
    func testIndependentRootsMergeAndTicketsAreConsumedOnce() throws {
        let (folder,store)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let a=URL(fileURLWithPath:"/repo-a"),b=URL(fileURLWithPath:"/repo-b")
        let ticketA=try store.begin(root:a),ticketB=try store.begin(root:b)
        XCTAssertTrue(try store.publish(ticketB,snapshots:[snapshot(b,.added)]).published)
        let result=try store.publish(ticketA,snapshots:[snapshot(a,.modified)])
        XCTAssertTrue(result.published);XCTAssertEqual(Set(result.snapshot.roots),[a.path,b.path])
        XCTAssertEqual(result.snapshot.states[b.appendingPathComponent("file").path],.added)
        let bytes=try Data(contentsOf:store.url)
        XCTAssertFalse(try store.publish(ticketA,snapshots:[snapshot(a,.normal)]).published)
        XCTAssertEqual(bytes,try Data(contentsOf:store.url))
    }
    func testSupersededAndOverlappingReadsCannotOverwriteFreshData() throws {
        let (folder,store)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let root=URL(fileURLWithPath:"/repo"),nested=root.appendingPathComponent("nested")
        let old=try store.begin(root:root),new=try store.begin(root:root)
        _ = try store.publish(new,snapshots:[snapshot(root,.conflicted)])
        XCTAssertFalse(try store.publish(old,snapshots:[snapshot(root,.normal)]).published)
        let parent=try store.begin(root:root),child=try store.begin(root:nested)
        _ = try store.publish(child,snapshots:[snapshot(nested,.modified)])
        XCTAssertFalse(try store.publish(parent,snapshots:[snapshot(root,.normal)]).published)
        let freshParent=try store.begin(root:root)
        let result=try store.publish(freshParent,snapshots:[snapshot(root,.normal)])
        XCTAssertTrue(result.published);XCTAssertEqual(result.snapshot.states[nested.appendingPathComponent("file").path],.modified)
    }
    func testRemovalInvalidatesReadsAndPreservesOtherRoots() throws {
        let (folder,store)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let a=URL(fileURLWithPath:"/repo-a"),b=URL(fileURLWithPath:"/repo-b")
        _ = try store.publish(store.begin(root:a),snapshots:[snapshot(a,.modified)])
        _ = try store.publish(store.begin(root:b),snapshots:[snapshot(b,.normal)])
        let pending=try store.begin(root:a),removed=try store.remove(root:a)
        XCTAssertEqual(removed.roots,[b.path]);XCTAssertFalse(try store.publish(pending,snapshots:[snapshot(a,.modified)]).published)
        XCTAssertFalse(try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.url)).roots.contains(a.path))
    }
    func testInvalidPayloadAndCorruptionNeverReplacePreviousSnapshot() throws {
        let (folder,store)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let root=URL(fileURLWithPath:"/repo"),ticket=try store.begin(root:root)
        _ = try store.publish(ticket,snapshots:[snapshot(root,.normal)])
        let original=try Data(contentsOf:store.url),fresh=try store.begin(root:root)
        let escaped=FinderSnapshot(roots:[root.path],states:["/other/file":.modified])
        XCTAssertThrowsError(try store.publish(fresh,snapshots:[escaped]));XCTAssertEqual(original,try Data(contentsOf:store.url))
        try Data("invalid json".utf8).write(to:store.url)
        XCTAssertThrowsError(try store.publish(fresh,snapshots:[snapshot(root,.modified)]));XCTAssertEqual(try Data(contentsOf:store.url),Data("invalid json".utf8))
    }
    func testLockCancellationAndForeignStoreTickets() async throws {
        let (folder,store)=try fixture();defer { try? FileManager.default.removeItem(at:folder) }
        let root=URL(fileURLWithPath:"/repo"),ticket=try store.begin(root:root)
        let foreign=FinderSnapshotStore(url:folder.appendingPathComponent("foreign.json"));_ = try foreign.begin(root:root)
        XCTAssertFalse(try foreign.publish(ticket,snapshots:[snapshot(root,.normal)]).published)
        let descriptor=Darwin.open(store.url.path+".lock",O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor,0);defer { flock(descriptor,LOCK_UN);Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor,LOCK_EX),0)
        let token=OperationCancellation(),operation=Task.detached { try store.begin(root:root,cancellation:token) }
        try await Task.sleep(nanoseconds:30_000_000);token.cancel()
        do { _ = try await operation.value;XCTFail("Cancelled lock wait acquired a ticket") } catch OperationCancellationFailure.cancelled {}
    }
}
