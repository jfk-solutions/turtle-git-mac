import XCTest
@testable import TurtleGitCore

final class WorkingFileDeleteTests: XCTestCase {
    func testTrashPreservesLiteralBinaryContentsAndUnrelatedStaging() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("retained staging\n".utf8).write(to: root.appendingPathComponent(tracked))
        try await repository.stage([tracked])
        let path = ":(glob)雪,\n.bin", bytes = Data([0, 255, 13, 10])
        try bytes.write(to: root.appendingPathComponent(path))
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let index = root.appendingPathComponent(".git/index"), original = try Data(contentsOf: index)
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == path }
        let result = try await repository.deleteWorkingFiles(selected)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(result.removedPaths, [path]); XCTAssertEqual(result.removedIndexPaths, [])
        XCTAssertEqual(result.trashedFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.trashedFiles.first)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        XCTAssertEqual(try Data(contentsOf: index), original)
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(finalHead, head)
    }

    func testMissingTrackedFileRemovesOnlyItsIndexEntryWithSplitIndex() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep\n".utf8).write(to: root.appendingPathComponent("retained")); try await repository.stage(["retained"])
        _ = try await repository.run(["update-index", "--split-index"])
        let retained = try await repository.run(["ls-files", "--stage", "-z", "--", "retained"]).stdout
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        try FileManager.default.removeItem(at: root.appendingPathComponent(tracked))
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == tracked }
        let result = try await repository.deleteWorkingFiles(selected)
        XCTAssertEqual(result.removedIndexPaths, [tracked]); XCTAssertTrue(result.trashedFiles.isEmpty)
        let finalTracked = try await repository.run(["ls-files", "--stage", "-z", "--", tracked]).stdout
        let finalRetained = try await repository.run(["ls-files", "--stage", "-z", "--", "retained"]).stdout
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertTrue(finalTracked.isEmpty); XCTAssertEqual(finalRetained, retained); XCTAssertEqual(finalHead, head)
    }

    func testMixedSelectionTrashesTrackedWorkingEditsAndUntrackedFile() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("working edits 雪\n".utf8)
        try bytes.write(to: root.appendingPathComponent(tracked)); try Data([7]).write(to: root.appendingPathComponent("new"))
        let selected = try await repository.status(refreshIndex: false)
        let result = try await repository.deleteWorkingFiles(selected)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(Set(result.removedPaths), Set([tracked, "new"]))
        XCTAssertEqual(result.removedIndexPaths, [tracked]); XCTAssertEqual(result.trashedFiles.count, 2)
        let recovered = try result.trashedFiles.map { try Data(contentsOf: $0) }
        XCTAssertTrue(recovered.contains(bytes)); XCTAssertTrue(recovered.contains(Data([7])))
        let finalTracked = try await repository.run(["ls-files", "--stage", "-z", "--", tracked]).stdout
        XCTAssertTrue(finalTracked.isEmpty)
    }

    func testStaleCancelledAndLockedSelectionLeavesFilesAndIndexUntouched() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "new", file = root.appendingPathComponent(path), bytes = Data([3])
        try bytes.write(to: file)
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == path }
        let index = root.appendingPathComponent(".git/index"), original = try Data(contentsOf: index)
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repository.deleteWorkingFiles(selected, cancellation: cancellation); XCTFail("Cancelled operation accepted") } catch {}
        let lock = root.appendingPathComponent(".git/index.lock"); try Data([99]).write(to: lock)
        do { _ = try await repository.deleteWorkingFiles(selected); XCTFail("Existing index lock overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: lock), Data([99])); try FileManager.default.removeItem(at: lock)
        try await repository.stage([path])
        let stagedIndex = try Data(contentsOf: index)
        do { _ = try await repository.deleteWorkingFiles(selected); XCTFail("Stale selection accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: index), stagedIndex); XCTAssertNotEqual(stagedIndex, original)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testUnselectedMarkEnablesTrackedSelectionAndRejectsStaleMark() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(tracked), bytes = Data("changed working bytes\n".utf8)
        try bytes.write(to: file); try Data([7]).write(to: root.appendingPathComponent("mark"))
        let status = try await repository.status(refreshIndex: false)
        let selected = status.filter { $0.path == tracked }, mark = try XCTUnwrap(status.first { $0.path == "mark" })
        let index = root.appendingPathComponent(".git/index"), original = try Data(contentsOf: index)
        try await repository.stage(["mark"])
        let stagedIndex = try Data(contentsOf: index)
        do { _ = try await repository.deleteWorkingFiles(selected, selectionMark: mark); XCTFail("Stale selection mark accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertEqual(try Data(contentsOf: index), stagedIndex)
        _ = try await repository.run(["reset", "--", "mark"])
        let result = try await repository.deleteWorkingFiles(selected, selectionMark: mark)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(result.removedPaths, [tracked]); XCTAssertEqual(result.removedIndexPaths, [tracked])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.trashedFiles.first)), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("mark")), Data([7]))
        XCTAssertNotEqual(try Data(contentsOf: index), original)
    }

    func testIndexDeletedPathWithUnversionedCopyCanBeDeleted() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(tracked), bytes = try Data(contentsOf: file)
        _ = try await repository.run(["rm", "--cached", "--", tracked])
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == tracked }
        let entry = try XCTUnwrap(selected.first)
        XCTAssertTrue(entry.hasUnversionedCopy); XCTAssertTrue(entry.canDeleteWithKeyboard)
        let index = root.appendingPathComponent(".git/index"), original = try Data(contentsOf: index)
        let result = try await repository.deleteWorkingFiles(selected)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.trashedFiles.first)), bytes)
        XCTAssertTrue(result.removedIndexPaths.isEmpty); XCTAssertEqual(try Data(contentsOf: index), original)
    }

    func testTrashMovesSymlinkWithoutTouchingOutsideTarget() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        let target = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target); try? FileManager.default.removeItem(at: root) }
        let bytes = Data("outside target 雪\n".utf8); try bytes.write(to: target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let selected = try await repository.status(refreshIndex: false).filter { $0.path == "link" }
        let result = try await repository.deleteWorkingFiles(selected)
        defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(result.trashedFiles.count, 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: XCTUnwrap(result.trashedFiles.first).path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }

    func testPermanentDeleteOfBrokenSymlinkInLinkedWorktreeLeavesMainIndexExact() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        let linked = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked); try? FileManager.default.removeItem(at: root) }
        _ = try await repository.run(["worktree", "add", "-b", "delete-linked", linked.path])
        let original = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let url = linked.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "absent-target")
        let other = GitRepository(root: linked), selected = try await other.status(refreshIndex: false).filter { $0.path == "broken" }
        let result = try await other.deleteWorkingFiles(selected, permanently: true)
        XCTAssertEqual(result.removedPaths, ["broken"]); XCTAssertTrue(result.trashedFiles.isEmpty)
        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), original)
    }
}
