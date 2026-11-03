import Foundation
import XCTest
@testable import TurtleGitCore

/// Object-key ordering is not part of the shared-cache protocol. These checks
/// retain both installed-peer formats, byte-exact path records and the existing
/// atomic control/session rules when large payloads use an unsorted JSON writer.
final class FinderPublicationEncodingTests:XCTestCase {
    private func fixture()throws->(URL,FinderSnapshotStore) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("FinderEncoding-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        return (folder,FinderSnapshotStore(url:folder.appendingPathComponent("status.json")))
    }
    private func snapshot(_ root:URL,count:Int)->FinderSnapshot {
        let first=(root.path as NSString).appendingPathComponent("café"),second=(root.path as NSString).appendingPathComponent("cafe\u{301}")
        var states:GitPathMap<FileState>=[first:.modified,second:.conflicted]
        for index in 0..<count {
            // Keep the Foundation-backed, long shared-prefix path shape from
            // real repository collectors; short native literal keys miss the
            // expensive bridged-key sorting path observed in the signed app.
            let path=(root.path as NSString).appendingPathComponent("shared-prefix/another-long-directory/fixture-file-\(index).txt")
            states[path] = index.isMultiple(of:2) ? .normal:.modified
        }
        states[(root.path as NSString).appendingPathComponent("quote\" and \\ slash\n\t.txt")] = .untracked
        return .init(roots:[root.path],states:states,updated:Date(timeIntervalSince1970:123),
                     repositories:[root.path:.init(bisectActive:true,mergeActive:true,hasStash:true,hasSubmoduleConfig:true,
                                                   submoduleParentRoot:second,hasLFS:true,hasGitSVN:true)],
                     overlayEntries:states,
                     indexFlags:[first:.init(skipWorktree:true,assumeUnchanged:false),second:.init(skipWorktree:false,assumeUnchanged:true)],
                     overlayPolicies:[root.path:.init(identity:"encoding-fixture-policy",caseSensitive:false)])
    }
    private func assertPayload(_ actual:FinderSnapshot,_ expected:FinderSnapshot,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(actual.roots.map {Data($0.utf8)},expected.roots.map {Data($0.utf8)},file:file,line:line)
        XCTAssertEqual(actual.states,expected.states,file:file,line:line)
        XCTAssertEqual(actual.overlayEntries,expected.overlayEntries,file:file,line:line)
        XCTAssertEqual(actual.indexFlags,expected.indexFlags,file:file,line:line)
        XCTAssertEqual(actual.repositories,expected.repositories,file:file,line:line)
        XCTAssertEqual(actual.overlayPolicies,expected.overlayPolicies,file:file,line:line)
        XCTAssertEqual(actual.updated,expected.updated,file:file,line:line)
        for (path,metadata) in expected.repositories {
            XCTAssertEqual(actual.repositories[path]?.submoduleParentRoot.map {Data($0.utf8)},metadata.submoduleParentRoot.map {Data($0.utf8)},file:file,line:line)
        }
    }
    private func assertWire(_ bytes:Data,_ expected:FinderSnapshot,file:StaticString=#filePath,line:UInt=#line)throws {
        let canonical=JSONEncoder();canonical.outputFormatting=[.sortedKeys]
        let oldWire=try XCTUnwrap(JSONSerialization.jsonObject(with:canonical.encode(expected)) as? NSDictionary,file:file,line:line)
        let newWire=try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? NSDictionary,file:file,line:line)
        XCTAssertTrue(newWire.isEqual(oldWire),"Exact and legacy wire fields must match independent of JSON object order",file:file,line:line)
        let decoded=try JSONDecoder().decode(FinderSnapshot.self,from:bytes)
        assertPayload(decoded,expected,file:file,line:line)
        XCTAssertEqual(decoded.liveRevision,expected.liveRevision,file:file,line:line)
    }

    func testLiveWarmAndControlPayloadsRetainExactAndLegacyWireFields()throws {
        let (folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repository"),input=snapshot(root,count:257)
        let started=Date()
        let result=try store.publish(store.begin(root:root,session:owner),snapshots:[input])
        let finished=Date()
        XCTAssertTrue(result.published);XCTAssertNil(result.persistenceFailure)
        try assertWire(Data(contentsOf:store.url),result.snapshot)
        let warmBytes=try Data(contentsOf:store.warmURL),warm=try JSONDecoder().decode(FinderSnapshot.self,from:warmBytes)
        var expectedWarm=input;expectedWarm.updated=warm.updated
        XCTAssertGreaterThanOrEqual(warm.updated,started);XCTAssertLessThanOrEqual(warm.updated,finished)
        assertPayload(warm,expectedWarm);XCTAssertNil(warm.liveRevision)
        try assertWire(warmBytes,expectedWarm)
        let control=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:store.url.path+".writers"))) as? [String:Any])
        XCTAssertEqual(control["version"] as? Int,4)
        let contributions=try XCTUnwrap(control["contributions"] as? [[String:Any]])
        XCTAssertEqual(contributions.count,1)
        let payloads=try XCTUnwrap(contributions[0]["snapshots"] as? [[String:Any]])
        XCTAssertEqual(payloads.count,1)
        try assertWire(JSONSerialization.data(withJSONObject:payloads[0]),input)
        XCTAssertEqual(try store.readLive().states[root.path+"/café"],.modified)
        XCTAssertEqual(try store.readLive().states[root.path+"/cafe\u{301}"],.conflicted)
    }

    func testColdLargeFoundationPathPayloadAndNewSiblingKeepClaimsAndPublishedContent()throws {
        let (folder,store)=try fixture(),owner=try store.startSession()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let root=folder.appendingPathComponent("repository"),other=folder.appendingPathComponent("sibling")
        let large=snapshot(root,count:10_001),small=snapshot(other,count:1),started=ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(try store.publish(store.begin(root:root,session:owner),snapshots:[large]).published)
        // An actual foreign atomic replacement invalidates both memoized file
        // identities while preserving the real publisher's live process lease.
        let control=URL(fileURLWithPath:store.url.path+".writers")
        try Data(contentsOf:control).write(to:control,options:.atomic)
        try Data(contentsOf:store.url).write(to:store.url,options:.atomic)
        let before=store.publicationWorkCounters
        let stale=try store.begin(root:other,session:owner),fresh=try store.begin(root:other,session:owner)
        XCTAssertFalse(try store.publish(stale,snapshots:[small]).published)
        XCTAssertTrue(try store.publish(fresh,snapshots:[small]).published)
        let after=store.publicationWorkCounters
        XCTAssertGreaterThan(after.controlDecodes,before.controlDecodes)
        XCTAssertGreaterThan(after.rawDecodes,before.rawDecodes)
        XCTAssertGreaterThan(after.contributionEncodes,before.contributionEncodes)
        let raw=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.url))
        let warm=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:store.warmURL))
        for (path,state) in large.states {XCTAssertEqual(raw.states[path],state);XCTAssertEqual(warm.states[path],state)}
        for (path,state) in small.states {XCTAssertEqual(raw.states[path],state);XCTAssertEqual(warm.states[path],state)}
        XCTAssertEqual(raw.states.count,large.states.count+small.states.count)
        XCTAssertEqual(raw.overlayEntries?.count,raw.states.count)
        XCTAssertEqual(raw.indexFlags?.count,4)
        XCTAssertEqual(raw.repositories.count,2);XCTAssertEqual(raw.overlayPolicies.count,2)
        XCTAssertEqual(try store.readLive().states,raw.states)
        print("Finder bridged-path encoding (private10001 long paths, cold identity and sibling publication): \(ProcessInfo.processInfo.systemUptime-started)s; no wall-clock threshold")
    }
}
