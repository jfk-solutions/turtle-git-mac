import XCTest
@testable import TurtleGitCore

final class FinderStatusPublicationTests:XCTestCase {
    private func fixture()throws->(URL,FinderSnapshotStore) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitStatusPolicy-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return(root,FinderSnapshotStore(url:root.appendingPathComponent("status.json")))
    }
    private func snapshot(_ policy:FinderStatusPolicy,state:FileState = .modified,caseSensitive:Bool = true)->FinderSnapshot {
        var result=FinderSnapshot(roots:["/repo"],states:["/repo/file":state],repositories:["/repo":.init()])
        result.recordOverlay(policy:policy,caseSensitive:caseSensitive,entries:["/repo/file":state],indexFlags:["/repo/file":.init(skipWorktree:false,assumeUnchanged:true)])
        return result
    }
    func testModeFenceRejectsOldReaderClearsBadgesAndRetainsContext()throws {
        let(root,store)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let owner=try store.startSession();defer{_ = try? store.endSession(owner)}
        let standard=FinderStatusPolicy(),shell=FinderStatusPolicy(cacheMode:.shell,caseSensitive:false)
        let first=try store.begin(root:URL(fileURLWithPath:"/repo"),session:owner,policy:standard)
        XCTAssertTrue(try store.publish(first,snapshots:[snapshot(standard)]).published)
        let pending=try store.begin(root:URL(fileURLWithPath:"/repo"),session:owner,policy:standard),old=try store.readLive()
        try store.setStatusPolicy(shell)
        let fenced=try store.readLive()
        XCTAssertEqual(fenced.states["/repo/file"],.modified);XCTAssertEqual(fenced.roots,["/repo"])
        XCTAssertTrue(fenced.overlayEntries?.isEmpty == true);XCTAssertTrue(fenced.overlayPolicies.isEmpty);XCTAssertTrue(fenced.indexFlags?.isEmpty == true)
        XCTAssertNotEqual(old.liveRevision,fenced.liveRevision)
        XCTAssertFalse(try store.publish(pending,snapshots:[snapshot(standard)]).published)
        XCTAssertThrowsError(try store.begin(root:URL(fileURLWithPath:"/repo"),session:owner,policy:standard))
        let current=try store.begin(root:URL(fileURLWithPath:"/repo"),session:owner,policy:shell)
        XCTAssertTrue(try store.publish(current,snapshots:[snapshot(shell,caseSensitive:false)]).published)
        let accepted=try store.readLive();XCTAssertFalse(accepted.overlayCaseSensitive(for:"/repo/file",fallback:true))
        let roundtrip=try JSONDecoder().decode(FinderSnapshot.self,from:JSONEncoder().encode(accepted))
        XCTAssertEqual(roundtrip.overlayPolicies["/repo"]?.identity,shell.identity)
        XCTAssertEqual(roundtrip.subtree(root:URL(fileURLWithPath:"/repo")).overlayPolicies["/repo"],accepted.overlayPolicies["/repo"])
    }
    func testFailedSettingsPublishRestoresOwnedRecordAndOriginalFence()throws {
        let(root,store)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let owner=try store.startSession();defer{_ = try? store.endSession(owner)}
        let standard=FinderStatusPolicy(),shell=FinderStatusPolicy(cacheMode:.shell)
        let ticket=try store.begin(root:URL(fileURLWithPath:"/repo"),session:owner,policy:standard)
        let file=root.appendingPathComponent("owned.json");try Data("before".utf8).write(to:file)
        enum Rejected:Error {case write}
        XCTAssertThrowsError(try store.configureStatusPolicy(policy:{shell},publish:{try Data("partial".utf8).write(to:file);throw Rejected.write},rollback:{try Data("before".utf8).write(to:file)}))
        XCTAssertEqual(try Data(contentsOf:file),Data("before".utf8))
        XCTAssertTrue(try store.publish(ticket,snapshots:[snapshot(standard)]).published)
    }
    func testConcurrentSettingsTransactionsMergeInsideOneWriterLock()async throws {
        let(root,a)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let b=FinderSnapshotStore(url:a.url),file=root.appendingPathComponent("merged.json")
        try Data("initial".utf8).write(to:file)
        let firstEntered=DispatchSemaphore(value:0),releaseFirst=DispatchSemaphore(value:0),secondEntered=DispatchSemaphore(value:0)
        let one=Task.detached {
            try a.configureStatusPolicy(policy:{firstEntered.signal();guard releaseFirst.wait(timeout:.now()+5) == .success else{throw FinderPublicationFailure.lockTimeout};return FinderStatusPolicy(cacheMode:.shell)},publish:{try Data("first".utf8).write(to:file)},rollback:{})
        }
        guard firstEntered.wait(timeout:.now()+5) == .success else{releaseFirst.signal();throw FinderPublicationFailure.lockTimeout}
        let two=Task.detached {
            try b.configureStatusPolicy(policy:{secondEntered.signal();guard try Data(contentsOf:file)==Data("first".utf8) else{throw FinderPublicationFailure.invalidUpdate};return FinderStatusPolicy(cacheMode:.shellExtended)},publish:{try Data("second".utf8).write(to:file)},rollback:{})
        }
        XCTAssertEqual(secondEntered.wait(timeout:.now()+0.1),.timedOut)
        releaseFirst.signal();try await one.value;try await two.value
        XCTAssertEqual(try Data(contentsOf:file),Data("second".utf8))
        let owner=try a.startSession();defer{_ = try? a.endSession(owner)}
        XCTAssertNoThrow(try a.begin(root:URL(fileURLWithPath:"/repo"),session:owner,policy:FinderStatusPolicy(cacheMode:.shellExtended)))
        XCTAssertThrowsError(try a.begin(root:URL(fileURLWithPath:"/repo"),session:owner,policy:FinderStatusPolicy(cacheMode:.shell)))
    }
    func testProjectionRequiresMatchingPolicyAndShellDoesNotPromoteModifiedGrandchild()throws {
        var settings=FinderOverlaySettings();settings.cacheMode = .shell;settings.volumes=[.fixed]
        let policy=FinderStatusPolicy(cacheMode:.shell)
        var value=FinderSnapshot(roots:["/repo"],states:["/repo/a/b/file":.modified],repositories:["/repo":.init()])
        value.recordOverlay(policy:policy,caseSensitive:true,entries:["/repo":.normal,"/repo/a":.normal,"/repo/a/b":.modified,"/repo/a/b/file":.modified],indexFlags:[:])
        let badges=settings.badges(snapshot:value,volume:{_ in .fixed},isDirectory:{!$0.hasSuffix("file")},statusPolicy:policy)
        XCTAssertEqual(badges["/repo/a/b"],.modified);XCTAssertEqual(badges["/repo/a"],.normal);XCTAssertEqual(badges["/repo"],.normal)
        XCTAssertTrue(settings.badges(snapshot:value,volume:{_ in .fixed},isDirectory:{_ in true},statusPolicy:FinderStatusPolicy(cacheMode:.shellExtended)).isEmpty)
    }
    func testRetainedDefaultOnlyOptionsDoNotAffectShellModes() {
        for mode in [FinderOverlayCacheMode.shell,.shellExtended,.standard] {
            var settings=FinderOverlaySettings();settings.cacheMode=mode;settings.volumes=[.fixed]
            settings.unversionedAsModified=true;settings.recurseSubmodules=true
            let policy=FinderStatusPolicy(cacheMode:mode)
            var value=FinderSnapshot(roots:["/repo","/repo/sub"],states:[:],repositories:["/repo":.init(),"/repo/sub":.init(submoduleParentRoot:"/repo")])
            value.recordOverlay(policy:policy,caseSensitive:true,entries:["/repo":.normal,"/repo/new":.untracked,"/repo/sub":.modified],indexFlags:[:])
            let badges=settings.badges(snapshot:value,volume:{_ in .fixed},isDirectory:{$0 != "/repo/new"},statusPolicy:policy)
            XCTAssertEqual(badges["/repo"],mode == .standard ? .modified : .normal,"Mode \(mode)")
            XCTAssertEqual(badges["/repo/sub"],.modified)
        }
    }

}
