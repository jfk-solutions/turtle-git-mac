import XCTest
@testable import TurtleGitCore

final class PatchTargetMatchingTests: XCTestCase {
    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMatching-雪\n-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root.standardizedFileURL
    }
    func files(_ names: [String], in directory: URL) throws {
        for name in names { let file = directory.appendingPathComponent(name); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try Data().write(to: file) }
    }
    func testCurrentAncestorThresholdAndPermissionBoundary() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child"); try files(["a"], in: child); try files(["a", "b"], in: root)
        let paths = ["a", "b", "c"].map { Data($0.utf8) }
        XCTAssertEqual(PatchTargetMatching.suggestion(start: child, paths: paths, boundary: root), root)
        XCTAssertNil(PatchTargetMatching.suggestion(start: child, paths: paths, boundary: child))
        try files(["b"], in: child)
        XCTAssertNil(PatchTargetMatching.suggestion(start: child, paths: paths, boundary: root))
        let token = OperationCancellation(); token.cancel()
        XCTAssertNil(PatchTargetMatching.suggestion(start: child, paths: paths, boundary: root, cancellation: token))
    }
    func testImmediateChildrenSkipAdminAndSymlinks() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let admin = root.appendingPathComponent(".git"), directory = root.appendingPathComponent("actual")
        try files(["file"], in: admin); try files(["file"], in: directory)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("aaa-link"), withDestinationURL: directory)
        XCTAssertEqual(PatchTargetMatching.suggestion(start: root, paths: [Data("file".utf8)], boundary: root)?.path, directory.path)
        XCTAssertNil(PatchTargetMatching.suggestion(start: root, paths: [Data("../file".utf8), Data(".git/file".utf8)], boundary: root))
    }
    func testNewFileParentDirectoryFallback() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("selected"), source = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let paths = ["src/new1", "src/new2", "src/new3"].map { Data($0.utf8) }
        XCTAssertEqual(PatchTargetMatching.suggestion(start: child, paths: paths, boundary: root), root)
    }
    func testDefaultStripForGitPlainAndBinaryHeaders() {
        XCTAssertEqual(PatchTargetMatching.initialStripCount(Data("--- src/file\n+++ src/file\n@@ -1 +1 @@\n-a\n+b\n".utf8)), 0)
        XCTAssertEqual(PatchTargetMatching.initialStripCount(Data("--- a/src/file\n+++ b/src/file\n@@ -1 +1 @@\n-a\n+b\n".utf8)), 1)
        XCTAssertEqual(PatchTargetMatching.initialStripCount(Data("diff --git a/bin b/bin\nGIT binary patch\n".utf8)), 1)
        XCTAssertEqual(PatchTargetMatching.initialStripCount(Data("--- /dev/null\n+++ \"b/雪\\nfile\"\n@@ -0,0 +1 @@\n+new\n".utf8)), 1)
    }
    func testRealGitPreimagesAndCancellation() async throws {
        let (root, repository, bytes) = try await WorkingTreePatchReviewTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let paths = try await repository.patchTargetPaths(bytes, stripCount: 1)
        XCTAssertTrue(paths.contains(Data("--old 雪".utf8))); XCTAssertFalse(paths.contains(Data("--new 雪".utf8)))
        XCTAssertEqual(paths.count, 4); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repository.patchTargetPaths(bytes, stripCount: 1, cancellation: token); XCTFail("Cancelled query ran") } catch is OperationCancellationFailure { }
    }
}
