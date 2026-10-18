import XCTest
@testable import TurtleGitCore

final class RebaseMessageEditingTests: XCTestCase {
    func testCleanEditIgnoresUntrackedFilesAndCancelledPreparationCreatesNoSelection() async throws {
        let (root, repo, _) = try await RebasePendingActionTests().paused()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try await repo.rebaseState(), head = try await repo.rebaseCommit("HEAD")
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("untracked"))
        let selection = try await repo.beginRebaseEditSelection(expected: state, expectedHead: head.hash)
        XCTAssertNil(selection)
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { _ = try await repo.beginRebaseEditSelection(expected: state, expectedHead: head.hash, cancellation: cancelled); XCTFail("Cancelled preparation accepted") } catch is OperationCancellationFailure {}
        let after = try await repo.rebaseState(), final = try await repo.rebaseCommit("HEAD")
        XCTAssertNil(after.split); XCTAssertEqual(final.hash, head.hash)
        let snapshot = try await repo.rebaseSessionSnapshot()
        XCTAssertEqual(snapshot.messageCommit?.hash, head.hash); XCTAssertEqual(snapshot.messageCommit?.message, head.message)
    }

    func testDirtyEditUsesDurableAmendSelectionPreservingExcludedChangesAndAuthorOptions() async throws {
        let (root, repo, _) = try await RebasePendingActionTests().paused()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = try await repo.rebaseState(), head = try await repo.rebaseCommit("HEAD")
        try Data("selected amendment\n".utf8).write(to: root.appendingPathComponent("first.txt"))
        try Data("excluded amendment\n".utf8).write(to: root.appendingPathComponent("upstream.txt")); try await repo.stage(["upstream.txt"])
        let staged = try await repo.run(["show", ":upstream.txt"]).stdout
        let preparedSelection = try await repo.beginRebaseEditSelection(expected: state, expectedHead: head.hash)
        let selected = try XCTUnwrap(preparedSelection)
        XCTAssertEqual(selected.parts, 0); XCTAssertEqual(selected.conflictRecovery, true); XCTAssertEqual(selected.expectedHead, head.hash); XCTAssertEqual(selected.firstParents, head.parents)
        let reopened = GitRepository(root: root, executable: repo.executable), recovered = try await reopened.rebaseState()
        XCTAssertEqual(recovered.split?.expectedHead, head.hash); XCTAssertTrue(recovered.isEditPause)
        var options = CommitOptions(); options.amend = true; options.amendDiffToLastCommit = true
        options.author = "Approved Author <approved@example.invalid>"; options.authorDate = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await reopened.commitRebaseSplit(message: "Approved message", paths: ["first.txt"], staging: false, options: options, expected: selected)
        let applied = try await reopened.rebaseCommit("HEAD"), actual = try await reopened.rebaseState()
        XCTAssertEqual(applied.subject, "Approved message"); XCTAssertEqual(applied.author, "Approved Author"); XCTAssertEqual(applied.email, "approved@example.invalid")
        XCTAssertEqual(ISO8601DateFormatter().date(from: applied.date)?.timeIntervalSince1970, options.authorDate?.timeIntervalSince1970)
        XCTAssertEqual(applied.parents, head.parents); XCTAssertEqual(actual.split?.parts, 1)
        let stillStaged = try await reopened.run(["show", ":upstream.txt"]).stdout
        let remaining = try await reopened.rebaseSplitHasRemainingChanges()
        XCTAssertEqual(stillStaged, staged); XCTAssertTrue(remaining)
        do { _ = try await reopened.continueRebase(); XCTFail("Excluded changes were silently continued") } catch RebaseFailure.plan {}
        _ = try await reopened.commitRebaseSplit(message: "Approved final message", paths: ["upstream.txt"], staging: false, options: options, expected: try XCTUnwrap(actual.split))
        let completed = try await reopened.continueRebase()
        XCTAssertEqual(completed.exitCode, 0, completed.output); XCTAssertFalse(completed.state.active)
    }

    func testCancelledAmendSelectionReturnsToEditAndMessageIdentityRejectsChangedHead() async throws {
        let (root, repo, _) = try await RebasePendingActionTests().paused()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repo.rebaseSessionSnapshot(), identity = try XCTUnwrap(RebaseMessageIdentity(state: before.state, head: before.head))
        try Data("dirty selection\n".utf8).write(to: root.appendingPathComponent("first.txt"))
        let selected = try await repo.beginRebaseEditSelection(expected: before.state, expectedHead: before.head)
        XCTAssertNotNil(selected)
        let prepared = try await repo.rebaseSessionSnapshot()
        XCTAssertNotEqual(RebaseMessageIdentity(state: prepared.state, head: prepared.head), identity)
        try await repo.cancelUnstartedRebaseSplit()
        let cancelled = try await repo.rebaseSessionSnapshot()
        XCTAssertNil(cancelled.state.split); XCTAssertTrue(cancelled.state.isEditPause); XCTAssertEqual(cancelled.head, before.head)
        XCTAssertEqual(RebaseMessageIdentity(state: cancelled.state, head: cancelled.head), identity)
        _ = try await repo.run(["commit", "--amend", "--only", "-m", "External amendment"])
        let changed = try await repo.rebaseSessionSnapshot()
        XCTAssertNotEqual(RebaseMessageIdentity(state: changed.state, head: changed.head), identity)
        XCTAssertEqual(changed.messageCommit?.subject, "External amendment")
        do { _ = try await repo.beginRebaseEditSelection(expected: before.state, expectedHead: before.head); XCTFail("Stale applied message accepted") } catch RebaseFailure.changed {}
    }
}
