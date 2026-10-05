import XCTest
@testable import TurtleGitCore

final class FinderCreationMenuTests: XCTestCase {
    func testSourceCreationClauses() {
        typealias C = FinderCreationMenuContext
        let both: [RepositoryAction] = [.clone, .initialize]
        let cases: [(C, [RepositoryAction])] = [
            (C(directory: false, ignored: true, extended: true), []),
            (C(directory: true), both),
            (C(directory: true, versioned: true), []),
            (C(directory: true, versioned: true, extended: true), [.clone]),
            (C(directory: true, folderInGit: true), []),
            (C(directory: true, folderInGit: true, extended: true), both),
            (C(directory: true, bare: true), []),
            (C(directory: true, bare: true, extended: true), both),
            (C(directory: true, ignored: true), both),
            (C(directory: true, inaccessible: true), []),
            (C(directory: true, inaccessible: true, extended: true), both),
            (C(directory: true, versioned: true, ignored: true, inaccessible: true), both)
        ]
        for (context, expected) in cases { XCTAssertEqual(context.actions, expected) }
    }
    func testCachedStatusAndBareMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tracked = root.appendingPathComponent("tracked", isDirectory: true)
        let ignored = root.appendingPathComponent("ignored", isDirectory: true)
        let bare = root.appendingPathComponent("bare", isDirectory: true)
        for path in [tracked, ignored, bare.appendingPathComponent("refs/heads")] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: bare.appendingPathComponent("objects"), withIntermediateDirectories: true)
        for name in ["HEAD", "config"] { try Data().write(to: bare.appendingPathComponent(name)) }
        let snapshot = FinderSnapshot(roots: [root.path], states: [tracked.path: .normal, ignored.path: .ignored, bare.path: .normal])
        XCTAssertEqual(FinderCreationMenuContext.read(directory: tracked, snapshot: snapshot, extended: false).actions, [])
        XCTAssertEqual(FinderCreationMenuContext.read(directory: tracked, snapshot: snapshot, extended: true).actions, [.clone])
        XCTAssertEqual(FinderCreationMenuContext.read(directory: ignored, snapshot: snapshot, extended: false).actions, [.clone, .initialize])
        XCTAssertTrue(FinderCreationMenuContext.read(directory: bare, snapshot: snapshot, extended: false).bare)
        XCTAssertEqual(FinderCreationMenuContext.read(directory: bare, snapshot: snapshot, extended: true).actions, [.clone, .initialize])
        try FileManager.default.removeItem(at: bare.appendingPathComponent("objects"))
        try Data().write(to: bare.appendingPathComponent("objects"))
        XCTAssertFalse(FinderCreationMenuContext.read(directory: bare, snapshot: snapshot, extended: true).bare, "Source directory probes must reject files")
        let other = root.appendingPathComponent("tracked-other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(FinderCreationMenuContext.read(directory: other, snapshot: snapshot, extended: false).actions, [.clone, .initialize])
        try Data().write(to: other.appendingPathComponent(".git"))
        XCTAssertTrue(FinderCreationMenuContext.read(directory: other, snapshot: nil, extended: false).inaccessible)
    }
    func testOnlyCreationRequestsCanOmitPaths() throws {
        for action in RepositoryAction.allCases {
            let request = FinderRequest(action: action, paths: [])
            if action == .clone || action == .initialize {
                let url = try XCTUnwrap(request.url)
                XCTAssertEqual(FinderRequest(url: url)?.action, action)
                XCTAssertEqual(FinderRequest(url: url)?.paths, [])
                XCTAssertNil(FinderRequest(url: URL(string: "turtlegit://action?command=\(action.rawValue)&path")!))
            } else { XCTAssertNil(request.url); XCTAssertNil(FinderRequest(url: URL(string: "turtlegit://action?command=\(action.rawValue)")!)) }
        }
    }
}
