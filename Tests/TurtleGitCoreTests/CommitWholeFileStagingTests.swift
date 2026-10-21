// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class CommitWholeFileStagingTests: XCTestCase {
    func testRetainedMultipleRenameRowsRemainIdempotentWithoutAdoptingAnotherDeletion() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = ["old 雪\n[*]", "old-second"], new = ["new 雪\n[*]", "new-second"]
        for path in old + ["a-other-deletion", "unrelated"] { try helper.write(root, path, "identical\n") }
        try await repo.stage(old + ["a-other-deletion", "unrelated"])
        _ = try await repo.commit(message: "base")
        for index in old.indices { _ = try await repo.run(["mv", old[index], new[index]]) }
        let status = try await repo.status()
        let retained = try new.map { path in try XCTUnwrap(status.first { $0.path == path && $0.index == "R" }) }
        XCTAssertEqual(GitPathSet(retained.compactMap(\.originalPath)), GitPathSet(old))
        // Identical blobs permit Git to re-pair a later deletion. That deletion
        // and unrelated staged content never become part of the retained rows.
        try FileManager.default.removeItem(at: root.appendingPathComponent("a-other-deletion"))
        try helper.write(root, "unrelated", "unrelated staged\n")
        try await repo.stage(["a-other-deletion", "unrelated"])
        let unrelated = try await repo.run(["ls-files", "--stage", "-z", "--", "a-other-deletion", "unrelated"]).stdout
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        for _ in 0..<2 {
            try await repo.setCommitFilesStaged(retained, staged: false)
            try await repo.setCommitFilesStaged(retained, staged: false)
            let restored = try await repo.run(["ls-files", "-z", "--"] + old + new).stdout
            XCTAssertEqual(GitPathSet(restored.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }), GitPathSet(old))
            try await repo.setCommitFilesStaged(retained, staged: true)
            try await repo.setCommitFilesStaged(retained, staged: true)
            let renamed = try await repo.run(["ls-files", "-z", "--"] + old + new).stdout
            XCTAssertEqual(GitPathSet(renamed.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }), GitPathSet(new))
        }
        let after = try await repo.run(["ls-files", "--stage", "-z", "--", "a-other-deletion", "unrelated"]).stdout
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(after, unrelated); XCTAssertEqual(afterHead, head)
        for path in new { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("identical\n".utf8)) }
    }

    func testCopyDestinationDoesNotInspectOrMutateItsRetainedSource() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "source", "base\n")
        try await repo.stage(["source"]); _ = try await repo.commit(message: "base")
        try helper.write(root, "source", "unrelated staged\n"); try await repo.stage(["source"])
        try helper.write(root, "source", "unrelated working\n")
        let path = "copy 雪\n[*]"
        try helper.write(root, path, "base\n")
        // Copy metadata does not authorize touching or even resolving a source.
        // An out-of-scope obsolete source must not reject a valid destination.
        let copy = StatusEntry(path: path, originalPath: "../obsolete-source", index: "C", worktree: " ")
        let source = try await repo.run(["ls-files", "--stage", "-z", "--", "source"]).stdout
        for _ in 0..<2 {
            try await repo.setCommitFilesStaged([copy], staged: true)
            let blob = try await repo.run(["show", ":" + path]).stdout
            XCTAssertEqual(blob, Data("base\n".utf8))
            try await repo.setCommitFilesStaged([copy], staged: false)
            let absent = try await repo.run(["ls-files", "-z", "--", path]).stdout
            XCTAssertTrue(absent.isEmpty)
        }
        let after = try await repo.run(["ls-files", "--stage", "-z", "--", "source"]).stdout
        XCTAssertEqual(after, source)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("source")), Data("unrelated working\n".utf8))
    }

    func testRetainedRenameUsesParentBaselineAndRootAmendUsesEmptyTree() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "old", "base\n"); try helper.write(root, "other", "other\n")
        try await repo.stage(["old", "other"]); _ = try await repo.commit(message: "root")
        let initial = try await repo.commitDialogStatus(amendToParent: true)
        let rootRow = try XCTUnwrap(initial.first { $0.path == "old" })
        try await repo.setCommitFilesStaged([rootRow], staged: false, amendToParent: true)
        let rootOff = try await repo.run(["ls-files", "-z", "--", "old"]).stdout
        XCTAssertTrue(rootOff.isEmpty)
        try await repo.setCommitFilesStaged([rootRow], staged: true, amendToParent: true)
        _ = try await repo.run(["mv", "old", "new"]); _ = try await repo.commit(message: "rename")
        try helper.write(root, "other", "unrelated staged\n"); try await repo.stage(["other"])
        let rows = try await repo.commitDialogStatus(amendToParent: true)
        let rename = try XCTUnwrap(rows.first { $0.path == "new" && $0.index == "R" })
        let other = try await repo.run(["ls-files", "--stage", "-z", "--", "other"]).stdout
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        for _ in 0..<2 {
            try await repo.setCommitFilesStaged([rename], staged: false, amendToParent: true)
            let parentNames = try await repo.run(["ls-files", "-z", "--", "old", "new"]).stdout
            XCTAssertEqual(parentNames, Data("old\0".utf8))
            try await repo.setCommitFilesStaged([rename], staged: true, amendToParent: true)
            let currentNames = try await repo.run(["ls-files", "-z", "--", "old", "new"]).stdout
            XCTAssertEqual(currentNames, Data("new\0".utf8))
        }
        let afterOther = try await repo.run(["ls-files", "--stage", "-z", "--", "other"]).stdout
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(afterOther, other); XCTAssertEqual(afterHead, head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("new")), Data("base\n".utf8))
    }

    func testUnbornRetainedAdditionAndAllPathValidationPrecedeMutation() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "chosen", "chosen\n"); try helper.write(root, "other", "other\n")
        try await repo.stage(["chosen", "other"])
        let row = StatusEntry(path: "chosen", originalPath: nil, index: "A", worktree: " ")
        try await repo.setCommitFilesStaged([row], staged: false)
        try await repo.setCommitFilesStaged([row], staged: false)
        try await repo.setCommitFilesStaged([row], staged: true, amendToParent: true)
        let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let invalid = StatusEntry(path: "chosen", originalPath: "../outside", index: "R", worktree: " ")
        for staged in [false, true] {
            do { try await repo.setCommitFilesStaged([row, invalid], staged: staged); XCTFail("Invalid retained rename source accepted") } catch WorkingFileRestoreFailure.location {}
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
            let badDestination = StatusEntry(path: ".git/config", originalPath: nil, index: "M", worktree: " ")
            do { try await repo.setCommitFilesStaged([row, badDestination], staged: staged); XCTFail("Invalid later destination accepted") } catch WorkingFileRestoreFailure.location {}
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        }
        let token = OperationCancellation(); token.cancel()
        do { try await repo.setCommitFilesStaged([row], staged: false, cancellation: token); XCTFail("Cancelled action mutated index") } catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("chosen")), Data("chosen\n".utf8))
    }

    func testFreshConflictsAtBothCapturedRenameSidesAndAlreadyResolvedRows() async throws {
        let helper = CommitConflictSelectionTests(), (root, repo, head, _) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Captured UI provenance predates the current merge. Both authorized
        // sides must use live conflict policy; the third conflict stays intact.
        let retained = StatusEntry(path: helper.chosen, originalPath: helper.unchecked, index: "R", worktree: " ")
        let third = try await repo.run(["ls-files", "--unmerged", "-z", "--", helper.missing]).stdout
        try await repo.setCommitFilesStaged([retained], staged: false)
        for path in [helper.chosen, helper.unchecked] {
            let unresolved = try await repo.run(["ls-files", "--unmerged", "-z", "--", path]).stdout
            let restored = try await repo.run(["show", ":" + path]).stdout
            XCTAssertTrue(unresolved.isEmpty); XCTAssertEqual(restored, Data("main\n".utf8))
            try Data("WORK manual\n".utf8).write(to: root.appendingPathComponent(path))
        }
        try await repo.setCommitFilesStaged([retained], staged: true)
        // A stale conflicted flag cannot make the now-resolved path a no-op.
        let stale = StatusEntry(path: helper.chosen, originalPath: nil, index: "U", worktree: "U")
        try await repo.setCommitFilesStaged([stale], staged: false)
        let off = try await repo.run(["show", ":" + helper.chosen]).stdout
        XCTAssertEqual(off, Data("main\n".utf8))
        try await repo.setCommitFilesStaged([stale], staged: true)
        for path in [helper.chosen, helper.unchecked] {
            let blob = try await repo.run(["show", ":" + path]).stdout
            XCTAssertEqual(blob, Data("CLEAN manual\n".utf8))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("WORK manual\n".utf8))
        }
        let afterThird = try await repo.run(["ls-files", "--unmerged", "-z", "--", helper.missing]).stdout
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(afterThird, third); XCTAssertEqual(afterHead, head)
    }
}
