import Foundation
import XCTest
@testable import TurtleGitCore

final class FinderPublicationClaimTests:XCTestCase {
    private func fixture()throws->(URL,FinderSnapshotStore) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("FinderClaims-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return (folder,FinderSnapshotStore(url:folder.appendingPathComponent("status.json")))
    }
    private func snapshot(_ root:URL,count:Int=1,state:FileState = .normal)->FinderSnapshot {
        var entries:GitPathMap<FileState>=[root.path:state]
        for index in 0..<count {entries[root.appendingPathComponent("directory/file-\(index).txt").path]=state}
        entries[root.appendingPathComponent("café").path] = .added
        entries[root.appendingPathComponent("cafe\u{301}").path] = .conflicted
        return .init(roots:[root.path],states:entries,updated:Date(timeIntervalSince1970:123),repositories:[root.path:.init()],overlayEntries:entries)
    }
    private func inode(_ url:URL)throws->UInt64 {try XCTUnwrap(FileManager.default.attributesOfItem(atPath:url.path)[.systemFileNumber] as? NSNumber).uint64Value}
    private func wait(_ ready:()->Bool)async throws {
        for _ in 0..<1500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw NSError(domain:"FinderPublicationClaimTests",code:1,userInfo:[NSLocalizedDescriptionKey:"Owned cache operation did not reach its gate"])
    }

    func testRetainedClaimsDoNotRepeatLargePayloadWorkOrRewriteLiveAndWarmFiles()throws {
        let (folder,store)=try fixture();let owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repository",isDirectory:true),large=snapshot(root,count:10_001)
        _ = try store.publish(store.begin(root:root,session:owner),snapshots:[large])
        let warm=URL(fileURLWithPath:store.url.path+".warm"),control=URL(fileURLWithPath:store.url.path+".writers")
        let liveInode=try inode(store.url),warmInode=try inode(warm)
        // Atomic replacement with identical bytes creates a genuine cold file
        // identity without losing the actual process lease. No cache reset seam.
        try Data(contentsOf:control).write(to:control,options:.atomic)
        try Data(contentsOf:store.url).write(to:store.url,options:.atomic)
        let coldLiveInode=try inode(store.url),before=store.publicationWorkCounters
        let coldStart=ProcessInfo.processInfo.systemUptime
        _ = try store.begin(root:root,session:owner)
        let coldElapsed=ProcessInfo.processInfo.systemUptime-coldStart,cold=store.publicationWorkCounters
        XCTAssertGreaterThan(cold.controlDecodes,before.controlDecodes);XCTAssertGreaterThan(cold.rawDecodes,before.rawDecodes)
        XCTAssertGreaterThan(cold.contributionEncodes,before.contributionEncodes)
        let retainedStart=ProcessInfo.processInfo.systemUptime
        for _ in 0..<5 {_ = try store.begin(root:root,session:owner)}
        let retainedElapsed=ProcessInfo.processInfo.systemUptime-retainedStart,retained=store.publicationWorkCounters
        XCTAssertEqual(retained.controlDecodes,cold.controlDecodes)
        XCTAssertEqual(retained.rawDecodes,cold.rawDecodes)
        XCTAssertEqual(retained.contributionEncodes,cold.contributionEncodes)
        XCTAssertEqual(retained.projections,cold.projections)
        XCTAssertEqual(retained.controlWrites,cold.controlWrites+5)
        XCTAssertEqual(try inode(store.url),coldLiveInode);XCTAssertEqual(try inode(warm),warmInode)
        XCTAssertNotEqual(liveInode,coldLiveInode)
        let current=try store.readLive();XCTAssertEqual(current.states,large.states)
        XCTAssertEqual(current.overlayEntries,large.overlayEntries)
        print("Finder claim cost (private10001 files; no wall-clock threshold): cold=\(coldElapsed)s retained5=\(retainedElapsed)s; coldCounters=\(cold) retainedCounters=\(retained)")
    }

