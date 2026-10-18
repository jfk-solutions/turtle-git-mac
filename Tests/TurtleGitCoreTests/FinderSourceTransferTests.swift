import XCTest
@testable import TurtleGitCore

final class FinderSourceTransferTests: XCTestCase {
    func testTwoFormsRoundTripLiteralSourcesWithoutClipboardPayload() throws {
        let sources = [FileTransferPaths.fileURL("/outside/-雪\n&?%.txt"), FileTransferPaths.fileURL("/outside/café.txt")]
        let selection = FinderRequest(action: .transferFiles, paths: sources + sources)
        let selected = try XCTUnwrap(FinderRequest(url: XCTUnwrap(selection.url)))
        XCTAssertTrue(selected.isTransferSourceSelection)
        XCTAssertFalse(selected.isTransferDestinationReview)
        XCTAssertEqual(selected.paths.map(\.path), sources.map(\.path))
        XCTAssertTrue(selected.sources.isEmpty)
        XCTAssertNil(selected.clipboardPatch)
        let destination = FileTransferPaths.fileURL("/repo/destination 雪\n&?")
        let review = try XCTUnwrap(FinderRequest(url: XCTUnwrap(FinderRequest(action: .transferFiles, paths: [destination], sources: sources).url)))
        XCTAssertTrue(review.isTransferDestinationReview)
        XCTAssertFalse(review.isTransferSourceSelection)
        XCTAssertEqual(review.paths.map(\.path), [destination.path])
        XCTAssertEqual(review.sources.map(\.path), sources.map(\.path))
        XCTAssertTrue(RepositoryAction.transferFiles.isFileTransfer)
        XCTAssertTrue(RepositoryAction.transferFiles.requiresWorkingTree)
        XCTAssertNil(FinderMenuEntry.entry(for: .transferFiles), "Mac adaptation must not consume an upstream Windows mask")
        XCTAssertEqual(RepositoryAction.transferFiles.icon, .rename)
    }
    func testMalformedBoundedAndAdministrativeFormsRefused() throws {
        let invalid = ["command=transferFiles", "command=transferFiles&path=/", "command=transferFiles&path=/repo/.GiT/config",
                       "command=transferFiles&path=/repo&source=/", "command=transferFiles&path=/repo&source=/other/.git/file",
                       "command=transferFiles&path=/repo&path=/other&source=/file", "command=transferFiles&path=/file&source",
                       "command=transferFiles&path=relative", "command=transferFiles&path=/file%00bad",
                       "command=transferFiles&path=/file&clipboardpatch=unavailable"]
        for query in invalid {
            XCTAssertNil(FinderRequest(url: try XCTUnwrap(URL(string: "turtlegit://action?" + query))), query)
        }
        let many = (0..<257).map { FileTransferPaths.fileURL("/file/\($0)") }
        XCTAssertNil(FinderRequest(action: .transferFiles, paths: many).url)
        XCTAssertNil(FinderRequest(action: .transferFiles, paths: [FileTransferPaths.fileURL("/repo")], sources: many).url)
        XCTAssertNil(FinderRequest(action: .transferFiles, paths: [URL(string: "https://example.com/file")!]).url)
        XCTAssertNil(FinderRequest(action: .transferFiles, paths: [FileTransferPaths.fileURL("/" + String(repeating: "x", count: 140000))]).url)
        let oversizedWire = "turtlegit://action?command=transferFiles&" + many.map { "path=" + $0.path }.joined(separator: "&")
        XCTAssertNil(FinderRequest(url: try XCTUnwrap(URL(string: oversizedWire))))
        let max = Array(many.prefix(256))
        XCTAssertNotNil(FinderRequest(action: .transferFiles, paths: max).url)
        XCTAssertNotNil(FinderRequest(action: .transferFiles, paths: [FileTransferPaths.fileURL("/repo")], sources: max).url)
    }
    func testCachedSourceEligibilityIncludesUnversionedAndExternalFilesButNotRoots() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = folder.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tracked = root.appendingPathComponent("tracked"), untracked = root.appendingPathComponent("untracked"), external = folder.appendingPathComponent("external")
        for file in [tracked, untracked, external] { try Data("x".utf8).write(to: file) }
        let symlink = root.appendingPathComponent("literal-link")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: external.path)
        var snapshot = FinderSnapshot.build(root: root, tracked: ["tracked"], changes: [])
        snapshot.repositories[root.path] = FinderRepositoryMetadata(bare: false)
        var settings = FinderMenuSettings()
        func request(_ sources: [URL]) -> FinderRequest? { FinderTransferContext.sourceRequest(selection: sources, snapshot: snapshot, settings: settings) }
        XCTAssertEqual(request([tracked, untracked, external, symlink])?.paths.map(\.lastPathComponent), ["tracked", "untracked", "external", "literal-link"])
        XCTAssertNotNil(request([root.appendingPathComponent("directory")]))
        XCTAssertNil(request([root]))
        XCTAssertNil(request([root.appendingPathComponent("missing")]))
        XCTAssertNil(request([root.appendingPathComponent(".GIT/config")]))
        XCTAssertNil(request([root, external]))
        settings.clipboardTransfers = false
        XCTAssertNil(request([tracked]))
        settings.clipboardTransfers = true
        snapshot.repositories[root.path] = FinderRepositoryMetadata(bare: true)
        XCTAssertNil(request([tracked]))
        XCTAssertNotNil(request([external]))
        XCTAssertEqual(request([external, external])?.paths.count, 1)
    }
    func testInvalidSourceRequestNeverBorrowsDestinationForm() throws {
        let destination = FileTransferPaths.fileURL("/repo")
        let source = FileTransferPaths.fileURL("/file")
        XCTAssertFalse(FinderRequest(action: .pasteCopy, paths: [source]).isTransferSourceSelection)
        XCTAssertFalse(FinderRequest(action: .pasteMove, paths: [destination], sources: [source]).isTransferDestinationReview)
        XCTAssertNil(FinderRequest(action: .log, paths: [destination], sources: [source]).url)
        XCTAssertNil(FinderRequest(action: .transferFiles, paths: [destination, source], sources: [source]).url)
    }
}
