import XCTest
@testable import TurtleGitCore

final class CommitSelectionTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Commit Tests"])
        _ = try await repo.run(["config", "user.email", "commit@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        return (root, repo)
    }
    func write(_ root: URL, _ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    func testCheckedWorkingTreeContentsExcludeAndPreserveUnrelatedStagedChanges() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for file in ["checked.txt", "unchecked.txt"] { try write(root, file, "base\n") }
        try await repo.stage(["checked.txt", "unchecked.txt"]); _ = try await repo.commit(message: "base")
        try write(root, "checked.txt", "staged version\n"); try await repo.stage(["checked.txt"])
        try write(root, "checked.txt", "current working tree\n")
        try write(root, "unchecked.txt", "unchecked staged\n"); try await repo.stage(["unchecked.txt"])
        _ = try await repo.commitSelected(message: "only checked", paths: ["checked.txt"])
        let checked = try await repo.run(["show", "HEAD:checked.txt"]).text
        let unchecked = try await repo.run(["show", "HEAD:unchecked.txt"]).text
        let staged = try await repo.run(["show", ":unchecked.txt"]).text
        XCTAssertEqual(checked, "current working tree\n"); XCTAssertEqual(unchecked, "base\n"); XCTAssertEqual(staged, "unchecked staged\n")
        let status = try await repo.status(); XCTAssertEqual(status.map(\.path), ["unchecked.txt"]); XCTAssertTrue(status[0].staged)
    }
    func testUnbornCheckedCommitPreservesUncheckedAddedFileAndLiteralNames() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let name = "*.txt\n雪"
        try write(root, name, "selected"); try write(root, "other.txt", "other")
        try await repo.stage(["other.txt"])
        _ = try await repo.commitSelected(message: "initial", paths: [name])
        let files = try await repo.run(["ls-tree", "-r", "--name-only", "-z", "HEAD"]).stdout
        XCTAssertEqual(files, Data((name + "\0").utf8))
        let status = try await repo.status(); XCTAssertEqual(status.first?.path, "other.txt"); XCTAssertTrue(status.first!.staged)
    }
    func testStagedRenameAndDeletionAreCommittedTogether() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "old.txt", "rename\n"); try write(root, "deleted.txt", "delete\n")
        try await repo.stage(["old.txt", "deleted.txt"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["mv", "old.txt", "new.txt"])
        _ = try await repo.run(["rm", "deleted.txt"])
        _ = try await repo.commitSelected(message: "rename and deletion", paths: ["new.txt", "deleted.txt"])
        let files = try await repo.run(["ls-tree", "-r", "--name-only", "HEAD"]).text
        XCTAssertEqual(files, "new.txt\n")
        let status = try await repo.status(); XCTAssertTrue(status.isEmpty)
    }
    func testAmendMessageOnlyLeavesStagedFilesAndAppliesAuthorAndSignoff() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "file.txt", "base"); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        try write(root, "file.txt", "staged"); try await repo.stage(["file.txt"])
        var options = CommitOptions(); options.amend = true; options.signOff = true; options.author = "Other Author <other@example.invalid>"
        _ = try await repo.commitSelected(message: "amended", paths: [], options: options)
        let history = try await repo.log(); let entry = try XCTUnwrap(history.first)
        XCTAssertEqual(entry.author, "Other Author"); XCTAssertTrue(entry.message.contains("Signed-off-by: Commit Tests <commit@example.invalid>"))
        let content = try await repo.run(["show", "HEAD:file.txt"]).text; XCTAssertEqual(content, "base")
        let status = try await repo.status(); XCTAssertTrue(status[0].staged)
    }
    func testStagingModeCommitsOnlyIndexAndPreservesLaterWorkingTreeEdits() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "file.txt", "base\n"); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        try write(root, "file.txt", "staged\n"); try await repo.stage(["file.txt"])
        try write(root, "file.txt", "unstaged\n")
        let staged = try await repo.stagingFiles(staged: true), unstaged = try await repo.stagingFiles(staged: false)
        XCTAssertEqual(staged.first?.added, 1); XCTAssertEqual(unstaged.first?.removed, 1)
        _ = try await repo.commitIndex(message: "index only")
        let committed = try await repo.run(["show", "HEAD:file.txt"]).text
        XCTAssertEqual(committed, "staged\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8), "unstaged\n")
        let status = try await repo.status(); XCTAssertFalse(status[0].staged); XCTAssertEqual(status[0].worktree, "M")
    }
    func testRejectedCommitKeepsHeadAndUnrelatedIndex() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "file.txt", "base"); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        try write(root, "other.txt", "other"); try await repo.stage(["other.txt"])
        try write(root, "file.txt", "changed")
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        do { _ = try await repo.commitSelected(message: "rejected", paths: ["file.txt"]); XCTFail("Hook must reject") } catch is GitFailure {}
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout, other = try await repo.run(["show", ":other.txt"]).text
        XCTAssertEqual(after, head); XCTAssertEqual(other, "other")
    }

}
