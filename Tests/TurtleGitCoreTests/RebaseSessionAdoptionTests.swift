// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

/// These sessions are created by Git itself, never by startRebase or the native
/// sequence editor. Adoption must not replay completed work or replace a draft.
final class RebaseSessionAdoptionTests: XCTestCase {
    private var editor: URL { RebaseTests().editor }
    private func externalPause(structural: Bool = false, updateRefs: Bool = false, extraCommits: Int = 0) async throws -> (URL, GitRepository) {
        let (root, repo, _) = try await RebaseTests().fixture()
        do {
            if structural {
                _ = try await repo.run(["switch", "-c", "side", "main"])
                try Data("side\n".utf8).write(to: root.appendingPathComponent("side.txt"))
                try await repo.stage(["side.txt"]); _ = try await repo.commit(message: "side")
                _ = try await repo.run(["switch", "topic"])
                _ = try await repo.run(["merge", "--no-ff", "--no-edit", "side"])
            }
            for number in 0..<extraCommits {
                let path = "external-extra-" + String(number) + ".txt"
                try Data((path + "\n").utf8).write(to: root.appendingPathComponent(path))
                try await repo.stage([path]); _ = try await repo.commit(message: "external extra " + String(number))
            }
            if updateRefs { _ = try await repo.run(["branch", "external-future", "topic"]) }
            let sequence = root.appendingPathComponent("external-sequence-editor")
            let script = """
            #!/bin/sh
            /usr/bin/awk 'BEGIN { changed=0 } !changed && $1 == "pick" { sub(/^pick /,"edit "); changed=1 } { print }' "$1" > "$1.external"
            /bin/mv "$1.external" "$1"
            """
            try Data(script.utf8).write(to: sequence)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sequence.path)
            var args = ["-c", "rebase.abbreviateCommands=false", "-c", "rebase.updateRefs=" + (updateRefs ? "true" : "false"), "rebase", "-i"]
            if structural { args.append("--rebase-merges") }
            args += ["upstream", "topic"]
            _ = try await repo.run(args, environmentOverrides: ["GIT_SEQUENCE_EDITOR": "'" + sequence.path.replacingOccurrences(of: "'", with: "'\\''") + "'", "GIT_EDITOR": "/usr/bin/true"])
            let directory = root.appendingPathComponent(".git/rebase-merge")
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("done").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("turtlegit-replay-identities.json").path))
            // Preserve a real current draft independently of any metadata the
            // adopter creates. Editing pending actions must leave this alone.
            try Data("Current external draft 雪\n\nkeep exact trailing bytes\n".utf8).write(to: directory.appendingPathComponent("message"))
            return (root, repo)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    private struct ExecutionBytes: Equatable {
        let files: [String: Data]
        let head: Data
        let index: Data
        let worktree: [String: Data]
    }
    private func executionBytes(_ root: URL, _ repo: GitRepository) async throws -> ExecutionBytes {
        let directory = root.appendingPathComponent(".git/rebase-merge")
        let names = ["git-rebase-todo", "done", "message", "message-squash", "message-fixup", "stopped-sha", "head-name", "orig-head", "onto", "author-script", "amend"]
        var files: [String: Data] = [:]
        for name in names { if let bytes = try? Data(contentsOf: directory.appendingPathComponent(name)) { files[name] = bytes } }
        var worktree: [String: Data] = [:]
        for name in ["first.txt", "second.txt", "side.txt", "upstream.txt"] { if let bytes = try? Data(contentsOf: root.appendingPathComponent(name)) { worktree[name] = bytes } }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        return ExecutionBytes(files: files, head: head, index: try Data(contentsOf: root.appendingPathComponent(".git/index")), worktree: worktree)
    }
    func testExternalLinearSnapshotIsReadOnlyAndPendingEditSurvivesReopen() async throws {
        let (root, repo) = try await externalPause(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await executionBytes(root, repo)
        let snapshot = try await repo.rebaseActionEditSnapshot()
        let observed = try await executionBytes(root, repo); XCTAssertEqual(observed, original)
        XCTAssertEqual(snapshot.replay.count, 2)
        XCTAssertEqual(snapshot.replay.first?.progress, .current)
        let future = try XCTUnwrap(snapshot.replay.last)
        XCTAssertEqual(future.progress, .pending)
        _ = try await repo.changePendingRebaseActions(.edit, ids: [future.id], expected: snapshot, editorExecutable: editor)
        let changed = try await executionBytes(root, repo)
        XCTAssertEqual(changed.head, original.head); XCTAssertEqual(changed.index, original.index); XCTAssertEqual(changed.worktree, original.worktree)
        for (name, bytes) in original.files where name != "git-rebase-todo" { XCTAssertEqual(changed.files[name], bytes, name) }
        let reopened = GitRepository(root: root, executable: repo.executable)
        let receipt = try await reopened.rebaseActionEditSnapshot()
        XCTAssertEqual(receipt.replay.map(\.id), snapshot.replay.map(\.id))
        XCTAssertEqual(receipt.replay.last?.action, .edit)
        let pause = try await reopened.continueRebase()
        XCTAssertTrue(pause.state.isEditPause); XCTAssertEqual(pause.state.stoppedEntryID, future.id)
        let complete = try await reopened.continueRebase()
        XCTAssertFalse(complete.state.active)
    }

    func testExternalLinearPendingSquashPreservesMessagesAndCompletes() async throws {
        let (root, repo) = try await externalPause(); defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try await repo.rebaseActionEditSnapshot(), future = try XCTUnwrap(receipt.replay.last)
        _ = try await repo.changePendingRebaseActions(.squash, ids: [future.id], expected: receipt, editorExecutable: editor)
        let reopened = GitRepository(root: root, executable: repo.executable)
        let pause = try await reopened.continueRebase()
        let message = try XCTUnwrap(pause.state.squashMessage?.message)
        XCTAssertTrue(message.contains("first")); XCTAssertTrue(message.contains("second"))
        let final = try await reopened.continueRebase(squashMessage: "Adopted external squash")
        XCTAssertFalse(final.state.active)
        let subjects = try await reopened.run(["log", "--format=%s", "upstream..topic"]).text
        XCTAssertEqual(subjects, "Adopted external squash\n")
    }

    func testExternalStructuralSkeletonAndMergeIdentitySurvivePendingEdit() async throws {
        let (root, repo) = try await externalPause(structural: true); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await executionBytes(root, repo)
        let snapshot = try await repo.rebaseActionEditSnapshot()
        let observed = try await executionBytes(root, repo); XCTAssertEqual(observed, original)
        let merge = try XCTUnwrap(snapshot.replay.first { $0.commit.parents.count > 1 })
        XCTAssertEqual(merge.progress, .pending)
        _ = try await repo.changePendingRebaseActions(.edit, ids: [merge.id], expected: snapshot, editorExecutable: editor)
        let changed = try await executionBytes(root, repo)
        XCTAssertEqual(changed.files["done"], original.files["done"]); XCTAssertEqual(changed.files["message"], original.files["message"])
        XCTAssertEqual(changed.head, original.head); XCTAssertEqual(changed.index, original.index)
        let reopened = GitRepository(root: root, executable: repo.executable)
        let saved = try await reopened.rebaseActionEditSnapshot()
        XCTAssertEqual(saved.replay.first { $0.id == merge.id }?.action, .edit)
        let pause = try await reopened.continueRebase()
        XCTAssertTrue(pause.state.isStructuralMergeEdit); XCTAssertEqual(pause.state.stoppedEntryID, merge.id)
        let final = try await reopened.continueRebase()
        XCTAssertFalse(final.state.active)
        let head = try await reopened.rebaseCommit("HEAD"); XCTAssertEqual(head.parents.count, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("side.txt")), Data("side\n".utf8))
    }

    func testExternalUnknownCommandsAreRefusedWithoutCreatingNativeMetadata() async throws {
        for command in ["exec true", "fixup HEAD", "reword HEAD", "custom-private-command HEAD"] {
            let (root, repo) = try await externalPause(); defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent(".git/rebase-merge"), todo = directory.appendingPathComponent("git-rebase-todo")
            var bytes = try Data(contentsOf: todo); bytes.append(Data((command + "\n").utf8)); try bytes.write(to: todo)
            let original = try await executionBytes(root, repo)
            do { _ = try await repo.rebaseActionEditSnapshot(); XCTFail("Custom session accepted: " + command) } catch is RebaseFailure { }
            let observed = try await executionBytes(root, repo); XCTAssertEqual(observed, original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("turtlegit-replay-identities.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("turtlegit-adopted-plan.json").path))
        }
    }

    func testExternalStaleCancelledAndLockedAdoptionDoesNotWriteMetadata() async throws {
        let (root, repo) = try await externalPause(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".git/rebase-merge"), todo = directory.appendingPathComponent("git-rebase-todo")
        let receipt = try await repo.rebaseActionEditSnapshot(), future = try XCTUnwrap(receipt.replay.last)
        let bytes = try Data(contentsOf: todo)
        try (bytes + Data("# another editor changed this\n".utf8)).write(to: todo)
        do { _ = try await repo.changePendingRebaseActions(.skip, ids: [future.id], expected: receipt, editorExecutable: editor); XCTFail("Stale adoption accepted") } catch RebaseFailure.changed { }
        try bytes.write(to: todo)
        let lock = directory.appendingPathComponent("git-rebase-todo.lock"); try Data("other owner\n".utf8).write(to: lock)
        do { _ = try await repo.changePendingRebaseActions(.skip, ids: [future.id], expected: receipt, editorExecutable: editor); XCTFail("Lock ignored") } catch RebaseFailure.actionEditLocked { }
        XCTAssertEqual(try Data(contentsOf: lock), Data("other owner\n".utf8)); try FileManager.default.removeItem(at: lock)
        let original = try await executionBytes(root, repo), token = OperationCancellation(); token.cancel()
        do { _ = try await repo.changePendingRebaseActions(.skip, ids: [future.id], expected: receipt, editorExecutable: editor, cancellation: token); XCTFail("Cancelled adoption accepted") } catch is OperationCancellationFailure { }
        let observed = try await executionBytes(root, repo); XCTAssertEqual(observed, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("turtlegit-replay-identities.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("turtlegit-adopted-plan.json").path))
        _ = try await repo.changePendingRebaseActions(.skip, ids: [future.id], expected: receipt, editorExecutable: editor)
        let final = try await repo.continueRebase(); XCTAssertFalse(final.state.active)
        let count = try await repo.run(["rev-list", "--count", "upstream..topic"]).text; XCTAssertEqual(count, "1\n")
    }

    func testOlderIdentityRecordsWithoutActionsAreReadWithoutMutationThenUpgraded() async throws {
        let (root, repo) = try await externalPause(); defer { try? FileManager.default.removeItem(at: root) }
        let projected = try await repo.rebaseActionEditSnapshot()
        let directory = root.appendingPathComponent(".git/rebase-merge"), identityURL = directory.appendingPathComponent("turtlegit-replay-identities.json")
        let legacy = try JSONSerialization.data(withJSONObject: projected.replay.map { ["hash": $0.commit.hash, "occurrence": 0] as [String: Any] })
        try legacy.write(to: identityURL)
        let original = try await executionBytes(root, repo)
        let snapshot = try await repo.rebaseActionEditSnapshot()
        XCTAssertEqual(try Data(contentsOf: identityURL), legacy)
        let observed = try await executionBytes(root, repo); XCTAssertEqual(observed, original)
        XCTAssertEqual(snapshot.replay.map(\.id), projected.replay.map(\.id))
        let future = try XCTUnwrap(snapshot.replay.last)
        _ = try await repo.changePendingRebaseActions(.edit, ids: [future.id], expected: snapshot, editorExecutable: editor)
        let saved = try await GitRepository(root: root, executable: repo.executable).rebaseActionEditSnapshot()
        XCTAssertEqual(saved.replay.last?.action, .edit)
        let upgraded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: identityURL)) as? [[String: Any]])
        XCTAssertEqual(upgraded.last?["action"] as? String, "edit")
        let pause = try await repo.continueRebase(); XCTAssertTrue(pause.state.isEditPause)
        let final = try await repo.continueRebase(); XCTAssertFalse(final.state.active)
    }

    func testInterruptedAdoptionJournalRollsBackOrCompletesAtTodoCommitPoint() async throws {
        let names = ["git-rebase-todo", "done", "turtlegit-replay-identities.json", "turtlegit-message-editor.json", "turtlegit-cherry-pick.json", "turtlegit-adopted-plan.json"]
        for committed in [false, true] {
            let (root, repo) = try await externalPause(); defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent(".git/rebase-merge")
            func capture() -> [String: [String: String]] {
                Dictionary(uniqueKeysWithValues: names.map { name in
                    let bytes = try? Data(contentsOf: directory.appendingPathComponent(name))
                    return (name, bytes.map { ["bytes": $0.base64EncodedString()] } ?? [:])
                })
            }
            func restore(_ values: [String: [String: String]]) throws {
                for name in names {
                    let url = directory.appendingPathComponent(name)
                    if let encoded = values[name]?["bytes"] { try XCTUnwrap(Data(base64Encoded: encoded)).write(to: url) }
                    else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                }
            }
            let before = capture(), original = try await executionBytes(root, repo)
            let snapshot = try await repo.rebaseActionEditSnapshot(), future = try XCTUnwrap(snapshot.replay.last)
            _ = try await repo.changePendingRebaseActions(.skip, ids: [future.id], expected: snapshot, editorExecutable: editor)
            let after = capture()
            XCTAssertNotEqual(before["git-rebase-todo"], after["git-rebase-todo"])
            XCTAssertEqual(before["done"], after["done"])
            try restore(before)
            // Simulate a crash after sidecars were staged, on either side of
            // the single Git todo commit point. Recovery must choose one side.
            for name in names where name != "git-rebase-todo" && name != "done" {
                if let encoded = after[name]?["bytes"] { try XCTUnwrap(Data(base64Encoded: encoded)).write(to: directory.appendingPathComponent(name)) }
            }
            if committed { try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(after["git-rebase-todo"]?["bytes"]))).write(to: directory.appendingPathComponent("git-rebase-todo")) }
            let journal = directory.appendingPathComponent("turtlegit-action-edit.json")
            try JSONSerialization.data(withJSONObject: ["version": 1, "before": before, "after": after]).write(to: journal)
            let reopened = GitRepository(root: root, executable: repo.executable)
            let recovered = try await reopened.rebaseActionEditSnapshot()
            XCTAssertEqual(capture(), committed ? after : before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
            XCTAssertEqual(recovered.replay.last?.action, committed ? .skip : .pick)
            let observed = try await executionBytes(root, repo)
            XCTAssertEqual(observed.head, original.head); XCTAssertEqual(observed.index, original.index)
            XCTAssertEqual(observed.files["done"], original.files["done"]); XCTAssertEqual(observed.files["message"], original.files["message"])
            let final = try await reopened.continueRebase(); XCTAssertFalse(final.state.active)
            let count = try await reopened.run(["rev-list", "--count", "upstream..topic"]).text
            XCTAssertEqual(count, committed ? "1\n" : "2\n")
        }
    }

    func testExternalUpdateRefsSurvivesAdoptedSquashAndLogicalMessagePause() async throws {
        // Unsupported Git versions ignore this configuration and cannot
        // generate a genuine update-ref todo, so detect the actual instruction.
        let (root, repo) = try await externalPause(updateRefs: true); defer { try? FileManager.default.removeItem(at: root) }
        let todoURL = root.appendingPathComponent(".git/rebase-merge/git-rebase-todo")
        let todo = try String(contentsOf: todoURL, encoding: .utf8)
        guard todo.contains("update-ref refs/heads/external-future") else { throw XCTSkip("Selected Git does not generate rebase --update-refs instructions") }
        let oldRef = try await repo.run(["rev-parse", "refs/heads/external-future"]).stdout
        let original = try await executionBytes(root, repo)
        let snapshot = try await repo.rebaseActionEditSnapshot()
        let observed = try await executionBytes(root, repo); XCTAssertEqual(observed, original)
        let future = try XCTUnwrap(snapshot.replay.last)
        _ = try await repo.changePendingRebaseActions(.squash, ids: [future.id], expected: snapshot, editorExecutable: editor)
        XCTAssertTrue(try String(contentsOf: todoURL, encoding: .utf8).contains("update-ref refs/heads/external-future"))
        let unchangedRef = try await repo.run(["rev-parse", "refs/heads/external-future"]).stdout; XCTAssertEqual(unchangedRef, oldRef)
        let reopened = GitRepository(root: root, executable: repo.executable)
        let pause = try await reopened.continueRebase()
        let message = try XCTUnwrap(pause.state.squashMessage?.message)
        XCTAssertTrue(message.contains("first")); XCTAssertTrue(message.contains("second"))
        // Reopen again while the logical message editor is stopped; the raw
        // sequencer also contains update-ref and must not shift commit identity.
        let again = GitRepository(root: root, executable: repo.executable)
        let pending = try await again.rebaseState(); XCTAssertNotNil(pending.squashMessage)
        let final = try await again.continueRebase(squashMessage: "External update-ref squash")
        XCTAssertFalse(final.state.active)
        let topic = try await again.run(["rev-parse", "refs/heads/topic"]).stdout
        let mapped = try await again.run(["rev-parse", "refs/heads/external-future"]).stdout
        XCTAssertEqual(mapped, topic); XCTAssertNotEqual(mapped, oldRef)
        let subjects = try await again.run(["log", "--format=%s", "upstream..topic"]).text
        XCTAssertEqual(subjects, "External update-ref squash\n")
    }

    func testExternalDuplicateOccurrencesKeepExactRemainingProjectionAcrossAdoption() async throws {
        let (root, repo) = try await externalPause(); defer { try? FileManager.default.removeItem(at: root) }
        let todoURL = root.appendingPathComponent(".git/rebase-merge/git-rebase-todo")
        var todo = try String(contentsOf: todoURL, encoding: .utf8)
        let futureLine = try XCTUnwrap(todo.split(separator: "\n").first { $0.hasPrefix("pick ") })
        todo += "\n" + String(futureLine) + "\n"; try Data(todo.utf8).write(to: todoURL)
        let original = try await executionBytes(root, repo)
        let snapshot = try await repo.rebaseActionEditSnapshot()
        let remaining = try await repo.remainingRebaseEntries()
        XCTAssertEqual(snapshot.replay.count, 3)
        XCTAssertEqual(Set(snapshot.replay.map(\.id)).count, snapshot.replay.count)
        XCTAssertEqual(remaining.map(\.id), snapshot.replay.filter { $0.progress != .completed }.map(\.id))
        XCTAssertEqual(remaining.suffix(2).map { $0.commit.hash }.first, remaining.suffix(2).map { $0.commit.hash }.last)
        let observed = try await executionBytes(root, repo); XCTAssertEqual(observed, original)
        let repeated = try XCTUnwrap(snapshot.replay.last)
        _ = try await repo.changePendingRebaseActions(.edit, ids: [repeated.id], expected: snapshot, editorExecutable: editor)
        let reopened = GitRepository(root: root, executable: repo.executable)
        let saved = try await reopened.rebaseActionEditSnapshot(), savedRemaining = try await reopened.remainingRebaseEntries()
        XCTAssertEqual(saved.replay.map(\.id), snapshot.replay.map(\.id))
        XCTAssertEqual(Set(savedRemaining.map(\.id)).count, savedRemaining.count)
        XCTAssertEqual(savedRemaining.map(\.id), saved.replay.filter { $0.progress != .completed }.map(\.id))
        XCTAssertEqual(savedRemaining.last?.action, .edit)
        XCTAssertEqual(saved.replay[1].action, .pick, "Changing repeated occurrence must not retarget its earlier object")
    }

    func testCurrentSkipRemainsDurableWhenAdoptedFutureActionsAreEditedAgain() async throws {
        let (root, repo) = try await externalPause(extraCommits: 2); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await repo.rebaseActionEditSnapshot()
        XCTAssertEqual(initial.replay.count, 4)
        let current = try XCTUnwrap(initial.replay.first), next = initial.replay[1], later = try XCTUnwrap(initial.replay.last)
        XCTAssertEqual(current.progress, .current)
        _ = try await repo.changePendingRebaseActions(.edit, ids: [next.id], expected: initial, editorExecutable: editor)
        // Exercise the actual Skip operation, rather than writing bookkeeping
        // that merely resembles a skip receipt.
        let skipped = try await repo.skipRebase()
        XCTAssertTrue(skipped.state.isEditPause); XCTAssertEqual(skipped.state.stoppedEntryID, next.id)
        let bookkeeping = root.appendingPathComponent(".git/rebase-merge/turtlegit-skipped-steps.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookkeeping.path))
        let skipBytes = try Data(contentsOf: bookkeeping)
        let reopened = GitRepository(root: root, executable: repo.executable)
        let snapshot = try await reopened.rebaseActionEditSnapshot()
        let skippedRow = try XCTUnwrap(snapshot.replay.first { $0.id == current.id })
        XCTAssertEqual(skippedRow.action, .skip); XCTAssertEqual(skippedRow.progress, .completed)
        XCTAssertEqual(snapshot.state.stoppedEntryID, next.id)
        let remaining = try await reopened.remainingRebaseEntries()
        XCTAssertEqual(remaining.map(\.id), snapshot.replay.filter { $0.progress != .completed }.map(\.id))
        XCTAssertFalse(remaining.contains { $0.id == current.id })
        _ = try await reopened.changePendingRebaseActions(.edit, ids: [later.id], expected: snapshot, editorExecutable: editor)
        XCTAssertEqual(try Data(contentsOf: bookkeeping), skipBytes)
        let again = GitRepository(root: root, executable: repo.executable)
        let saved = try await again.rebaseActionEditSnapshot()
        XCTAssertEqual(saved.replay.first { $0.id == current.id }?.action, .skip)
        XCTAssertEqual(saved.replay.first { $0.id == current.id }?.progress, .completed)
        XCTAssertEqual(saved.replay.last?.action, .edit)
        let savedRemaining = try await again.remainingRebaseEntries()
        XCTAssertEqual(savedRemaining.map(\.id), saved.replay.filter { $0.progress != .completed }.map(\.id))
        let laterPause = try await again.continueRebase()
        XCTAssertTrue(laterPause.state.isEditPause); XCTAssertEqual(laterPause.state.stoppedEntryID, later.id)
        let final = try await again.continueRebase(); XCTAssertFalse(final.state.active)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("external-extra-1.txt")), Data("external-extra-1.txt\n".utf8))
    }

}
