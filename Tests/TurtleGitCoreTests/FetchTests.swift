import XCTest
@testable import TurtleGitCore

final class FetchTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, GitRepository, GitRepository, String) {
        let (root, publisher, remote, path) = try await PushTests().fixture()
        var push = PushOptions(); push.remote = "origin"; push.source = "refs/heads/main"; _ = try await publisher.push(push)
        let destination = root.appendingPathComponent("consumer")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let consumer = GitRepository(root: destination)
        _ = try await consumer.run(["clone", "--branch", "main", "--", remote.root.path, "."])
        return (root, publisher, remote, consumer, path)
    }
    func testFetchRebasePinsSelectedBranchAndPreservesDirtyWorktree() async throws {
        let (root, publisher, _, consumer, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let beforeHead = try await consumer.run(["rev-parse", "HEAD"]).text
        try Data("index\n".utf8).write(to: consumer.root.appendingPathComponent(path)); try await consumer.stage([path])
        try Data("worktree\n".utf8).write(to: consumer.root.appendingPathComponent(path))
        let beforeIndex = try await consumer.diff(staged: true), beforeWorking = try await consumer.diff()
        try Data("remote\n".utf8).write(to: root.appendingPathComponent(path)); try await publisher.stage([path]); _ = try await publisher.commit(message: "remote advancement")
        _ = try await publisher.run(["branch", "topic/雪"]); _ = try await publisher.run(["push", "origin", "main", "topic/雪"])
        // A custom refspec must not accidentally select a stale conventional ref.
        _ = try await consumer.run(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/custom/*"])
        var options = FetchOptions(); options.remote = "origin"; options.branch = "topic/雪"
        let result = try await consumer.fetchForRebase(options)
        let expected = try await publisher.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(result.upstream, expected)
        _ = try await publisher.run(["checkout", "-b", "later"])
        try Data("later\n".utf8).write(to: root.appendingPathComponent(path)); try await publisher.stage([path]); _ = try await publisher.commit(message: "later target")
        _ = try await publisher.run(["push", "origin", "later"])
        options.branch = "later"; let later = try await consumer.fetchForRebase(options)
        XCTAssertNotEqual(result.upstream, later.upstream)
        let afterHead = try await consumer.run(["rev-parse", "HEAD"]).text
        let afterIndex = try await consumer.diff(staged: true), afterWorking = try await consumer.diff()
        XCTAssertEqual(beforeHead, afterHead); XCTAssertEqual(beforeIndex, afterIndex); XCTAssertEqual(beforeWorking, afterWorking)
        options.allRemotes = true
        do { _ = try await consumer.fetchForRebase(options); XCTFail("Ambiguous destination") } catch FetchRebaseFailure.destination {}
        options.allRemotes = false; options.branch = ""
        do { _ = try await consumer.fetchForRebase(options); XCTFail("Missing branch") } catch FetchRebaseFailure.destination {}
        options.branch = "missing"
        do { _ = try await consumer.fetchForRebase(options); XCTFail("Must not reuse stale FETCH_HEAD on failed fetch") } catch {}
    }
    func testFetchRebasePlanReplaysOntoFetchedCommitAndRejectsActiveSession() async throws {
        let (root, publisher, remote, consumer, _) = try await PullTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("local\n".utf8).write(to: consumer.root.appendingPathComponent("local.txt")); try await consumer.stage(["local.txt"]); _ = try await consumer.commit(message: "local topic")
        try Data("remote\n".utf8).write(to: root.appendingPathComponent("remote.txt")); try await publisher.stage(["remote.txt"]); _ = try await publisher.commit(message: "remote topic")
        _ = try await publisher.run(["push", "origin", "main"])
        _ = try await consumer.run(["config", "pull.rebase", "merges"])
        var defaults = try await consumer.pullDefaults(); XCTAssertTrue(defaults.rebase); XCTAssertTrue(defaults.preserveMerges)
        _ = try await consumer.run(["config", "branch.main.rebase", "false"])
        defaults = try await consumer.pullDefaults(); XCTAssertFalse(defaults.rebase); XCTAssertFalse(defaults.preserveMerges)
        var fetch = FetchOptions(); fetch.remote = "origin"; fetch.branch = "main"
        let fetched = try await consumer.fetchForRebase(fetch)
        var options = RebaseOptions(); options.branch = "main"; options.upstream = fetched.upstream
        var plan = try await consumer.rebasePlan(options); plan.entries[0].action = .edit
        let result = try await consumer.startRebase(plan, editorExecutable: RebaseTests().editor)
        XCTAssertEqual(result.exitCode, 0, result.output); XCTAssertTrue(result.state.active)
        let before = try await consumer.run(["rev-parse", "FETCH_HEAD"]).text
        fetch.remote = remote.root.path; fetch.arbitraryURL = true
        do { _ = try await consumer.fetchForRebase(fetch); XCTFail("Active session must prevent another fetch") } catch FetchRebaseFailure.active {}
        let after = try await consumer.run(["rev-parse", "FETCH_HEAD"]).text; XCTAssertEqual(before, after)
        let completed = try await consumer.continueRebase(); XCTAssertEqual(completed.exitCode, 0, completed.output)
        let parent = try await consumer.run(["rev-parse", "HEAD^"]).text.trimmingCharacters(in: .newlines)
        let branch = try await consumer.branch(); XCTAssertEqual(branch, "main"); XCTAssertEqual(parent, fetched.upstream)
        XCTAssertTrue(FileManager.default.fileExists(atPath: consumer.root.appendingPathComponent("local.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: consumer.root.appendingPathComponent("remote.txt").path))
    }
    func testConfiguredFetchUpdatesTrackingRefsWithoutChangingHeadIndexOrWorktree() async throws {
        let (root, publisher, _, consumer, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let originalHead = try await consumer.run(["rev-parse", "HEAD"]).text
        try Data("staged\n".utf8).write(to: consumer.root.appendingPathComponent(path)); try await consumer.stage([path])
        try Data("working\n".utf8).write(to: consumer.root.appendingPathComponent(path))
        let beforeIndex = try await consumer.diff(staged: true), beforeWorking = try await consumer.diff()
        try Data("publisher next\n".utf8).write(to: root.appendingPathComponent(path)); try await publisher.stage([path]); _ = try await publisher.commit(message: "next")
        _ = try await publisher.run(["branch", "topic"])
        _ = try await publisher.run(["push", "origin", "main", "topic"])
        var options = FetchOptions(); options.remote = "origin"; options.branch = "does-not-exist-but-is-ignored-for-configured-fetch"
        _ = try await consumer.fetch(options)
        let tracking = try await consumer.run(["rev-parse", "refs/remotes/origin/main"]).text
        let expected = try await publisher.run(["rev-parse", "HEAD"]).text
        let head = try await consumer.run(["rev-parse", "HEAD"]).text
        let topic = try await consumer.run(["rev-parse", "refs/remotes/origin/topic"]).text
        let afterIndex = try await consumer.diff(staged: true), afterWorking = try await consumer.diff()
        XCTAssertEqual(tracking, expected); XCTAssertEqual(topic, expected); XCTAssertEqual(head, originalHead)
        XCTAssertEqual(beforeIndex, afterIndex); XCTAssertEqual(beforeWorking, afterWorking)
        let defaults = try await consumer.fetchDefaults(); XCTAssertEqual(defaults.remote, "origin"); XCTAssertEqual(defaults.branch, "main"); XCTAssertFalse(defaults.bare)
    }
    func testTagAndPruneThreeStateOverridesRespectConfiguration() async throws {
        let (root, publisher, _, consumer, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await publisher.run(["tag", "release"]); _ = try await publisher.run(["branch", "topic"]); _ = try await publisher.run(["push", "origin", "--tags", "main", "topic"])
        _ = try await consumer.run(["config", "remote.origin.tagopt", "--no-tags"])
        var options = FetchOptions(); options.remote = "origin"
        _ = try await consumer.fetch(options)
        var refs = try await consumer.checkoutReferences(); XCTAssertFalse(refs.contains { $0.name == "refs/tags/release" })
        options.tags = .enabled; _ = try await consumer.fetch(options)
        refs = try await consumer.checkoutReferences(); XCTAssertTrue(refs.contains { $0.name == "refs/tags/release" })
        _ = try await publisher.run(["push", "origin", ":refs/heads/topic"])
        _ = try await consumer.run(["config", "fetch.prune", "true"])
        options.prune = .disabled; _ = try await consumer.fetch(options)
        refs = try await consumer.checkoutReferences(); XCTAssertTrue(refs.contains { $0.name == "refs/remotes/origin/topic" })
        options.prune = .configured; _ = try await consumer.fetch(options)
        refs = try await consumer.checkoutReferences(); XCTAssertFalse(refs.contains { $0.name == "refs/remotes/origin/topic" })
        let defaults = try await consumer.fetchDefaults(); XCTAssertEqual(defaults.tags, "None"); XCTAssertEqual(defaults.prune, "true")
        _ = try await publisher.run(["tag", "another"]); _ = try await publisher.run(["push", "origin", "--tags"])
        _ = try await consumer.run(["config", "remote.origin.tagopt", "--tags"])
        options.tags = .disabled; _ = try await consumer.fetch(options)
        refs = try await consumer.checkoutReferences(); XCTAssertFalse(refs.contains { $0.name == "refs/tags/another" })
        options.tags = .configured; _ = try await consumer.fetch(options)
        refs = try await consumer.checkoutReferences(); XCTAssertTrue(refs.contains { $0.name == "refs/tags/another" })
    }
    func testArbitraryURLBranchBrowseAndShallowDepth() async throws {
        let (root, publisher, remote, consumer, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for n in 1...3 { try Data("next \(n)\n".utf8).write(to: root.appendingPathComponent(path)); try await publisher.stage([path]); _ = try await publisher.commit(message: "next \(n)") }
        _ = try await publisher.run(["branch", "topic/雪"]); _ = try await publisher.run(["push", "origin", "main", "topic/雪"])
        let branches = try await consumer.remoteBranches(remote: remote.root.path); XCTAssertEqual(branches, ["main", "topic/雪"])
        var options = FetchOptions(); options.arbitraryURL = true; options.remote = remote.root.absoluteString; options.branch = "topic/雪"; options.depth = 1; options.tags = .disabled
        let before = try await consumer.run(["rev-parse", "HEAD"]).text
        _ = try await consumer.fetch(options)
        let fetched = try await consumer.run(["rev-parse", "FETCH_HEAD"]).text, expected = try await publisher.run(["rev-parse", "HEAD"]).text
        let after = try await consumer.run(["rev-parse", "HEAD"]).text
        let count = try await consumer.run(["rev-list", "--count", "FETCH_HEAD"]).text
        XCTAssertEqual(fetched, expected); XCTAssertEqual(before, after); XCTAssertEqual(count, "1\n")
        let defaults = try await consumer.fetchDefaults(); XCTAssertTrue(defaults.shallow)
        options.depth = 2; _ = try await consumer.fetch(options)
        let deeper = try await consumer.run(["rev-list", "--count", "FETCH_HEAD"]).text; XCTAssertEqual(deeper, "2\n")
    }
    func testAllRemotesAndInvalidRequests() async throws {
        let (root, publisher, remote, consumer, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await consumer.saveRemote(name: "second", fetchURL: remote.root.path, pushURL: "", existing: false)
        try await publisher.saveRemote(name: "second", fetchURL: remote.root.path, pushURL: "", existing: false)
        let untrackedDefaults = try await publisher.fetchDefaults(); XCTAssertEqual(untrackedDefaults.remote, "")
        var options = FetchOptions(); options.allRemotes = true
        _ = try await consumer.fetch(options)
        let refs = try await consumer.checkoutReferences(); XCTAssertTrue(refs.contains { $0.name == "refs/remotes/second/main" })
        options.arbitraryURL = true
        do { _ = try await consumer.fetch(options); XCTFail("Invalid destination combination") } catch FetchFailure.remote {}
        options.allRemotes = false; options.remote = remote.root.path; options.depth = 0
        do { _ = try await consumer.fetch(options); XCTFail("Invalid depth") } catch FetchFailure.depth {}
        options.depth = nil; options.branch = "main:refs/heads/main"
        do { _ = try await consumer.fetch(options); XCTFail("Refspec injection") } catch FetchFailure.branch {}
        options.branch = ""; options.arbitraryURL = false; options.remote = "unknown"
        do { _ = try await consumer.fetch(options); XCTFail("Unknown remote") } catch FetchFailure.remote {}
    }
}
