import Foundation
import XCTest
@testable import TurtleGitCore

final class FinderPublicationPipelineTests:XCTestCase {
    // Independent old wire encoder: preserve the original V2 [{path,value}]
    // arrays and legacy canonical-collision projections, not just modern decode.
    private struct OldPairs<Value:Codable>:Encodable {
        struct Entry:Encodable {let path:String;let value:Value}
        let map:GitPathMap<Value>
        func encode(to encoder:Encoder)throws {
            var container=encoder.singleValueContainer()
            try container.encode(map.keys.sorted {$0.utf8.lexicographicallyPrecedes($1.utf8)}.map {Entry(path:$0,value:map[$0]!)})
        }
    }
    private struct OldWire:Encodable {
        let snapshot:FinderSnapshot
        enum CodingKeys:String,CodingKey {case roots,states,statesV2,updated,repositories,repositoriesV2,overlayEntries,overlayEntriesV2,indexFlags,indexFlagsV2,liveRevision,overlayPolicies}
        private func legacy<Value>(_ map:GitPathMap<Value>,_ combine:(Value,Value)->Value)->[String:Value] {
            Dictionary(map.sorted {$0.key.utf8.lexicographicallyPrecedes($1.key.utf8)}.map {($0.key,$0.value)},uniquingKeysWith:combine)
        }
        func encode(to encoder:Encoder)throws {
            var values=encoder.container(keyedBy:CodingKeys.self)
            try values.encode(snapshot.roots,forKey:.roots)
            try values.encode(OldPairs(map:snapshot.states),forKey:.statesV2)
            try values.encode(legacy(snapshot.states) {FinderSnapshot.statePriority($0)>=FinderSnapshot.statePriority($1) ? $0:$1},forKey:.states)
            try values.encode(snapshot.updated,forKey:.updated)
            try values.encodeIfPresent(snapshot.liveRevision,forKey:.liveRevision)
            try values.encode(OldPairs(map:snapshot.overlayPolicies),forKey:.overlayPolicies)
            try values.encode(OldPairs(map:snapshot.repositories),forKey:.repositoriesV2)
            try values.encode(legacy(snapshot.repositories) {first,_ in first},forKey:.repositories)
            if let entries=snapshot.overlayEntries {
                try values.encode(OldPairs(map:entries),forKey:.overlayEntriesV2)
                try values.encode(legacy(entries) {FinderSnapshot.statePriority($0)>=FinderSnapshot.statePriority($1) ? $0:$1},forKey:.overlayEntries)
            }
            if let flags=snapshot.indexFlags {
                try values.encode(OldPairs(map:flags),forKey:.indexFlagsV2)
                try values.encode(legacy(flags) {_,last in last},forKey:.indexFlags)
            }
        }
    }
    func testExactAndLegacyWireBytesMatchIndependentPreviousEncoder()throws {
        let a="/repo/café/file",b="/repo/cafe\u{301}/file"
        var snapshot=FinderSnapshot(roots:["/repo"],states:[a:.added,b:.conflicted],updated:Date(timeIntervalSince1970:123),repositories:["/repo":.init(),a:.init(bare:true),b:.init(mergeActive:true)],overlayEntries:[a:.modified,b:.normal],indexFlags:[a:.init(skipWorktree:true,assumeUnchanged:false),b:.init(skipWorktree:false,assumeUnchanged:true)],overlayPolicies:["/repo":.init(identity:"same",caseSensitive:true)])
        snapshot.liveRevision="known/lease/revision"
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        XCTAssertEqual(try encoder.encode(snapshot),try encoder.encode(OldWire(snapshot:snapshot)))
        let decoded=try JSONDecoder().decode(FinderSnapshot.self,from:encoder.encode(snapshot))
        XCTAssertEqual(decoded.states,snapshot.states);XCTAssertEqual(decoded.repositories,snapshot.repositories)
        XCTAssertEqual(decoded.overlayEntries,snapshot.overlayEntries);XCTAssertEqual(decoded.indexFlags,snapshot.indexFlags)
        struct Legacy:Decodable {let states:[String:FileState],repositories:[String:FinderRepositoryMetadata],overlayEntries:[String:FileState],indexFlags:[String:FinderIndexFlags]}
        let legacy=try JSONDecoder().decode(Legacy.self,from:encoder.encode(snapshot))
        XCTAssertEqual(legacy.states.count,1);XCTAssertEqual(legacy.states[a],.conflicted)
        XCTAssertEqual(legacy.overlayEntries.count,1);XCTAssertEqual(legacy.overlayEntries[a],.modified)
        // Ordering of NFC vs NFD is UTF8, so NFD supplies first metadata,
        // NFC supplies last index flags. Never use canonical String sort here.
        XCTAssertEqual(legacy.repositories[a],snapshot.repositories[b]);XCTAssertEqual(legacy.indexFlags[a],snapshot.indexFlags?[a])
    }
    func testNativeAndBridgedStringStorageHaveEqualExactHashFeed() {
        for name in ["plain",String(repeating:"deep/",count:40)+"café 🧪","cafe\u{301}","embedded\0byte"] {
            let native=String(decoding:Array(name.utf8),as:UTF8.self)
            let bridged=(NSMutableString(string:name) as String)
            let joined=("prefix"+name).dropFirst(6)
            let names=[native,bridged,String(joined)]
            for value in names {
                XCTAssertTrue(value.utf8.elementsEqual(name.utf8))
                XCTAssertEqual(GitReferenceName(value).hashValue,GitReferenceName(native).hashValue)
                var map:GitPathMap<Int>=[native:1];map[value]=2
                XCTAssertEqual(map.count,1);XCTAssertEqual(map[native],2)
                XCTAssertEqual(GitPathSet([native,value]).count,1)
            }
        }
        let a="café",b="cafe\u{301}"
        var exact:GitPathMap<Int>=[a:1,b:2]
        exact[(NSMutableString(string:a) as String)]=3
        XCTAssertEqual(exact.count,2);XCTAssertEqual(exact[a],3);XCTAssertEqual(exact[b],2)
    }
    func testExactRootComponentsPreserveLongestOwnerBoundariesAndValueCopies() {
        let a="/repo/café",b="/repo/cafe\u{301}"
        let original=FinderSnapshot(roots:["/","/repo",a,b,a+"/nested"],states:[:])
        let examples:[(String,String?)]=[("/","/"),("/other/deep","/"),("/repository/file","/"),("/repo/file","/repo"),(a+"/file",a),(b+"/file",b),(a+"/nested/file",a+"/nested"),(a+"/nestedness/file",a),(a+"/nested///",a+"/nested"),("relative/file",nil)]
        for (path,expected) in examples {XCTAssertTrue(GitReferenceName.equal(original.exactRepositoryRoot(for:path) ?? "<nil>",expected ?? "<nil>"),path)}
        var changed=original;changed.roots.removeAll {GitReferenceName.equal($0,a+"/nested")}
        XCTAssertEqual(changed.exactRepositoryRoot(for:a+"/nested/file"),a)
        XCTAssertEqual(original.exactRepositoryRoot(for:a+"/nested/file"),a+"/nested")
        let malformed=FinderSnapshot(roots:["/repo/","/repo//child"],states:[:])
        XCTAssertNil(malformed.exactRepositoryRoot(for:"/repo/"))
        XCTAssertEqual(malformed.exactRepositoryRoot(for:"/repo//child"),"/repo//child")
        XCTAssertNil(malformed.exactRepositoryRoot(for:"/repo//child/file"))
    }
    private func fixture()throws->(URL,FinderSnapshotStore,FinderPublicationSession) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPipeline-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        let store=FinderSnapshotStore(url:folder.appendingPathComponent("status.json"))
        var accepted=false,started:FinderPublicationSession?
        defer {
            if !accepted {
                if let started {_ = try? store.endSession(started)}
                try? FileManager.default.removeItem(at:folder)
            }
        }
        let session=try store.startSession();started=session
        let root=URL(fileURLWithPath:"/repo")
        _=try store.publish(store.begin(root:root,session:session),snapshots:[FinderSnapshot(roots:["/repo"],states:["/repo/file":.modified])])
        accepted=true
        return(folder,store,session)
    }
    func testSupersededPublicationStillReturnsCurrentLeaseFilteredProjection()throws {
        let(folder,store,owner)=try fixture()
        defer{_ = try? store.endSession(owner);try? FileManager.default.removeItem(at:folder)}
        let sibling=try store.startSession()
        var ended=false;defer{if !ended{_ = try? store.endSession(sibling)}}
        let other=URL(fileURLWithPath:"/other")
        _=try store.publish(store.begin(root:other,session:sibling),snapshots:[FinderSnapshot(roots:["/other"],states:["/other/file":.added])])
        let root=URL(fileURLWithPath:"/repo"),old=try store.begin(root:root,session:owner)
        let fresh=try store.begin(root:root,session:owner)
        _=try store.publish(fresh,snapshots:[FinderSnapshot(roots:["/repo"],states:["/repo/file":.conflicted])])
        let rejected=try store.publish(old,snapshots:[FinderSnapshot(roots:["/repo"],states:["/repo/file":.normal])])
        XCTAssertFalse(rejected.published);XCTAssertEqual(rejected.snapshot.states["/repo/file"],.conflicted)
        XCTAssertEqual(rejected.snapshot.states["/other/file"],.added)
        _=try store.endSession(sibling);ended=true
        let afterRetirement=try store.publish(old,snapshots:[FinderSnapshot(roots:["/repo"],states:["/repo/file":.normal])])
        XCTAssertFalse(afterRetirement.published);XCTAssertEqual(afterRetirement.snapshot.roots,["/repo"])
        XCTAssertNil(afterRetirement.snapshot.states["/other/file"])
        XCTAssertEqual(afterRetirement.snapshot.states["/repo/file"],.conflicted)
    }
    func testRawFileReplacementInsideSettingsCallbackCannotReuseEarlierTypeCheck()throws {
        let(folder,store,session)=try fixture()
        defer{_ = try? store.endSession(session);try? FileManager.default.removeItem(at:folder)}
        enum Rejected:Error {case publish}
        let corrupt=Data("hostile replacement".utf8)
        XCTAssertThrowsError(try store.configureStatusPolicy(policy:{FinderStatusPolicy(cacheMode:.shell)},publish:{
            try corrupt.write(to:store.url,options:.atomic);throw Rejected.publish
        },rollback:{}))
        // The rollback's writeLive must re-authenticate the replacement and
        // refuse it; silently trusting a transaction-local cached old decode
        // would overwrite this diagnostic evidence with a successful snapshot.
        XCTAssertEqual(try Data(contentsOf:store.url),corrupt)
        XCTAssertThrowsError(try store.readLive())
    }
    func testRawFileSymlinkInsideSettingsCallbackIsRejectedWithoutTouchingTarget()throws {
        let(folder,store,session)=try fixture()
        defer{_ = try? store.endSession(session);try? FileManager.default.removeItem(at:folder)}
        enum Rejected:Error {case publish}
        let target=folder.appendingPathComponent("unrelated.txt"),bytes=Data("must remain".utf8)
        try bytes.write(to:target)
        XCTAssertThrowsError(try store.configureStatusPolicy(policy:{FinderStatusPolicy(cacheMode:.shell)},publish:{
            try FileManager.default.removeItem(at:store.url)
            try FileManager.default.createSymbolicLink(at:store.url,withDestinationURL:target)
            throw Rejected.publish
        },rollback:{}))
        XCTAssertEqual(try Data(contentsOf:target),bytes)
        let attributes=try FileManager.default.attributesOfItem(atPath:store.url.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType,.typeSymbolicLink)
        XCTAssertThrowsError(try store.readLive())
    }
}
