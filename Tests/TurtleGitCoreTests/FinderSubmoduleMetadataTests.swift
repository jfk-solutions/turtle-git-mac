import XCTest
@testable import TurtleGitCore

final class FinderSubmoduleMetadataTests: XCTestCase {
    func testMetadataCompatibilityAndRootClauses() throws {
        let old = Data(#"{"bare":false,"bisectActive":false,"mergeActive":false,"hasStash":false,"hasSubmoduleConfig":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(FinderRepositoryMetadata.self, from: old).submoduleParentRoot)
        let info = FinderRepositoryMetadata(submoduleParentRoot: "/parent")
        XCTAssertEqual(try JSONDecoder().decode(FinderRepositoryMetadata.self, from: JSONEncoder().encode(info)), info)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = FinderSnapshot(roots: [root.path], states: [root.path: .normal], repositories: [root.path: info])
        let flags = FinderShellRules.flags(paths: [root], snapshot: snapshot)
        XCTAssertTrue(flags.contains(.submodule)); XCTAssertTrue(flags.contains(.workingTreeRoot))
        XCTAssertTrue(FinderShellRules.allows(.rename, flags: flags)); XCTAssertTrue(snapshot.canRename([root]))
        XCTAssertTrue(FinderShellRules.allows(.remove, flags: flags)); XCTAssertTrue(snapshot.canRemove([root]))
        XCTAssertFalse(FinderShellRules.allows(.removeKeep, flags: flags))
        let ordinary = FinderSnapshot(roots: [root.path], states: [root.path: .normal], repositories: [root.path: FinderRepositoryMetadata()])
        XCTAssertFalse(FinderShellRules.flags(paths: [root], snapshot: ordinary).contains(.submodule))
        XCTAssertFalse(ordinary.canRename([root])); XCTAssertFalse(ordinary.canRemove([root]))
    }
    func testRegisteredSubmoduleRenameRoutesToParentAndUpdatesGitMetadata() async throws {
        let (root, parent, _) = try await GitPatchTests().fixture()
        let (source, _, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let path = "group/module 雪\nname"
        _ = try await parent.run(["-c", "protocol.file.allow=always", "submodule", "add", "--name", "module", "--", source.path, path])
        try await parent.stage([".gitmodules", path]); _ = try await parent.commit(message: "add module")
        let child = GitRepository(root: root.appendingPathComponent(path, isDirectory: true))
        let metadata = try await child.finderMetadata()
        XCTAssertEqual(metadata.submoduleParentRoot, root.path)
        let renameRoot = try await child.discoverSelectionRoot(for: .rename, selected: child.root)
        let removeRoot = try await child.discoverSelectionRoot(for: .remove, selected: child.root)
        XCTAssertEqual(renameRoot.path, root.path); XCTAssertEqual(removeRoot.path, root.path)
        let logRoot = try await child.discoverSelectionRoot(for: .log, selected: child.root)
        XCTAssertEqual(logRoot, child.root)
        _ = try await parent.rename(RenameOptions(source: path, name: "renamed 雪\nmodule"))
        let newPath = "group/renamed 雪\nmodule"
        let indexed = try await parent.submodulePaths(); XCTAssertTrue(indexed.contains(newPath)); XCTAssertFalse(indexed.contains(path))
        let moved = GitRepository(root: root.appendingPathComponent(newPath, isDirectory: true))
        let movedMetadata = try await moved.finderMetadata(); XCTAssertEqual(movedMetadata.submoduleParentRoot, root.path)
        let oldRoot = try await child.registeredSubmoduleParent(); XCTAssertNil(oldRoot)
        let parentHead = try await parent.run(["rev-parse", "HEAD"]).text
        _ = try await parent.removeVersionedPath(newPath, keepLocal: false)
        let afterRemoval = try await parent.submodulePaths(); XCTAssertFalse(afterRemoval.contains(newPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.root.path))
        let currentHead = try await parent.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(currentHead, parentHead)
    }
    func testUnregisteredNestedRepositoryIsNotSubmodule() async throws {
        let (root, parent, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested 雪", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try await parent.run(["init", nested.path])
        let child = GitRepository(root: nested)
        let nestedMetadata = try await child.finderMetadata(); XCTAssertNil(nestedMetadata.submoduleParentRoot)
        let owner = try await child.discoverSelectionRoot(for: .rename, selected: nested)
        XCTAssertEqual(owner, nested)
        try Data("[submodule \"other\"]\npath = nested 雪-other\n".utf8).write(to: root.appendingPathComponent(".gitmodules"))
        let unmatched = try await child.registeredSubmoduleParent(); XCTAssertNil(unmatched)
    }
}
