import XCTest
@testable import TurtleGitCore

final class AddTests: XCTestCase {
    func testFolderSelectionIgnoredDefaultsAndLiteralCheckedAdd() async throws {
        let (root, repo, tracked) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = "new/:(glob)* 雪\n.txt", other = "new/unchecked.txt", ignored = "secret.log"
        for path in [file, other, ignored] { try Data(path.utf8).write(to: root.appendingPathComponent(path)) }
        try Data("*.log\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let folderRows = try await repo.addDialogSelection(paths: ["new"], includeIgnored: false)
        XCTAssertEqual(Set(folderRows.entries.map(\.path)), [file, other]); XCTAssertEqual(folderRows.initiallyChecked, [file, other])
        let hidden = try await repo.addDialogSelection(paths: ["."], includeIgnored: false)
        XCTAssertFalse(hidden.entries.contains { $0.path == ignored })
        let visible = try await repo.addDialogSelection(paths: ["."], includeIgnored: true)
        XCTAssertTrue(visible.entries.contains { $0.path == ignored }); XCTAssertFalse(visible.initiallyChecked.contains(ignored))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        _ = try await repo.addReviewedPaths([file, ignored])
        let staged = try await repo.run(["diff", "--cached", "--name-only", "-z"]).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(Set(staged), [file, ignored])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(file)), Data(file.utf8))
        let currentHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(currentHead, head)
        let directNormal = try await repo.addDialogSelection(paths: [tracked], includeIgnored: false)
        XCTAssertEqual(directNormal.entries.first?.state, .normal); XCTAssertEqual(directNormal.initiallyChecked, [tracked])
    }
    func testFileFastRouteUnbornAndCancelledAddition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root); _ = try await repo.run(["init", "-b", "main"])
        try Data("first".utf8).write(to: root.appendingPathComponent("first.txt"))
        let direct = try await repo.addSelectionIsFiles(["first.txt"]); XCTAssertTrue(direct)
        let whole = try await repo.addSelectionIsFiles(["."]); XCTAssertFalse(whole)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.addReviewedPaths(["first.txt"], cancellation: token); XCTFail("Cancelled add succeeded") } catch {}
        let before = try await repo.trackedPaths(); XCTAssertTrue(before.isEmpty)
        _ = try await repo.addReviewedPaths(["first.txt"])
        let after = try await repo.trackedPaths(); XCTAssertEqual(after, ["first.txt"])
    }
    func testForeignNestedFileAndInvalidPathsRejectBeforeIndexChange() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try await repo.run(["init", nested.path]); try Data("foreign".utf8).write(to: nested.appendingPathComponent("file"))
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        for paths in [[], ["."], ["../outside"], [".git/config"], ["nested/file"]] {
            do { _ = try await repo.addReviewedPaths(paths); XCTFail("Invalid paths accepted: \(paths)") } catch {}
        }
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout; XCTAssertEqual(after, index)
    }
}
