import XCTest
@testable import TurtleGitCore

final class PartialMetadataTests: XCTestCase {
    func testStageTextWithExecutableBitAndReverseOneHunkRetainsOtherText() async throws {
        let (root, repository, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let working = try GitPatchTests().change(root, path), file = root.appendingPathComponent(path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        var patch = try await repository.patch(paths: [path], staged: false)
        XCTAssertTrue(patch.files[0].supportsPartialChanges); XCTAssertTrue(patch.files[0].hasSelectedTextMetadata)
        try await repository.applyPatchSelection(patch, paths: [path], staged: false, lines: [patch.files[0].hunks[1].header], entireHunks: true)
        var indexed = try await repository.run(["show", ":" + path]).text
        var mode = try await repository.run(["ls-files", "--stage", "--", path]).text
        XCTAssertTrue(indexed.contains("second change")); XCTAssertFalse(indexed.contains("first change")); XCTAssertTrue(mode.hasPrefix("100755"))
        try await repository.stage([path])
        patch = try await repository.patch(paths: [path], staged: true)
        try await repository.applyPatchSelection(patch, paths: [path], staged: true, lines: [patch.files[0].hunks[1].header], entireHunks: true)
        indexed = try await repository.run(["show", ":" + path]).text
        mode = try await repository.run(["ls-files", "--stage", "--", path]).text
        XCTAssertTrue(indexed.contains("first change")); XCTAssertFalse(indexed.contains("second change")); XCTAssertTrue(mode.hasPrefix("100644"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), working)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o111, 0o111)
    }

    func testPartialRenameUnstageMovesIndexPathWithSelectedTextOnly() async throws {
        let (root, repository, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = "renamed 雪\n file.txt"
        _ = try await repository.run(["mv", "--", path, renamed])
        let working = try GitPatchTests().change(root, renamed)
        try await repository.stage([renamed])
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let patch = try await repository.patch(paths: [path, renamed], staged: true)
        XCTAssertTrue(patch.files[0].header.contains { $0.hasPrefix("rename from ") })
        XCTAssertTrue(patch.files[0].supportsPartialChanges)
        try await repository.applyPatchSelection(patch, paths: [path, renamed], staged: true, lines: [patch.files[0].hunks[1].header], entireHunks: true)
        let indexed = try await repository.run(["show", ":" + path]).text
        let destination = try await repository.run(["ls-files", "-z", "--", renamed]).stdout
        XCTAssertTrue(indexed.contains("first change")); XCTAssertFalse(indexed.contains("second change")); XCTAssertTrue(destination.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(renamed), encoding: .utf8), working)
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(afterHead, head)
    }

    func testMetadataOnlyAndNonregularModeChangesHaveNoPartialAction() {
        let modeOnly = GitPatch(text: "diff --git a/file b/file\nold mode 100644\nnew mode 100755\n")
        XCTAssertFalse(modeOnly.files[0].supportsPartialChanges)
        let renameOnly = GitPatch(text: "diff --git a/old b/new\nsimilarity index 100%\nrename from old\nrename to new\n")
        XCTAssertFalse(renameOnly.files[0].supportsPartialChanges)
        XCTAssertThrowsError(try renameOnly.selectedPatch(lines: [1], entireHunks: true, reverse: false))
        let symlink = GitPatch(text: "diff --git a/file b/file\nold mode 100644\nnew mode 120000\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+target\n")
        XCTAssertFalse(symlink.files[0].supportsPartialChanges)
    }
}
