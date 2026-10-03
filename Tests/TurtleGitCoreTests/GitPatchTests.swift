import XCTest
@testable import TurtleGitCore

final class GitPatchTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root), path = "file 雪\n.txt"
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Patch Tests"])
        _ = try await repo.run(["config", "user.email", "patch@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data((1...30).map { "line \($0)\n" }.joined().utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.commit(message: "base")
        return (root, repo, path)
    }
    func change(_ root: URL, _ path: String) throws -> String {
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).replacingOccurrences(of: "line 2\n", with: "first change\nextra first\n").replacingOccurrences(of: "line 26\n", with: "second change\n")
        try Data(text.utf8).write(to: root.appendingPathComponent(path)); return text
    }
    func testStageSecondHunkWithoutFirstAndUnstageIt() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let working = try change(root, path), document = try await repo.patch(paths: [path], staged: false)
        XCTAssertEqual(document.files[0].hunks.count, 2)
        let hunk = document.files[0].hunks[1]
        try await repo.applyPatchSelection(document, paths: [path], staged: false, lines: [hunk.header], entireHunks: true)
        var index = try await repo.run(["show", ":" + path]).text
        XCTAssertTrue(index.contains("second change")); XCTAssertFalse(index.contains("first change"))
        let staged = try await repo.patch(paths: [path], staged: true)
        try await repo.applyPatchSelection(staged, paths: [path], staged: true, lines: [staged.files[0].hunks[0].header], entireHunks: true)
        index = try await repo.run(["show", ":" + path]).text
        XCTAssertTrue(index.contains("line 26")); XCTAssertFalse(index.contains("second change"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), working)
    }
    func testStageOneAddedLineAndUnstageOneLineFromPartiallyStagedFile() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try change(root, path)
        var document = try await repo.patch(paths: [path], staged: false)
        let line = try XCTUnwrap(document.lines.firstIndex(of: "+extra first"))
        try await repo.applyPatchSelection(document, paths: [path], staged: false, lines: [line], entireHunks: false)
        let index = try await repo.run(["show", ":" + path]).text
        XCTAssertTrue(index.contains("line 2\nextra first\n")); XCTAssertFalse(index.contains("first change")); XCTAssertFalse(index.contains("second change"))
        document = try await repo.patch(paths: [path], staged: true)
        try await repo.applyPatchSelection(document, paths: [path], staged: true, lines: [try XCTUnwrap(document.lines.firstIndex(of: "+extra first"))], entireHunks: false)
        let after = try await repo.diff(staged: true); XCTAssertTrue(after.isEmpty)
    }
    func testStageBothHunksAdjustsOffsetsAndRejectsStalePatch() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let working = try change(root, path), document = try await repo.patch(paths: [path], staged: false)
        try await repo.applyPatchSelection(document, paths: [path], staged: false, lines: Set(document.files[0].hunks.map(\.header)), entireHunks: true)
        let index = try await repo.run(["show", ":" + path]).text; XCTAssertEqual(index, working)
        do { try await repo.applyPatchSelection(document, paths: [path], staged: false, lines: [document.files[0].hunks[0].header], entireHunks: true); XCTFail("Stale patch must fail") } catch PatchFailure.changed {}
    }
    func testNoNewlineMarkerSurvivesAndUnsupportedMetadataFails() throws {
        let document = GitPatch(text: "diff --git a/a b/a\nindex aaa..bbb 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n")
        let result = try document.selectedPatch(lines: [4], entireHunks: true, reverse: false)
        XCTAssertEqual(result.components(separatedBy: "\\ No newline").count, 3)
        let newFile = GitPatch(text: "diff --git a/a b/a\nnew file mode 100644\n--- /dev/null\n+++ b/a\n@@ -0,0 +1 @@\n+new\n")
        XCTAssertThrowsError(try newFile.selectedPatch(lines: [4], entireHunks: true, reverse: false))
    }
    func testReverseSecondHunkWithEarlierIndexInsertionAndRestoreOneRemovedLine() async throws {
        let (root, repo, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try change(root, path); try await repo.stage([path])
        var document = try await repo.patch(paths: [path], staged: true)
        try await repo.applyPatchSelection(document, paths: [path], staged: true, lines: [document.files[0].hunks[1].header], entireHunks: true)
        var index = try await repo.run(["show", ":" + path]).text
        XCTAssertTrue(index.contains("first change")); XCTAssertTrue(index.contains("line 26")); XCTAssertFalse(index.contains("second change"))
        document = try await repo.patch(paths: [path], staged: true)
        let removed = try XCTUnwrap(document.lines.firstIndex(of: "-line 2"))
        try await repo.applyPatchSelection(document, paths: [path], staged: true, lines: [removed], entireHunks: false)
        index = try await repo.run(["show", ":" + path]).text
        XCTAssertTrue(index.contains("line 2")); XCTAssertTrue(index.contains("first change")); XCTAssertTrue(index.contains("extra first"))
    }

}
