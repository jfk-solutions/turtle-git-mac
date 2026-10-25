import XCTest
import Darwin
@testable import TurtleGitCore

final class FinderCachePersistenceTests: XCTestCase {
    private func fixture() throws -> (URL, FinderSnapshotStore) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitWarmCache-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        return (directory,FinderSnapshotStore(url:directory.appendingPathComponent("status.json")))
    }
    private func snapshot(_ path:String,_ state:FileState) -> FinderSnapshot {
        FinderSnapshot(roots:[path],states:[path:state,path+"/file":state],repositories:[path:.init()])
    }
    private func publish(_ store:FinderSnapshotStore,_ session:FinderPublicationSession,_ path:String,_ state:FileState) throws -> FinderPublicationResult {
        // Foundation's fileURLWithPath may decompose Unicode on Darwin;
        // fixtures carrying Git's raw identity must preserve its exact spelling.
        let ticket=try store.begin(root:FileTransferPaths.fileURL(path),session:session)
        XCTAssertEqual(Data(ticket.root.utf8),Data(path.utf8))
        return try store.publish(ticket,snapshots:[snapshot(path,state)])
    }
    func testWarmDataNeedsAnExplicitRootClaimAndDisableKeepsLiveBadges() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        XCTAssertTrue(try store.persistence().cacheSave)
        let first=try store.startSession()
        XCTAssertTrue(try publish(store,first,"/allowed",.modified).published)
        XCTAssertTrue(try publish(store,first,"/unclaimed",.conflicted).published)
        _ = try store.endSession(first)
        XCTAssertTrue(try store.readLive().roots.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:store.warmURL.path))
        let restarted=FinderSnapshotStore(url:store.url),second=try restarted.startSession()
        XCTAssertTrue(try restarted.readLive().roots.isEmpty)
        let pending=try restarted.begin(root:URL(fileURLWithPath:"/allowed"),session:second)
        XCTAssertEqual(try restarted.readLive().roots,["/allowed"])
        XCTAssertEqual(try restarted.readLive().states["/allowed/file"],.modified)
        try restarted.setPersistence(.init(cacheSave:false))
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.warmURL.path))
        XCTAssertEqual(try restarted.readLive().states["/allowed/file"],.modified)
        // A policy change neither consumes nor invalidates an in-flight read.
        XCTAssertTrue(try restarted.publish(pending,snapshots:[snapshot("/allowed",.added)]).published)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.warmURL.path))
        _ = try restarted.endSession(second)
        XCTAssertFalse(try FinderSnapshotStore(url:store.url).persistence().cacheSave)
        let third=try store.startSession();defer {_ = try? store.endSession(third)}
        _ = try store.begin(root:URL(fileURLWithPath:"/allowed"),session:third)
        XCTAssertTrue(try store.readLive().roots.isEmpty)
    }
    func testRetiringOverlappingOwnersRevealsOtherLiveContributions() throws {
        let (directory,a)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let b=FinderSnapshotStore(url:a.url),one=try a.startSession(),two=try b.startSession()
        _ = try publish(a,one,"/repo",.modified)
        _ = try publish(a,one,"/independent",.added)
        _ = try publish(b,two,"/repo",.conflicted)
        let before=try a.readLive()
        XCTAssertEqual(before.states["/repo/file"],.conflicted)
        _ = try b.endSession(two)
        let after=try a.readLive()
        XCTAssertEqual(after.states["/repo/file"],.modified)
        XCTAssertEqual(after.states["/independent/file"],.added)
        XCTAssertNotEqual(before.liveRevision,after.liveRevision)
        XCTAssertEqual(after.liveRevision,try a.readLive().liveRevision)
        // Repeating cleanup is harmless, and a retired owner cannot claim again.
        _ = try b.endSession(two)
        XCTAssertThrowsError(try b.begin(root:URL(fileURLWithPath:"/repo"),session:two))
        _ = try a.endSession(one)
    }
    func testStoreLifetimeLeaseFiltersStaleRawStatusAndRejectsOldTickets() throws {
        let (directory,reader)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        var writer:FinderSnapshotStore?=FinderSnapshotStore(url:reader.url)
        let session=try XCTUnwrap(writer).startSession()
        _ = try publish(try XCTUnwrap(writer),session,"/old",.modified)
        let pending=try XCTUnwrap(writer).begin(root:URL(fileURLWithPath:"/old"),session:session)
        let liveReader=FinderSnapshotLiveReader(url:reader.url)
        let raw=try Data(contentsOf:reader.url),identity=try liveReader.read().liveRevision
        writer=nil // Simulates an owner disappearing without writing an empty projection.
        XCTAssertEqual(try Data(contentsOf:reader.url),raw)
        let filtered=try liveReader.read()
        XCTAssertTrue(filtered.roots.isEmpty);XCTAssertNotEqual(identity,filtered.liveRevision)
        XCTAssertTrue(FinderSnapshot.readLive(from:reader.url)?.roots.isEmpty == true)
        XCTAssertFalse(try reader.publish(pending,snapshots:[snapshot("/old",.normal)]).published)
        let replacement=try reader.startSession();defer {_ = try? reader.endSession(replacement)}
        XCTAssertTrue(try reader.readLive().roots.isEmpty)
        _ = try reader.begin(root:URL(fileURLWithPath:"/old"),session:replacement)
        XCTAssertEqual(try reader.readLive().states["/old/file"],.modified)
    }
    func testWarmFailureIsSeparateFromLiveAndFalsePolicySurvivesCleanupFailure() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        try FileManager.default.createDirectory(at:store.warmURL,withIntermediateDirectories:false)
        let sentinel=store.warmURL.appendingPathComponent("do-not-delete")
        try Data("owned elsewhere".utf8).write(to:sentinel)
        let session=try store.startSession()
        XCTAssertNotNil(session.persistenceFailure)
        let ticket=try store.begin(root:URL(fileURLWithPath:"/repo"),session:session)
        XCTAssertNotNil(ticket.persistenceFailure)
        let result=try store.publish(ticket,snapshots:[snapshot("/repo",.modified)])
        XCTAssertTrue(result.published);XCTAssertNotNil(result.persistenceFailure);XCTAssertFalse(result.warmCacheRebuilt,"An actual failed cache write must not be labeled successful recovery")
        XCTAssertEqual(try store.readLive().states["/repo/file"],.modified)
        XCTAssertThrowsError(try store.setPersistence(.init(cacheSave:false)))
        XCTAssertFalse(try store.persistence().cacheSave)
        XCTAssertEqual(try Data(contentsOf:sentinel),Data("owned elsewhere".utf8))
        XCTAssertEqual(try store.readLive().states["/repo/file"],.modified)
        try FileManager.default.removeItem(at:store.warmURL)
        try store.setPersistence(.init(cacheSave:false))
        try store.setPersistence(.init(cacheSave:true))
        XCTAssertEqual(try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL)).states["/repo/file"],.modified)
        var warningSnapshot=result.snapshot;warningSnapshot.persistenceFailure="transient"
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(warningSnapshot)) as? [String:Any])
        XCTAssertNil(object["persistenceFailure"])
        _ = try store.endSession(session)
    }
    func testCanonicalPeersStaySeparateAcrossWarmRestoreAndOwnerRemoval() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let a="/wire/\u{00c5}",b="/wire/A\u{030a}",session=try store.startSession()
        _ = try publish(store,session,a,.modified);_ = try publish(store,session,b,.added)
        _ = try store.endSession(session)
        let restored=try store.startSession()
        _ = try store.begin(root:FileTransferPaths.fileURL(a),session:restored)
        XCTAssertEqual(try store.readLive().roots.map {Data($0.utf8)},[Data(a.utf8)])
        _ = try store.begin(root:FileTransferPaths.fileURL(b),session:restored)
        XCTAssertEqual(try store.readLive().states[a+"/file"],.modified)
        XCTAssertEqual(try store.readLive().states[b+"/file"],.added)
        _ = try store.remove(root:FileTransferPaths.fileURL(a),session:restored)
        XCTAssertEqual(try store.readLive().roots.map {Data($0.utf8)},[Data(b.utf8)])
        _ = try store.endSession(restored)
    }
    func testLegacySnapshotMigratesOnlyToWarmAndFutureControlRemainsUntouched() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        try JSONEncoder().encode(snapshot("/legacy",.deleted)).write(to:store.url)
        XCTAssertTrue(try store.readLive().roots.isEmpty)
        let session=try store.startSession()
        XCTAssertTrue(try store.readLive().roots.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:store.warmURL.path))
        _ = try store.begin(root:URL(fileURLWithPath:"/legacy"),session:session)
        XCTAssertEqual(try store.readLive().states["/legacy/file"],.deleted)
        let control=URL(fileURLWithPath:store.url.path+".writers")
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:control)) as? [String:Any])
        object["version"]=99
        let bytes=try JSONSerialization.data(withJSONObject:object);try bytes.write(to:control)
        XCTAssertThrowsError(try store.endSession(session))
        XCTAssertEqual(try Data(contentsOf:control),bytes)
        XCTAssertNil(FinderSnapshot.readLive(from:store.url))
        // Even an error during metadata cleanup releases the owner's lease.
        let lease=URL(fileURLWithPath:store.url.path+".sessions").appendingPathComponent(session.id.uuidString+".lease")
        XCTAssertFalse(FileManager.default.fileExists(atPath:lease.path))
    }
    func testFailedDisableMustInvalidateOldArchiveBeforeReenabling() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let session=try store.startSession();_ = try publish(store,session,"/stale",.conflicted)
        _ = try store.endSession(session)
        let old=try Data(contentsOf:store.warmURL)
        try FileManager.default.removeItem(at:store.warmURL)
        try FileManager.default.createDirectory(at:store.warmURL,withIntermediateDirectories:false)
        XCTAssertThrowsError(try store.setPersistence(.init(cacheSave:false)))
        XCTAssertFalse(try store.persistence().cacheSave)
        // Model a regular archive surviving a failed unlink. The durable reset
        // fence, rather than file absence alone, must prevent resurrection.
        try FileManager.default.removeItem(at:store.warmURL);try old.write(to:store.warmURL)
        let reopened=FinderSnapshotStore(url:store.url)
        try reopened.setPersistence(.init(cacheSave:true))
        let next=try reopened.startSession();defer {_ = try? reopened.endSession(next)}
        _ = try reopened.begin(root:URL(fileURLWithPath:"/stale"),session:next)
        XCTAssertTrue(try reopened.readLive().roots.isEmpty)
    }
    func testOwnerRemovalFencesNestedTicketsWithoutRemovingAnotherOwner() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let a=try store.startSession(),b=try store.startSession()
        _ = try publish(store,a,"/repo",.modified)
        _ = try publish(store,b,"/repo",.added) // Exact-root claim now belongs to B.
        let late=try store.begin(root:URL(fileURLWithPath:"/repo/child-a"),session:a)
        let other=try store.begin(root:URL(fileURLWithPath:"/repo/child-b"),session:b)
        _ = try store.remove(root:URL(fileURLWithPath:"/repo"),session:a)
        XCTAssertEqual(try store.readLive().states["/repo/file"],.added)
        XCTAssertFalse(try store.publish(late,snapshots:[snapshot("/repo/child-a",.conflicted)]).published)
        XCTAssertTrue(try store.publish(other,snapshots:[snapshot("/repo/child-b",.normal)]).published)
        _ = try store.endSession(a);_ = try store.endSession(b)
    }
    func testCorruptRegularWarmArchiveRebuildsFromLiveAndRetryClearsWarning() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let session=try store.startSession();defer {_ = try? store.endSession(session)}
        try Data("invalid warm JSON".utf8).write(to:store.warmURL)
        let ticket=try store.begin(root:URL(fileURLWithPath:"/repo"),session:session)
        XCTAssertNotNil(ticket.persistenceFailure)
        let rebuilt=try store.publish(ticket,snapshots:[snapshot("/repo",.modified)])
        XCTAssertTrue(rebuilt.published);XCTAssertNotNil(rebuilt.persistenceFailure)
        XCTAssertEqual(try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL)).states["/repo/file"],.modified)
        let retried=try publish(store,session,"/repo",.added)
        XCTAssertTrue(retried.published);XCTAssertNil(retried.persistenceFailure)
        XCTAssertEqual(try store.readLive().states["/repo/file"],.added)
    }

    func testStrictReaderNeverWaitsForWriterLockAndForeignCleanupKeepsLease() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let session=try store.startSession();_ = try publish(store,session,"/repo",.modified)
        let reader=FinderSnapshotLiveReader(url:store.url)
        XCTAssertEqual(try reader.read().states["/repo/file"],.modified)
        let lock=Darwin.open(store.url.path+".lock",O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(lock,0);defer {flock(lock,LOCK_UN);Darwin.close(lock)}
        XCTAssertEqual(flock(lock,LOCK_EX | LOCK_NB),0)
        // A cache miss as well as a cache hit must stay independent of the lock.
        XCTAssertEqual(try FinderSnapshotLiveReader(url:store.url).read().states["/repo/file"],.modified)
        XCTAssertEqual(try reader.read().states["/repo/file"],.modified)
        flock(lock,LOCK_UN)
        let foreign=FinderSnapshotStore(url:directory.appendingPathComponent("other.json"))
        XCTAssertThrowsError(try foreign.endSession(session))
        XCTAssertEqual(try reader.read().states["/repo/file"],.modified)
        _ = try store.endSession(session)
        XCTAssertTrue(try reader.read().roots.isEmpty)
    }

    func testRemovingOwnedNestedDataPreservesOtherPublishersPrecedenceAndChangesRevision() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let a=try store.startSession(),b=try store.startSession()
        let root=FileTransferPaths.fileURL("/repo"),child=FileTransferPaths.fileURL("/repo/child")
        var older=snapshot("/repo",.modified);older.states["/repo/child/file"] = .modified
        _ = try store.publish(store.begin(root:root,session:a),snapshots:[older])
        let reader=FinderSnapshotLiveReader(url:store.url),before=try reader.read()
        _ = try store.remove(root:child,session:a)
        let removed=try reader.read()
        XCTAssertNotEqual(before.liveRevision,removed.liveRevision)
        XCTAssertNil(removed.states["/repo/child/file"])
        XCTAssertEqual(removed.states["/repo/file"],.modified)
        // Restore A's tree, then publish B's newer independent view of the same
        // parent. Removing A's nested data must not promote its older remainder.
        _ = try store.publish(store.begin(root:root,session:a),snapshots:[older])
        var newer=snapshot("/repo",.added);newer.states["/repo/child/file"] = .conflicted
        _ = try store.publish(store.begin(root:root,session:b),snapshots:[newer])
        let newerView=try reader.read()
        XCTAssertEqual(newerView.states["/repo/file"],.added)
        _ = try store.remove(root:child,session:a)
        let retained=try reader.read()
        XCTAssertNotEqual(newerView.liveRevision,retained.liveRevision)
        XCTAssertEqual(retained.states["/repo/file"],.added)
        XCTAssertEqual(retained.states["/repo/child/file"],.conflicted)
        _ = try store.endSession(b)
        let revealed=try reader.read()
        XCTAssertEqual(revealed.states["/repo/file"],.modified)
        XCTAssertNil(revealed.states["/repo/child/file"])
        _ = try store.endSession(a)
    }

    func testInvalidWarmNamespaceCannotPoisonFreshClaimAndValidSiblingSurvives() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let damaged=FinderSnapshot(roots:["/claimed","/sibling"],states:["/claimed/trailing/":.modified,"/sibling/file":.added],repositories:["/claimed":.init(),"/sibling":.init()])
        let archive=try JSONEncoder().encode(damaged);try archive.write(to:store.warmURL)
        let session=try store.startSession();defer {_ = try? store.endSession(session)}
        XCTAssertTrue(try store.readLive().roots.isEmpty)
        let fresh=try store.begin(root:URL(fileURLWithPath:"/claimed"),session:session)
        XCTAssertNotNil(fresh.persistenceFailure)
        XCTAssertTrue(try store.readLive().roots.isEmpty,"Invalid warm data must not become lease-backed authority")
        XCTAssertEqual(try Data(contentsOf:store.warmURL),archive,"Beginning a claim must not erase sibling restart data")
        _ = try store.begin(root:URL(fileURLWithPath:"/sibling"),session:session)
        XCTAssertEqual(try store.readLive().states["/sibling/file"],.added)
        // Incoming producers retain the exact same strict namespace contract.
        XCTAssertThrowsError(try store.publish(fresh,snapshots:[FinderSnapshot(roots:["/claimed"],states:["/claimed/trailing/":.modified])]))
        XCTAssertEqual(try store.readLive().states["/sibling/file"],.added)
        let result=try store.publish(fresh,snapshots:[snapshot("/claimed",.normal)])
        XCTAssertTrue(result.published);XCTAssertFalse(result.warmCacheRebuilt);XCTAssertNil(result.persistenceFailure)
        XCTAssertEqual(result.snapshot.states["/claimed/file"],.normal)
        XCTAssertEqual(result.snapshot.states["/sibling/file"],.added)
        XCTAssertNil(result.snapshot.states["/claimed/trailing/"])
        let saved=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL))
        XCTAssertEqual(saved.states["/claimed/file"],.normal);XCTAssertEqual(saved.states["/sibling/file"],.added)
        XCTAssertNil(saved.states["/claimed/trailing/"])
        // A new reader still validates the persisted control record, rather than
        // relying on a special case in the writer that performed recovery.
        XCTAssertEqual(try FinderSnapshotStore(url:store.url).readLive().states["/sibling/file"],.added)
    }
    func testMalformedWarmJSONWarnsWithoutBlockingColdSessionAndFreshPublication() throws {
        let (directory,store)=try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let malformed=Data("{invalid restart archive".utf8);try malformed.write(to:store.warmURL)
        let session=try store.startSession();defer {_ = try? store.endSession(session)}
        XCTAssertNotNil(session.persistenceFailure,"An optional archive error must be reported without refusing the live session")
        let ticket=try store.begin(root:URL(fileURLWithPath:"/claimed"),session:session)
        XCTAssertNotNil(ticket.persistenceFailure);XCTAssertTrue(try store.readLive().roots.isEmpty)
        XCTAssertEqual(try Data(contentsOf:store.warmURL),malformed)
        let result=try store.publish(ticket,snapshots:[snapshot("/claimed",.modified)])
        XCTAssertTrue(result.published);XCTAssertTrue(result.warmCacheRebuilt);XCTAssertNotNil(result.persistenceFailure,"The successful rebuild must disclose discarded malformed restart bytes")
        XCTAssertEqual(result.snapshot.states["/claimed/file"],.modified)
        let rebuilt=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL))
        XCTAssertEqual(rebuilt.states["/claimed/file"],.modified)
        // A later corrupted archive must rebuild from all validated live
        // contributions, retaining an unrelated already-published sibling.
        try malformed.write(to:store.warmURL)
        let sibling=try store.begin(root:URL(fileURLWithPath:"/sibling"),session:session)
        let recoveredSibling=try store.publish(sibling,snapshots:[snapshot("/sibling",.added)])
        XCTAssertTrue(recoveredSibling.published);XCTAssertTrue(recoveredSibling.warmCacheRebuilt)
        let both=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL))
        XCTAssertEqual(both.states["/claimed/file"],.modified);XCTAssertEqual(both.states["/sibling/file"],.added)
        let retry=try store.begin(root:URL(fileURLWithPath:"/claimed"),session:session)
        XCTAssertNil(retry.persistenceFailure)
        XCTAssertNil(try store.publish(retry,snapshots:[snapshot("/claimed",.normal)]).persistenceFailure)
    }

}
