import XCTest
@testable import TurtleGitCore

final class FinderCachedLiveTests:XCTestCase {
    private func fixture()throws->(URL,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitFastLive-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        return(root,root.appendingPathComponent("status.json"))
    }
    private func publish(_ writer:FinderSnapshotStore,_ session:FinderPublicationSession,root:URL,state:FileState)throws {
        let ticket=try writer.begin(root:root,session:session)
        let snapshot=FinderSnapshot(roots:[root.path],states:[root.path:state,root.appendingPathComponent("file").path:state],repositories:[root.path:.init()])
        XCTAssertTrue(try writer.publish(ticket,snapshots:[snapshot]).published)
    }
    func testFastReceiptRequiresReadAndInvalidatesChangedPublicationBeforeReturningStatus()throws {
        let (directory,url)=try fixture();defer{try? FileManager.default.removeItem(at:directory)}
        let root=directory.appendingPathComponent("repo"),writer=FinderSnapshotStore(url:url),session=try writer.startSession()
        defer{_ = try? writer.endSession(session)}
        try publish(writer,session,root:root,state:.modified)
        let reader=FinderSnapshotLiveReader(url:url)
        XCTAssertNil(reader.cachedLiveIfCurrent(),"A cold callback must not synchronously decode a projection")
        let accepted=try reader.read()
        XCTAssertEqual(reader.cachedLiveIfCurrent()?.liveRevision,accepted.liveRevision)
        XCTAssertEqual(reader.cachedLiveIfCurrent()?.states[root.appendingPathComponent("file").path],.modified)
        try publish(writer,session,root:root,state:.conflicted)
        XCTAssertNil(reader.cachedLiveIfCurrent(),"Changed writer/raw identities must not serve the prior badge")
        let refreshed=try reader.read()
        XCTAssertNotEqual(refreshed.liveRevision,accepted.liveRevision)
        XCTAssertEqual(reader.cachedLiveIfCurrent()?.states[root.appendingPathComponent("file").path],.conflicted)
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try reader.read(cancellation:token))
        XCTAssertEqual(reader.cachedLiveIfCurrent()?.liveRevision,refreshed.liveRevision,"A refused read cannot erase or replace an unchanged valid receipt")
    }
    func testOwnerDeathInvalidatesCachedStatusEvenWithUnchangedRawAndControlFiles()throws {
        let (directory,url)=try fixture();defer{try? FileManager.default.removeItem(at:directory)}
        let root=directory.appendingPathComponent("repo")
        var writer:FinderSnapshotStore?=FinderSnapshotStore(url:url)
        let session=try XCTUnwrap(writer).startSession()
        try publish(try XCTUnwrap(writer),session,root:root,state:.added)
        let reader=FinderSnapshotLiveReader(url:url);_=try reader.read()
        XCTAssertEqual(reader.cachedLiveIfCurrent()?.states[root.path],.added)
        let raw=try Data(contentsOf:url),controlURL=URL(fileURLWithPath:url.path+".writers"),control=try Data(contentsOf:controlURL)
        writer=nil
        XCTAssertEqual(try Data(contentsOf:url),raw);XCTAssertEqual(try Data(contentsOf:controlURL),control)
        XCTAssertNil(reader.cachedLiveIfCurrent(),"Lease death alone must clear callback badge authority")
        XCTAssertTrue(try reader.read().roots.isEmpty)
        XCTAssertTrue(reader.cachedLiveIfCurrent()?.states.isEmpty==true)
    }
    func testWorkerMenuPreparationPreservesNestedOwnersExactAliasesAndCancellation()throws {
        let root=FileTransferPaths.fileURL("/menu-preparation")
        var snapshot=FinderSnapshot.build(root:root,tracked:["folder/normal","folder/nested/conflict"],changes:StatusEntry.parse(Data("UU folder/nested/conflict\0".utf8)))
        let nested=root.path+"/folder/nested",nfc="/exact/caf\u{00e9}",nfd="/exact/cafe\u{301}"
        snapshot.roots += [nested,nfc,nfd]
        snapshot.states[nfc+"/file"] = .modified;snapshot.states[nfd+"/file"] = .added
        snapshot.overlayEntries?[nfc+"/file"] = .modified;snapshot.overlayEntries?[nfd+"/file"] = .added
        let parent=FileTransferPaths.fileURL(root.path+"/folder"),nestedFile=FileTransferPaths.fileURL(nested+"/conflict")
        let selections=[[parent],[nestedFile],[FileTransferPaths.fileURL(nfc+"/file")],[FileTransferPaths.fileURL(nfd+"/file")]]
        let flags=selections.map{FinderShellRules.flags(paths:$0,snapshot:snapshot).rawValue}
        let owners=selections.map{snapshot.repositoryRoot(for:$0[0]).map{Data($0.utf8)}}
        XCTAssertFalse(snapshot.canResolve([parent]),"Nested checkout conflicts cannot authorize parent-folder resolution")
        try snapshot.prepareFinderMenuQueries()
        XCTAssertEqual(selections.map{FinderShellRules.flags(paths:$0,snapshot:snapshot).rawValue},flags)
        XCTAssertEqual(selections.map{snapshot.repositoryRoot(for:$0[0]).map{Data($0.utf8)}},owners)
        XCTAssertEqual(snapshot.repositoryRoot(for:selections[2][0]).map{Data($0.utf8)},Data(nfc.utf8))
        XCTAssertEqual(snapshot.repositoryRoot(for:selections[3][0]).map{Data($0.utf8)},Data(nfd.utf8))
        let token=OperationCancellation();token.cancel()
        XCTAssertThrowsError(try snapshot.prepareFinderMenuQueries(cancellation:token))
        XCTAssertEqual(selections.map{FinderShellRules.flags(paths:$0,snapshot:snapshot).rawValue},flags)
    }
    func testFutureControlAndRawReplacementCannotReuseCachedBadgeAuthority()throws {
        let (directory,url)=try fixture();defer{try? FileManager.default.removeItem(at:directory)}
        let root=directory.appendingPathComponent("repo"),writer=FinderSnapshotStore(url:url),session=try writer.startSession()
        defer{_ = try? writer.endSession(session)}
        try publish(writer,session,root:root,state:.modified)
        let reader=FinderSnapshotLiveReader(url:url);_=try reader.read()
        let raw=try Data(contentsOf:url),controlURL=URL(fileURLWithPath:url.path+".writers"),control=try Data(contentsOf:controlURL)
        try Data("{invalid".utf8).write(to:url,options:.atomic)
        XCTAssertNil(reader.cachedLiveIfCurrent())
        XCTAssertThrowsError(try reader.read())
        XCTAssertNil(reader.cachedLiveIfCurrent())
        try raw.write(to:url,options:.atomic);_=try reader.read()
        XCTAssertEqual(reader.cachedLiveIfCurrent()?.states[root.path],.modified)
        var future=try XCTUnwrap(JSONSerialization.jsonObject(with:control) as? [String:Any]);future["version"]=99
        let bytes=try JSONSerialization.data(withJSONObject:future);try bytes.write(to:controlURL,options:.atomic)
        XCTAssertNil(reader.cachedLiveIfCurrent())
        XCTAssertThrowsError(try reader.read())
        XCTAssertNil(reader.cachedLiveIfCurrent())
        XCTAssertEqual(try Data(contentsOf:controlURL),bytes,"Read-only callback recovery must not rewrite a future writer protocol")
        try control.write(to:controlURL,options:.atomic)
    }
}
