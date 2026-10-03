import XCTest
@testable import TurtleGitCore

final class PullTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, GitRepository, GitRepository, String) {
        let (root, publisher, remote, consumer, path) = try await FetchTests().fixture()
        _ = try await consumer.run(["config", "user.name", "Pull Tests"])
        _ = try await consumer.run(["config", "user.email", "pull@example.invalid"])
        _ = try await consumer.run(["config", "commit.gpgsign", "false"])
        _ = try await consumer.run(["config", "pull.rebase", "false"])
        return (root, publisher, remote, consumer, path)
    }
    func publish(_ root: URL, _ publisher: GitRepository, name: String = "remote.txt", text: String = "remote\n") async throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name)); try await publisher.stage([name]); _ = try await publisher.commit(message: "remote change"); _ = try await publisher.run(["push", "origin", "main"])
    }
    func options() -> PullOptions { var o = PullOptions(); o.fetch.remote = "origin"; o.fetch.branch = "main"; return o }
    func testFastForwardUpdatesHeadAndTrackingWithoutTouchingUnrelatedMixedChanges() async throws {
        let (root, publisher, _, consumer, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("staged\n".utf8).write(to: consumer.root.appendingPathComponent(path)); try await consumer.stage([path]); try Data("later\n".utf8).write(to: consumer.root.appendingPathComponent(path))
        let index = try await consumer.diff(staged: true), working = try await consumer.diff()
        try await publish(root, publisher)
        var o = options(); o.fastForwardOnly = true; _ = try await consumer.pull(o)
        let head = try await consumer.run(["rev-parse", "HEAD"]).text, expected = try await publisher.run(["rev-parse", "HEAD"]).text
        let tracking = try await consumer.run(["rev-parse", "refs/remotes/origin/main"]).text
        let afterIndex = try await consumer.diff(staged: true), afterWorking = try await consumer.diff()
        XCTAssertEqual(head, expected); XCTAssertEqual(tracking, expected); XCTAssertEqual(index, afterIndex); XCTAssertEqual(working, afterWorking)
    }
    func testNoFastForwardCreatesMergeAndNoCommitStopsBeforeCommit() async throws {
        let (root, publisher, _, consumer, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try await consumer.run(["rev-parse", "HEAD"]).text
        try await publish(root, publisher)
        var o = options(); o.noFastForward = true; o.noCommit = true; _ = try await consumer.pull(o)
        let head = try await consumer.run(["rev-parse", "HEAD"]).text, merge = try await consumer.run(["rev-parse", "MERGE_HEAD"]).text, expected = try await publisher.run(["rev-parse", "HEAD"]).text
        XCTAssertEqual(head, old); XCTAssertEqual(merge, expected)
        let staged = try await consumer.diff(staged: true); XCTAssertTrue(staged.contains("remote.txt"))
        _ = try await consumer.commit(message: "Complete pull merge")
        let parents = try await consumer.run(["rev-list", "--parents", "-n", "1", "HEAD"]).text.split(separator: " "); XCTAssertEqual(parents.count, 3)
        try await publish(root, publisher, name: "next.txt")
        o.noCommit = false; _ = try await consumer.pull(o)
        let nextParents = try await consumer.run(["rev-list", "--parents", "-n", "1", "HEAD"]).text.split(separator: " "); XCTAssertEqual(nextParents.count, 3)
    }
    func testSquashStagesChangesWithoutHeadOrMergeHead() async throws {
        let (root, publisher, _, consumer, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try await consumer.run(["rev-parse", "HEAD"]).text
        try await publish(root, publisher)
        var o = options(); o.squash = true; _ = try await consumer.pull(o)
        let head = try await consumer.run(["rev-parse", "HEAD"]).text, staged = try await consumer.diff(staged: true)
        XCTAssertEqual(head, old); XCTAssertTrue(staged.contains("remote.txt"))
        do { _ = try await consumer.run(["rev-parse", "--verify", "MERGE_HEAD"]); XCTFail("Squash must not set MERGE_HEAD") } catch is GitFailure {}
    }
    func testDivergedFastForwardRejectsThenMergeLeavesResolvableConflict() async throws {
        let (root, publisher, _, consumer, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("local conflict\n".utf8).write(to: consumer.root.appendingPathComponent(path)); try await consumer.stage([path]); _ = try await consumer.commit(message: "local")
        let old = try await consumer.run(["rev-parse", "HEAD"]).text
        try await publish(root, publisher, name: path, text: "remote conflict\n")
        var o = options(); o.fastForwardOnly = true
        do { _ = try await consumer.pull(o); XCTFail("Divergence must reject ff-only") } catch is GitFailure {}
        let rejected = try await consumer.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(old, rejected)
        o.fastForwardOnly = false
        do { _ = try await consumer.pull(o); XCTFail("Merge must expose conflict") } catch is GitFailure {}
        let unmerged = try await consumer.run(["ls-files", "-u"]).text; XCTAssertFalse(unmerged.isEmpty)
        let merge = try await consumer.run(["rev-parse", "MERGE_HEAD"]).text, expected = try await publisher.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(merge, expected)
        _ = try await consumer.run(["merge", "--abort"])
        let restored = try await consumer.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(restored, old)
    }
    func testURLBranchSelectionAndConfiguredRebaseDoesNotMutate() async throws {
        let (root, publisher, remote, consumer, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await publish(root, publisher)
        let old = try await consumer.run(["rev-parse", "HEAD"]).text
        _ = try await consumer.run(["config", "branch.main.rebase", "merges"])
        var o = options()
        do { _ = try await consumer.pull(o); XCTFail("Configured interactive workflow is required") } catch PullFailure.rebaseWorkflow {}
        let blocked = try await consumer.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(blocked, old)
        _ = try await consumer.run(["config", "branch.main.rebase", "false"])
        let defaults = try await consumer.pullDefaults(); XCTAssertFalse(defaults.rebase); XCTAssertEqual(defaults.trackedRemote, "origin"); XCTAssertEqual(defaults.trackedBranch, "main")
        _ = try await consumer.run(["config", "branch.main.rebase", "merges"])
        o.fetch.arbitraryURL = true; o.fetch.remote = remote.root.path; _ = try await consumer.pull(o)
        let head = try await consumer.run(["rev-parse", "HEAD"]).text, expected = try await publisher.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(head, expected)
        o.noFastForward = true; o.fastForwardOnly = true
        do { _ = try await consumer.pull(o); XCTFail("Incompatible flags") } catch PullFailure.combination {}
        o.noFastForward = false; o.fetch.branch = "main:refs/heads/injected"
        do { _ = try await consumer.pull(o); XCTFail("Invalid branch") } catch FetchFailure.branch {}
    }
}