    func testSecondStoreSessionAndClaimPreserveLiveBytesAndNewerTicketFences()throws {
        let (folder,first)=try fixture(),owner=try first.startSession()
        let root=folder.appendingPathComponent("repository",isDirectory:true)
        _ = try first.publish(first.begin(root:root,session:owner),snapshots:[snapshot(root,state:.modified)])
        let bytes=try Data(contentsOf:first.url),rawInode=try inode(first.url)
        let second=FinderSnapshotStore(url:first.url),peer=try second.startSession()
        defer{_ = try? second.endSession(peer);_ = try? first.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        XCTAssertEqual(try inode(first.url),rawInode)
        let stale=try first.begin(root:root,session:owner),fresh=try second.begin(root:root,session:peer)
        XCTAssertEqual(try Data(contentsOf:first.url),bytes);XCTAssertEqual(try inode(first.url),rawInode)
        XCTAssertFalse(try first.publish(stale,snapshots:[snapshot(root,state:.normal)]).published)
        XCTAssertTrue(try second.publish(fresh,snapshots:[snapshot(root,state:.conflicted)]).published)
        XCTAssertEqual(try first.readLive().states[root.path],.conflicted)
        let json=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:first.url.path+".writers"))) as? [String:Any])
        XCTAssertEqual(json["version"] as? Int,4)
        XCTAssertEqual((json["contributions"] as? [[String:Any]])?.count,2)
    }

    func testExternalSameRevisionPayloadReplacementInvalidatesProjectionObjects()throws {
        let (folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repository",isDirectory:true)
        _ = try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root,state:.normal)])
        XCTAssertEqual(try store.readLive().states[root.path],.normal)
        let control=URL(fileURLWithPath:store.url.path+".writers")
        var wire=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:control)) as? [String:Any])
        var contributions=try XCTUnwrap(wire["contributions"] as? [[String:Any]])
        var snapshots=try XCTUnwrap(contributions[0]["snapshots"] as? [[String:Any]])
        var values=try XCTUnwrap(snapshots[0]["statesV2"] as? [[String:Any]])
        let index=try XCTUnwrap(values.firstIndex{($0["path"] as? String)==root.path})
        values[index]["value"]="conflicted";snapshots[0]["statesV2"]=values
        contributions[0]["snapshots"]=snapshots;wire["contributions"]=contributions
        // Store/session/sequence/revision deliberately unchanged. File identity
        // and exact immutable payload object identity must still invalidate.
        try JSONSerialization.data(withJSONObject:wire,options:.sortedKeys).write(to:control,options:.atomic)
        XCTAssertEqual(try store.readLive().states[root.path],.conflicted)
        let pending=try store.begin(root:root,session:owner)
        XCTAssertTrue(try store.publish(pending,snapshots:[snapshot(root,state:.added)]).published)
        XCTAssertEqual(try store.readLive().states[root.path],.added)
    }

    func testCanceledLocalQueueNeverClaimsOrOverwritesLivePayload()async throws {
        let (folder,first)=try fixture(),owner=try first.startSession()
        let second=FinderSnapshotStore(url:first.url),peer=try second.startSession()
        defer{_ = try? second.endSession(peer);_ = try? first.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repository",isDirectory:true)
        _ = try first.publish(first.begin(root:root,session:owner),snapshots:[snapshot(root,state:.modified)])
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let holder=Task.detached {try first.begin(root:root,session:owner,authorize:{entered.signal();_ = release.wait(timeout:.now()+20)})}
        try await wait{entered.wait(timeout:.now()) == .success}
        let token=OperationCancellation(),before=first.publicationWorkCounters
        let queued=Task.detached {try second.begin(root:root,session:peer,cancellation:token)}
        do {
            try await wait{first.publicationWorkCounters.localWaits>before.localWaits};token.cancel()
            do {_ = try await queued.value;XCTFail("Canceled queued writer acquired a claim")}
            catch OperationCancellationFailure.cancelled {}
            release.signal();let ticket=try await holder.value
            XCTAssertTrue(try first.publish(ticket,snapshots:[snapshot(root,state:.added)]).published)
            XCTAssertEqual(try second.readLive().states[root.path],.added)
        }catch {release.signal();_ = try? await holder.value;_ = try? await queued.value;throw error}
    }

    func testRejectedClaimAndCorruptOrSymlinkReplacementStayFailClosed()throws {
        let (folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repository",isDirectory:true)
        _ = try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root)])
        let control=URL(fileURLWithPath:store.url.path+".writers"),before=try Data(contentsOf:control)
        enum Refused:Error {case authority}
        XCTAssertThrowsError(try store.begin(root:root,session:owner,authorize:{throw Refused.authority}))
        XCTAssertEqual(try Data(contentsOf:control),before)
        try Data("corrupt control".utf8).write(to:control,options:.atomic)
        XCTAssertThrowsError(try store.begin(root:root,session:owner));XCTAssertThrowsError(try store.readLive())
        let foreign=folder.appendingPathComponent("foreign-control");try before.write(to:foreign)
        try FileManager.default.removeItem(at:control);try FileManager.default.createSymbolicLink(at:control,withDestinationURL:foreign)
        XCTAssertThrowsError(try store.begin(root:root,session:owner));XCTAssertEqual(try Data(contentsOf:foreign),before)
    }
}
