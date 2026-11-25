import XCTest
@testable import TurtleGitCore

final class SSHConfigurationAccessTests:XCTestCase {
    final class ResultBox:@unchecked Sendable {
        private let lock=NSLock()
        private var received=false,error:Error?
        func finish(_ error:Error?) {lock.lock();self.error=error;received=error==nil;lock.unlock()}
        var result:(Bool,Error?) {lock.lock();defer{lock.unlock()};return(received,error)}
    }
    final class Bookmarks:RepositoryBookmarkProvider,@unchecked Sendable {
        let lock=NSLock()
        private var _starts=0,_stops=0,_creates=0,_resolves=0
        var available=true,failResolve=false,stale=false,moved:URL?
        var resolveHook:(()->Void)?
        var counts:(starts:Int,stops:Int,creates:Int,resolves:Int) {lock.lock();defer{lock.unlock()};return(_starts,_stops,_creates,_resolves)}
        func create(for url:URL)throws->Data {lock.lock();defer{lock.unlock()};_creates += 1;return Data(url.absoluteString.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark {
            lock.lock();_resolves += 1;let hook=resolveHook,fail=failResolve,target=moved,isStale=stale;lock.unlock()
            hook?()
            if fail {throw SSHConfigurationAccessFailure.permission}
            return .init(url:target ?? URL(string:String(decoding:data,as:UTF8.self))!,stale:isStale)
        }
        func startAccessing(_ url:URL)->Bool {lock.lock();defer{lock.unlock()};if available {_starts += 1};return available}
        func stopAccessing(_ url:URL) {lock.lock();defer{lock.unlock()};_stops += 1}
    }
    struct Fixture {
        let root:URL,folder:URL,file:URL,bookmarks:Bookmarks,store:SSHConfigurationAccessStore
        init()throws {
            root=FileManager.default.temporaryDirectory.appendingPathComponent("ssh-config-"+UUID().uuidString).standardizedFileURL
            folder=root.appendingPathComponent("settings");file=root.appendingPathComponent("other config\n雪")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try Data([0xff,0,0xfe]).write(to:file)
            bookmarks=Bookmarks();store=SSHConfigurationAccessStore(storageURL:root.appendingPathComponent("private/grants.json"),provider:bookmarks)
        }
        func cleanup(){try? FileManager.default.removeItem(at:root)}
    }
    func testExplicitFileDirectoryListingAndPrivatePersistence()throws {
        let f=try Fixture();defer{f.cleanup()}
        try f.store.remember(f.folder,requireSecurityScope:true);try f.store.remember(f.file,requireSecurityScope:true)
        let before=f.bookmarks.counts,grants=try f.store.grants()
        XCTAssertEqual(grants.map(\.kind),[.directory,.file]);XCTAssertEqual(grants.map(\.configuredPath),[f.folder.path,f.file.path])
        XCTAssertEqual(f.bookmarks.counts.resolves,before.resolves);XCTAssertEqual(f.bookmarks.counts.starts,before.starts)
        var accesses:[SSHConfigurationAccess]?=try f.store.acquireAll(requireSecurityScope:true)
        XCTAssertEqual(accesses?.map(\.url),[f.folder,f.file]);XCTAssertEqual(f.bookmarks.counts.starts,f.bookmarks.counts.stops+2)
        accesses=nil;XCTAssertEqual(f.bookmarks.counts.starts,f.bookmarks.counts.stops)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:f.store.storageURL.path)[.posixPermissions] as? Int,0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:f.store.storageURL.deletingLastPathComponent().path)[.posixPermissions] as? Int,0o700)
        let reopened=SSHConfigurationAccessStore(storageURL:f.store.storageURL,provider:f.bookmarks)
        XCTAssertEqual(try reopened.grants(),grants)
        XCTAssertEqual(try Data(contentsOf:f.file),Data([0xff,0,0xfe]))
    }
    func testStaleMovedRenewalRejectsOldForgetAndBalancesLease()throws {
        let f=try Fixture();defer{f.cleanup()}
        try f.store.remember(f.file);let reviewed=try XCTUnwrap(f.store.grants().first)
        let moved=f.root.appendingPathComponent("moved");try FileManager.default.moveItem(at:f.file,to:moved)
        f.bookmarks.moved=moved;f.bookmarks.stale=true
        var access:SSHConfigurationAccess?=try f.store.acquire(reviewed,requireSecurityScope:true)
        XCTAssertEqual(access?.url,moved);XCTAssertEqual(access?.grant.configuredPath,f.file.path)
        XCTAssertNotEqual(access?.grant,reviewed);XCTAssertThrowsError(try f.store.forget([reviewed]))
        let refreshed=try f.store.grants();try f.store.forget(refreshed)
        XCTAssertTrue(try f.store.grants().isEmpty);XCTAssertTrue(access?.permission.hasSecurityScope==true)
        access=nil;XCTAssertEqual(f.bookmarks.counts.starts,f.bookmarks.counts.stops)
    }
    func testRawUnicodeIdentitiesAndForgetReaddABA()throws {
        let f=try Fixture();defer{f.cleanup()}
        let a=URL(string:f.root.absoluteString+"/Caf%C3%A9")!,b=URL(string:f.root.absoluteString+"/Cafe%CC%81")!
        try Data().write(to:a);try Data().write(to:b)
        try f.store.remember(a);try f.store.remember(b)
        let old=try f.store.grants();XCTAssertEqual(Set(old.map(\.id)).count,2)
        try f.store.forget([old[0]]);try f.store.remember(a)
        let before=try Data(contentsOf:f.store.storageURL)
        XCTAssertThrowsError(try f.store.forget([old[0]]));XCTAssertThrowsError(try f.store.acquire(old[0]))
        XCTAssertEqual(try Data(contentsOf:f.store.storageURL),before)
        let current=try f.store.grants();try f.store.forget(current.filter{$0.id==GitReferenceName(b.path)})
        XCTAssertEqual(try f.store.grants().map(\.id),[GitReferenceName(a.path)])
    }
    func testDeniedMissingSymlinkKindReplacementAndMalformedArchive()throws {
        let f=try Fixture();defer{f.cleanup()}
        f.bookmarks.available=false
        XCTAssertThrowsError(try f.store.remember(f.file,requireSecurityScope:true));XCTAssertFalse(FileManager.default.fileExists(atPath:f.store.storageURL.path))
        f.bookmarks.available=true
        let link=f.root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:f.file)
        XCTAssertThrowsError(try f.store.remember(link));XCTAssertThrowsError(try f.store.remember(f.root.appendingPathComponent("missing")))
        try f.store.remember(f.file);let grant=try XCTUnwrap(f.store.grants().first)
        try FileManager.default.removeItem(at:f.file);try FileManager.default.createDirectory(at:f.file,withIntermediateDirectories:false)
        XCTAssertThrowsError(try f.store.acquire(grant));XCTAssertEqual(f.bookmarks.counts.starts,f.bookmarks.counts.stops)
        try Data("not JSON".utf8).write(to:f.store.storageURL)
        XCTAssertThrowsError(try f.store.grants());XCTAssertThrowsError(try f.store.remember(f.folder))
        XCTAssertEqual(try Data(contentsOf:f.store.storageURL),Data("not JSON".utf8))
    }
    func testAllOrNothingFailureAndCancellationReleaseEarlierScopes()throws {
        let f=try Fixture();defer{f.cleanup()}
        try f.store.remember(f.folder);try f.store.remember(f.file)
        try FileManager.default.removeItem(at:f.file)
        XCTAssertThrowsError(try f.store.acquireAll(requireSecurityScope:true));XCTAssertEqual(f.bookmarks.counts.starts,f.bookmarks.counts.stops)
        try Data().write(to:f.file)
        let token=OperationCancellation();var resolutions=0
        f.bookmarks.resolveHook={resolutions += 1;if resolutions==2 {token.cancel()}}
        XCTAssertThrowsError(try f.store.acquireAll(requireSecurityScope:true,cancellation:token));XCTAssertEqual(f.bookmarks.counts.starts,f.bookmarks.counts.stops)
        let before=f.bookmarks.counts;let cancelled=OperationCancellation();cancelled.cancel()
        XCTAssertThrowsError(try f.store.acquireAll(cancellation:cancelled));XCTAssertEqual(f.bookmarks.counts.resolves,before.resolves)
    }
    func testRevokedResolutionScopeAndResolvedSymlinkNeverAdmit()throws {
        let f=try Fixture();defer{f.cleanup()}
        try f.store.remember(f.file);let snapshot=try XCTUnwrap(f.store.grants().first)
        f.bookmarks.failResolve=true;XCTAssertThrowsError(try f.store.acquire(snapshot,requireSecurityScope:true))
        f.bookmarks.failResolve=false;f.bookmarks.available=false
        XCTAssertThrowsError(try f.store.acquire(snapshot,requireSecurityScope:true));f.bookmarks.available=true
        let link=f.root.appendingPathComponent("resolved-link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:f.file)
        f.bookmarks.moved=link;XCTAssertThrowsError(try f.store.acquire(snapshot,requireSecurityScope:true))
        XCTAssertEqual(f.bookmarks.counts.starts,f.bookmarks.counts.stops)
        XCTAssertEqual(try f.store.grants(),[snapshot])
    }
    func testReauthorizationDuringResolutionRefusesOldIdenticalBookmark()throws {
        let f=try Fixture();defer{f.cleanup()}
        try f.store.remember(f.file);let before=try f.store.grants();var replacementError:Error?
        f.bookmarks.resolveHook={
            do {try f.store.forget(before);try f.store.remember(f.file)}catch{replacementError=error}
        }
        XCTAssertThrowsError(try f.store.acquireAll(requireSecurityScope:true))
        XCTAssertNil(replacementError);XCTAssertNotEqual(try f.store.grants(),before)
        XCTAssertEqual(f.bookmarks.counts.starts,f.bookmarks.counts.stops)
    }
    func testConcurrentForgetDuringAcquireCannotAdmitCapturedGrant()throws {
        let f=try Fixture();defer{f.cleanup()}
        try f.store.remember(f.file);let snapshot=try f.store.grants()
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
        let box=ResultBox(),store=f.store
        f.bookmarks.resolveHook={entered.signal();_ = release.wait(timeout:.now()+5)}
        DispatchQueue.global().async {
            do {_=try store.acquireAll(requireSecurityScope:true);box.finish(nil)}
            catch {box.finish(error)}
            done.signal()
        }
        defer{release.signal()}
        XCTAssertEqual(entered.wait(timeout:.now()+5),.success)
        let second=SSHConfigurationAccessStore(storageURL:f.store.storageURL,provider:f.bookmarks)
        try second.forget(snapshot);release.signal()
        XCTAssertEqual(done.wait(timeout:.now()+5),.success)
        let (actualReceived,actualFailure)=box.result
        XCTAssertFalse(actualReceived);XCTAssertNotNil(actualFailure);XCTAssertTrue(try second.grants().isEmpty)
        XCTAssertEqual(f.bookmarks.counts.starts,f.bookmarks.counts.stops)
    }
}
