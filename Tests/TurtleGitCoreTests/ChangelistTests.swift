import XCTest
@testable import TurtleGitCore

final class ChangelistTests: XCTestCase {
    func testExactPathAndNamePersistenceAcrossActorsAndCodable() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = "café/file", b = "cafe\u{301}/file", first = "réview", second = "re\u{301}view"
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        _ = try await repo.assignChangelist(paths: [a, b, a], name: first)
        let other = GitRepository(root: root)
        let lists = try await other.assignChangelist(paths: [b], name: second)
        XCTAssertEqual(lists.exactAssignments.count, 2)
        XCTAssertEqual(lists.nameIdentities.count, 2)
        XCTAssertTrue(GitReferenceName.equal(try XCTUnwrap(lists.name(for: a)), first))
        XCTAssertTrue(GitReferenceName.equal(try XCTUnwrap(lists.name(for: b)), second))
        XCTAssertEqual(try JSONDecoder().decode(GitChangelists.self, from: JSONEncoder().encode(lists)), lists)
        let read = try await repo.changelists(); XCTAssertEqual(read, lists)
        let removed = try await repo.assignChangelist(paths: [a], name: nil)
        XCTAssertNil(removed.name(for: a)); XCTAssertTrue(GitReferenceName.equal(try XCTUnwrap(removed.name(for: b)), second))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testLegacyJSONObjectAndUTF16ImportRetainCanonicalSpellings() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".git/turtlegit-changelists.json")
        let json = #"{"version":1,"assignments":{"café":"réview","cafe\u0301":"re\u0301view"}}"#
        try Data(json.utf8).write(to: file)
        var lists = try await repo.changelists()
        XCTAssertEqual(lists.exactAssignments.count, 2); XCTAssertEqual(lists.nameIdentities.count, 2)
        _ = try await repo.assignChangelist(paths: ["another"], name: "Third")
        struct Header: Decodable { let version: Int }
        XCTAssertEqual(try JSONDecoder().decode(Header.self, from: Data(contentsOf: file)).version, 2)
        lists = try await repo.changelists(); XCTAssertEqual(lists.exactAssignments.count, 3)
        let legacy = root.appendingPathComponent(".git/tgitchangelist")
        let text = "<réview>\ncafé\n<re\u{301}view>\ncafe\u{301}\n"
        for (bom, encoding) in [(Data([255,254]), String.Encoding.utf16LittleEndian), (Data([254,255]), .utf16BigEndian)] {
            try FileManager.default.removeItem(at: file)
            let bytes = bom + (try XCTUnwrap(text.data(using: encoding))); try bytes.write(to: legacy)
            lists = try await repo.changelists()
            XCTAssertEqual(lists.exactAssignments.count, 2); XCTAssertEqual(lists.nameIdentities.count, 2)
            _ = try await repo.assignChangelist(paths: ["third"], name: "Third")
            XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        }
    }
    func testExactScopedPruningAndCancellationPreserveOtherSpelling() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = "café", b = "cafe\u{301}"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(a), withIntermediateDirectories: true)
        _ = try await repo.assignChangelist(paths: [a + "/one", b + "/two"], name: "Work")
        let lists = try await repo.pruneChangelists(retainingPathNames: [], scope: [a])
        XCTAssertNil(lists.name(for: a + "/one")); XCTAssertEqual(lists.name(for: b + "/two"), "Work")
        let file = root.appendingPathComponent(".git/turtlegit-changelists.json"), before = try Data(contentsOf: file)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.pruneChangelists(retainingPathNames: [], cancellation: token); XCTFail("Cancelled pruning wrote metadata") } catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testDuplicateExactRecordsAreRefusedWithoutOverwriting() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".git/turtlegit-changelists.json")
        let bytes = Data(#"{"version":2,"assignments":[{"path":"file","name":"A"},{"path":"file","name":"B"}]}"#.utf8)
        try bytes.write(to: file)
        do { _ = try await repo.assignChangelist(paths: ["file"], name: "Changed"); XCTFail("Duplicate record accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".lock"))
    }

    func testCancelledAssignmentRetainsExistingMetadataAndGitIndex() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.assignChangelist(paths: [path], name: "Keep")
        let file = root.appendingPathComponent(".git/turtlegit-changelists.json")
        let original = try Data(contentsOf: file), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.assignChangelist(paths: [path], name: "Replace", cancellation: token); XCTFail("Cancelled assignment wrote metadata") } catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".lock"))
    }

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
