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
        let result = try await repo.startRebase(plan, editorExecutable: editor); XCTAssertEqual(result.exitCode, 0, result.output)
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

}
