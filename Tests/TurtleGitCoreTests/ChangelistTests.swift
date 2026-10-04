import XCTest
@testable import TurtleGitCore

final class ChangelistTests: XCTestCase {
    func testPersistMoveRemoveAndLiteralNamesPreserveGitAndWorkingState() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: root.appendingPathComponent(path)), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let empty = try await repo.changelists(); XCTAssertTrue(empty.assignments.isEmpty)
        var lists = try await repo.assignChangelist(paths: [path, path], name: "Feature 雪\n<literal>")
        XCTAssertEqual(lists.names, ["Feature 雪\n<literal>"])
        let other = GitRepository(root: root)
        let loaded = try await other.changelists(); XCTAssertEqual(loaded, lists)
        lists = try await other.assignChangelist(paths: [path], name: GitChangelists.ignored); XCTAssertTrue(lists.ignores(path))
        lists = try await repo.assignChangelist(paths: [path], name: nil); XCTAssertTrue(lists.assignments.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(finalHead, head)
    }
    func testMutationReloadsOtherActorAssignmentsAndRejectsInvalidInputsAndExistingLock() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.assignChangelist(paths: [path], name: "First")
        let other = GitRepository(root: root); _ = try await other.assignChangelist(paths: ["another"], name: "Second")
        let lists = try await repo.assignChangelist(paths: ["third"], name: "Third")
        XCTAssertEqual(lists.assignments[path], "First"); XCTAssertEqual(lists.assignments["another"], "Second")
        let file = root.appendingPathComponent(".git/turtlegit-changelists.json"), original = try Data(contentsOf: file)
        for paths in [[String](), [".git/index"], ["../escape"]] {
            do { _ = try await repo.assignChangelist(paths: paths, name: "Invalid"); XCTFail("Invalid paths accepted") } catch {}
        }
        for name in ["", "nul\0name"] {
            do { _ = try await repo.assignChangelist(paths: [path], name: name); XCTFail("Invalid name accepted") } catch {}
        }
        let lock = root.appendingPathComponent(".git/turtlegit-changelists.json.lock"); try Data([99]).write(to: lock)
        do { _ = try await repo.assignChangelist(paths: [path], name: "Locked"); XCTFail("Existing lock overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original); XCTAssertEqual(try Data(contentsOf: lock), Data([99]))
    }
    func testLegacyImportLeavesSourceExactAndNewlinePathsRoundTripInNativeFile() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(".git/tgitchangelist")
        let text = "default.txt\r\n<Feature 雪>\r\nnested/file.txt\r\n\r\n<ignore-on-commit>\r\nignored.txt\r\n"
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
            var bytes = try XCTUnwrap(text.data(using: encoding))
            if encoding == .utf16LittleEndian { bytes.insert(contentsOf: [255, 254], at: 0) }
            if encoding == .utf16BigEndian { bytes.insert(contentsOf: [254, 255], at: 0) }
            try bytes.write(to: source)
            let lists = try await repo.changelists()
            XCTAssertTrue(lists.ignores("default.txt")); XCTAssertTrue(lists.ignores("ignored.txt")); XCTAssertEqual(lists.assignments["nested/file.txt"], "Feature 雪")
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
        let legacy = try Data(contentsOf: source)
        _ = try await repo.assignChangelist(paths: [path], name: "Native")
        let loaded = try await repo.changelists(); XCTAssertEqual(loaded.assignments[path], "Native")
        XCTAssertEqual(loaded.assignments["nested/file.txt"], "Feature 雪"); XCTAssertEqual(try Data(contentsOf: source), legacy)
    }
    func testLinkedWorktreesHaveIndependentChangelists() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        let linked = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: root) }
        _ = try await repo.assignChangelist(paths: [path], name: "Main")
        let metadata = try Data(contentsOf: root.appendingPathComponent(".git/turtlegit-changelists.json"))
        _ = try await repo.run(["worktree", "add", "-b", "changelist-linked", linked.path])
        let other = GitRepository(root: linked), empty = try await other.changelists(); XCTAssertTrue(empty.assignments.isEmpty)
        _ = try await other.assignChangelist(paths: [path], name: "Linked")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/turtlegit-changelists.json")), metadata)
        let loaded = try await other.changelists(); XCTAssertEqual(loaded.assignments[path], "Linked")
    }
    func testCommitPruningPreservesUncheckedRestoredOutsideScopeAndFileScopes() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        let paths = ["folder/committed", "folder/unchecked", "folder/restored", "outside"]
        _ = try await repo.assignChangelist(paths: paths, name: "Feature")
        var lists = try await repo.pruneChangelists(retaining: ["folder/unchecked", "folder/restored"], scope: ["folder"])
        XCTAssertEqual(Set(lists.assignments.keys), Set(["folder/unchecked", "folder/restored", "outside"]))
        try Data([1]).write(to: root.appendingPathComponent("file-scope"))
        lists = try await repo.pruneChangelists(retaining: [], scope: ["file-scope"])
        XCTAssertEqual(lists.assignments.count, 3)
        lists = try await repo.pruneChangelists(retaining: ["folder/restored"])
        XCTAssertEqual(lists.assignments, ["folder/restored": "Feature"])
    }
    func testCorruptUnknownVersionAndSymlinkMetadataFailWithoutOverwriting() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".git/turtlegit-changelists.json")
        for contents in ["broken", "{\"version\":99,\"assignments\":{}}"] {
            let bytes = Data(contents.utf8); try bytes.write(to: file)
            do { _ = try await repo.assignChangelist(paths: [path], name: "New"); XCTFail("Invalid metadata overwritten") } catch {}
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        try FileManager.default.removeItem(at: file); let bytes = Data("outside\n".utf8); try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: outside.path)
        do { _ = try await repo.assignChangelist(paths: [path], name: "New"); XCTFail("Symlink metadata accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), outside.path)
    }
}
