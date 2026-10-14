import XCTest
@testable import TurtleGitCore

final class WorkingFileRevertRetryTests: XCTestCase {
    func testRetryReadsCurrentRowsWithoutIncludingUnselectedChanges() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let other = "unselected.txt"; try Data("other".utf8).write(to: root.appendingPathComponent(other)); try await repo.stage([other]); _ = try await repo.commit(message: "other")
        try Data("selected edits".utf8).write(to: root.appendingPathComponent(path))
        let old = try await repo.status().filter { $0.path == path }
        try await repo.stage([path]); try Data("further edits".utf8).write(to: root.appendingPathComponent(path)); try Data("unselected edits".utf8).write(to: root.appendingPathComponent(other))
        let refreshed = try await repo.workingFileRevertSelection(old)
        XCTAssertEqual(refreshed.count, 1); XCTAssertEqual(refreshed.first?.path, path); XCTAssertNotEqual(refreshed.first, old.first)
        let result = try await repo.revertWorkingFiles(refreshed); defer { for url in result.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(other)), Data("unselected edits".utf8))
        let clean = try await repo.workingFileRevertSelection(old); XCTAssertEqual(clean.count, 1); XCTAssertEqual(clean.first?.index, " "); XCTAssertEqual(clean.first?.worktree, " ")
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.workingFileRevertSelection(old, cancellation: token); XCTFail("Cancelled retry read succeeded") } catch OperationCancellationFailure.cancelled {}
    }
}
