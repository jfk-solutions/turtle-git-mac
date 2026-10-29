import Foundation
import XCTest
@testable import TurtleGitCore

final class FinderPublicationRetirementTests:XCTestCase {
    private func fixture()throws->(URL,FinderSnapshotStore) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("FinderRetirement-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return (folder,FinderSnapshotStore(url:folder.appendingPathComponent("status.json")))
    }
    private func snapshot(_ root:String,count:Int=1,state:FileState = .normal,merging:Bool=false)->FinderSnapshot {
        var entries:GitPathMap<FileState>=[root:state]
        for index in 0..<count {entries[root+"/directory/file-\(index).txt"]=state}
        entries[root+"/caf\u{e9}.txt"] = .added;entries[root+"/cafe\u{301}.txt"] = .conflicted
        return .init(roots:[root],states:entries,updated:Date(timeIntervalSince1970:123),repositories:[root:.init(mergeActive:merging)],overlayEntries:entries,indexFlags:[root+"/flags":.init(skipWorktree:merging,assumeUnchanged:!merging)],overlayPolicies:[root:.init(identity:"private-policy",caseSensitive:true)])
    }
    private func publish(_ store:FinderSnapshotStore,_ owner:FinderPublicationSession,_ value:FinderSnapshot)throws {
        let root=URL(fileURLWithPath:try XCTUnwrap(value.roots.first),isDirectory:true)
        XCTAssertTrue(try store.publish(store.begin(root:root,session:owner),snapshots:[value]).published)
    }
    private func inode(_ url:URL)throws->UInt64 {try XCTUnwrap(FileManager.default.attributesOfItem(atPath:url.path)[.systemFileNumber] as? NSNumber).uint64Value}
    private func control(_ store:FinderSnapshotStore)throws->[String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:store.url.path+".writers"))) as? [String:Any])
    }

    func testCurrentMultiRootArchiveRetiresWithoutAnyWarmDecodeOrRewrite()throws {
        let (folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        try store.setPersistence(.init(cacheSave:true))
        for (root,count) in [("/retire-a",5000),("/retire-b",3000),("/retire-c",2001)] {try publish(store,owner,snapshot(root,count:count))}
        XCTAssertNotNil(try control(store)["warmMaintenance"])
        let warm=store.warmURL,bytes=try Data(contentsOf:warm),identity=try inode(warm),before=store.publicationWorkCounters
        let began=ProcessInfo.processInfo.systemUptime
        let retired=try store.endSession(owner),after=store.publicationWorkCounters
        XCTAssertTrue(retired.roots.isEmpty)
        XCTAssertEqual(after.warmWrites,before.warmWrites);XCTAssertEqual(after.warmDecodes,before.warmDecodes)
        XCTAssertEqual(try Data(contentsOf:warm),bytes);XCTAssertEqual(try inode(warm),identity)
        let liveBytes=try Data(contentsOf:store.url),liveInode=try inode(store.url),settled=store.publicationWorkCounters
        _ = try store.endSession(owner)
        XCTAssertEqual(try Data(contentsOf:store.url),liveBytes);XCTAssertEqual(try inode(store.url),liveInode)
        XCTAssertEqual(store.publicationWorkCounters.controlWrites,settled.controlWrites)
        XCTAssertEqual(store.publicationWorkCounters.warmWrites,settled.warmWrites)
        print("Finder retirement private10001 files: \(ProcessInfo.processInfo.systemUptime-began)s, warmWritesDelta=\(after.warmWrites-before.warmWrites), warmDecodesDelta=\(after.warmDecodes-before.warmDecodes); no timing threshold")
    }

    func testMissingReceiptMergesOnceButIdenticalArchiveKeepsColdSiblingsAndInode()throws {
        let (folder,store)=try fixture(),cold=try store.startSession()
        defer{try? FileManager.default.removeItem(at:folder)}
        try publish(store,cold,snapshot("/cold-sibling",state:.deleted,merging:true));_ = try store.endSession(cold)
        let owner=try store.startSession();defer{_ = try? store.endSession(owner)}
        try publish(store,owner,snapshot("/current-a",state:.modified));try publish(store,owner,snapshot("/current-b",state:.added,merging:true))
        // Remove only the optional receipt, preserving real warm data and every
        // lease/ticket field. Recovery must not require a receipt to be correct.
        let path=URL(fileURLWithPath:store.url.path+".writers")
        var wire=try control(store);wire.removeValue(forKey:"warmMaintenance")
        try JSONSerialization.data(withJSONObject:wire,options:.sortedKeys).write(to:path,options:.atomic)
        let bytes=try Data(contentsOf:store.warmURL),identity=try inode(store.warmURL),before=store.publicationWorkCounters
        _ = try store.endSession(owner)
        let after=store.publicationWorkCounters
        XCTAssertEqual(after.warmWrites,before.warmWrites);XCTAssertLessThanOrEqual(after.warmDecodes-before.warmDecodes,1)
        XCTAssertEqual(try Data(contentsOf:store.warmURL),bytes);XCTAssertEqual(try inode(store.warmURL),identity)
        let warm=try JSONDecoder().decode(FinderSnapshot.self,from:bytes)
        for root in ["/cold-sibling","/current-a","/current-b"] {
            XCTAssertEqual(warm.states[root+"/caf\u{e9}.txt"],.added);XCTAssertEqual(warm.states[root+"/cafe\u{301}.txt"],.conflicted)
        }
        XCTAssertTrue(warm.repositories["/cold-sibling"]?.mergeActive == true)
        XCTAssertEqual(warm.indexFlags?["/cold-sibling/flags"],.init(skipWorktree:true,assumeUnchanged:false))
        XCTAssertEqual(warm.overlayPolicies["/cold-sibling"]?.identity,"private-policy")
    }

    func testMissingArchiveRebuildsAllDepartingRootsWithOneWrite()throws {
        let (folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        try publish(store,owner,snapshot("/batch-a",state:.modified));try publish(store,owner,snapshot("/batch-b",state:.added,merging:true))
        try FileManager.default.removeItem(at:store.warmURL)
        let before=store.publicationWorkCounters
        let retired=try store.endSession(owner),after=store.publicationWorkCounters
        XCTAssertNil(retired.persistenceFailure);XCTAssertTrue(retired.roots.isEmpty)
        XCTAssertEqual(after.warmWrites-before.warmWrites,1)
        let warm=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL))
        XCTAssertEqual(GitPathSet(warm.roots),["/batch-a","/batch-b"])
        XCTAssertEqual(warm.states["/batch-a"],.modified);XCTAssertEqual(warm.states["/batch-b"],.added)
        XCTAssertTrue(warm.repositories["/batch-b"]?.mergeActive == true)
        XCTAssertEqual(warm.indexFlags?["/batch-b/flags"],.init(skipWorktree:true,assumeUnchanged:false))
    }

    func testOverlappingPeerExposureDoesNotAcquireFalseWarmAuthorityReceipt()throws {
        let (folder,store)=try fixture(),older=try store.startSession(),newer=try store.startSession()
        defer{_ = try? store.endSession(newer);_ = try? store.endSession(older);try? FileManager.default.removeItem(at:folder)}
        try publish(store,older,snapshot("/overlap",state:.added))
        try publish(store,newer,snapshot("/overlap",state:.modified,merging:true))
        try store.setPersistence(.init(cacheSave:true))
        let before=store.publicationWorkCounters,identity=try inode(store.warmURL)
        let afterNewer=try store.endSession(newer)
        XCTAssertEqual(afterNewer.states["/overlap"],.added)
        XCTAssertEqual(store.publicationWorkCounters.warmWrites,before.warmWrites);XCTAssertEqual(try inode(store.warmURL),identity)
        XCTAssertNil(try control(store)["warmMaintenance"],"Pre-retirement newer payload cannot certify an older exposed peer")
        let warmBefore=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL))
        XCTAssertEqual(warmBefore.states["/overlap"],.modified)
        _ = try store.endSession(older)
        XCTAssertEqual(store.publicationWorkCounters.warmWrites-before.warmWrites,1)
        let warmAfter=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL))
        XCTAssertEqual(warmAfter.states["/overlap"],.added);XCTAssertFalse(warmAfter.repositories["/overlap"]!.mergeActive)
    }

    func testNestedOlderPeerResurfacesWithoutFalseWarmReceipt()throws {
        let (folder,store)=try fixture(),older=try store.startSession(),newer=try store.startSession()
        defer{_ = try? store.endSession(newer);_ = try? store.endSession(older);try? FileManager.default.removeItem(at:folder)}
        var parent=snapshot("/parent",state:.added)
        parent.states["/parent/nested/file"] = .deleted
        try publish(store,older,parent)
        try publish(store,newer,snapshot("/parent/nested",state:.modified))
        try store.setPersistence(.init(cacheSave:true))
        _ = try store.endSession(newer)
        XCTAssertEqual(try store.readLive().states["/parent/nested/file"],.deleted)
        XCTAssertNil(try control(store)["warmMaintenance"])
        _ = try store.endSession(older)
        let warm=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL))
        XCTAssertEqual(warm.states["/parent/nested/file"],.deleted)
    }

    func testEmptyRetirementStillRemovesExpiredUnrelatedLivePeer()throws {
        let (folder,store)=try fixture(),expired=try store.startSession(),empty=try store.startSession()
        defer{_ = try? store.endSession(empty);_ = try? store.endSession(expired);try? FileManager.default.removeItem(at:folder)}
        try publish(store,expired,snapshot("/expired",state:.modified))
        let lease=URL(fileURLWithPath:store.url.path+".sessions").appendingPathComponent(expired.id.uuidString+".lease")
        try FileManager.default.removeItem(at:lease)
        let before=store.publicationWorkCounters
        XCTAssertTrue(try store.endSession(empty).roots.isEmpty)
        XCTAssertTrue(try store.readLive().roots.isEmpty)
        XCTAssertEqual(store.publicationWorkCounters.warmWrites,before.warmWrites)
        let raw=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.url))
        XCTAssertTrue(raw.roots.isEmpty,"The no-contribution shortcut must still clean expired peers")
    }

    func testMetadataOnlyCanonicalParentChangeRequiresExactArchiveWrite()throws {
        let (folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        var value=snapshot("/child")
        let accepted="/caf\u{e9}",external="/cafe\u{301}"
        value.repositories["/child"]?.submoduleParentRoot=accepted
        try publish(store,owner,value)
        var archive=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL))
        archive.repositories["/child"]?.submoduleParentRoot=external
        try JSONEncoder().encode(archive).write(to:store.warmURL,options:.atomic)
        let before=store.publicationWorkCounters
        _ = try store.endSession(owner)
        XCTAssertEqual(store.publicationWorkCounters.warmWrites-before.warmWrites,1)
        let result=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL))
        XCTAssertTrue(GitReferenceName.equal(try XCTUnwrap(result.repositories["/child"]?.submoduleParentRoot),accepted))
        XCTAssertFalse(GitReferenceName.equal(accepted,external))
    }

    func testEmptyClaimRetirementPreservesPayloadsAndRevokesOnlyOwnedClaim()throws {
        let (folder,store)=try fixture(),owner=try store.startSession(),claimant=try store.startSession()
        defer{_ = try? store.endSession(claimant);_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=URL(fileURLWithPath:"/still-live",isDirectory:true)
        try publish(store,owner,snapshot(root.path,state:.modified))
        let abandoned=try store.begin(root:root,session:claimant)
        let raw=try Data(contentsOf:store.url),rawInode=try inode(store.url),warm=try Data(contentsOf:store.warmURL),warmInode=try inode(store.warmURL),before=store.publicationWorkCounters
        let retired=try store.endSession(claimant)
        XCTAssertEqual(retired.states[root.path],.modified)
        XCTAssertEqual(try Data(contentsOf:store.url),raw);XCTAssertEqual(try inode(store.url),rawInode)
        XCTAssertEqual(try Data(contentsOf:store.warmURL),warm);XCTAssertEqual(try inode(store.warmURL),warmInode)
        XCTAssertEqual(store.publicationWorkCounters.warmWrites,before.warmWrites)
        XCTAssertFalse(try store.publish(abandoned,snapshots:[snapshot(root.path,state:.deleted)]).published)
        try publish(store,owner,snapshot(root.path,state:.conflicted))
        XCTAssertEqual(try store.readLive().states[root.path],.conflicted)
    }
}
