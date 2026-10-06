import XCTest
@testable import TurtleGitCore

final class RebaseTests: XCTestCase {
    var editor: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/TurtleGitMac") }
    func fixture(conflict: Bool = false) async throws -> (URL, GitRepository, String) {
        let (root, repo, path) = try await GitPatchTests().fixture()
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "-b", "upstream"])
        try Data("upstream\n".utf8).write(to: root.appendingPathComponent(conflict ? path : "upstream.txt"))
        try await repo.stage([conflict ? path : "upstream.txt"]); _ = try await repo.commit(message: "upstream")
        _ = try await repo.run(["checkout", "-b", "topic", base])
        try Data("first\n".utf8).write(to: root.appendingPathComponent(conflict ? path : "first.txt"))
        try await repo.stage([conflict ? path : "first.txt"]); _ = try await repo.commit(message: "first")
        try Data("second\n".utf8).write(to: root.appendingPathComponent("second.txt")); try await repo.stage(["second.txt"]); _ = try await repo.commit(message: "second")
        return (root, repo, path)
    }
    func options() -> RebaseOptions { var o = RebaseOptions(); o.branch = "topic"; o.upstream = "upstream"; return o }
    func splitFixture() async throws -> (URL, GitRepository, RebasePlan) {
        let (root, repo, _) = try await GitPatchTests().fixture()
        let base = try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["checkout", "-b", "upstream"])
        try Data("upstream\n".utf8).write(to: root.appendingPathComponent("upstream.txt")); try await repo.stage(["upstream.txt"]); _ = try await repo.commit(message: "upstream")
        _ = try await repo.run(["checkout", "-b", "topic", base.hash])
        for name in ["left 雪\n.txt", "right.txt"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        try await repo.stage(["left 雪\n.txt", "right.txt"]); _ = try await repo.commit(message: "two files")
        try Data("future\n".utf8).write(to: root.appendingPathComponent("future.txt")); try await repo.stage(["future.txt"]); _ = try await repo.commit(message: "future")
        var plan = try await repo.rebasePlan(options()); plan.entries[0].action = .edit
        return (root, repo, plan)
    }
    func testHeadlessEditorWritesOnlyRequestedPlanAndReturnsErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("plan"), target = directory.appendingPathComponent("todo"); try Data("pick abc subject\n".utf8).write(to: source)
        XCTAssertNil(RebaseEditor.handle(arguments: ["app"], environment: [:]))
        XCTAssertEqual(RebaseEditor.handle(arguments: ["app", RebaseEditor.argument, target.path], environment: ["TURTLEGIT_REBASE_PLAN": source.path]), 0)
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: source))
        XCTAssertEqual(RebaseEditor.handle(arguments: ["app", RebaseEditor.argument, target.path], environment: [:]), 1)
    }
    func testPickSkipAndReorderedPlanUseRealApplicationEditor() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: editor.path))
        var plan = try await repo.rebasePlan(options()); XCTAssertEqual(plan.entries.map { $0.commit.subject }, ["first", "second"])
        plan.entries.reverse(); plan.entries[1].action = .skip
        let result = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertEqual(result.exitCode, 0, result.output); XCTAssertFalse(result.state.active)
        let parent = try await repo.run(["rev-parse", "HEAD^"]).text, upstream = try await repo.run(["rev-parse", "upstream"]).text; XCTAssertEqual(parent, upstream)
        let branch = try await repo.branch(); XCTAssertEqual(branch, "topic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.txt").path)); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("first.txt").path))
    }
    func testSquashCombinesMessagesAndEditCanAmendThenContinue() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var plan = try await repo.rebasePlan(options()); plan.entries[1].action = .squash
        let paused = try await repo.startRebase(plan, editorExecutable: editor)
        XCTAssertTrue(paused.state.active); XCTAssertNotNil(paused.state.squashMessage)
        let result = try await repo.continueRebase(squashMessage: paused.state.squashMessage!.message); XCTAssertEqual(result.exitCode, 0, result.output)
        let message = try await repo.run(["log", "-1", "--format=%B"]).text; XCTAssertTrue(message.contains("first")); XCTAssertTrue(message.contains("second"))
        let count = try await repo.run(["rev-list", "--count", "upstream..topic"]).text; XCTAssertEqual(count, "1\n")
        var force = options(); force.force = true
        plan = try await repo.rebasePlan(force); plan.entries[0].action = .edit
        let stopped = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertEqual(stopped.exitCode, 0, stopped.output); XCTAssertTrue(stopped.state.active); XCTAssertEqual(stopped.state.branch, "refs/heads/topic")
        try Data("edited\n".utf8).write(to: root.appendingPathComponent("edited.txt")); try await repo.stage(["edited.txt"])
        _ = try await repo.amendRebaseCommit(message: "Edited combined commit")
        let completed = try await repo.continueRebase(); XCTAssertEqual(completed.exitCode, 0, completed.output); XCTAssertFalse(completed.state.active)
        let edited = try await repo.run(["log", "-1", "--format=%s"]).text; XCTAssertEqual(edited, "Edited combined commit\n")
    }
    func testConflictStateSurvivesNewRepositoryObjectAndResolutionContinues() async throws {
        let (root, repo, path) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await repo.rebasePlan(options()), stopped = try await repo.startRebase(plan, editorExecutable: editor)
        XCTAssertNotEqual(stopped.exitCode, 0); XCTAssertTrue(stopped.state.active); XCTAssertEqual(stopped.state.conflicts, [path]); XCTAssertEqual(stopped.state.originalHead, plan.branchHash)
        let reopened = GitRepository(root: root), state = try await reopened.rebaseState(); XCTAssertTrue(state.active); XCTAssertEqual(state.branch, "refs/heads/topic"); XCTAssertEqual(state.currentStep, 1)
        try Data("resolved\n".utf8).write(to: root.appendingPathComponent(path)); try await reopened.stage([path])
        let completed = try await reopened.continueRebase(); XCTAssertEqual(completed.exitCode, 0, completed.output); XCTAssertFalse(completed.state.active)
        let ancestry = try await reopened.run(["merge-base", "--is-ancestor", "upstream", "topic"]); XCTAssertTrue(ancestry.text.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "resolved\n")
    }
    func testCheckedConflictCommitPreservesExcludedIndexAndRecoversAmendLoop() async throws {
        let (root, repo, path) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await repo.rebasePlan(options()); _ = try await repo.startRebase(plan, editorExecutable: editor)
        let head = try await repo.rebaseCommit("HEAD")
        try Data("resolved\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        let excluded = "excluded 雪\n.txt"
        try Data("excluded content\n".utf8).write(to: root.appendingPathComponent(excluded)); try await repo.stage([excluded])
        let state = try await repo.rebaseState()
        let selected = try await repo.commitRebaseConflictSelection(message: "selected recovery", paths: [path], expected: state, expectedHead: head.hash)
        XCTAssertEqual(selected.state.split?.conflictRecovery, true); XCTAssertEqual(selected.state.split?.parts, 1)
        let applied = try await repo.rebaseCommit("HEAD")
        XCTAssertEqual(applied.subject, "selected recovery"); XCTAssertEqual(applied.author, plan.entries[0].commit.author); XCTAssertEqual(applied.date, plan.entries[0].commit.date)
        let files = try await repo.files(in: applied); XCTAssertEqual(files.map(\.path), [path])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(excluded), encoding: .utf8), "excluded content\n")
        let status = try await repo.status(); XCTAssertEqual(status.first(where: { $0.path == excluded })?.index, "A")
        do { _ = try await repo.continueRebase(); XCTFail("Excluded changes must prevent automatic continuation") } catch RebaseFailure.plan {}
        let reopened = GitRepository(root: root), captured = try await reopened.rebaseState().split!
        var amendment = CommitOptions(); amendment.amend = true
        _ = try await reopened.commitRebaseSplit(message: "completed recovery", paths: [excluded], staging: false, options: amendment, expected: captured)
        let amended = try await reopened.rebaseCommit("HEAD"); XCTAssertEqual(amended.parents, applied.parents)
        let all = try await reopened.files(in: amended); XCTAssertEqual(Set(all.map(\.path)), [path, excluded])
        let completed = try await reopened.continueRebase(); XCTAssertEqual(completed.exitCode, 0, completed.output); XCTAssertFalse(completed.state.active)
        let history = try await reopened.run(["log", "--format=%s", "upstream..HEAD"]).text; XCTAssertEqual(history, "second\ncompleted recovery\n")
        let destination = try await reopened.rebaseCommit(head.hash); XCTAssertEqual(destination.subject, "upstream")
    }
    func testCheckedConflictRejectsUnresolvedStaleAndEmptySelectionsWithoutMovingHead() async throws {
        let (root, repo, path) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await repo.rebasePlan(options()); _ = try await repo.startRebase(plan, editorExecutable: editor)
        let state = try await repo.rebaseState(), head = try await repo.rebaseCommit("HEAD")
        do { _ = try await repo.commitRebaseConflictSelection(message: "unresolved", paths: [path], expected: state, expectedHead: head.hash); XCTFail() } catch RebaseFailure.changed {}
        try Data("resolved\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        let resolved = try await repo.rebaseState()
        do { _ = try await repo.commitRebaseConflictSelection(message: "none", paths: [], expected: resolved, expectedHead: head.hash); XCTFail() } catch RebaseFailure.plan {}
        do { _ = try await repo.commitRebaseConflictSelection(message: "stale", paths: [path], expected: resolved, expectedHead: plan.branchHash); XCTFail() } catch RebaseFailure.changed {}
        let unchanged = try await repo.rebaseCommit("HEAD"); XCTAssertEqual(unchanged.hash, head.hash)
    }
    func testCheckedConflictEditKeepsRecoveryOnRejectedMessageAndAbortRestoresBranch() async throws {
        let (root, repo, path) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        var plan = try await repo.rebasePlan(options()); plan.entries[0].action = .edit
        _ = try await repo.startRebase(plan, editorExecutable: editor)
        try Data("resolved\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        let state = try await repo.rebaseState(), destination = try await repo.rebaseCommit("HEAD")
        let selected = try await repo.commitRebaseConflictSelection(message: "checked Edit", paths: [path], expected: state, expectedHead: destination.hash)
        XCTAssertTrue(selected.state.isEditPause); XCTAssertTrue(selected.state.canSplit)
        do { _ = try await repo.continueRebase(editMessage: " \n"); XCTFail("Blank approval") } catch RebaseFailure.message {}
        let reopened = GitRepository(root: root), retry = try await reopened.rebaseState()
        XCTAssertTrue(retry.isEditPause); XCTAssertEqual(retry.split?.expectedHead, selected.state.split?.expectedHead)
        XCTAssertEqual(retry.message, "checked Edit\n")
        let aborted = try await reopened.abortRebase(); XCTAssertEqual(aborted.exitCode, 0, aborted.output); XCTAssertFalse(aborted.state.active)
        let restored = try await reopened.rebaseCommit("HEAD"); XCTAssertEqual(restored.hash, plan.branchHash)
        let branch = try await reopened.branch(); XCTAssertEqual(branch, "topic")
    }
    func testAbortRestoresOriginalBranchAndSkipDropsConflictingCommit() async throws {
        let (root, repo, path) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        var plan = try await repo.rebasePlan(options()); _ = try await repo.startRebase(plan, editorExecutable: editor)
        do { _ = try await repo.rebasePlan(options()); XCTFail("Active rebase must not be replaced") } catch RebaseFailure.active {}
        let aborted = try await repo.abortRebase(); XCTAssertEqual(aborted.exitCode, 0); XCTAssertFalse(aborted.state.active)
        let original = try await repo.run(["rev-parse", "topic"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(original, plan.branchHash); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "first\n")
        plan = try await repo.rebasePlan(options()); _ = try await repo.startRebase(plan, editorExecutable: editor)
        let skipped = try await repo.skipRebase(); XCTAssertEqual(skipped.exitCode, 0, skipped.output); XCTAssertFalse(skipped.state.active)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "upstream\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.txt").path))
    }
    func testOntoStaleReferencesAndInvalidPlans() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var plan = try await repo.rebasePlan(options()); plan.entries[0].action = .squash
        do { _ = try await repo.rebaseTodo(plan); XCTFail("First squash") } catch RebaseFailure.squash {}
        plan.entries.removeLast()
        do { _ = try await repo.rebaseTodo(plan); XCTFail("Missing commit") } catch RebaseFailure.plan {}
        plan = try await repo.rebasePlan(options()); _ = try await repo.run(["branch", "-f", "upstream", "main"])
        do { _ = try await repo.startRebase(plan, editorExecutable: editor); XCTFail("Stale upstream") } catch RebaseFailure.changed {}
        _ = try await repo.run(["branch", "-f", "upstream", plan.upstreamHash])
        var o = options(); o.onto = "main"; plan = try await repo.rebasePlan(o)
        let result = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("upstream.txt").path))
        let count = try await repo.run(["rev-list", "--count", "main..topic"]).text; XCTAssertEqual(count, "2\n")
    }
    func testPreserveMergesRetainsMergeParentTopology() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["checkout", "-b", "side", "main"])
        try Data("side\n".utf8).write(to: root.appendingPathComponent("side.txt")); try await repo.stage(["side.txt"]); _ = try await repo.commit(message: "side")
        _ = try await repo.run(["checkout", "topic"]); _ = try await repo.run(["merge", "--no-ff", "--no-edit", "side"])
        var o = options(); o.preserveMerges = true
        var plan = try await repo.rebasePlan(o); XCTAssertTrue(plan.entries.contains { $0.commit.parents.count == 2 })
        plan.entries[0].action = .skip
        do { _ = try await repo.rebaseTodo(plan); XCTFail("Structural plans cannot be custom edited yet") } catch RebaseFailure.preservePlan {}
        plan = try await repo.rebasePlan(o); let result = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertEqual(result.exitCode, 0, result.output)
        let parents = try await repo.run(["rev-list", "--parents", "-n", "1", "topic"]).text.split(separator: " "); XCTAssertEqual(parents.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("side.txt").path)); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("upstream.txt").path))
    }
    func testLinkedWorktreeStateIsIsolatedAndDirtyStartDoesNotCreateSession() async throws {
        let (root, repo, path) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        let linkedURL = root.appendingPathComponent("linked")
        _ = try await repo.run(["worktree", "add", "-b", "linked-topic", linkedURL.path, "topic"])
        let linked = GitRepository(root: linkedURL)
        var o = options(); o.branch = "linked-topic"
        let plan = try await linked.rebasePlan(o)
        let stopped = try await linked.startRebase(plan, editorExecutable: editor); XCTAssertTrue(stopped.state.active); XCTAssertEqual(stopped.state.conflicts, [path])
        let parentState = try await repo.rebaseState(); XCTAssertFalse(parentState.active)
        let aborted = try await linked.abortRebase(); XCTAssertEqual(aborted.exitCode, 0)
        try Data("dirty\n".utf8).write(to: linkedURL.appendingPathComponent(path)); try await linked.stage([path])
        let rejected = try await linked.startRebase(plan, editorExecutable: editor); XCTAssertNotEqual(rejected.exitCode, 0); XCTAssertFalse(rejected.state.active)
        let head = try await linked.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, plan.branchHash)
        let index = try await linked.run(["show", ":" + path]).text; XCTAssertEqual(index, "dirty\n")
    }

    func testDispositionAndFastForwardPreserveBranchIdentity() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var o = options()
        let divergent = try await repo.rebasePlan(o); XCTAssertEqual(divergent.disposition, .ready)
        o.upstream = "topic"
        let equal = try await repo.rebasePlan(o); XCTAssertEqual(equal.disposition, .equal)
        o.upstream = "main"
        let current = try await repo.rebasePlan(o); XCTAssertEqual(current.disposition, .upToDate)
        o.force = true
        let forced = try await repo.rebasePlan(o); XCTAssertEqual(forced.disposition, .ready)
        o.force = false; o.branch = "main"; o.upstream = "upstream"
        let forward = try await repo.rebasePlan(o); XCTAssertEqual(forward.disposition, .fastForward); XCTAssertTrue(forward.entries.isEmpty)
        let result = try await repo.startRebase(forward, editorExecutable: editor); XCTAssertEqual(result.exitCode, 0, result.output)
        let branch = try await repo.branch(); XCTAssertEqual(branch, "main")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, forward.upstreamHash)
    }
    func testRecoveredEntriesContainStoppedAndPendingCommitMetadata() async throws {
        let (root, repo, _) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await repo.rebasePlan(options()); _ = try await repo.startRebase(plan, editorExecutable: editor)
        let reopened = GitRepository(root: root)
        let entries = try await reopened.remainingRebaseEntries()
        XCTAssertEqual(entries.map { $0.commit.subject }, ["first", "second"])
        XCTAssertEqual(entries.map(\.id), plan.entries.map(\.id))
        XCTAssertEqual(entries.map(\.action), [.edit, .pick])
        _ = try await reopened.abortRebase()
        let empty = try await reopened.remainingRebaseEntries(); XCTAssertTrue(empty.isEmpty)
    }

    func testCherryPickPlanAppendsSelectedCommitsAndRejectsChangedBranch() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = try await repo.run(["rev-list", "main..topic"]).text.split(separator: "\n").map(String.init)
        _ = try await repo.run(["checkout", "main"])
        var plan = try await repo.cherryPickPlan(revisions: selected)
        XCTAssertTrue(plan.options.isCherryPick)
        XCTAssertEqual(plan.entries.map { $0.commit.subject }, ["first", "second"])
        do { _ = try await repo.cherryPickPlan(revisions: [selected[0], selected[0]]); XCTFail("Duplicate selections must fail") } catch RebaseFailure.plan {}
        _ = try await repo.run(["checkout", "-b", "other"])
        do { _ = try await repo.startRebase(plan, editorExecutable: editor); XCTFail("Same hash on a different branch must fail") } catch RebaseFailure.changed {}
        _ = try await repo.run(["checkout", "main"])
        plan.entries[0].action = .skip
        let result = try await repo.startRebase(plan, editorExecutable: editor)
        XCTAssertEqual(result.exitCode, 0, result.output); XCTAssertFalse(result.state.active)
        let branch = try await repo.branch(); XCTAssertEqual(branch, "main")
        let parent = try await repo.run(["rev-parse", "HEAD^"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(parent, plan.branchHash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("first.txt").path))
    }

    func testCherryPickBothMergeMainlinesMatchGitAndKeepOriginalMetadataOnRecovery() async throws {
        for mainline in 1...2 {
            let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            _ = try await repo.run(["merge", "--no-ff", "--no-edit", "upstream"])
            let merge = try await repo.rebaseCommit("HEAD")
            _ = try await repo.run(["checkout", "-b", "expected", merge.parents[mainline - 1]])
            _ = try await repo.run(["cherry-pick", "-m", String(mainline), merge.hash])
            let expectedTree = try await repo.run(["rev-parse", "HEAD^{tree}"]).text
            let expectedAuthor = try await repo.run(["show", "-s", "--format=%an%x00%ae%x00%aI%x00%B", "HEAD"]).stdout
            _ = try await repo.run(["checkout", "-b", "actual", merge.parents[mainline - 1]])
            var plan = try await repo.cherryPickPlan(revisions: [merge.hash])
            do { _ = try await repo.startRebase(plan, editorExecutable: editor); XCTFail("Merge parent must be explicit") } catch RebaseFailure.mainline {}
            plan.entries[0].mainline = mainline; plan.entries[0].action = .edit
            let stopped = try await repo.startRebase(plan, editorExecutable: editor)
            XCTAssertEqual(stopped.exitCode, 0, stopped.output); XCTAssertTrue(stopped.state.active); XCTAssertTrue(stopped.state.isCherryPick)
            XCTAssertEqual(stopped.state.stoppedCommit, merge.hash)
            let reopened = GitRepository(root: root)
            let recovered = try await reopened.remainingRebaseEntries()
            XCTAssertEqual(recovered.map(\.id), [merge.hash]); XCTAssertEqual(recovered[0].commit.parents, merge.parents)
            let actualTree = try await reopened.run(["rev-parse", "HEAD^{tree}"]).text
            let actualAuthor = try await reopened.run(["show", "-s", "--format=%an%x00%ae%x00%aI%x00%B", "HEAD"]).stdout
            XCTAssertEqual(actualTree, expectedTree); XCTAssertEqual(actualAuthor, expectedAuthor)
            let completed = try await reopened.continueRebase(); XCTAssertEqual(completed.exitCode, 0, completed.output); XCTAssertFalse(completed.state.isCherryPick)
            let branch = try await reopened.branch(); XCTAssertEqual(branch, "actual")
            let parent = try await reopened.run(["rev-parse", "HEAD^"]).text.trimmingCharacters(in: .newlines)
            XCTAssertEqual(parent, merge.parents[mainline - 1])
        }
    }

    func testCherryPickConflictReopensAndAbortRestoresTarget() async throws {
        let (root, repo, path) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        let selected = try await repo.run(["rev-list", "main..topic"]).text.split(separator: "\n").map(String.init)
        _ = try await repo.run(["checkout", "upstream"])
        let plan = try await repo.cherryPickPlan(revisions: selected)
        let stopped = try await repo.startRebase(plan, editorExecutable: editor)
        XCTAssertNotEqual(stopped.exitCode, 0); XCTAssertTrue(stopped.state.isCherryPick); XCTAssertEqual(stopped.state.conflicts, [path])
        let reopened = GitRepository(root: root)
        let entries = try await reopened.remainingRebaseEntries(); XCTAssertEqual(entries.map(\.id), plan.originalCommits)
        let aborted = try await reopened.abortRebase(); XCTAssertEqual(aborted.exitCode, 0, aborted.output); XCTAssertFalse(aborted.state.active)
        let head = try await reopened.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(head, plan.branchHash)
        let branch = try await reopened.branch(); XCTAssertEqual(branch, "upstream")
    }

    func testCherryPickSquashReorderEmptyCommitAndDetachedTarget() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = try await repo.run(["rev-list", "main..topic"]).text.split(separator: "\n").map(String.init)
        _ = try await repo.run(["checkout", "--detach", "main"])
        var plan = try await repo.cherryPickPlan(revisions: selected)
        plan.entries.reverse(); plan.entries[1].action = .squash
        let paused = try await repo.startRebase(plan, editorExecutable: editor)
        XCTAssertNotNil(paused.state.squashMessage)
        let completed = try await repo.continueRebase(squashMessage: paused.state.squashMessage!.message)
        XCTAssertEqual(completed.exitCode, 0, completed.output); XCTAssertFalse(completed.state.active)
        let symbolic = try await repo.run(["symbolic-ref", "--quiet", "HEAD"], successfulExitCodes: 0...1); XCTAssertEqual(symbolic.exitCode, 1)
        let message = try await repo.run(["log", "-1", "--format=%B"]).text
        XCTAssertTrue(message.contains("first")); XCTAssertTrue(message.contains("second"))
        let parent = try await repo.run(["rev-parse", "HEAD^"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(parent, plan.branchHash)
        _ = try await repo.run(["checkout", "topic"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "empty source"])
        let empty = try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["checkout", "main"])
        plan = try await repo.cherryPickPlan(revisions: [empty.hash])
        let kept = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertEqual(kept.exitCode, 0, kept.output)
        let subject = try await repo.run(["log", "-1", "--format=%s"]).text; XCTAssertEqual(subject, "empty source\n")
        plan = try await repo.cherryPickPlan(revisions: [empty.hash]); plan.entries[0].action = .edit
        let edit = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertTrue(edit.state.active)
        let editedEmpty = try await repo.continueRebase(editMessage: "Edited originally empty\n\nBody")
        XCTAssertEqual(editedEmpty.exitCode, 0, editedEmpty.output); XCTAssertFalse(editedEmpty.state.active)
    }

    func testCherryPickMergeConflictRestoresOriginalIDsAndSkipContinues() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["merge", "--no-ff", "--no-edit", "upstream"])
        let merge = try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["checkout", "-b", "target", merge.parents[0]])
        try Data("target conflict\n".utf8).write(to: root.appendingPathComponent("upstream.txt"))
        try await repo.stage(["upstream.txt"]); _ = try await repo.commit(message: "target change")
        var plan = try await repo.cherryPickPlan(revisions: [merge.hash]); plan.entries[0].mainline = 1
        let stopped = try await repo.startRebase(plan, editorExecutable: editor)
        XCTAssertNotEqual(stopped.exitCode, 0); XCTAssertTrue(stopped.state.isCherryPick)
        XCTAssertEqual(stopped.state.stoppedCommit, merge.hash); XCTAssertEqual(stopped.state.conflicts, ["upstream.txt"])
        let reopened = GitRepository(root: root)
        let recovered = try await reopened.remainingRebaseEntries(); XCTAssertEqual(recovered.map(\.id), [merge.hash])
        let skipped = try await reopened.skipRebase(); XCTAssertEqual(skipped.exitCode, 0, skipped.output); XCTAssertFalse(skipped.state.active)
        let head = try await reopened.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, plan.branchHash)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("upstream.txt"), encoding: .utf8), "target conflict\n")
    }

    func testCherryPickedFromAttributionMatchesGitForOrdinaryAndMergeCommits() async throws {
        for merging in [false, true] {
            let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            if merging { _ = try await repo.run(["merge", "--no-ff", "--no-edit", "upstream"]) }
            let source = try await repo.rebaseCommit("HEAD")
            _ = try await repo.run(["checkout", "-b", "expected", source.parents[0]])
            _ = try await repo.run(["cherry-pick", "-x"] + (merging ? ["-m", "1"] : []) + [source.hash])
            let expected = try await repo.run(["show", "-s", "--format=%T%x00%an%x00%ae%x00%aI%x00%B", "HEAD"]).stdout
            _ = try await repo.run(["checkout", "-b", "actual", source.parents[0]])
            var plan = try await repo.cherryPickPlan(revisions: [source.hash]); plan.options.addCherryPickedFrom = true
            if merging { plan.entries[0].mainline = 1 }
            let result = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertEqual(result.exitCode, 0, result.output)
            let actual = try await repo.run(["show", "-s", "--format=%T%x00%an%x00%ae%x00%aI%x00%B", "HEAD"]).stdout
            XCTAssertEqual(actual, expected)
        }
    }

    func testAddingCommitsKeepsPlanSnapshotAndAppendsInPickerOrder() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let revisions = try await repo.run(["rev-list", "main..topic"]).text.split(separator: "\n").map(String.init)
        _ = try await repo.run(["checkout", "main"])
        let original = try await repo.cherryPickPlan(revisions: [revisions[1]])
        var extended = try await repo.addingRebaseCommits(original, revisions: [revisions[0], revisions[1]])
        XCTAssertEqual(extended.entries.map { $0.commit.subject }, ["first", "first", "second"])
        XCTAssertEqual(extended.entries.map(\.occurrence), [0, 1, 0])
        XCTAssertEqual(Set(extended.entries.map(\.id)).count, 3)
        XCTAssertEqual(extended.branchHash, original.branchHash); XCTAssertEqual(extended.branchReference, original.branchReference)
        XCTAssertTrue(extended.hasAddedCommits); XCTAssertTrue(extended.entries.allSatisfy { $0.action == .pick })
        do { _ = try await repo.addingRebaseCommits(extended, revisions: ["no-such-commit"]); XCTFail("Invalid additions must fail atomically") } catch RebaseFailure.revision {}
        XCTAssertEqual(original.entries.count, 1)
        extended.entries[1].action = .skip
        let result = try await repo.startRebase(extended, editorExecutable: editor); XCTAssertEqual(result.exitCode, 0, result.output)
        let subjects = try await repo.run(["log", "--format=%s", original.branchHash + "..HEAD"]).text
        XCTAssertEqual(subjects, "second\nfirst\n")
        let branch = try await repo.branch(); XCTAssertEqual(branch, "main")
    }

    func testRepeatedAddedCommitsKeepDistinctIDsAcrossEditReopeningAndContinue() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["commit", "--allow-empty", "-m", "repeatable empty"])
        let commit = try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["checkout", "main"])
        let original = try await repo.cherryPickPlan(revisions: [commit.hash])
        var plan = try await repo.addingRebaseCommits(original, revisions: [commit.hash])
        plan.entries[0].action = .edit; plan.entries[1].action = .edit
        let first = try await repo.startRebase(plan, editorExecutable: editor)
        XCTAssertEqual(first.exitCode, 0, first.output); XCTAssertTrue(first.state.active)
        XCTAssertEqual(first.state.stoppedEntryID, plan.entries[0].id)
        let reopened = GitRepository(root: root)
        let remaining = try await reopened.remainingRebaseEntries(); XCTAssertEqual(remaining.map(\.id), plan.entries.map(\.id))
        let second = try await reopened.continueRebase(); XCTAssertEqual(second.exitCode, 0, second.output); XCTAssertTrue(second.state.active)
        XCTAssertEqual(second.state.stoppedCommit, commit.hash); XCTAssertEqual(second.state.stoppedEntryID, plan.entries[1].id)
        let finalRows = try await reopened.remainingRebaseEntries(); XCTAssertEqual(finalRows.map(\.id), [plan.entries[1].id])
        let done = try await reopened.continueRebase(); XCTAssertEqual(done.exitCode, 0, done.output); XCTAssertFalse(done.state.active)
        let count = try await reopened.run(["rev-list", "--count", original.branchHash + "..HEAD"]).text; XCTAssertEqual(count, "2\n")
    }

    func testAddMakesUpToDateRebaseReplayAndPreserveMergesDisallowsAdd() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let upstream = try await repo.rebaseCommit("upstream")
        var settings = options(); settings.upstream = "main"
        let original = try await repo.rebasePlan(settings); XCTAssertEqual(original.disposition, .upToDate)
        let plan = try await repo.addingRebaseCommits(original, revisions: [upstream.hash])
        XCTAssertEqual(plan.disposition, .ready); XCTAssertFalse(plan.options.force)
        let result = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertEqual(result.exitCode, 0, result.output)
        let branch = try await repo.branch(); XCTAssertEqual(branch, "topic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("upstream.txt").path))
        settings.preserveMerges = true
        let structural = try await repo.rebasePlan(settings)
        do { _ = try await repo.addingRebaseCommits(structural, revisions: [upstream.hash]); XCTFail("Preserve Merges disables Add") } catch RebaseFailure.preservePlan {}
    }

    func testAddDraftResolvesRepeatedEntriesWithoutCapturingOrChangingReferences() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let revisions = try await repo.run(["rev-list", "main..topic"]).text.split(separator: "\n").map(String.init)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let entries = try await repo.addingRebaseEntries([], revisions: revisions)
        XCTAssertEqual(entries.map { $0.commit.subject }, ["first", "second"])
        let repeated = try await repo.addingRebaseEntries(entries, revisions: [revisions[1]])
        XCTAssertEqual(repeated.map(\.occurrence), [0, 0, 1]); XCTAssertEqual(Set(repeated.map(\.id)).count, 3)
        do { _ = try await repo.addingRebaseEntries(repeated, revisions: [revisions[0], "missing"]); XCTFail("Bad draft selection must fail atomically") } catch RebaseFailure.revision {}
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(afterHead, head); XCTAssertEqual(afterIndex, index)
        let state = try await repo.rebaseState(); XCTAssertFalse(state.active)
    }

    func testCherryPickAlreadyAppliedPatchStopsForRecoveryAndSkipKeepsTarget() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await repo.rebaseCommit("topic^")
        _ = try await repo.run(["checkout", "main"])
        _ = try await repo.run(["cherry-pick", source.hash])
        try Data("marker\n".utf8).write(to: root.appendingPathComponent("target-marker.txt"))
        try await repo.stage(["target-marker.txt"]); _ = try await repo.commit(message: "target marker")
        let plan = try await repo.cherryPickPlan(revisions: [source.hash])
        let stopped = try await repo.startRebase(plan, editorExecutable: editor)
        XCTAssertNotEqual(stopped.exitCode, 0); XCTAssertTrue(stopped.state.isCherryPick); XCTAssertTrue(stopped.state.active)
        XCTAssertTrue(stopped.state.conflicts.isEmpty); XCTAssertEqual(stopped.state.stoppedCommit, source.hash)
        XCTAssertEqual(stopped.state.stoppedEntryID, source.hash)
        let reopened = GitRepository(root: root)
        let entries = try await reopened.remainingRebaseEntries(); XCTAssertEqual(entries.map(\.id), [source.hash])
        let skipped = try await reopened.skipRebase(); XCTAssertEqual(skipped.exitCode, 0, skipped.output); XCTAssertFalse(skipped.state.active)
        let head = try await reopened.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, plan.branchHash)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("first.txt"), encoding: .utf8), "first\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target-marker.txt"), encoding: .utf8), "marker\n")
    }

    func testSquashMessageRecoveryAndAllAuthorDatePoliciesPreserveFirstAuthorAndTree() async throws {
        for policy in [RebaseSquashDate.first, .latest, .current] {
            let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let base = try await repo.rebaseCommit("HEAD")
            for (name, date, author) in [("first", "2001-01-01T01:02:03+02:00", "First Author"), ("second", "2002-02-02T02:03:04-03:00", "Second Author")] {
                try Data(name.utf8).write(to: root.appendingPathComponent(name)); try await repo.stage([name])
                _ = try await repo.run(["commit", "-m", name + "\n\n# literal message 雪"], environmentOverrides: ["GIT_AUTHOR_DATE": date, "GIT_AUTHOR_NAME": author, "GIT_AUTHOR_EMAIL": name + "@example.invalid"])
            }
            let first = try await repo.rebaseCommit("HEAD^"), last = try await repo.rebaseCommit("HEAD")
            var settings = RebaseOptions(); settings.upstream = base.hash; settings.force = true; settings.squashDate = policy
            var plan = try await repo.rebasePlan(settings); plan.entries[1].action = .squash
            let stopped = try await repo.startRebase(plan, editorExecutable: editor)
            let pending = try XCTUnwrap(stopped.state.squashMessage)
            XCTAssertTrue(stopped.state.active); XCTAssertNotEqual(stopped.exitCode, 0); XCTAssertTrue(stopped.state.conflicts.isEmpty)
            XCTAssertEqual(pending.datePolicy, policy); XCTAssertEqual(pending.latestDate, last.date)
            XCTAssertTrue(pending.message.contains("# literal message 雪")); XCTAssertFalse(pending.message.contains("This is a combination"))
            let reopened = GitRepository(root: root); let recovered = try await reopened.rebaseState()
            XCTAssertEqual(recovered.squashMessage?.message, pending.message)
            let pausedHead = try await reopened.rebaseCommit("HEAD")
            do { _ = try await reopened.continueRebase(); XCTFail("Message approval required") } catch RebaseFailure.message {}
            do { _ = try await reopened.continueRebase(squashMessage: " \n "); XCTFail("Blank message") } catch RebaseFailure.message {}
            let unchanged = try await reopened.rebaseCommit("HEAD"); XCTAssertEqual(unchanged.hash, pausedHead.hash)
            let approved = "Combined 雪\n\n# literal retained\nDetails"
            let before = Date().timeIntervalSince1970
            let done = try await reopened.continueRebase(squashMessage: approved)
            XCTAssertEqual(done.exitCode, 0, done.output); XCTAssertFalse(done.state.active); XCTAssertNil(done.state.squashMessage)
            let result = try await reopened.rebaseCommit("HEAD")
            XCTAssertEqual(result.author, first.author); XCTAssertEqual(result.email, first.email)
            switch policy {
            case .first: XCTAssertEqual(result.date, first.date)
            case .latest: XCTAssertEqual(result.date, last.date)
            case .current:
                let time = try XCTUnwrap(ISO8601DateFormatter().date(from: result.date)).timeIntervalSince1970
                XCTAssertGreaterThanOrEqual(time, before - 1); XCTAssertLessThanOrEqual(time, Date().timeIntervalSince1970 + 1)
            }
            let text = try await reopened.run(["log", "-1", "--format=%B"]).text; XCTAssertEqual(text, approved + "\n")
            let tree = try await reopened.run(["rev-parse", "HEAD^{tree}"]).text
            let expected = try await reopened.run(["rev-parse", last.hash + "^{tree}"]).text; XCTAssertEqual(tree, expected)
        }
    }

    func testConflictThenSquashMessagePauseCanAbortWithoutLosingOriginalBranch() async throws {
        let (root, repo, path) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        var plan = try await repo.rebasePlan(options()); plan.entries[1].action = .squash
        let conflict = try await repo.startRebase(plan, editorExecutable: editor)
        XCTAssertEqual(conflict.state.conflicts, [path]); XCTAssertNil(conflict.state.squashMessage)
        try Data("resolved\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        let pause = try await repo.continueRebase(); XCTAssertNotNil(pause.state.squashMessage); XCTAssertTrue(pause.state.active)
        let aborted = try await GitRepository(root: root).abortRebase(); XCTAssertEqual(aborted.exitCode, 0, aborted.output)
        let restored = try await repo.rebaseCommit("HEAD"); XCTAssertEqual(restored.hash, plan.branchHash)
        let branch = try await repo.branch(); XCTAssertEqual(branch, "topic")
    }

    func testLinkedWorktreeCherryPickSquashUsesItsOwnMessageMetadata() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let linkedRoot = root.appendingPathComponent("linked")
        _ = try await repo.run(["worktree", "add", "--detach", linkedRoot.path, "main"])
        let linked = GitRepository(root: linkedRoot)
        let newest = try await repo.rebaseCommit("topic"), older = try await repo.rebaseCommit("topic^")
        var plan = try await linked.cherryPickPlan(revisions: [newest.hash, older.hash]); plan.entries[1].action = .squash
        let stopped = try await linked.startRebase(plan, editorExecutable: editor); XCTAssertNotNil(stopped.state.squashMessage)
        let mainState = try await repo.rebaseState(); XCTAssertFalse(mainState.active)
        let done = try await GitRepository(root: linkedRoot).continueRebase(squashMessage: "Linked combined message")
        XCTAssertEqual(done.exitCode, 0, done.output); XCTAssertFalse(done.state.active)
        let text = try await linked.run(["log", "-1", "--format=%s"]).text; XCTAssertEqual(text, "Linked combined message\n")
    }

    func testTwoSquashGroupsRequireSeparateApprovalsAndEditMessageIsKept() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["third", "fourth"] {
            try Data(name.utf8).write(to: root.appendingPathComponent(name)); try await repo.stage([name]); _ = try await repo.commit(message: name)
        }
        var plan = try await repo.rebasePlan(options())
        plan.entries[0].action = .edit; plan.entries[1].action = .squash; plan.entries[3].action = .squash
        let edit = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertTrue(edit.state.active); XCTAssertNil(edit.state.squashMessage)
        _ = try await repo.amendRebaseCommit(message: "Edited first\n\n# retained first body")
        let first = try await repo.continueRebase()
        let request = try XCTUnwrap(first.state.squashMessage); XCTAssertTrue(request.message.contains("Edited first")); XCTAssertTrue(request.message.contains("# retained first body"))
        let second = try await repo.continueRebase(squashMessage: "Approved group one")
        XCTAssertTrue(second.state.active); XCTAssertNotNil(second.state.squashMessage)
        XCTAssertTrue(second.state.squashMessage!.message.contains("third")); XCTAssertTrue(second.state.squashMessage!.message.contains("fourth"))
        XCTAssertFalse(second.state.squashMessage!.message.contains("Approved group one"))
        let done = try await GitRepository(root: root).continueRebase(squashMessage: "Approved group two")
        XCTAssertEqual(done.exitCode, 0, done.output); XCTAssertFalse(done.state.active)
        let subjects = try await repo.run(["log", "-2", "--format=%s"]).text; XCTAssertEqual(subjects, "Approved group two\nApproved group one\n")
        let count = try await repo.run(["rev-list", "--count", "upstream..topic"]).text; XCTAssertEqual(count, "2\n")
    }

    func testSquashApprovalHookFailureRetainsAttemptedDraftAndUnchangedHead() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var plan = try await repo.rebasePlan(options()); plan.entries[1].action = .squash
        let pause = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertNotNil(pause.state.squashMessage)
        let head = try await repo.rebaseCommit("HEAD")
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        do { _ = try await repo.continueRebase(squashMessage: "Attempted draft 雪"); XCTFail("Hook failure must stop approval") } catch is GitFailure {}
        let reopened = GitRepository(root: root), state = try await reopened.rebaseState()
        XCTAssertTrue(state.active); XCTAssertEqual(state.squashMessage?.message, "Attempted draft 雪")
        let unchanged = try await reopened.rebaseCommit("HEAD"); XCTAssertEqual(unchanged.hash, head.hash)
        try FileManager.default.removeItem(at: hook)
        let done = try await reopened.continueRebase(squashMessage: state.squashMessage!.message)
        XCTAssertEqual(done.exitCode, 0, done.output); XCTAssertFalse(done.state.active)
    }

    func testSkippingSquashCannotExposeItsOldRequestAtLaterEditStep() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("third\n".utf8).write(to: root.appendingPathComponent("third.txt")); try await repo.stage(["third.txt"]); _ = try await repo.commit(message: "third")
        var plan = try await repo.rebasePlan(options()); plan.entries[1].action = .squash; plan.entries[2].action = .edit
        let pause = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertNotNil(pause.state.squashMessage)
        let skipped = try await repo.skipRebase(); XCTAssertTrue(skipped.state.active); XCTAssertEqual(skipped.state.currentStep, 3); XCTAssertNil(skipped.state.squashMessage)
        let reopened = GitRepository(root: root), state = try await reopened.rebaseState(); XCTAssertNil(state.squashMessage)
        let done = try await reopened.continueRebase(); XCTAssertEqual(done.exitCode, 0, done.output); XCTAssertFalse(done.state.active)
    }

    func testSplitFirstParentSelectionAndLaterCommitResumeAsThreeCommits() async throws {
        let (root, repo, plan) = try await splitFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pause = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertTrue(pause.state.canSplit)
        let startingHead = try await repo.rebaseCommit("HEAD")
        let split = try await repo.beginRebaseSplit(); XCTAssertEqual(split.parts, 0)
        let unchanged = try await repo.rebaseCommit("HEAD"); XCTAssertEqual(unchanged.hash, startingHead.hash)
        var firstOptions = CommitOptions(); firstOptions.amend = true; firstOptions.amendDiffToLastCommit = false
        _ = try await repo.commitRebaseSplit(message: "left part", paths: ["left 雪\n.txt"], staging: false, options: firstOptions, expected: split)
        let first = try await repo.run(["ls-tree", "--name-only", "HEAD"]).text; XCTAssertTrue(first.contains("left")); XCTAssertFalse(first.contains("right.txt"))
        do { _ = try await repo.commitRebaseSplit(message: "stale", paths: ["right.txt"], staging: false, options: firstOptions, expected: split); XCTFail("Stale part") } catch RebaseFailure.changed {}
        let reopened = GitRepository(root: root), recovered = try await reopened.rebaseState()
        XCTAssertEqual(recovered.split?.parts, 1); let remaining = try await reopened.rebaseSplitHasRemainingChanges(); XCTAssertTrue(remaining)
        do { _ = try await reopened.continueRebase(); XCTFail("Uncommitted tracked parts") } catch RebaseFailure.plan {}
        _ = try await reopened.commitRebaseSplit(message: "right part", paths: ["right.txt"], staging: false, options: CommitOptions(), expected: recovered.split!)
        let done = try await reopened.continueRebase(); XCTAssertEqual(done.exitCode, 0, done.output); XCTAssertFalse(done.state.active)
        let log = try await reopened.run(["log", "-3", "--format=%s"]).text; XCTAssertEqual(log, "future\nright part\nleft part\n")
        let count = try await reopened.run(["rev-list", "--count", "upstream..topic"]).text; XCTAssertEqual(count, "3\n")
        for name in ["left 雪\n.txt", "right.txt", "future.txt", "upstream.txt"] { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
    }

    func testUnstartedSplitCancelAndMultilineEditContinueLeaveReplayUsable() async throws {
        let (root, repo, plan) = try await splitFixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.startRebase(plan, editorExecutable: editor)
        let original = try await repo.rebaseCommit("HEAD")
        _ = try await repo.beginRebaseSplit(); try await repo.cancelUnstartedRebaseSplit()
        let state = try await repo.rebaseState(); XCTAssertNil(state.split); XCTAssertTrue(state.canSplit)
        let unchanged = try await repo.rebaseCommit("HEAD"); XCTAssertEqual(unchanged.hash, original.hash)
        do { _ = try await repo.continueRebase(editMessage: " \n "); XCTFail("Blank edit") } catch RebaseFailure.message {}
        let done = try await repo.continueRebase(editMessage: "Edited first 雪\n\nMultiline body")
        XCTAssertEqual(done.exitCode, 0, done.output); XCTAssertFalse(done.state.active)
        let text = try await repo.run(["log", "-1", "--format=%B", "HEAD^"]).text; XCTAssertTrue(text.contains("Edited first 雪\n\nMultiline body"))
    }

    func testSplitAbortRestoresOriginalBranchAfterPartialAmend() async throws {
        let (root, repo, plan) = try await splitFixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.startRebase(plan, editorExecutable: editor); let split = try await repo.beginRebaseSplit()
        var options = CommitOptions(); options.amend = true; options.amendDiffToLastCommit = false
        _ = try await repo.commitRebaseSplit(message: "partial", paths: ["left 雪\n.txt"], staging: false, options: options, expected: split)
        let aborted = try await GitRepository(root: root).abortRebase(); XCTAssertEqual(aborted.exitCode, 0, aborted.output)
        let restored = try await repo.rebaseCommit("HEAD"); XCTAssertEqual(restored.hash, plan.branchHash)
        let branch = try await repo.branch(); XCTAssertEqual(branch, "topic")
    }

    func testSquashSplitConsumesPendingMessageThenContinuesWithoutSecondAmend() async throws {
        let (root, repo, original) = try await splitFixture(); defer { try? FileManager.default.removeItem(at: root) }
        var plan = original; plan.entries[0].action = .pick; plan.entries[1].action = .squash
        let pause = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertNotNil(pause.state.squashMessage); XCTAssertTrue(pause.state.canSplit)
        let split = try await repo.beginRebaseSplit(); var options = CommitOptions(); options.amend = true; options.amendDiffToLastCommit = false
        _ = try await repo.commitRebaseSplit(message: "squash left", paths: ["left 雪\n.txt"], staging: false, options: options, expected: split)
        let state = try await repo.rebaseState(); XCTAssertNil(state.squashMessage); XCTAssertEqual(state.split?.parts, 1)
        _ = try await repo.commitRebaseSplit(message: "squash remainder", paths: ["right.txt", "future.txt"], staging: false, options: CommitOptions(), expected: state.split!)
        let done = try await repo.continueRebase(); XCTAssertEqual(done.exitCode, 0, done.output); XCTAssertFalse(done.state.active)
        let log = try await repo.run(["log", "-2", "--format=%s"]).text; XCTAssertEqual(log, "squash remainder\nsquash left\n")
    }

    func testConflictedEditCannotSplitBeforeItsCommitIsApplied() async throws {
        let (root, repo, path) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        var plan = try await repo.rebasePlan(options()); plan.entries[0].action = .edit
        let stopped = try await repo.startRebase(plan, editorExecutable: editor)
        XCTAssertTrue(stopped.state.needsFileRecovery); XCTAssertFalse(stopped.state.isEditPause); XCTAssertFalse(stopped.state.canSplit)
        try Data("resolved\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        let resolved = try await GitRepository(root: root).rebaseState()
        XCTAssertTrue(resolved.needsFileRecovery); XCTAssertTrue(resolved.conflicts.isEmpty); XCTAssertFalse(resolved.isEditPause); XCTAssertFalse(resolved.canSplit)
        let head = try await repo.rebaseCommit("HEAD")
        do { _ = try await repo.beginRebaseSplit(); XCTFail("Edit has not been applied") } catch RebaseFailure.plan {}
        let unchanged = try await repo.rebaseCommit("HEAD"); XCTAssertEqual(unchanged.hash, head.hash)
        let done = try await repo.continueRebase(editMessage: "Must not amend destination")
        XCTAssertEqual(done.exitCode, 0, done.output); XCTAssertFalse(done.state.active)
        let message = try await repo.run(["log", "-1", "--format=%s", "upstream"]).text; XCTAssertEqual(message, "upstream\n")
    }

}
