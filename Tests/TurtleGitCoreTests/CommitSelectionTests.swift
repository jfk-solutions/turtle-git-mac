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
    func testMessageOnlyCommitsAndDatesPreserveUncheckedIndex() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "file.txt", "base\n"); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        let beforeTree = try await repo.run(["rev-parse", "HEAD^{tree}"]).text
        try write(root, "file.txt", "staged\n"); try await repo.stage(["file.txt"])
        try write(root, "file.txt", "worktree\n")
        let index = try await repo.diff(staged: true), working = try await repo.diff()
        var options = CommitOptions(); options.messageOnly = true; options.authorDate = Date(timeIntervalSince1970: 1234567890)
        _ = try await repo.commitSelected(message: "empty with date", paths: ["file.txt"], options: options)
        let tree = try await repo.run(["rev-parse", "HEAD^{tree}"]).text
        let date = try await repo.run(["show", "-s", "--format=%at", "HEAD"]).text
        let afterIndex = try await repo.diff(staged: true), afterWorking = try await repo.diff()
        XCTAssertEqual(beforeTree, tree); XCTAssertEqual(date, "1234567890\n"); XCTAssertEqual(index, afterIndex); XCTAssertEqual(working, afterWorking)
        options.amend = true; options.resetAuthorDate = true
        _ = try await repo.commitSelected(message: "reset author date", paths: [], options: options)
        let reset = try await repo.run(["show", "-s", "--format=%at", "HEAD"]).text
        XCTAssertGreaterThan(Int(reset.trimmingCharacters(in: .newlines)) ?? 0, 1234567890)
        options.amend = false; options.resetAuthorDate = false
        _ = try await repo.commitIndex(message: "staging message only includes index", options: options)
        let contents = try await repo.run(["show", "HEAD:file.txt"]).text
        let staged = try await repo.diff(staged: true), remaining = try await repo.diff()
        XCTAssertEqual(contents, "staged\n"); XCTAssertEqual(staged, ""); XCTAssertEqual(working, remaining)
    }
    func testNewBranchCommitAndSubmoduleIndexMetadata() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "file.txt", "base\n"); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        let original = try await repo.run(["rev-parse", "HEAD"]).text
        try write(root, "file.txt", "topic\n")
        var options = CommitOptions(); options.newBranch = "topic/雪"
        _ = try await repo.commitSelected(message: "on new branch", paths: ["file.txt"], options: options)
        let branch = try await repo.branch(), main = try await repo.run(["rev-parse", "main"]).text
        XCTAssertEqual(branch, "topic/雪"); XCTAssertEqual(main, original)
        let hash = original.trimmingCharacters(in: .newlines), path = "module\t雪"
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + hash + "," + path])
        let submodules = try await repo.submodulePaths(); XCTAssertEqual(submodules, [path])
        let before = try await repo.diff(staged: true)
        options.newBranch = "invalid:branch"
        do { _ = try await repo.commitIndex(message: "invalid", options: options); XCTFail("Invalid branch") } catch {}
        let after = try await repo.diff(staged: true); XCTAssertEqual(before, after)
    }
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

    func operationFixture(cherryPick: Bool = false, revert: Bool = false) async throws -> (URL, GitRepository, String, String) {
        let (root, repo) = try await fixture()
        try write(root, "checked.txt", "base\n"); try write(root, "unchecked 雪.txt", "base unchecked\n")
        try await repo.stage(["checked.txt", "unchecked 雪.txt"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["checkout", "-b", "incoming"])
        try write(root, "checked.txt", "incoming\n"); try write(root, "unchecked 雪.txt", "incoming unchecked\n")
        try await repo.stage(["checked.txt", "unchecked 雪.txt"])
        _ = try await repo.run(["commit", "-m", "incoming", "--author=Incoming Author <incoming@example.invalid>", "--date=2009-02-13T23:31:30Z"])
        let incoming = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "main"])
        try write(root, "checked.txt", "main\n"); try await repo.stage(["checked.txt"]); _ = try await repo.commit(message: "main")
        let previous = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        do { _ = try await repo.run(revert ? ["revert", "--no-edit", incoming] : cherryPick ? ["cherry-pick", incoming] : ["merge", "--no-edit", "incoming"]); XCTFail("Expected conflict") } catch is GitFailure {}
        try write(root, "checked.txt", "resolved staged\n"); try await repo.stage(["checked.txt"])
        try write(root, "checked.txt", "resolved whole file\n")
        return (root, repo, previous, incoming)
    }
    func testCheckedMergeRetainsParentsUncheckedIndexAndWholeWorkingFiles() async throws {
        let (root, repo, previous, incoming) = try await operationFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let operation = try await repo.commitOperation(); XCTAssertEqual(operation, .merge)
        let unchecked = try await repo.run(["show", ":unchecked 雪.txt"]).stdout
        let working = try Data(contentsOf: root.appendingPathComponent("checked.txt"))
        _ = try await repo.commitSelected(message: "selected merge", paths: ["checked.txt"])
        let parents = try await repo.run(["show", "-s", "--format=%P", "HEAD"]).text
        XCTAssertEqual(parents, previous + " " + incoming + "\n")
        let selectedTree = try await repo.run(["show", "HEAD:checked.txt"]).stdout
        let uncheckedTree = try await repo.run(["show", "HEAD:unchecked 雪.txt"]).text
        let retained = try await repo.run(["show", ":unchecked 雪.txt"]).stdout
        XCTAssertEqual(selectedTree, working); XCTAssertEqual(uncheckedTree, "base unchecked\n"); XCTAssertEqual(retained, unchecked)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("checked.txt")), working)
        let after = try await repo.commitOperation(); XCTAssertNil(after)
    }
    func testCheckedCherryPickRetainsIncomingAuthorAndUncheckedChanges() async throws {
        let (root, repo, previous, incoming) = try await operationFixture(cherryPick: true); defer { try? FileManager.default.removeItem(at: root) }
        let operation = try await repo.commitOperation(); XCTAssertEqual(operation, .cherryPick)
        let author = try await repo.run(["show", "-s", "--format=%an <%ae> %at", incoming]).text
        let unchecked = try await repo.run(["show", ":unchecked 雪.txt"]).stdout
        try write(root, "unchecked 雪.txt", "later unchecked working\n")
        _ = try await repo.commitSelected(message: "selected pick", paths: ["checked.txt"])
        let parents = try await repo.run(["show", "-s", "--format=%P", "HEAD"]).text
        let pickedAuthor = try await repo.run(["show", "-s", "--format=%an <%ae> %at", "HEAD"]).text
        let retained = try await repo.run(["show", ":unchecked 雪.txt"]).stdout
        let tree = try await repo.run(["show", "HEAD:unchecked 雪.txt"]).text
        XCTAssertEqual(parents, previous + "\n"); XCTAssertEqual(pickedAuthor, author)
        XCTAssertEqual(retained, unchecked); XCTAssertEqual(tree, "base unchecked\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("unchecked 雪.txt")), Data("later unchecked working\n".utf8))
        let after = try await repo.commitOperation(); XCTAssertNil(after)
    }
    func testCheckedRevertKeepsSingleParentAndClearsRevertState() async throws {
        let (root, repo, previous, _) = try await operationFixture(revert: true); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repo.commitOperation(); XCTAssertEqual(before, .revert)
        let working = try Data(contentsOf: root.appendingPathComponent("checked.txt"))
        _ = try await repo.commitSelected(message: "selected revert", paths: ["checked.txt"])
        let parents = try await repo.run(["show", "-s", "--format=%P", "HEAD"]).text
        let contents = try await repo.run(["show", "HEAD:checked.txt"]).stdout
        let author = try await repo.run(["show", "-s", "--format=%an <%ae>", "HEAD"]).text
        XCTAssertEqual(parents, previous + "\n"); XCTAssertEqual(contents, working)
        XCTAssertEqual(author, "Commit Tests <commit@example.invalid>\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("checked.txt")), working)
        let after = try await repo.commitOperation(); XCTAssertNil(after)
    }
    func testMergeGuardsAndHookFailureRetainOperationThenEmptySelectionCanFinish() async throws {
        let (root, repo, previous, incoming) = try await operationFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        var options = CommitOptions(); options.newBranch = "must-not-exist"
        do { _ = try await repo.commitSelected(message: "invalid", paths: ["checked.txt"], options: options); XCTFail("Branch creation allowed") } catch is GitFailure {}
        let afterGuard = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(index, afterGuard)
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\necho reject-merge >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        do { _ = try await repo.commitSelected(message: "rejected", paths: ["checked.txt"]); XCTFail("Hook rejection ignored") } catch let error as GitFailure { XCTAssertTrue(error.message.contains("reject-merge")) }
        let retainedOperation = try await repo.commitOperation(); XCTAssertEqual(retainedOperation, .merge)
        let retainedHead = try await repo.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(retainedHead, previous + "\n")
        try FileManager.default.removeItem(at: hook)
        let retainedIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        _ = try await repo.commitSelected(message: "merge without selected changes", paths: [])
        let parents = try await repo.run(["show", "-s", "--format=%P", "HEAD"]).text
        let afterIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(parents, previous + " " + incoming + "\n"); XCTAssertEqual(retainedIndex, afterIndex)
        let after = try await repo.commitOperation(); XCTAssertNil(after)
    }

}
