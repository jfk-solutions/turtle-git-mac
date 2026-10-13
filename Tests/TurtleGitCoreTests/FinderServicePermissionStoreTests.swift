import XCTest
@testable import TurtleGitCore

final class FinderServicePermissionStoreTests:XCTestCase {
    final class Provider:RepositoryBookmarkProvider,RepositoryTransferBookmarkProvider {
        var starts=0,stops=0,rejectPersistence=false
        var moves:[String:URL]=[:],unavailable=Set<String>()
        func create(for url:URL) throws -> Data { if rejectPersistence { throw RepositoryAccessFailure.securityScopeUnavailable };return Data(("RECEIVER:"+url.path).utf8) }
        func resolve(_ data:Data) throws -> ResolvedBookmark {
            let text=String(decoding:data,as:UTF8.self);guard text.hasPrefix("RECEIVER:") else { throw RepositoryAccessFailure.unknownRepository }
            let path=String(text.dropFirst(9));if unavailable.contains(path) { throw RepositoryAccessFailure.securityScopeUnavailable }
            return ResolvedBookmark(url:moves[path] ?? URL(fileURLWithPath:path,isDirectory:true),stale:moves[path] != nil)
        }
        func createTransfer(for url:URL) throws -> Data { Data(("TRANSFER:"+url.path).utf8) }
        func resolveTransfer(_ data:Data) throws -> ResolvedBookmark { ResolvedBookmark(url:URL(fileURLWithPath:String(String(decoding:data,as:UTF8.self).dropFirst(9)),isDirectory:true),stale:false) }
        func startAccessing(_ url:URL) -> Bool { starts += 1;return true }
        func stopAccessing(_ url:URL) { stops += 1 }
    }
    func folder() throws -> URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitReceiverStore-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false);return root
    }
    @MainActor func testInstallRelaunchMovedScopeAndFailedEntriesRemain() throws {
        let folder=try folder();defer { try? FileManager.default.removeItem(at:folder) }
        let provider=Provider(),url=folder.appendingPathComponent("private/grants.json"),store=try FinderServicePermissionStore(url:url,provider:provider)
        let id=UUID(),request=FinderServiceAuthorization(grants:[FinderServiceWatchGrant(id:id,bookmark:Data("TRANSFER:/scope".utf8),repositoryComponents:["repo"])])
        do { let accesses=try store.install(request,transfer:provider);XCTAssertEqual(accesses[0].root.path,"/scope/repo") }
        XCTAssertEqual(provider.starts,provider.stops)
        let bytes=try String(contentsOf:url);XCTAssertTrue(bytes.contains("repositoryComponents"));XCTAssertFalse(bytes.contains("TRANSFER:"))
        let reopened=try FinderServicePermissionStore(url:url,provider:provider);provider.moves["/scope"]=URL(fileURLWithPath:"/moved",isDirectory:true)
        do { let restored=try reopened.restore();XCTAssertEqual(restored.accesses[0].root.path,"/moved/repo");XCTAssertTrue(restored.failures.isEmpty) }
        XCTAssertEqual(reopened.grants[0].id,id)
        provider.unavailable.insert("/moved")
        let failed=try reopened.restore();XCTAssertTrue(failed.accesses.isEmpty);XCTAssertNotNil(failed.failures[id]);XCTAssertEqual(reopened.grants.count,1)
        try reopened.remove(id);XCTAssertTrue(reopened.grants.isEmpty)
        XCTAssertEqual(provider.starts,provider.stops)
    }
    @MainActor func testFailedReplacementLeavesPreviousDiskAndMemoryAndReleasesLeases() throws {
        let folder=try folder();defer { try? FileManager.default.removeItem(at:folder) }
        let provider=Provider(),url=folder.appendingPathComponent("grants.json"),store=try FinderServicePermissionStore(url:url,provider:provider)
        let request=FinderServiceAuthorization(grants:[FinderServiceWatchGrant(id:UUID(),bookmark:Data("TRANSFER:/scope".utf8),repositoryComponents:[])])
        do { _ = try store.install(request,transfer:provider) }
        let before=try Data(contentsOf:url),grants=store.grants
        provider.rejectPersistence=true
        XCTAssertThrowsError(try store.install(FinderServiceAuthorization(grants:[FinderServiceWatchGrant(id:UUID(),bookmark:Data("TRANSFER:/other".utf8),repositoryComponents:[])]),transfer:provider))
        XCTAssertEqual(store.grants,grants);XCTAssertEqual(try Data(contentsOf:url),before);XCTAssertEqual(provider.starts,provider.stops)
    }
    @MainActor func testCorruptRegistryIsNeverReplacedAndFileIsPrivate() throws {
        let folder=try folder();defer { try? FileManager.default.removeItem(at:folder) }
        let url=folder.appendingPathComponent("grants.json");try Data("broken".utf8).write(to:url)
        XCTAssertThrowsError(try FinderServicePermissionStore(url:url));XCTAssertEqual(try Data(contentsOf:url),Data("broken".utf8))
        try FileManager.default.removeItem(at:url)
        let store=try FinderServicePermissionStore(url:url);try store.remove(UUID())
        let mode=try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue,0o600)
    }
}
