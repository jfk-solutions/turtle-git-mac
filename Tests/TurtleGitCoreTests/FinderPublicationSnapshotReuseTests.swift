import Foundation
import Darwin
import XCTest
@testable import TurtleGitCore

final class FinderPublicationSnapshotReuseTests:XCTestCase {
    private func fixture()throws->(URL,FinderSnapshotStore) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("FinderSnapshotReuse-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        return (folder,FinderSnapshotStore(url:folder.appendingPathComponent("status.json")))
    }
    private func snapshot(_ root:URL,state:FileState = .modified)->FinderSnapshot {
        let a=root.path+"/café",b=root.path+"/cafe\u{301}"
        return FinderSnapshot(roots:[root.path],states:[a:state,b:.conflicted],updated:Date(timeIntervalSince1970:123),
                              repositories:[root.path:.init(bisectActive:true,mergeActive:true,hasStash:true,hasSubmoduleConfig:true,
                                                            submoduleParentRoot:root.path+"/cafe\u{301}",hasLFS:true,hasGitSVN:true)],
                              overlayEntries:[a:state,b:.added],
                              indexFlags:[a:.init(skipWorktree:true,assumeUnchanged:false),b:.init(skipWorktree:false,assumeUnchanged:true)],
                              overlayPolicies:[root.path:.init(identity:"fixture-policy",caseSensitive:false)])
    }
    private func decode(_ location:URL)throws->FinderSnapshot {
        try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:location))
    }
    private func replace(_ snapshot:FinderSnapshot,at location:URL)throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        try encoder.encode(snapshot).write(to:location,options:.atomic)
    }
    func testOwnPublicationsAndPeerSessionsReuseWrittenSnapshotsWithoutChangingExactBytesOrFences()throws {
        let(folder,store)=try fixture(),owner=try store.startSession()
        var peer:FinderPublicationSession?,ownerEnded=false
        let second=FinderSnapshotStore(url:store.url)
        defer{if let peer {_ = try? second.endSession(peer)};if !ownerEnded {_ = try? store.endSession(owner)};try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repo"),other=folder.appendingPathComponent("other")
        var first=snapshot(root)
        _ = try store.publish(store.begin(root:root,session:owner),snapshots:[first])
        let before=store.publicationWorkCounters
        peer=try second.startSession();let activePeer=try XCTUnwrap(peer)
        // Mutating the caller's copy must never mutate a cached wire snapshot.
        first.states[root.path+"/café"] = .deleted
        XCTAssertEqual(try decode(store.url).states[root.path+"/café"],.modified)
        XCTAssertEqual(try store.readLive().states[root.path+"/café"],.modified)
        _ = try second.publish(second.begin(root:other,session:activePeer),snapshots:[snapshot(other,state:.added)])
        let stale=try store.begin(root:root,session:owner),current=try second.begin(root:root,session:activePeer)
        XCTAssertFalse(try store.publish(stale,snapshots:[snapshot(root,state:.normal)]).published)
        let publicationBegan=Date()
        XCTAssertTrue(try second.publish(current,snapshots:[first]).published)
        let publicationEnded=Date()
        XCTAssertFalse(try second.publish(current,snapshots:[snapshot(root,state:.normal)]).published)
        let after=store.publicationWorkCounters
        XCTAssertEqual(after.rawDecodes,before.rawDecodes)
        XCTAssertEqual(after.warmDecodes,before.warmDecodes)
        XCTAssertGreaterThan(after.warmWrites,before.warmWrites)
        let raw=try decode(store.url),warm=try decode(store.warmURL),live=try store.readLive()
        XCTAssertEqual(raw.states,live.states);XCTAssertEqual(raw.overlayEntries,live.overlayEntries);XCTAssertEqual(raw.indexFlags,live.indexFlags)
        XCTAssertEqual(raw.roots,live.roots);XCTAssertEqual(raw.repositories,live.repositories)
        XCTAssertEqual(raw.overlayPolicies,live.overlayPolicies);XCTAssertEqual(raw.updated,live.updated)
        XCTAssertEqual(raw.liveRevision,live.liveRevision);XCTAssertNil(raw.persistenceFailure);XCTAssertNil(live.persistenceFailure)
        XCTAssertEqual(warm.states,live.states);XCTAssertEqual(warm.indexFlags,live.indexFlags)
        XCTAssertEqual(warm.repositories,live.repositories);XCTAssertEqual(warm.overlayEntries,live.overlayEntries)
        XCTAssertEqual(warm.overlayPolicies,live.overlayPolicies)
        // Live projection retains the scans' timestamp; the optional archive
        // records the subtree merge time under the established persistence policy.
        XCTAssertGreaterThanOrEqual(warm.updated,publicationBegan)
        XCTAssertLessThanOrEqual(warm.updated,publicationEnded)
        XCTAssertEqual(raw.states[root.path+"/café"],.deleted)
        XCTAssertEqual(raw.states[root.path+"/cafe\u{301}"],.conflicted)
        XCTAssertEqual(raw.states[other.path+"/café"],.added)
        XCTAssertNil(warm.liveRevision);XCTAssertNotNil(raw.liveRevision)
        let permissions=try FileManager.default.attributesOfItem(atPath:store.warmURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue,0o600)
        // Once both live publishers retire, a new claim restores the actual
        // saved subtree. Its cached timestamp and exact payload must agree with
        // an independent disk decode, rather than the earlier scan timestamp.
        _ = try store.endSession(owner);ownerEnded=true
        _ = try second.endSession(activePeer);peer=nil
        let archived=try decode(store.warmURL).subtree(root:root)
        let resumed=try store.startSession();defer{_ = try? store.endSession(resumed)}
        _ = try store.begin(root:root,session:resumed)
        let restored=try store.readLive()
        XCTAssertEqual(restored.updated,archived.updated)
        XCTAssertEqual(restored.states,archived.states);XCTAssertEqual(restored.repositories,archived.repositories)
        XCTAssertEqual(restored.overlayEntries,archived.overlayEntries);XCTAssertEqual(restored.indexFlags,archived.indexFlags)
        XCTAssertEqual(restored.overlayPolicies,archived.overlayPolicies)
    }
    func testExternalRawReplacementStillDecodesAndCorruptReplacementCannotBeOverwrittenByCachedSuccess()throws {
        let(folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repo")
        _ = try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root)])
        let bytes=try Data(contentsOf:store.url),before=store.publicationWorkCounters
        try bytes.write(to:store.url,options:.atomic)
        _ = try store.begin(root:root,session:owner)
        XCTAssertEqual(store.publicationWorkCounters.rawDecodes,before.rawDecodes+1)
        let corrupt=Data("external invalid live snapshot".utf8)
        try corrupt.write(to:store.url,options:.atomic)
        XCTAssertThrowsError(try store.begin(root:root,session:owner))
        XCTAssertThrowsError(try store.readLive())
        XCTAssertEqual(try Data(contentsOf:store.url),corrupt)
    }
    func testExternalWarmReplacementPreservesItsSiblingAndCorruptWarmStillRebuildsAfterAcceptedLivePublication()throws {
        let(folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repo"),sibling=folder.appendingPathComponent("archive-only")
        _ = try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root)])
        let before=store.publicationWorkCounters
        try replace(snapshot(sibling,state:.added),at:store.warmURL)
        let update=try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root,state:.deleted)])
        XCTAssertTrue(update.published);XCTAssertNil(update.persistenceFailure)
        XCTAssertEqual(store.publicationWorkCounters.warmDecodes,before.warmDecodes+1)
        let warm=try decode(store.warmURL)
        XCTAssertEqual(warm.states[sibling.path+"/café"],.added)
        XCTAssertEqual(warm.states[root.path+"/café"],.deleted)
        try Data("external invalid restart archive".utf8).write(to:store.warmURL,options:.atomic)
        let repaired=try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root,state:.normal)])
        XCTAssertTrue(repaired.published);XCTAssertTrue(repaired.warmCacheRebuilt);XCTAssertNotNil(repaired.persistenceFailure)
        XCTAssertEqual(try store.readLive().states[root.path+"/café"],.normal)
        XCTAssertEqual(try decode(store.warmURL).states[root.path+"/café"],.normal)
        XCTAssertNil(try decode(store.warmURL).states[sibling.path+"/café"])
    }
    func testWarmWriteRefusalRemainsVisibleAndLaterExternalRecoveryIsNotHiddenByPreviousMemoizedArchive()throws {
        let(folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repo"),sibling=folder.appendingPathComponent("recovered")
        _ = try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root)])
        try FileManager.default.removeItem(at:store.warmURL)
        try FileManager.default.createDirectory(at:store.warmURL,withIntermediateDirectories:false)
        let refused=try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root,state:.deleted)])
        XCTAssertTrue(refused.published);XCTAssertNotNil(refused.persistenceFailure);XCTAssertFalse(refused.warmCacheRebuilt)
        XCTAssertEqual(try store.readLive().states[root.path+"/café"],.deleted)
        try FileManager.default.removeItem(at:store.warmURL)
        try replace(snapshot(sibling,state:.added),at:store.warmURL)
        let recovered=try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root,state:.normal)])
        XCTAssertTrue(recovered.published);XCTAssertNil(recovered.persistenceFailure)
        XCTAssertEqual(try decode(store.warmURL).states[sibling.path+"/café"],.added)
        XCTAssertEqual(try decode(store.warmURL).states[root.path+"/café"],.normal)
    }
    func testSnapshotSymlinkRefusalsDoNotTouchTargetsOrLeaveOwnedStagingFiles()throws {
        let(folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repo"),target=folder.appendingPathComponent("unrelated")
        let bytes=Data("unrelated bytes".utf8);try bytes.write(to:target)
        _ = try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root)])
        try FileManager.default.removeItem(at:store.warmURL)
        try FileManager.default.createSymbolicLink(at:store.warmURL,withDestinationURL:target)
        let update=try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root,state:.added)])
        XCTAssertTrue(update.published);XCTAssertNotNil(update.persistenceFailure)
        XCTAssertEqual(try Data(contentsOf:target),bytes)
        try FileManager.default.removeItem(at:store.url)
        try FileManager.default.createSymbolicLink(at:store.url,withDestinationURL:target)
        XCTAssertThrowsError(try store.begin(root:root,session:owner))
        XCTAssertEqual(try Data(contentsOf:target),bytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:folder.path).contains {$0.hasPrefix(".finder-control-")})
    }
    func testDisabledRestartPersistenceDoesNotReuseOrResurrectTheWrittenWarmSnapshot()throws {
        let(folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repo")
        _ = try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root)])
        try store.setPersistence(.init(cacheSave:false))
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.warmURL.path))
        let before=store.publicationWorkCounters
        let result=try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root,state:.deleted)])
        XCTAssertTrue(result.published);XCTAssertNil(result.persistenceFailure)
        XCTAssertEqual(store.publicationWorkCounters.warmWrites,before.warmWrites)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.warmURL.path))
        try store.setPersistence(.init(cacheSave:true))
        let warm=try decode(store.warmURL)
        XCTAssertEqual(warm.states[root.path+"/café"],.deleted)
        XCTAssertEqual(warm.states[root.path+"/cafe\u{301}"],.conflicted)
        let stable=store.publicationWorkCounters
        try store.setPersistence(.init(cacheSave:true))
        XCTAssertEqual(store.publicationWorkCounters.warmWrites,stable.warmWrites)
        XCTAssertEqual(store.publicationWorkCounters.warmDecodes,stable.warmDecodes)
    }
    func testInPlaceSnapshotEditsWithRestoredModificationTimeInvalidateTheWrittenMemoizedValues()throws {
        let(folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repo")
        _ = try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root)])
        func editInPlacePreservingModificationTime(_ location:URL)throws {
            var before=stat();XCTAssertEqual(lstat(location.path,&before),0)
            let original=try Data(contentsOf:location)
            var edited=try decode(location);edited.updated=edited.updated.addingTimeInterval(1)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let replacement=try encoder.encode(edited)
            XCTAssertEqual(replacement.count,original.count);XCTAssertNotEqual(replacement,original)
            let handle=try FileHandle(forWritingTo:location);defer{try? handle.close()}
            try handle.write(contentsOf:replacement)
            let times=[before.st_atimespec,before.st_mtimespec]
            let result=location.path.withCString { path in
                times.withUnsafeBufferPointer { Darwin.utimensat(AT_FDCWD,path,$0.baseAddress,0) }
            }
            XCTAssertEqual(result,0)
            var after=stat();XCTAssertEqual(lstat(location.path,&after),0)
            XCTAssertEqual(after.st_dev,before.st_dev);XCTAssertEqual(after.st_ino,before.st_ino)
            XCTAssertEqual(after.st_size,before.st_size)
            XCTAssertEqual(after.st_mtimespec.tv_sec,before.st_mtimespec.tv_sec)
            XCTAssertEqual(after.st_mtimespec.tv_nsec,before.st_mtimespec.tv_nsec)
            XCTAssertTrue(after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec || after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec)
        }
        let before=store.publicationWorkCounters
        try editInPlacePreservingModificationTime(store.url)
        _ = try store.begin(root:root,session:owner)
        XCTAssertEqual(store.publicationWorkCounters.rawDecodes,before.rawDecodes+1)
        try editInPlacePreservingModificationTime(store.warmURL)
        let update=try store.publish(store.begin(root:root,session:owner),snapshots:[snapshot(root,state:.added)])
        XCTAssertTrue(update.published);XCTAssertNil(update.persistenceFailure)
        XCTAssertEqual(store.publicationWorkCounters.warmDecodes,before.warmDecodes+1)
        XCTAssertEqual(try decode(store.warmURL).states[root.path+"/café"],.added)
    }
}
