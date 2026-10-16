import XCTest
@testable import TurtleGitCore

final class CommitPatchTests: XCTestCase {
    func testStagingStatesIgnoreAmbiguousRenamePairing() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["remove", "rename", "other"] { try helper.write(root, path, "identical content\n") }
        try await repo.stage(["remove", "rename", "other"]); _ = try await repo.commit(message: "base")
        try FileManager.default.removeItem(at: root.appendingPathComponent("remove")); _ = try await repo.run(["mv", "rename", "renamed"])
        let rows = try await repo.status(), deletion = try XCTUnwrap(rows.first { $0.path == "remove" })
        try await repo.setCommitFilesStaged([deletion], staged: true)
        let states = try await repo.commitStagingStates(for: rows)
        XCTAssertEqual(states["remove"], .staged); XCTAssertEqual(states["renamed"], .staged)
        try await repo.setCommitFilesStaged(rows, staged: false)
        let after = try await repo.commitStagingStates(for: rows), staged = try await repo.run(["diff", "--cached", "--name-only"]).stdout
        XCTAssertTrue(after.values.allSatisfy { $0 == .unstaged }); XCTAssertTrue(staged.isEmpty)
    }
    func testWholeFileCopyDoesNotStageItsModifiedSource() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "source", "base\n"); try await repo.stage(["source"]); _ = try await repo.commit(message: "base")
        try helper.write(root, "copy", "base\n"); try helper.write(root, "source", "unrelated working\n")
        let row = StatusEntry(path: "copy", originalPath: "source", index: "C", worktree: " ")
        try await repo.setCommitFilesStaged([row], staged: true)
        let names = try await repo.run(["diff", "--cached", "--name-only"]).stdout
        XCTAssertEqual(names, Data("copy\n".utf8))
        let states = try await repo.commitStagingStates(for: [row]); XCTAssertEqual(states["copy"], .staged)
        let source = try await repo.run(["show", ":source"]).stdout; XCTAssertEqual(source, Data("base\n".utf8))
    }
    func testWholeFileStagingRetainsBothRenameSidesAndUnrelatedIndex() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "old", "base\n"); try helper.write(root, "other", "other\n")
        try await repo.stage(["old", "other"]); _ = try await repo.commit(message: "base")
        try helper.write(root, "other", "unrelated staged\n"); try await repo.stage(["other"])
        _ = try await repo.run(["mv", "old", "new"])
        let status = try await repo.status()
        let row = try XCTUnwrap(status.first { $0.path == "new" })
        XCTAssertEqual(row.index, "R")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        try await repo.setCommitFilesStaged([row], staged: false)
        let names = try await repo.run(["diff", "--cached", "--name-only"]).stdout
        XCTAssertEqual(names, Data("other\n".utf8))
        try await repo.setCommitFilesStaged([row], staged: true)
        let after = try await repo.status()
        XCTAssertEqual(after.first { $0.path == "new" }?.index, "R")
        let other = try await repo.run(["show", ":other"]).stdout, afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(other, Data("unrelated staged\n".utf8)); XCTAssertEqual(afterHead, head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("new")), Data("base\n".utf8))
    }
    func testUnbornMixedWholeFileUnstageKeepsWorkingBytes() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "new", "staged\n"); try helper.write(root, "other", "unrelated\n")
        try await repo.stage(["new", "other"]); try helper.write(root, "new", "working\n")
        let status = try await repo.status()
        let row = try XCTUnwrap(status.first { $0.path == "new" })
        let mixed = try await repo.commitStagingStates(for: [row]); XCTAssertEqual(mixed["new"], .partial)
        try await repo.setCommitFilesStaged([row], staged: false)
        let off = try await repo.commitStagingStates(for: [row]); XCTAssertEqual(off["new"], .unstaged)
        let names = try await repo.run(["ls-files"]).stdout, other = try await repo.run(["show", ":other"]).stdout
        XCTAssertEqual(names, Data("other\n".utf8)); XCTAssertEqual(other, Data("unrelated\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("new")), Data("working\n".utf8))
        let token = OperationCancellation(); token.cancel()
        do { try await repo.setCommitFilesStaged([row], staged: true, cancellation: token); XCTFail("Cancelled checkbox staged bytes") } catch is OperationCancellationFailure {}
        let after = try await repo.run(["ls-files"]).stdout; XCTAssertEqual(after, names)
    }
    func testCancelledPreferenceSavePreservesConfigurationAndIndex() async throws {
        let helper=CommitSelectionTests(),(root,repo)=try await helper.fixture();defer{try? FileManager.default.removeItem(at:root)}
        try helper.write(root,"file","base\n");try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        try await repo.saveCommitPreferences(staging:false,showPatch:false)
        let configuration=try Data(contentsOf:root.appendingPathComponent(".git/config")),index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.saveCommitPreferences(staging:true,showPatch:true,cancellation:token);XCTFail("Cancelled preferences written")} catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/config")),configuration);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head)
    }
    func testPreferenceReadSeparatesWarningsFromBooleanOutput() async throws {
        let helper=CommitSelectionTests(),(root,repo)=try await helper.fixture();defer{try? FileManager.default.removeItem(at:root)}
        try await repo.saveCommitPreferences(staging:true,showPatch:true)
        let executable=root.appendingPathComponent("warning-git"),quoted="'"+repo.executable.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        try Data(("#!/bin/sh\nprintf 'warning: preference diagnostic\\n' >&2\nexec "+quoted+" \"$@\"\n").utf8).write(to:executable)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        let settings=try await GitRepository(root:root,executable:executable).commitPreferences()
        XCTAssertTrue(settings.staging);XCTAssertTrue(settings.showPatch)
    }
    func testWorkingTreePatchIncludesStagedAndUnstagedChangesWithoutMutation() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "file\t雪.txt"
        try helper.write(root, path, "base\nother\n"); try await repo.stage([path]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        try helper.write(root, path, "staged\nother\n"); try await repo.stage([path]); try helper.write(root, path, "staged\nworking\n")
        let index = try await repo.diff(staged: true), working = try await repo.diff()
        let document = try await repo.workingTreePatch(paths: [path])
        XCTAssertTrue(document.text.contains("+staged")); XCTAssertTrue(document.text.contains("+working")); XCTAssertTrue(document.text.contains("-base"))
        let partial = try await repo.patch(paths: [path], staged: false)
        XCTAssertFalse(partial.text.contains("+staged")); XCTAssertTrue(partial.text.contains("+working"))
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text
        let afterIndex = try await repo.diff(staged: true), afterWorking = try await repo.diff()
        XCTAssertEqual(head, afterHead); XCTAssertEqual(index, afterIndex); XCTAssertEqual(working, afterWorking)
    }
    func testComparisonPatchUsesParentAndIncludesBothSidesOfRename() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "old.txt", "base\n"); try await repo.stage(["old.txt"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["mv", "old.txt", "new.txt"]); _ = try await repo.commit(message: "rename")
        let base = try await repo.commitComparisonBase(amendToParent: true)
        let ordinary = try await repo.workingTreePatch(paths: ["old.txt", "new.txt"])
        let previous = try await repo.workingTreePatch(paths: ["old.txt", "new.txt"], base: base)
        XCTAssertEqual(ordinary.text, ""); XCTAssertTrue(previous.text.contains("rename from old.txt")); XCTAssertTrue(previous.text.contains("rename to new.txt"))
    }
    func testUnbornComparisonAndRepositoryPreferences() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "initial.txt", "initial\n"); try await repo.stage(["initial.txt"])
        let patch = try await repo.workingTreePatch(paths: ["initial.txt"])
        XCTAssertTrue(patch.text.contains("+initial"))
        let index = try await repo.diff(staged: true)
        try await repo.saveCommitPreferences(staging: true, showPatch: true)
        var settings = try await repo.commitPreferences(); XCTAssertTrue(settings.staging); XCTAssertTrue(settings.showPatch)
        try await repo.saveCommitPreferences(showPatch: false)
        settings = try await repo.commitPreferences(); XCTAssertTrue(settings.staging); XCTAssertFalse(settings.showPatch)
        let reopened = GitRepository(root: root), restored = try await reopened.commitPreferences()
        XCTAssertTrue(restored.staging); XCTAssertFalse(restored.showPatch)
        let after = try await repo.diff(staged: true); XCTAssertEqual(index, after)
    }
}
