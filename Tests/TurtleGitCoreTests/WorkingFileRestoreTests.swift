import XCTest
@testable import TurtleGitCore

final class WorkingFileRestoreTests: XCTestCase {
    func testRevealSelectsLiteralFilesAndLinksOrOpensNearestExistingFolderWithoutCheckout() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: root.appendingPathComponent("broken-link").path, withDestinationPath: "/missing/target")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let selected = try await repo.fileRevealDestination(path: path); XCTAssertEqual(selected, .select(root.appendingPathComponent(path)))
        let linked = try await repo.fileRevealDestination(path: "broken-link"); XCTAssertEqual(linked, .select(root.appendingPathComponent("broken-link")))
        let missing = try await repo.fileRevealDestination(path: "nested/gone/deleted.txt"); XCTAssertEqual(missing, .openDirectory(root.appendingPathComponent("nested")))
        let rootFallback = try await repo.fileRevealDestination(path: "gone/deleted.txt"); XCTAssertEqual(rootFallback, .openDirectory(URL(fileURLWithPath: root.path, isDirectory: true)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(finalHead, head)
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent("gone").path))
    }
    func testRevealRejectsMetadataEscapingParentAndBareRepository() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
        for path in ["../outside", ".git/index", "escape/missing", "bad\0path"] {
            do { _ = try await repo.fileRevealDestination(path: path); XCTFail("Unsafe reveal accepted") } catch {}
        }
        let bare = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["init", "--bare", bare.path])
        do { _ = try await GitRepository(root: bare).fileRevealDestination(path: "file"); XCTFail("Bare reveal accepted") } catch RevisionComparisonFailure.selection {}
    }
    func testRestoreBinaryCopyAfterCommitPreservesCommittedIndexAndPermissions() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data([0, 255, 239, 187, 191, 13, 10, 65])
        try original.write(to: root.appendingPathComponent(path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(path).path)
        let copy = try await repo.captureWorkingFileRestoreCopy(path: path)
        let committed = Data([0, 254, 66])
        try committed.write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "intermediate contents")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        try await repo.restoreWorkingFile(copy)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let staged = try await repo.run(["show", ":" + path]).stdout
        XCTAssertEqual(finalHead, head); XCTAssertEqual(staged, committed)
    }
    func testRestoreSymlinkCopiesTargetTextWithoutTouchingOutsideFile() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside untouched".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let path = "link 雪\n", location = root.appendingPathComponent(path)
        try FileManager.default.createSymbolicLink(atPath: location.path, withDestinationPath: outside.path)
        try await repo.stage([path]); _ = try await repo.commit(message: "link")
        let copy = try await repo.captureWorkingFileRestoreCopy(path: path)
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createSymbolicLink(atPath: location.path, withDestinationPath: "missing target")
        try await repo.restoreWorkingFile(copy)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: location.path), outside.path)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside untouched".utf8))
    }
    func testRestoreRejectsEscapingParentAndRetainsCopyForRetry() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder"), path = "folder/file"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("saved".utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "folder")
        let copy = try await repo.captureWorkingFileRestoreCopy(path: path)
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("file"))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(atPath: folder.path, withDestinationPath: outside.path)
        do { try await repo.restoreWorkingFile(copy); XCTFail("Escaping parent accepted") }
        catch { XCTAssertTrue(error is WorkingFileRestoreFailure) }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file")), Data("outside".utf8))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await repo.restoreWorkingFile(copy)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("saved".utf8))
    }
    func testWrongRepositoryUnversionedAndDirectoryDestinationsAreRejected() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try await repo.captureWorkingFileRestoreCopy(path: path)
        let other = GitRepository(root: root.deletingLastPathComponent())
        do { try await other.restoreWorkingFile(copy); XCTFail("Wrong repository accepted") }
        catch { XCTAssertTrue(error is WorkingFileRestoreFailure) }
        try Data("new".utf8).write(to: root.appendingPathComponent("untracked"))
        do { _ = try await repo.captureWorkingFileRestoreCopy(path: "untracked"); XCTFail("Untracked file accepted") }
        catch { XCTAssertTrue(error is WorkingFileRestoreFailure) }
        let location = root.appendingPathComponent(path)
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        do { try await repo.restoreWorkingFile(copy); XCTFail("Directory overwritten") }
        catch { XCTAssertTrue(error is WorkingFileRestoreFailure) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.path))
        try FileManager.default.removeItem(at: location)
        try await repo.restoreWorkingFile(copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.path))
    }
}
