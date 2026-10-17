import Foundation
import XCTest
@testable import TurtleGitCore

final class FinderRootIdentityTests: XCTestCase {
    private let a="/wire/\u{00c5}", b="/wire/A\u{030a}", alias="/wire/\u{212b}"
    private func url(_ path:String) -> URL { FileTransferPaths.fileURL(path) }
    private func snapshot(_ root:String, state:FileState = .normal, metadata:FinderRepositoryMetadata = .init()) -> FinderSnapshot {
        FinderSnapshot(roots:[root],states:[root:state,root+"/file":state],repositories:[root:metadata],overlayEntries:[root+"/file":state])
    }
    private func fixture() throws -> (URL,FinderSnapshotStore) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitRootIdentity-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return (folder,FinderSnapshotStore(url:folder.appendingPathComponent("status.json")))
    }
    func testMetadataRoundTripIsLosslessAndLegacyFieldRemainsReadable() throws {
        var value=snapshot(a,metadata:.init(mergeActive:true))
        value.replaceSubtree(root:url(b),snapshots:[snapshot(b,metadata:.init(bisectActive:true,hasStash:true))])
        XCTAssertEqual(value.repositories.count,2)
        let bytes=try JSONEncoder().encode(value),restored=try JSONDecoder().decode(FinderSnapshot.self,from:bytes)
        XCTAssertEqual(restored.repositories.count,2)
        XCTAssertEqual(restored.repositories[a]?.mergeActive,true)
        XCTAssertEqual(restored.repositories[b]?.bisectActive,true)
        XCTAssertEqual(restored.repositories[b]?.mergeActive,false)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        XCTAssertEqual((object["repositoriesV2"] as? [Any])?.count,2)
        XCTAssertEqual((object["repositories"] as? [String:Any])?.count,1)
        object.removeValue(forKey:"repositoriesV2")
        let legacy=try JSONDecoder().decode(FinderSnapshot.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(legacy.repositories.count,1)
        // A malformed lossless record cannot silently fall back to its lossy field.
        let rows=try XCTUnwrap((try JSONSerialization.jsonObject(with:bytes) as? [String:Any])?["repositoriesV2"] as? [Any])
        object["repositoriesV2"]=[rows[0],rows[0]]
        XCTAssertThrowsError(try JSONDecoder().decode(FinderSnapshot.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    func testNearestRootAndMixedSelectionsUseExactNamesWithUniqueAliasFallback() throws {
        var value=snapshot(a,state:.modified,metadata:.init(hasStash:true))
        value.replaceSubtree(root:url(b),snapshots:[snapshot(b,state:.conflicted,metadata:.init(mergeActive:true))])
        XCTAssertTrue(GitReferenceName.equal(try XCTUnwrap(value.repositoryRoot(for:url(a+"/file"))),a))
        XCTAssertTrue(GitReferenceName.equal(try XCTUnwrap(value.repositoryRoot(for:url(b+"/file"))),b))
        XCTAssertEqual(value.cachedState(for:url(a+"/file")),.modified)
        XCTAssertEqual(value.cachedState(for:url(b+"/file")),.conflicted)
        XCTAssertNil(value.commonRepositoryRoot(for:[url(a+"/file"),url(b+"/file")]))
        XCTAssertNil(value.commonFileOperationOwner(for:[url(a+"/file"),url(b+"/file")]))
        XCTAssertNil(value.repositoryMetadata(for:[url(a),url(b)]))
        XCTAssertNil(value.repositoryRoot(for:url(alias+"/unknown")))
        let unique=snapshot(a)
        XCTAssertTrue(GitReferenceName.equal(try XCTUnwrap(unique.repositoryRoot(for:url(alias+"/unknown"))),a))
        XCTAssertTrue(unique.isRepositoryRoot(url(alias),root:a))
        XCTAssertFalse(unique.canRename([url(alias)]))
        XCTAssertNil(value.repositoryRoot(for:url("/wire/elsewhere/file")))
    }
    func testSubtreeReplacementPreservesPeerRootsAndIndependentNestedOwners() {
        var value=snapshot("/wire")
        value.replaceSubtree(root:url("/wire"),snapshots:[snapshot("/wire"),snapshot(a,state:.modified),snapshot(b,state:.added)])
        XCTAssertEqual(value.repositories.count,3)
        value.replaceSubtree(root:url(a),snapshots:[])
        XCTAssertNil(value.repositories[a]);XCTAssertNil(value.states[a+"/file"])
        XCTAssertEqual(value.repositories[b]?.bare,false);XCTAssertEqual(value.states[b+"/file"],.added)
        value.replaceSubtree(root:url("/wire"),snapshots:[snapshot("/wire")])
        XCTAssertTrue(GitPathSet(value.roots).contains(b));XCTAssertEqual(value.states[b+"/file"],.added)
    }
    func testPublicationReopenRemoveAndStaleTicketsDoNotConflatePeers() throws {
        let (folder,store)=try fixture();defer {try? FileManager.default.removeItem(at:folder)}
        let first=try store.begin(root:url(a)),second=try store.begin(root:url(b))
        XCTAssertTrue(GitReferenceName.equal(first.root,a));XCTAssertTrue(GitReferenceName.equal(second.root,b))
        XCTAssertTrue(try store.publish(second,snapshots:[snapshot(b,state:.conflicted)]).published)
        let published=try store.publish(first,snapshots:[snapshot(a,state:.modified)])
        XCTAssertTrue(published.published);XCTAssertEqual(published.snapshot.repositories.count,2)
        let reopened=FinderSnapshotStore(url:store.url)
        let stale=try reopened.begin(root:url(a)),fresh=try reopened.begin(root:url(a))
        XCTAssertTrue(try reopened.publish(fresh,snapshots:[snapshot(a,state:.added)]).published)
        XCTAssertFalse(try reopened.publish(stale,snapshots:[snapshot(a)]).published)
        let pending=try reopened.begin(root:url(b)),removed=try reopened.remove(root:url(b))
        XCTAssertEqual(GitPathSet(removed.roots),[a]);XCTAssertEqual(removed.states[a+"/file"],.added)
        XCTAssertFalse(try reopened.publish(pending,snapshots:[snapshot(b)]).published)
        XCTAssertFalse(try reopened.publish(first,snapshots:[snapshot(a)]).published)
    }
    func testPayloadCannotEscapeIntoCanonicalPeerOrLexicalAlias() throws {
        let (folder,store)=try fixture();defer {try? FileManager.default.removeItem(at:folder)}
        let ticket=try store.begin(root:url(a))
        XCTAssertThrowsError(try store.publish(ticket,snapshots:[snapshot(b)]))
        var escaping=snapshot(a);escaping.repositories[b] = .init(hasStash:true)
        XCTAssertThrowsError(try store.publish(ticket,snapshots:[escaping]))
        escaping=snapshot(a);escaping.states[a+"/child/../file"] = .modified
        XCTAssertThrowsError(try store.publish(ticket,snapshots:[escaping]))
        XCTAssertTrue(try store.publish(ticket,snapshots:[snapshot(a)]).published)
    }
    func testVersionOneWriterStateMigratesWithoutDiscardingCounter() throws {
        let (folder,store)=try fixture();defer {try? FileManager.default.removeItem(at:folder)}
        let control=URL(fileURLWithPath:store.url.path+".writers"),identity=UUID()
        let old:[String:Any]=["version":1,"id":identity.uuidString,"counter":20,"sequences":["/old":19],"consumed":["/old":18]]
        try JSONSerialization.data(withJSONObject:old).write(to:control)
        _ = try store.begin(root:url(a))
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:control)) as? [String:Any])
        XCTAssertEqual(object["version"] as? Int,2);XCTAssertEqual(object["counter"] as? Int,21)
        XCTAssertEqual(object["id"] as? String,identity.uuidString)
        let sequences=try XCTUnwrap(object["sequences"] as? [[String:Any]])
        XCTAssertEqual(sequences.count,2)
        XCTAssertEqual(sequences.first { ($0["path"] as? String)=="/old" }?["value"] as? Int,19)
        var future=object;future["version"]=3
        try JSONSerialization.data(withJSONObject:future).write(to:control)
        XCTAssertThrowsError(try store.begin(root:url(a)))
    }
    func testFinderRelativeSelectionRejectsAnotherRootAndPreservesRawNames() throws {
        let request=FinderRequest(action:.log,paths:[url(a+"/file"),url(b+"/file")])
        XCTAssertEqual(request.paths.count,2)
        XCTAssertEqual(request.relativePaths(root:url(a)),["file"])
        XCTAssertEqual(request.relativePaths(root:url(b)),["file"])
        let restored=try XCTUnwrap(request.url.flatMap(FinderRequest.init(url:)))
        XCTAssertEqual(restored.paths.map { Data($0.path.utf8) },[Data((a+"/file").utf8),Data((b+"/file").utf8)])
        XCTAssertEqual(FinderRequest(action:.log,paths:[url(a),url(b)]).relativePaths(root:url(a)),["."])
    }
    func testOverlayPropagationAndShellFactsStayInsideEachRoot() {
        var value=snapshot(a,state:.modified,metadata:.init(mergeActive:true))
        value.replaceSubtree(root:url(b),snapshots:[snapshot(b,state:.normal,metadata:.init(bisectActive:true))])
        var preferences=FinderOverlaySettings();preferences.recurseSubmodules=true
        let badges=preferences.overlayBadges(snapshot:value,volume:{_ in .fixed},isDirectory:{GitPathSet([self.a,self.b]).contains($0)})
        XCTAssertEqual(badges[a],.modified);XCTAssertEqual(badges[b],.normal)
        let first=FinderShellRules.flags(paths:[url(a+"/file")],snapshot:value),second=FinderShellRules.flags(paths:[url(b+"/file")],snapshot:value)
        XCTAssertTrue(first.contains(.merge));XCTAssertFalse(first.contains(.bisect))
        XCTAssertTrue(second.contains(.bisect));XCTAssertFalse(second.contains(.merge))
    }
}
