import XCTest
@testable import TurtleGitCore

final class FinderWatchRetirementTests:XCTestCase {
    private enum Refused:Error {case retiredWatch}
    private func fixture()throws->(URL,FinderSnapshotStore) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitWatchRetirement-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        return(folder,FinderSnapshotStore(url:folder.appendingPathComponent("status.json")))
    }
    private func snapshot(_ root:URL,_ state:FileState)->FinderSnapshot {
        .init(roots:[root.path],states:[root.path:state,root.appendingPathComponent("file").path:state],repositories:[root.path:.init()])
    }
    func testExactRetirementPreservesIndependentNestedTicketAndPeerContribution()throws {
        let(folder,store)=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let owner=try store.startSession(),peer=try store.startSession()
        defer{_=try? store.endSession(owner);_=try? store.endSession(peer)}
        let root=folder.appendingPathComponent("A"),nested=root.appendingPathComponent("nested"),other=folder.appendingPathComponent("B")
        let parent=try store.begin(root:root,session:owner)
        XCTAssertTrue(try store.publish(parent,snapshots:[snapshot(root,.modified)]).published)
        let child=try store.begin(root:nested,session:owner)
        XCTAssertTrue(try store.publish(child,snapshots:[snapshot(nested,.added)]).published)
        let heldChild=try store.begin(root:nested,session:owner)
        let otherTicket=try store.begin(root:other,session:peer)
        XCTAssertTrue(try store.publish(otherTicket,snapshots:[snapshot(other,.conflicted)]).published)
        let retired=try store.removeWatchContribution(root:root,session:owner,expected:parent)
        XCTAssertEqual(Set(retired.roots),Set([nested.path,other.path]))
        XCTAssertFalse(try store.publish(parent,snapshots:[snapshot(root,.normal)]).published)
        XCTAssertTrue(try store.publish(heldChild,snapshots:[snapshot(nested,.modified)]).published,"Exact parent retirement must not advance ancestor overlap sequence")
        XCTAssertEqual(try store.readLive().states[other.path],.conflicted)
    }
    func testLateRetirementCannotRemoveNewerSameSessionReplacementOrPeerClaim()throws {
        let(folder,store)=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let owner=try store.startSession(),peer=try store.startSession(),root=folder.appendingPathComponent("A")
        defer{_=try? store.endSession(owner);_=try? store.endSession(peer)}
        let old=try store.begin(root:root,session:owner)
        XCTAssertTrue(try store.publish(old,snapshots:[snapshot(root,.modified)]).published)
        let replacement=try store.begin(root:root,session:owner)
        XCTAssertTrue(try store.publish(replacement,snapshots:[snapshot(root,.added)]).published)
        XCTAssertEqual(try store.removeWatchContribution(root:root,session:owner,expected:old).states[root.path],.added)
        let peerTicket=try store.begin(root:root,session:peer)
        _=try store.removeWatchContribution(root:root,session:owner,expected:replacement)
        XCTAssertTrue(try store.publish(peerTicket,snapshots:[snapshot(root,.conflicted)]).published,"Old owner's cleanup revoked peer's exact-root claim")
        XCTAssertEqual(try store.readLive().states[root.path],.conflicted)
    }
    func testLatestUnpublishedCancelledBeginRetiresOlderContributionAndItsClaim()throws {
        let(folder,store)=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let owner=try store.startSession(),root=folder.appendingPathComponent("A")
        defer{_=try? store.endSession(owner)}
        let old=try store.begin(root:root,session:owner)
        XCTAssertTrue(try store.publish(old,snapshots:[snapshot(root,.modified)]).published)
        let token=OperationCancellation(),latest=try store.begin(root:root,session:owner,cancellation:token)
        token.cancel()
        XCTAssertThrowsError(try store.publish(latest,snapshots:[snapshot(root,.added)],cancellation:token))
        XCTAssertTrue(try store.removeWatchContribution(root:root,session:owner,expected:latest).roots.isEmpty)
        XCTAssertFalse(try store.publish(latest,snapshots:[snapshot(root,.added)]).published)
        XCTAssertFalse(try store.publish(old,snapshots:[snapshot(root,.normal)]).published)
    }
    func testStaleAuthorizationRefusesBeforeClaimOrOrderingMutation()throws {
        let(folder,store)=try fixture();defer{try? FileManager.default.removeItem(at:folder)}
        let oldOwner=try store.startSession(),newOwner=try store.startSession(),root=folder.appendingPathComponent("A")
        defer{_=try? store.endSession(oldOwner);_=try? store.endSession(newOwner)}
        let old=try store.begin(root:root,session:oldOwner)
        XCTAssertTrue(try store.publish(old,snapshots:[snapshot(root,.modified)]).published)
        let replacement=try store.begin(root:root,session:newOwner)
        let control=URL(fileURLWithPath:store.url.path+".writers"),before=try Data(contentsOf:control),raw=try Data(contentsOf:store.url)
        XCTAssertThrowsError(try store.begin(root:root,session:oldOwner,authorize:{throw Refused.retiredWatch}))
        XCTAssertEqual(try Data(contentsOf:control),before,"Rejected authorization changed claim/counter ordering")
        XCTAssertEqual(try Data(contentsOf:store.url),raw)
        _=try store.removeWatchContribution(root:root,session:oldOwner,expected:old)
        XCTAssertTrue(try store.publish(replacement,snapshots:[snapshot(root,.conflicted)]).published)
        XCTAssertEqual(try store.readLive().states[root.path],.conflicted)
    }
}
