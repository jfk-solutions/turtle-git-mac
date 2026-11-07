import Foundation
import XCTest
@testable import TurtleGitCore

final class FinderWarmCohortTests:XCTestCase {
    private func snapshot(_ root:String,count:Int=0,state:FileState = .normal,parent:String?=nil)->FinderSnapshot {
        var rows:GitPathMap<FileState>=[root:state]
        for index in 0..<count {rows[root+"/file-\(index)"]=state}
        rows[root+"/caf\u{e9}"] = .added
        rows[root+"/cafe\u{301}"] = .conflicted
        return .init(roots:[root],states:rows,repositories:[root:.init(submoduleParentRoot:parent)],overlayEntries:rows,indexFlags:[root+"/flags":.init(skipWorktree:true,assumeUnchanged:false)],overlayPolicies:[root:.init(identity:"cohort",caseSensitive:true)])
    }
    private func publish(_ store:FinderSnapshotStore,_ owner:FinderPublicationSession,_ value:FinderSnapshot)throws {
        let root=try XCTUnwrap(value.roots.first)
        XCTAssertTrue(try store.publish(store.begin(root:URL(fileURLWithPath:root),session:owner),snapshots:[value]).published)
    }
    func testIdenticalRetirementScansColdArchiveOnceWithoutReinsertingColdPaths()throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("FinderCohort-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let store=FinderSnapshotStore(url:folder.appendingPathComponent("status.json")),cold=try store.startSession()
        defer{_ = try? store.endSession(cold);try? FileManager.default.removeItem(at:folder)}
        try publish(store,cold,snapshot("/cold-sibling",count:12000,state:.deleted))
        try publish(store,cold,snapshot("/active-a/independent",count:12000,state:.modified))
        _ = try store.endSession(cold)
        let owner=try store.startSession();defer{_ = try? store.endSession(owner)}
        for root in ["/active-a","/active-b","/active-c","/active-d"] {try publish(store,owner,snapshot(root,state:.added))}
        let bytes=try Data(contentsOf:store.warmURL)
        let archive=try JSONDecoder().decode(FinderSnapshot.self,from:bytes)
        let inode=try FileManager.default.attributesOfItem(atPath:store.warmURL.path)[.systemFileNumber] as? NSNumber
        let control=URL(fileURLWithPath:store.url.path+".writers")
        var wire=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:control)) as? [String:Any])
        wire.removeValue(forKey:"warmMaintenance")
        try JSONSerialization.data(withJSONObject:wire,options:.sortedKeys).write(to:control,options:.atomic)
        let before=store.publicationWorkCounters
        XCTAssertTrue(try store.endSession(owner).roots.isEmpty)
        let after=store.publicationWorkCounters
        XCTAssertEqual(after.warmMergeCohorts-before.warmMergeCohorts,1)
        let entries=archive.states.count+archive.repositories.count+(archive.overlayEntries?.count ?? 0)+(archive.indexFlags?.count ?? 0)+archive.overlayPolicies.count
        XCTAssertEqual(after.warmMergeScannedEntries-before.warmMergeScannedEntries,entries)
        XCTAssertLessThan(after.warmMergeAffectedEntries-before.warmMergeAffectedEntries,100,"Independent nested cold data must remain shared")
        XCTAssertEqual(after.warmMergePatchedEntries-before.warmMergePatchedEntries,0)
        XCTAssertEqual(after.warmWrites,before.warmWrites)
        XCTAssertEqual(try Data(contentsOf:store.warmURL),bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:store.warmURL.path)[.systemFileNumber] as? NSNumber,inode)
        XCTAssertEqual(archive.states["/active-a/independent/caf\u{e9}"],.added)
        XCTAssertEqual(archive.states["/active-a/independent/cafe\u{301}"],.conflicted)
        XCTAssertEqual(archive.indexFlags?["/cold-sibling/flags"],.init(skipWorktree:true,assumeUnchanged:false))
    }
    func testIndependentNestedRootsSurviveAncestorButExplicitRefreshReplacesTheirPaths() {
        for parent in ["/caf\u{e9}","/cafe\u{301}"] {
            let independent=parent+"/independent",child=independent+"/child",stale=parent+"/stale"
            var value=snapshot(parent,state:.modified)
            value.replaceSubtree(root:FileTransferPaths.fileURL(independent),snapshots:[snapshot(independent,count:100,state:.deleted)])
            value.replaceSubtree(root:FileTransferPaths.fileURL(child),snapshots:[snapshot(child,state:.added)])
            value.replaceSubtree(root:FileTransferPaths.fileURL(stale),snapshots:[snapshot(stale,parent:parent)])
            value.replaceSubtree(root:FileTransferPaths.fileURL(parent),snapshots:[snapshot(parent,state:.conflicted)])
            XCTAssertEqual(value.states[independent+"/file-99"],.deleted)
            XCTAssertEqual(value.states[child],.added)
            XCTAssertNil(value.states[stale]);XCTAssertFalse(GitPathSet(value.roots).contains(stale))
            XCTAssertEqual(value.states[parent],.conflicted)
            value.replaceSubtree(root:FileTransferPaths.fileURL(independent),snapshots:[snapshot(independent,state:.normal)])
            XCTAssertNil(value.states[independent+"/file-99"])
            XCTAssertEqual(value.states[child],.added,"Separately opened descendant remains independent")
            XCTAssertEqual(value.states[independent],.normal)
            XCTAssertEqual(value.overlayPolicies[child]?.identity,"cohort")
        }
    }
    func testAncestorContributesOnlyAbsentRowsInsideIndependentNestedRoot() {
        let parent="/ancestor",nested=parent+"/independent"
        var value=snapshot(parent)
        var independent=snapshot(nested,state:.deleted)
        independent.states[nested+"/existing"] = .conflicted
        independent.overlayEntries?[nested+"/existing"] = .modified
        independent.indexFlags?[nested+"/existing"] = .init(skipWorktree:true,assumeUnchanged:false)
        value.replaceSubtree(root:FileTransferPaths.fileURL(nested),snapshots:[independent])
        var incoming=snapshot(parent,state:.modified)
        incoming.states[nested+"/existing"] = .normal
        incoming.states[nested+"/new"] = .added
        incoming.overlayEntries?[nested+"/existing"] = .normal
        incoming.overlayEntries?[nested+"/new"] = .untracked
        incoming.indexFlags?[nested+"/existing"] = .init(skipWorktree:false,assumeUnchanged:true)
        incoming.indexFlags?[nested+"/new"] = .init(skipWorktree:false,assumeUnchanged:true)
        value.replaceSubtree(root:FileTransferPaths.fileURL(parent),snapshots:[incoming])
        XCTAssertEqual(value.states[nested+"/existing"],.conflicted)
        XCTAssertEqual(value.states[nested+"/new"],.added)
        XCTAssertEqual(value.overlayEntries?[nested+"/existing"],.modified)
        XCTAssertEqual(value.overlayEntries?[nested+"/new"],.untracked)
        XCTAssertEqual(value.indexFlags?[nested+"/existing"],.init(skipWorktree:true,assumeUnchanged:false))
        XCTAssertEqual(value.indexFlags?[nested+"/new"],.init(skipWorktree:false,assumeUnchanged:true))
        XCTAssertEqual(value.states[nested],.deleted)
        XCTAssertTrue(GitPathSet(value.roots).contains(nested))
    }
    func testLegacyOverlayFallbackDoesNotAdoptNewStateOnlyRows() {
        var value=FinderSnapshot(roots:["/target","/cold"],states:["/target/old":.modified,"/cold/file":.added])
        let update=FinderSnapshot(roots:["/target"],states:["/target/state-only":.deleted,"/target/visible":.modified],overlayEntries:["/target/visible":.modified])
        value.replaceSubtree(root:URL(fileURLWithPath:"/target"),snapshots:[update])
        XCTAssertEqual(value.overlayEntries?["/cold/file"],.added)
        XCTAssertNil(value.overlayEntries?["/target/old"])
        XCTAssertNil(value.overlayEntries?["/target/state-only"])
        XCTAssertEqual(value.states["/target/state-only"],.deleted)
        XCTAssertEqual(value.overlayEntries?["/target/visible"],.modified)
    }
    func testRefreshedSubmoduleBadgeRetainsStrongerParentGitlinkState() {
        var value=snapshot("/parent")
        var parent=snapshot("/parent")
        parent.states["/parent/sub"] = .conflicted
        value.replaceSubtree(root:URL(fileURLWithPath:"/parent"),snapshots:[parent,snapshot("/parent/sub",state:.normal,parent:"/parent")])
        XCTAssertEqual(value.states["/parent/sub"],.conflicted)
        XCTAssertEqual(value.repositories["/parent/sub"]?.submoduleParentRoot,"/parent")
        XCTAssertEqual(value.overlayEntries?["/parent/sub/cafe\u{301}"],.conflicted)
    }
}
