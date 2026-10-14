import XCTest
@testable import TurtleGitCore
final class FinderTransferTests: XCTestCase {
    func testTransferURLSeparatesDestinationFromLiteralCapturedSources() throws {
        let destination=URL(fileURLWithPath:"/repo/target 雪\n&?",isDirectory:true),sources=[URL(fileURLWithPath:"/outside/-雪\n&?.txt"),URL(fileURLWithPath:"/outside/second.txt")]
        for action in [RepositoryAction.pasteCopy,.pasteMove] {
            let request=FinderRequest(action:action,paths:[destination],sources:sources+sources)
            let decoded=try XCTUnwrap(FinderRequest(url:XCTUnwrap(request.url)))
            XCTAssertEqual(decoded.paths.map(\.path),[destination.path]);XCTAssertEqual(decoded.sources.map(\.path),sources.map(\.path));XCTAssertTrue(action.requiresWorkingTree);XCTAssertNil(FinderMenuEntry.entry(for:action))
        }
    }
    func testMalformedOrUnboundedTransferPayloadsAreRejected() {
        for value in ["command=pasteCopy&path=/repo", "command=pasteMove&path=/repo&source", "command=pasteCopy&path=/repo&source=relative", "command=pasteCopy&path=/repo&path=/other&source=/file", "command=log&path=/repo&source=/file", "command=pasteCopy&path=/repo&source=/file%00bad"] {
            XCTAssertNil(FinderRequest(url:URL(string:"turtlegit://action?"+value)!))
        }
        XCTAssertNil(FinderRequest(action:.pasteCopy,paths:[URL(fileURLWithPath:"/repo")],sources:(0..<257).map{URL(fileURLWithPath:"/file/\($0)")}).url)
        XCTAssertNil(FinderRequest(action:.log,paths:[URL(fileURLWithPath:"/repo")],sources:[URL(fileURLWithPath:"/file")]).url)
    }
    func testCachedMenusOfferMoveOnlyForSameWorktreeVersionedSources() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),destination=root.appendingPathComponent("target",isDirectory:true),tracked=root.appendingPathComponent("file"),untracked=root.appendingPathComponent("untracked")
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        for file in [tracked,untracked]{try Data("x".utf8).write(to:file)}
        var snapshot=FinderSnapshot.build(root:root,tracked:["file"],changes:[]);snapshot.repositories[root.path]=FinderRepositoryMetadata(bare:false)
        func actions(_ files:[URL],folder:URL?=nil)->[RepositoryAction]{FinderTransferContext.requests(destination:folder ?? destination,sources:files,snapshot:snapshot,settings:FinderMenuSettings()).map(\.action)}
        XCTAssertEqual(actions([tracked]),[.pasteCopy,.pasteMove]);XCTAssertEqual(actions([untracked]),[.pasteCopy]);XCTAssertEqual(actions([tracked],folder:tracked),[])
        XCTAssertEqual(actions([root.appendingPathComponent(".GIT/file")]),[])
        snapshot.repositories[root.path]=FinderRepositoryMetadata(bare:true);XCTAssertEqual(actions([tracked]),[])
    }
    func testNativePreferenceRoundtripKeepsSourceMasksAndOldDefaults() throws {
        let old=try JSONDecoder().decode(FinderMenuSettings.self,from:Data("{\"showIcons\":false}".utf8));XCTAssertTrue(old.clipboardTransfers)
        var settings=old;settings.clipboardTransfers=false;settings.topLevelMask=UInt64.max
        let decoded=try JSONDecoder().decode(FinderMenuSettings.self,from:JSONEncoder().encode(settings));XCTAssertFalse(decoded.clipboardTransfers);XCTAssertEqual(decoded.topLevelMask,UInt64.max)
    }
}
