import XCTest
@testable import TurtleGitCore

final class FinderExactCacheTests: XCTestCase {
    private let root = FileTransferPaths.fileURL("/repo")
    private let nfc = "café", nfd = "cafe\u{301}"
    private func url(_ path: String) -> URL { FileTransferPaths.fileURL("/repo/" + path) }

    func testBuildWireRefreshAndLegacyProjectionRetainExactEntries() throws {
        let changes = StatusEntry.parse(Data(" M \(nfc)/file\0UU \(nfd)/file\0".utf8))
        let snapshot = FinderSnapshot.build(root:root,tracked:[nfc+"/file",nfd+"/file"],changes:changes)
        XCTAssertEqual(snapshot.overlayEntries?.count,2)
        XCTAssertEqual(snapshot.states[url(nfc).path],.modified)
        XCTAssertEqual(snapshot.states[url(nfd).path],.conflicted)
        XCTAssertEqual(snapshot.states[root.path],.conflicted)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FinderSnapshot.self,from:data)
        XCTAssertEqual(decoded.states,snapshot.states)
        XCTAssertEqual(decoded.overlayEntries,snapshot.overlayEntries)
        struct OldReader: Decodable { let states:[String:FileState]; let overlayEntries:[String:FileState] }
        let old = try JSONDecoder().decode(OldReader.self,from:data)
        XCTAssertEqual(old.overlayEntries.count,1)
        XCTAssertEqual(old.overlayEntries[url(nfc+"/file").path],.conflicted)
        var combined = FinderSnapshot(roots:["/other"],states:["/other/file":.added])
        combined.replaceSubtree(root:root,snapshots:[decoded])
        XCTAssertEqual(combined.overlayEntries?.count,3)
        XCTAssertEqual(combined.states[url(nfc+"/file").path],.modified)
        XCTAssertEqual(combined.states[url(nfd+"/file").path],.conflicted)
        XCTAssertEqual(combined.states["/other/file"],.added)
    }
    func testMenusKeepExactParentNamespaceAndUniqueAliasFallback() {
        let snapshot = FinderSnapshot.build(root:root,tracked:[nfc+"/tracked",nfd+"/conflict"],changes:StatusEntry.parse(Data("UU \(nfd)/conflict\0".utf8)))
        XCTAssertTrue(snapshot.canResolve([url(nfd)]))
        XCTAssertFalse(snapshot.canResolve([url(nfc)]))
        XCTAssertFalse(FinderShellRules.flags(paths:[url(nfc+"/tracked")],snapshot:snapshot,extended:false).contains(.conflicted))
        XCTAssertTrue(FinderShellRules.flags(paths:[url(nfd+"/conflict")],snapshot:snapshot,extended:false).contains(.conflicted))
        XCTAssertNil(snapshot.cachedState(for:url(nfc+"/conflict")))
        XCTAssertEqual(snapshot.cachedState(for:url(nfd+"/conflict")),.conflicted)
        let unique = FinderSnapshot.build(root:root,tracked:[nfc+"/tracked"],changes:[])
        XCTAssertEqual(unique.cachedState(for:url(nfd+"/tracked")),.normal)
        XCTAssertTrue(unique.canRemove([url(nfd+"/tracked")]))
    }
    func testBadgeProjectionRetainsSensitiveNamesAndRanksInsensitiveAliases() {
        let snapshot = FinderSnapshot.build(root:root,tracked:[],changes:StatusEntry.parse(Data(" M \(nfc)/file\0UU \(nfd)/file\0".utf8)))
        let settings = FinderOverlaySettings()
        let badges = settings.overlayBadges(snapshot:snapshot,volume:{_ in .fixed},isDirectory:{_ in false})
        XCTAssertEqual(badges[url(nfc+"/file").path],.modified)
        XCTAssertEqual(badges[url(nfd+"/file").path],.conflicted)
        XCTAssertEqual(badges[url(nfc).path],.modified)
        XCTAssertEqual(badges[url(nfd).path],.conflicted)
        let literal = FinderOverlayBadgeLookup(badges:badges,caseSensitive:{_ in true})
        XCTAssertEqual(literal.badge(for:url(nfc+"/file").path,caseSensitive:true),.modified)
        let folded = FinderOverlayBadgeLookup(badges:badges,caseSensitive:{_ in false})
        XCTAssertEqual(folded.badge(for:url(nfc+"/file").path,caseSensitive:false),.conflicted)
    }
    func testRequestPreservesEveryRawDirectoryComponent() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let first = FileTransferPaths.fileURL(temporary.path + "/" + nfc + "/nested/file")
        try FileManager.default.createDirectory(at:first.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("bytes".utf8).write(to:first)
        let second = FileTransferPaths.fileURL(temporary.path + "/" + nfd + "/nested/file")
        let request = FinderRequest(action:.diff,paths:[first,second])
        XCTAssertEqual(request.paths.count,2)
        let restored = try XCTUnwrap(FinderRequest(url:XCTUnwrap(request.url)))
        XCTAssertTrue(GitReferenceName.equal(restored.paths[0].path,first.path))
        XCTAssertTrue(GitReferenceName.equal(restored.paths[1].path,second.path))
    }
    func testLegacyCacheAndMalformedModernRecords() throws {
        let source = FinderSnapshot(roots:["/repo"],states:["/repo/a":.modified],overlayEntries:["/repo/a":.modified])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(source)) as? [String:Any])
        object.removeValue(forKey:"statesV2"); object.removeValue(forKey:"overlayEntriesV2")
        let legacy = try JSONDecoder().decode(FinderSnapshot.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertEqual(legacy.states,source.states); XCTAssertEqual(legacy.overlayEntries,source.overlayEntries)
        object["statesV2"] = [["path":"/repo/a","value":"modified"],["path":"/repo/a","value":"normal"]]
        XCTAssertThrowsError(try JSONDecoder().decode(FinderSnapshot.self,from:JSONSerialization.data(withJSONObject:object)))
    }
}
