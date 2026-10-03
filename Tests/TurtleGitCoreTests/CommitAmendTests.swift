import XCTest
@testable import TurtleGitCore

final class CommitAmendTests: XCTestCase {
    func testHookFailureRetainsHeadAndUncheckedIndexContents() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["selected.txt", "unchecked.txt"] { try helper.write(root, path, "base\n") }
        try await repo.stage(["selected.txt", "unchecked.txt"]); _ = try await repo.commit(message: "base")
        try helper.write(root, "selected.txt", "last\n"); try await repo.stage(["selected.txt"]); _ = try await repo.commit(message: "last")
        try helper.write(root, "unchecked.txt", "index\n"); try await repo.stage(["unchecked.txt"]); try helper.write(root, "unchecked.txt", "worktree\n")
        let original = try await repo.run(["rev-parse", "HEAD"]).text
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        var options = CommitOptions(); options.amend = true; options.amendDiffToLastCommit = false
        do { _ = try await repo.commitSelected(message: "rejected", paths: ["selected.txt"], options: options); XCTFail("Hook must reject") } catch {}
        let after = try await repo.run(["rev-parse", "HEAD"]).text
        let unchecked = try await repo.run(["show", ":unchecked.txt"]).text
        XCTAssertEqual(original, after); XCTAssertEqual(unchecked, "index\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("unchecked.txt")), "worktree\n")
    }

    func testParentAmendOfMergeKeepsBothParents() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "base.txt", "base\n"); try await repo.stage(["base.txt"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["checkout", "-b", "side"])
        try helper.write(root, "side.txt", "side\n"); try await repo.stage(["side.txt"]); _ = try await repo.commit(message: "side")
        _ = try await repo.run(["checkout", "main"])
        try helper.write(root, "main.txt", "main\n"); try await repo.stage(["main.txt"]); _ = try await repo.commit(message: "main")
        _ = try await repo.run(["merge", "--no-edit", "side"])
        let parents = try await repo.run(["show", "-s", "--format=%P", "HEAD"]).text
        var options = CommitOptions(); options.amend = true; options.amendDiffToLastCommit = false
        _ = try await repo.commitSelected(message: "amended merge", paths: ["side.txt"], options: options)
        let amendedParents = try await repo.run(["show", "-s", "--format=%P", "HEAD"]).text
        XCTAssertEqual(parents, amendedParents); XCTAssertEqual(parents.split(separator: " ").count, 2)
    }
    func testParentComparisonIncludesLastCommitAndOmitsUncheckedChangeFromAmend() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["keep.txt", "omit.txt", "mixed.txt"] { try helper.write(root, path, "base\n") }
        try await repo.stage(["keep.txt", "omit.txt", "mixed.txt"]); _ = try await repo.commit(message: "base")
        let parent = try await repo.run(["rev-parse", "HEAD"]).text
        try helper.write(root, "keep.txt", "last keep\n"); try helper.write(root, "omit.txt", "last omit\n")
        try await repo.stage(["keep.txt", "omit.txt"]); _ = try await repo.commit(message: "last")
        try helper.write(root, "mixed.txt", "index\n"); try await repo.stage(["mixed.txt"]); try helper.write(root, "mixed.txt", "worktree\n")
        let beforeWorking = try await repo.diff(), beforeMixed = try await repo.run(["show", ":mixed.txt"]).text
        let normal = try await repo.commitDialogStatus(amendToParent: false), amend = try await repo.commitDialogStatus(amendToParent: true)
        XCTAssertEqual(Set(normal.map(\.path)), ["mixed.txt"])
        XCTAssertEqual(Set(amend.map(\.path)), ["keep.txt", "omit.txt", "mixed.txt"])
        var options = CommitOptions(); options.amend = true; options.amendDiffToLastCommit = false
        _ = try await repo.commitSelected(message: "selective amend", paths: ["keep.txt"], options: options)
        let kept = try await repo.run(["show", "HEAD:keep.txt"]).text, omitted = try await repo.run(["show", "HEAD:omit.txt"]).text
        let afterParent = try await repo.run(["rev-parse", "HEAD^"]).text
        let afterMixed = try await repo.run(["show", ":mixed.txt"]).text, afterWorking = try await repo.diff()
        XCTAssertEqual(kept, "last keep\n"); XCTAssertEqual(omitted, "base\n"); XCTAssertEqual(parent, afterParent)
        XCTAssertEqual(beforeMixed, afterMixed); XCTAssertEqual(beforeWorking, afterWorking)
        let staged = try await repo.diff(staged: true); XCTAssertTrue(staged.contains("last omit")); XCTAssertTrue(staged.contains("index"))
    }

    func testRootAndRenamedAmendUseTheirCorrectBaseline() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["selected.txt", "other.txt"] { try helper.write(root, path, "root\n") }
        try await repo.stage(["selected.txt", "other.txt"]); _ = try await repo.commit(message: "root")
        var options = CommitOptions(); options.amend = true; options.amendDiffToLastCommit = false
        let rootStatus = try await repo.commitDialogStatus(amendToParent: true)
        XCTAssertEqual(Set(rootStatus.map(\.path)), ["selected.txt", "other.txt"])
        XCTAssertTrue(rootStatus.allSatisfy { $0.state == .added })
        _ = try await repo.commitSelected(message: "selected root", paths: ["selected.txt"], options: options)
        let rootFiles = try await repo.run(["ls-tree", "--name-only", "HEAD"]).text
        XCTAssertEqual(rootFiles, "selected.txt\n")
        try await repo.unstage(["other.txt"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("other.txt"))
        _ = try await repo.run(["mv", "selected.txt", "renamed\t雪.txt"]); _ = try await repo.commit(message: "rename")
        let renamed = try await repo.commitDialogStatus(amendToParent: true)
        XCTAssertTrue(renamed.contains { $0.path == "renamed\t雪.txt" && $0.originalPath == "selected.txt" })
        _ = try await repo.commitSelected(message: "retain rename", paths: ["renamed\t雪.txt"], options: options)
        let names = try await repo.run(["ls-tree", "--name-only", "-z", "HEAD"]).stdout
        XCTAssertEqual(String(decoding: names, as: UTF8.self), "renamed\t雪.txt\0")
    }

    func testParentBasedUnstageAndPartialPatchKeepWorktree() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "file.txt", "base\n"); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        try helper.write(root, "file.txt", "last\n"); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "last")
        let base = try await repo.commitComparisonBase(amendToParent: true)
        let patch = try await repo.patch(paths: ["file.txt"], staged: true, base: base)
        let lines = Set(patch.lines.indices.filter { patch.changedLine($0) })
        try await repo.applyPatchSelection(patch, paths: ["file.txt"], staged: true, lines: lines, entireHunks: true, base: base)
        let contents = try await repo.run(["show", ":file.txt"]).text
        XCTAssertEqual(contents, "base\n"); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "last\n")
        try await repo.stage(["file.txt"]); try await repo.unstageCommitPaths(["file.txt"], amendToParent: true)
        let unstaged = try await repo.run(["show", ":file.txt"]).text
        XCTAssertEqual(unstaged, "base\n")
        var options = CommitOptions(); options.amend = true; options.amendDiffToLastCommit = true; options.messageOnly = true
        _ = try await repo.commitIndex(message: "index amend", options: options)
        let committed = try await repo.run(["show", "HEAD:file.txt"]).text
        XCTAssertEqual(committed, "base\n"); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "last\n")
    }
}
