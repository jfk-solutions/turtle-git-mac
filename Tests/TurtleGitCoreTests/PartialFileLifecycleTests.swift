import XCTest
@testable import TurtleGitCore

final class PartialFileLifecycleTests: XCTestCase {
    func testUntrackedPreviewPartialStageAndNewFileUnstagePreserveWorktree() async throws {
        for executable in [false, true] {
            let (root, repo, _) = try await GitPatchTests().fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let path = "new 雪\n space.txt", url = root.appendingPathComponent(path), content = Data("first\nmiddle\nlast".utf8)
            try content.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            let indexURL = root.appendingPathComponent(".git/index"), before = try Data(contentsOf: indexURL)
            var patch = try await repo.patch(paths: [path], staged: false, includeUntracked: true)
            XCTAssertEqual(patch.files.count, 1); XCTAssertTrue(patch.files[0].supportsPartialChanges)
            XCTAssertEqual(try Data(contentsOf: indexURL), before, "Untracked preview mutated index")
            try await repo.applyPatchSelection(patch, paths: [path], staged: false, lines: [try XCTUnwrap(patch.lines.firstIndex(of: "+middle"))], entireHunks: false)
            var indexed = try await repo.run(["show", ":" + path]).stdout
            XCTAssertEqual(indexed, Data("middle\n".utf8))
            let mode = try await repo.run(["ls-files", "--stage", "--", path]).text
            XCTAssertTrue(mode.hasPrefix(executable ? "100755" : "100644"))
            XCTAssertEqual(try Data(contentsOf: url), content)
            try await repo.stage([path])
            patch = try await repo.patch(paths: [path], staged: true)
            try await repo.applyPatchSelection(patch, paths: [path], staged: true, lines: [try XCTUnwrap(patch.lines.firstIndex(of: "+middle"))], entireHunks: false)
            indexed = try await repo.run(["show", ":" + path]).stdout
            XCTAssertEqual(indexed, Data("first\nlast".utf8))
            patch = try await repo.patch(paths: [path], staged: true)
            try await repo.applyPatchSelection(patch, paths: [path], staged: true, lines: Set(patch.files[0].hunks.map(\.header)), entireHunks: true)
            let remaining = try await repo.run(["ls-files", "-z", "--", path]).stdout
            XCTAssertTrue(remaining.isEmpty); XCTAssertEqual(try Data(contentsOf: url), content)
        }
    }

    func testDeletedFilePartialStageAndPartialRestoreNeverRecreateWorkingFile() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(path), content = Data("first\nmiddle\nlast".utf8)
        try content.write(to: url); try await repo.stage([path]); _ = try await repo.commit(message: "short file")
        try FileManager.default.removeItem(at: url)
        var patch = try await repo.patch(paths: [path], staged: false)
        try await repo.applyPatchSelection(patch, paths: [path], staged: false, lines: [try XCTUnwrap(patch.lines.firstIndex(of: "-middle"))], entireHunks: false)
        var indexed = try await repo.run(["show", ":" + path]).stdout
        XCTAssertEqual(indexed, Data("first\nlast".utf8)); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        patch = try await repo.patch(paths: [path], staged: false)
        try await repo.applyPatchSelection(patch, paths: [path], staged: false, lines: Set(patch.files[0].hunks.map(\.header)), entireHunks: true)
        var tracked = try await repo.run(["ls-files", "-z", "--", path]).stdout
        XCTAssertTrue(tracked.isEmpty)
        patch = try await repo.patch(paths: [path], staged: true)
        try await repo.applyPatchSelection(patch, paths: [path], staged: true, lines: [try XCTUnwrap(patch.lines.firstIndex(of: "-middle"))], entireHunks: false)
        indexed = try await repo.run(["show", ":" + path]).stdout
        XCTAssertEqual(indexed, Data("middle\n".utf8)); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        patch = try await repo.patch(paths: [path], staged: true)
        try await repo.applyPatchSelection(patch, paths: [path], staged: true, lines: Set(patch.files[0].hunks.map(\.header)), entireHunks: true)
        indexed = try await repo.run(["show", ":" + path]).stdout
        XCTAssertEqual(indexed, content)
        tracked = try await repo.run(["ls-files", "-z", "--", path]).stdout
        XCTAssertFalse(tracked.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testIntentToAddHasOnePatchAndUnrelatedStagedContentIsPreserved() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent(path)
        try Data("other staged\n".utf8).write(to: other); try await repo.stage([path])
        let added = "intent.txt"; try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent(added))
        _ = try await repo.run(["add", "-N", "--", added])
        let patch = try await repo.patch(paths: [added], staged: false, includeUntracked: true)
        XCTAssertEqual(patch.files.count, 1)
        try await repo.applyPatchSelection(patch, paths: [added], staged: false, lines: [try XCTUnwrap(patch.lines.firstIndex(of: "+two"))], entireHunks: false)
        let indexed = try await repo.run(["show", ":" + added]).stdout
        let retained = try await repo.run(["show", ":" + path]).stdout
        XCTAssertEqual(indexed, Data("two\n".utf8)); XCTAssertEqual(retained, Data("other staged\n".utf8))
    }

    func testStaleUntrackedSnapshotAndUnsupportedMetadataRefuseMutation() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "new.txt", url = root.appendingPathComponent(path)
        try Data("old\n".utf8).write(to: url)
        let patch = try await repo.patch(paths: [path], staged: false, includeUntracked: true)
        try Data("changed\n".utf8).write(to: url)
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        do { try await repo.applyPatchSelection(patch, paths: [path], staged: false, lines: Set(patch.files[0].hunks.map(\.header)), entireHunks: true); XCTFail("Stale untracked snapshot accepted") } catch PatchFailure.changed {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        for header in ["new file mode 120000", "index abc..def 120000", "old mode 100644\nnew mode 100755", "rename from x\nrename to y", "GIT binary patch"] {
            let document = GitPatch(text: "diff --git a/x b/x\n" + header + "\n--- /dev/null\n+++ b/x\n@@ -0,0 +1 @@\n+line\n")
            XCTAssertFalse(document.files[0].supportsPartialChanges)
        }
    }
}
