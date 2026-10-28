import XCTest
import Darwin
@testable import TurtleGitCore

final class FinderRegisteredRootsTests:XCTestCase {
    private func fixture()throws->(URL,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitRegisteredRoots-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        return(root,root.appendingPathComponent("registered-roots.json"))
    }
    private func entry(_ path:String,id:UUID=UUID(),kind:FinderRegisteredRoots.Kind = .workingTree)->FinderRegisteredRoots.Entry {
        .init(id:id,root:path,kind:kind)
    }
    func testRoundTripUsesExactRootIdentityAndLongestLexicalAncestorWithoutDiskAccess()throws {
        let (directory,url)=try fixture();defer{try? FileManager.default.removeItem(at:directory)}
        let a=entry("/not-mounted/caf\u{00e9}"),b=entry("/not-mounted/cafe\u{301}"),nested=entry(a.root+"/nested",kind:.bare),unknown=entry("/not-mounted/unknown",kind:.unknown)
        let catalog=FinderRegisteredRoots(entries:[a,b,nested,unknown])
        XCTAssertTrue(try catalog.write(to:url))
        let read=try FinderRegisteredRoots.read(from:url)
        XCTAssertEqual(read.entries.map{Data($0.root.utf8)},catalog.entries.map{Data($0.root.utf8)})
        XCTAssertEqual(read.root(for:FileTransferPaths.fileURL(a.root+"/file"))?.id,a.id)
        XCTAssertEqual(read.root(for:FileTransferPaths.fileURL(b.root+"/file"))?.id,b.id)
        XCTAssertEqual(read.root(for:FileTransferPaths.fileURL(nested.root+"/child"))?.id,nested.id)
        XCTAssertEqual(read.root(for:FileTransferPaths.fileURL(nested.root))?.kind,.bare)
        XCTAssertEqual(read.root(for:FileTransferPaths.fileURL(unknown.root))?.kind,.unknown)
        XCTAssertNil(read.root(for:FileTransferPaths.fileURL(a.root+"-neighbor/file")))
        XCTAssertNil(read.root(for:URL(string:"https://example.invalid/not-mounted")!))
        var info=stat();XCTAssertEqual(lstat(url.path,&info),0);XCTAssertEqual(info.st_mode & 0o777,0o600)
    }
    func testInvalidIdentitiesAndLimitsNeverReplacePreviouslyAcceptedCatalog()throws {
        let (directory,url)=try fixture();defer{try? FileManager.default.removeItem(at:directory)}
        let original=entry("/accepted"),catalog=FinderRegisteredRoots(entries:[original]);try catalog.write(to:url)
        let bytes=try Data(contentsOf:url)
        let invalid:[FinderRegisteredRoots]=[
            .init(entries:[original,entry("/second",id:original.id)]),
            .init(entries:[original,entry(original.root)]),
            .init(entries:[entry("relative")]),.init(entries:[entry("/")]),.init(entries:[entry("/repo/.git/private")]),.init(entries:[entry("/parent/../child")]),
            .init(entries:[entry("/null\0path")]),.init(entries:[entry("/"+String(repeating:"x",count:16384))]),
            .init(entries:(0...FinderRegisteredRoots.maximumEntries).map{entry("/root/\($0)")}),
            // A legal record count and legal individual paths can still exceed
            // the serialized byte ceiling. Neither cap substitutes for the other.
            .init(entries:(0..<300).map{entry("/\($0)/"+String(repeating:"x",count:8192))})
        ]
        for value in invalid {
            XCTAssertNil(value.root(for:FileTransferPaths.fileURL("/accepted/file")),"Invalid direct model must not admit partial hints")
            XCTAssertThrowsError(try value.write(to:url))
            XCTAssertEqual(try Data(contentsOf:url),bytes)
            XCTAssertEqual(try FinderRegisteredRoots.read(from:url).entries.first?.id,original.id)
        }
        XCTAssertTrue(try FinderRegisteredRoots.read(from:directory.appendingPathComponent("missing")).entries.isEmpty)
        XCTAssertTrue(try FinderRegisteredRoots.read(from:nil).entries.isEmpty)
        XCTAssertFalse(try catalog.write(to:nil))
    }
    func testCorruptFutureOversizedAndSymlinkCatalogsRefuseHintsAndPreserveTheirBytes()throws {
        let (directory,url)=try fixture();defer{try? FileManager.default.removeItem(at:directory)}
        let value=FinderRegisteredRoots(entries:[entry("/accepted")]);try value.write(to:url)
        var future=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]);future["version"]=2
        let futureBytes=try JSONSerialization.data(withJSONObject:future)
        for bytes in [futureBytes,Data("{truncated".utf8),Data(repeating:32,count:FinderRegisteredRoots.maximumBytes+1)] {
            try bytes.write(to:url,options:.atomic)
            XCTAssertThrowsError(try FinderRegisteredRoots.read(from:url))
            XCTAssertEqual(try Data(contentsOf:url),bytes)
        }
        try FileManager.default.removeItem(at:url)
        let target=directory.appendingPathComponent("owned-elsewhere.json");try value.write(to:target)
        let targetBytes=try Data(contentsOf:target)
        try FileManager.default.createSymbolicLink(at:url,withDestinationURL:target)
        XCTAssertThrowsError(try FinderRegisteredRoots.read(from:url))
        XCTAssertThrowsError(try value.write(to:url))
        XCTAssertEqual(try Data(contentsOf:target),targetBytes)
    }
    func testAtomicWriterFailureKeepsOldCatalogAndRecoversWithoutLosingPeerRoots()throws {
        let (directory,url)=try fixture();defer{try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path);try? FileManager.default.removeItem(at:directory)}
        let a=entry("/a"),b=entry("/b"),first=FinderRegisteredRoots(entries:[a,b]);try first.write(to:url)
        let before=try Data(contentsOf:url),updated=FinderRegisteredRoots(entries:[entry("/moved",id:a.id),b])
        if geteuid() != 0 {
            try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:directory.path)
            XCTAssertThrowsError(try updated.write(to:url))
            XCTAssertEqual(try Data(contentsOf:url),before)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        }
        XCTAssertTrue(try updated.write(to:url))
        let renewed=try FinderRegisteredRoots.read(from:url)
        XCTAssertNil(renewed.root(for:FileTransferPaths.fileURL("/a")))
        XCTAssertEqual(renewed.root(for:FileTransferPaths.fileURL("/moved/child"))?.id,a.id)
        XCTAssertEqual(renewed.root(for:FileTransferPaths.fileURL("/b"))?.id,b.id)
        try FinderRegisteredRoots(entries:[b]).write(to:url)
        let removed=try FinderRegisteredRoots.read(from:url)
        XCTAssertNil(removed.root(for:FileTransferPaths.fileURL("/moved")))
        XCTAssertEqual(removed.entries.map(\.id),[b.id])
    }
    func testPublicationProjectsCurrentArchiveRatherThanStaleHintsAndFencesRenewedKinds()throws {
        let (directory,url)=try fixture();defer{try? FileManager.default.removeItem(at:directory)}
        let archive=directory.appendingPathComponent("private-watches.json")
        let a=entry("/a"),b=entry("/b",kind:.bare)
        func records(_ entries:[FinderRegisteredRoots.Entry])throws {
            let values=entries.map{SavedRepository(id:$0.id,name:"Private",lastKnownPath:$0.root,bookmark:Data($0.root.utf8),lastOpened:Date(timeIntervalSince1970:0))}
            try JSONEncoder().encode(values).write(to:archive,options:.atomic)
        }
        try records([a]);XCTAssertTrue(try FinderRegisteredRoots.publish(watchArchive:archive,kindHints:[a],to:url))
        try records([a,b]);try FinderRegisteredRoots.publish(watchArchive:archive,kindHints:[b],to:url)
        try FinderRegisteredRoots.publish(watchArchive:archive,kindHints:[a],to:url)
        var read=try FinderRegisteredRoots.read(from:url)
        XCTAssertEqual(Set(read.entries.map(\.id)),Set([a.id,b.id]),"Late stale publication must retain current peer registration")
        XCTAssertEqual(read.root(for:FileTransferPaths.fileURL(b.root))?.kind,.bare)
        try records([b]);try FinderRegisteredRoots.publish(watchArchive:archive,kindHints:[a],to:url)
        XCTAssertEqual(try FinderRegisteredRoots.read(from:url).entries.map(\.id),[b.id],"Stale hints cannot revive removed authority")
        let renewed=entry("/renewed",id:b.id,kind:.workingTree)
        try records([renewed]);try FinderRegisteredRoots.publish(watchArchive:archive,kindHints:[b],to:url)
        read=try FinderRegisteredRoots.read(from:url)
        XCTAssertEqual(read.entries.first?.root,renewed.root)
        XCTAssertEqual(read.entries.first?.kind,.unknown,"Same ID at a different root must not inherit old bare classification")
        try FinderRegisteredRoots.publish(watchArchive:archive,kindHints:[renewed],to:url)
        let accepted=try Data(contentsOf:url)
        try Data("{broken private archive".utf8).write(to:archive,options:.atomic)
        XCTAssertThrowsError(try FinderRegisteredRoots.publish(watchArchive:archive,kindHints:[a,b],to:url))
        XCTAssertEqual(try Data(contentsOf:url),accepted,"Malformed private archive cannot replace accepted discovery context")
        try records([renewed]);XCTAssertFalse(try FinderRegisteredRoots.publish(watchArchive:archive,kindHints:[b],to:url))
        XCTAssertEqual(try FinderRegisteredRoots.read(from:url).entries.first?.kind,.workingTree)
        try records([]);try FinderRegisteredRoots.publish(watchArchive:archive,kindHints:[a,b],to:url)
        XCTAssertTrue(try FinderRegisteredRoots.read(from:url).entries.isEmpty)
    }
    func testCancelledWriteCannotCreateOrReplaceDiscoveryContext()throws {
        let (directory,url)=try fixture();defer{try? FileManager.default.removeItem(at:directory)}
        let token=OperationCancellation();token.cancel()
        let value=FinderRegisteredRoots(entries:[entry("/registered")])
        XCTAssertThrowsError(try value.write(to:url,cancellation:token))
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        try value.write(to:url);let before=try Data(contentsOf:url)
        XCTAssertThrowsError(try FinderRegisteredRoots().write(to:url,cancellation:token))
        XCTAssertEqual(try Data(contentsOf:url),before)
    }
}
