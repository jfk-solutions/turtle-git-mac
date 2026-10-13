import XCTest
@testable import TurtleGitCore

final class FinderServiceAuthorizationTests:XCTestCase {
    final class Provider:RepositoryBookmarkProvider,RepositoryTransferBookmarkProvider {
        var started=0,stopped=0,available=true
        var moved:URL?
        func create(for url:URL) throws -> Data { Data(("PERSIST:"+url.path).utf8) }
        func resolve(_ data:Data) throws -> ResolvedBookmark { ResolvedBookmark(url:moved ?? URL(fileURLWithPath:String(decoding:data,as:UTF8.self).replacingOccurrences(of:"PERSIST:",with:""),isDirectory:true),stale:moved != nil) }
        func createTransfer(for url:URL) throws -> Data { Data(("TRANSFER:"+url.path).utf8) }
        func resolveTransfer(_ data:Data) throws -> ResolvedBookmark { ResolvedBookmark(url:moved ?? URL(fileURLWithPath:String(decoding:data,as:UTF8.self).replacingOccurrences(of:"TRANSFER:",with:""),isDirectory:true),stale:moved != nil) }
        func startAccessing(_ url:URL) -> Bool { let allowed=available && url.path != "/unavailable";if allowed { started += 1 };return allowed }
        func stopAccessing(_ url:URL) { stopped += 1 }
    }
    func testPrivateTransferAndReceiverPersistenceKeepRelativeRoot() throws {
        let provider=Provider(),scope=URL(fileURLWithPath:"/scope",isDirectory:true),id=UUID()
        var lease:RepositoryAccessLease?=RepositoryAccessLease(url:scope,provider:provider)
        let request=try FinderServiceAuthorization.capture([(id,scope.appendingPathComponent("repo"),lease!)],provider:provider)
        XCTAssertEqual(request.grants[0].repositoryComponents,["repo"])
        var accesses:[FinderServiceAccess]?=try JSONDecoder().decode(FinderServiceAuthorization.self,from:JSONEncoder().encode(request)).acquire(provider:provider)
        XCTAssertEqual(accesses?.first?.root.path,"/scope/repo")
        let saved=try XCTUnwrap(accesses?.first).persistentGrant(provider:provider)
        XCTAssertTrue(String(decoding:saved.bookmark,as:UTF8.self).hasPrefix("PERSIST:"));XCTAssertEqual(saved.id,id)
        accesses=nil;lease=nil;XCTAssertEqual(provider.started,provider.stopped)
        provider.moved=URL(fileURLWithPath:"/moved",isDirectory:true)
        let (root,resumed)=try saved.acquire(provider:provider)
        XCTAssertEqual(root.path,"/moved/repo");XCTAssertTrue(resumed.contains(root))
    }
    func testInvalidDuplicateEscapingAndPartialScopesAreRejectedAndReleased() throws {
        let provider=Provider(),root=URL(fileURLWithPath:"/scope",isDirectory:true),lease=RepositoryAccessLease(url:root,provider:provider),id=UUID()
        XCTAssertThrowsError(try FinderServiceAuthorization.capture([(id,root,lease),(id,root,lease)],provider:provider))
        XCTAssertThrowsError(try FinderServiceAuthorization.capture([(id,URL(fileURLWithPath:"/outside"),lease)],provider:provider))
        let escaped=FinderServiceAuthorization(grants:[FinderServiceWatchGrant(id:id,bookmark:Data("TRANSFER:/scope".utf8),repositoryComponents:["..","outside"])])
        XCTAssertThrowsError(try escaped.acquire(provider:provider));XCTAssertEqual(provider.started,1)
        let before=provider.started
        let duplicate=FinderServiceAuthorization(grants:[FinderServiceWatchGrant(id:id,bookmark:Data("TRANSFER:/scope".utf8),repositoryComponents:[]),FinderServiceWatchGrant(id:id,bookmark:Data("TRANSFER:/scope".utf8),repositoryComponents:[])])
        XCTAssertThrowsError(try duplicate.acquire(provider:provider));XCTAssertEqual(before,provider.started)
        let stopped=provider.stopped
        let partial=FinderServiceAuthorization(grants:[FinderServiceWatchGrant(id:UUID(),bookmark:Data("TRANSFER:/scope".utf8),repositoryComponents:[]),FinderServiceWatchGrant(id:UUID(),bookmark:Data("TRANSFER:/unavailable".utf8),repositoryComponents:[])])
        XCTAssertThrowsError(try partial.acquire(provider:provider));XCTAssertEqual(provider.started,before+1);XCTAssertEqual(provider.stopped,stopped+1)
        let afterPartial=provider.started
        provider.available=false
        let normal=FinderServiceAuthorization(grants:[FinderServiceWatchGrant(id:id,bookmark:Data("TRANSFER:/scope".utf8),repositoryComponents:[])])
        XCTAssertThrowsError(try normal.acquire(provider:provider));XCTAssertEqual(afterPartial,provider.started)
    }
    func testSymlinkCannotWidenTransferredScope() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitGrant-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false);defer { try? FileManager.default.removeItem(at:folder) }
        try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("escape"),withDestinationURL:URL(fileURLWithPath:"/"))
        let provider=Provider(),before=provider.started
        let request=FinderServiceAuthorization(grants:[FinderServiceWatchGrant(id:UUID(),bookmark:try provider.createTransfer(for:folder),repositoryComponents:["escape","etc"])])
        XCTAssertThrowsError(try request.acquire(provider:provider));XCTAssertEqual(provider.started,before+1);XCTAssertEqual(provider.stopped,1)
    }
}
