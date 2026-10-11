import XCTest
@testable import TurtleGitCore

final class SynchronizationTransportTests: XCTestCase {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [GitOutputChunk] = []
        func append(_ chunk: GitOutputChunk) { lock.lock(); defer { lock.unlock() }; chunks.append(chunk) }
        func bytes(_ stream: GitOutputChunk.Stream) -> Data {
            lock.lock(); defer { lock.unlock() }
            return chunks.filter { $0.stream == stream }.reduce(into: Data()) { $0.append($1.data) }
        }
    }
    private struct Fixture {
        let directory: URL
        let server: GitRepository
        let author: GitRepository
        let client: GitRepository
        let base: String
    }
    private func hash(_ repo: GitRepository, _ revision: String = "HEAD") async throws -> String {
        String(decoding: try await repo.run(["rev-parse", "--verify", "--end-of-options", revision]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-sync-transport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let git = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/git")
        let parent = GitRepository(root: directory, executable: git)
        let server = GitRepository(root: directory.appendingPathComponent("server 雪.git"), executable: git)
        let author = GitRepository(root: directory.appendingPathComponent("author"), executable: git)
        let client = GitRepository(root: directory.appendingPathComponent("client"), executable: git)
        _ = try await parent.run(["init", "--template=", "--bare", "-b", "main", server.root.path])
        _ = try await server.run(["config", "core.hooksPath", "/dev/null"])
        _ = try await parent.run(["init", "--template=", "-b", "main", author.root.path])
        for (key, value) in [("user.name", "Sync QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await author.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: author.root.appendingPathComponent("file"))
        try await author.stage(["file"]); _ = try await author.commit(message: "base")
        _ = try await author.run(["remote", "add", "origin", server.root.path]); _ = try await author.run(["push", "-u", "origin", "main"])
        _ = try await parent.run(["clone", "--template=", "--", server.root.path, client.root.path])
        for (key, value) in [("user.name", "Sync QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("pull.rebase", "false"), ("pull.ff", "only")] { _ = try await client.run(["config", key, value]) }
        return Fixture(directory: directory, server: server, author: author, client: client, base: try await hash(client))
    }
    private func options(_ action: SynchronizationTransportAction) -> SynchronizationTransportOptions {
        var value = SynchronizationTransportOptions(action: action); value.localBranch = "main"; value.remote = "origin"; value.remoteBranch = "main"; return value
    }
    private func advance(_ fixture: Fixture) async throws -> String {
        try Data("remote change\n".utf8).write(to: fixture.author.root.appendingPathComponent("incoming 雪.txt"))
        try await fixture.author.stage(["incoming 雪.txt"]); _ = try await fixture.author.commit(message: "incoming")
        _ = try await fixture.author.run(["push", "origin", "main"])
        return try await hash(fixture.author)
    }
    func testSourceCommandPlansAndReadOnlyMetadata() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.client.run(["remote", "add", "second", f.server.root.path])
        _ = try await f.client.run(["config", "core.notesRef", "refs/notes/review"])
        let notes = String(decoding: try await f.client.run(["notes", "get-ref"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")), config = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")), refs = try await f.client.run(["show-ref"]).stdout
        for action in [SynchronizationTransportAction.fetch, .fetchAndRebase] {
            let plan = try await f.client.synchronizationTransportPlan(options(action))
            XCTAssertEqual(plan.arguments, ["fetch", "--progress", "-v", "--", "origin", "main:remotes/origin/main"])
            XCTAssertEqual(plan.oldHead, f.base); XCTAssertEqual(plan.oldRemoteHash, f.base)
            XCTAssertEqual(plan.rebaseMode, action == .fetch ? .none : .choose)
        }
        var fetch = options(.fetch); fetch.remoteBranch = " missing \t"; fetch.fetchVerbose = false; fetch.force = true
        let missingPlan = try await f.client.synchronizationTransportPlan(fetch)
        XCTAssertEqual(missingPlan.arguments, ["fetch", "--progress", "--force", "--", "origin", "missing"])
        let all = try await f.client.synchronizationTransportPlan(options(.fetchAllBranches))
        XCTAssertEqual(all.arguments, ["fetch", "--progress", "-v", "--", "origin"]); XCTAssertNil(all.oldRemoteHash)
        let update = try await f.client.synchronizationTransportPlan(options(.remoteUpdate))
        XCTAssertEqual(update.arguments, ["remote", "update"]); XCTAssertEqual(update.transportRemotes, ["origin", "second"])
        let prune = try await f.client.synchronizationTransportPlan(options(.prune))
        XCTAssertEqual(prune.arguments, ["remote", "prune", "--", "origin"])
        let pull = try await f.client.synchronizationTransportPlan(options(.pull))
        XCTAssertEqual(pull.arguments, ["pull", "-v", "--progress", "--", "origin"]); XCTAssertNil(pull.checkoutBranch)
        var url = options(.pull); url.remote = f.server.root.path
        let urlPlan = try await f.client.synchronizationTransportPlan(url)
        XCTAssertEqual(urlPlan.arguments, ["pull", "-v", "--progress", "--", f.server.root.path, "main"])
        for action in [SynchronizationTransportAction.push, .pushTags, .pushNotes] {
            var input = options(action); input.force = true; input.remoteBranch = "review"
            var expected = ["push", "-v", "--progress"]
            if action == .pushTags { expected.append("--tags") }; expected += ["--force", "--", "origin", action == .pushNotes ? notes : "main:review"]
            let plan = try await f.client.synchronizationTransportPlan(input)
            XCTAssertEqual(plan.arguments, expected)
        }
        let after = try await f.client.run(["show-ref"]).stdout
        XCTAssertEqual(after, refs); XCTAssertEqual(try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")), index); XCTAssertEqual(try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")), config)
    }
    func testFetchExistingTrackingRefAndForcePreserveLocalWork() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let tip = try await advance(f)
        try Data("staged\n".utf8).write(to: f.client.root.appendingPathComponent("file")); try await f.client.stage(["file"])
        try Data("unstaged\n".utf8).write(to: f.client.root.appendingPathComponent("file"))
        let index = try Data(contentsOf: f.client.root.appendingPathComponent(".git/index"))
        let plan = try await f.client.synchronizationTransportPlan(options(.fetch))
        let output = Output()
        let result = try await f.client.synchronize(plan, onOutput: { output.append($0) })
        XCTAssertEqual(result.command.exitCode, 0); XCTAssertNil(result.rebaseTarget)
        XCTAssertFalse(output.bytes(.stderr).isEmpty); XCTAssertEqual(output.bytes(.stderr), result.command.stderr)
        XCTAssertEqual(output.bytes(.stdout), result.command.stdout)
        let fetched = try await hash(f.client, "refs/remotes/origin/main"); XCTAssertEqual(fetched, tip)
        _ = try await f.server.run(["update-ref", "refs/heads/main", f.base])
        let rejected = try await f.client.synchronizationTransportPlan(options(.fetch))
        do { _ = try await f.client.synchronize(rejected); XCTFail("non-fast-forward accepted") } catch is GitFailure {}
        var forced = options(.fetch); forced.force = true
        _ = try await f.client.synchronize(f.client.synchronizationTransportPlan(forced))
        let rewound = try await hash(f.client, "refs/remotes/origin/main"), head = try await hash(f.client)
        XCTAssertEqual(rewound, f.base); XCTAssertEqual(head, f.base)
        XCTAssertEqual(try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try String(contentsOf: f.client.root.appendingPathComponent("file")), "unstaged\n")
    }
    func testPushTagsIncludesBranchAndNotesIgnoresDestination() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try Data("local\n".utf8).write(to: f.client.root.appendingPathComponent("local")); try await f.client.stage(["local"]); _ = try await f.client.commit(message: "local")
        let tip = try await hash(f.client)
        _ = try await f.client.run(["tag", "review-tag"])
        var tags = options(.pushTags); tags.remoteBranch = "review"
        _ = try await f.client.synchronize(f.client.synchronizationTransportPlan(tags))
        let branch = try await hash(f.server, "refs/heads/review"), tag = try await hash(f.server, "refs/tags/review-tag")
        XCTAssertEqual(branch, tip); XCTAssertEqual(tag, tip)
        _ = try await f.client.run(["config", "core.notesRef", "refs/notes/review"])
        _ = try await f.client.run(["notes", "add", "-m", "review note", tip])
        let notesRef = String(decoding: try await f.client.run(["notes", "get-ref"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        var notes = options(.pushNotes); notes.remoteBranch = "must-not-be-used"
        _ = try await f.client.synchronize(f.client.synchronizationTransportPlan(notes))
        let notesHash = try await hash(f.client, notesRef), remoteNotes = try await hash(f.server, notesRef)
        XCTAssertEqual(remoteNotes, notesHash)
        let missing = try await f.server.run(["show-ref", "--verify", "--quiet", "refs/heads/must-not-be-used"], successfulExitCodes: 0...1)
        XCTAssertEqual(missing.exitCode, 1)
    }
    func testPullCheckoutRequiresAuthorizationAndThenPullsSelectedBranch() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let tip = try await advance(f)
        _ = try await f.client.run(["switch", "-c", "other"])
        let plan = try await f.client.synchronizationTransportPlan(options(.pull))
        XCTAssertEqual(plan.checkoutBranch, "main"); XCTAssertEqual(plan.oldHead, f.base)
        do { _ = try await f.client.synchronize(plan); XCTFail("switched without authorization") } catch SynchronizationTransportFailure.checkoutNotAuthorized {}
        let before = try await f.client.branch(); XCTAssertEqual(before, "other")
        let result = try await f.client.synchronize(plan, checkoutAuthorized: true)
        XCTAssertEqual(result.command.exitCode, 0)
        let branch = try await f.client.branch(), head = try await hash(f.client)
        XCTAssertEqual(branch, "main"); XCTAssertEqual(head, tip)
        let incoming = try await f.client.synchronizationIncoming(from: plan.oldHead!, to: head)
        XCTAssertEqual(incoming.commits.map(\.hash), [tip]); XCTAssertEqual(incoming.comparison.files.map(\.path), ["incoming 雪.txt"])
    }
    func testConfiguredPullRebaseFetchesAndPinsHandoffWithoutChangingHEAD() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let tip = try await advance(f)
        _ = try await f.client.run(["config", "branch.main.rebase", "merges"])
        let plan = try await f.client.synchronizationTransportPlan(options(.pull))
        XCTAssertEqual(plan.rebaseMode, .preserveMerges); XCTAssertEqual(plan.arguments.first, "fetch")
        let result = try await f.client.synchronize(plan)
        XCTAssertEqual(result.rebaseTarget, tip)
        _ = try await f.client.run(["update-ref", "refs/remotes/origin/main", f.base])
        let head = try await hash(f.client); XCTAssertEqual(head, f.base); XCTAssertEqual(result.rebaseTarget, tip)
        var empty = options(.pull); empty.remoteBranch = ""
        do { _ = try await f.client.synchronizationTransportPlan(empty); XCTFail("configured rebase accepted empty branch") } catch SynchronizationTransportFailure.rebaseBranchRequired {}
        _ = try await f.client.run(["config", "branch.main.rebase", "false"])
        _ = try await f.client.run(["config", "pull.rebase", "true"])
        let override = try await f.client.synchronizationTransportPlan(options(.pull)); XCTAssertEqual(override.rebaseMode, .none)
        _ = try await f.client.run(["config", "branch.main.rebase", "2"])
        let numeric = try await f.client.synchronizationTransportPlan(options(.pull)); XCTAssertEqual(numeric.rebaseMode, .rebase)
        _ = try await f.client.run(["config", "--unset", "branch.main.rebase"])
        let configURL = f.client.root.appendingPathComponent(".git/config")
        let config = try Data(contentsOf: configURL)
        try (config + Data("\n[branch \"main\"]\n\trebase\n".utf8)).write(to: configURL)
        let bareBoolean = try await f.client.synchronizationTransportPlan(options(.pull)); XCTAssertEqual(bareBoolean.rebaseMode, .rebase)
    }
    func testCancellationCrossRepositoryAndStalePullDoNotStartTransport() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var invalid = options(.fetch); invalid.remoteBranch = "main\0bad"
        do { _ = try await f.client.synchronizationTransportPlan(invalid); XCTFail("NUL accepted") } catch SynchronizationFailure.invalidInput {}
        let plan = try await f.client.synchronizationTransportPlan(options(.fetch))
        do { _ = try await f.author.synchronize(plan); XCTFail("cross-repository plan accepted") } catch SynchronizationTransportFailure.repositoryChanged {}
        let before = try await f.client.run(["show-ref"]).stdout
        let token = OperationCancellation()
        do { _ = try await f.client.synchronize(plan, cancellation: token, prepareTransport: { _, cancellation in cancellation.cancel(); return nil }); XCTFail("cancelled authentication started fetch") } catch is OperationCancellationFailure {}
        let after = try await f.client.run(["show-ref"]).stdout; XCTAssertEqual(before, after)
        let pull = try await f.client.synchronizationTransportPlan(options(.pull))
        _ = try await f.client.run(["switch", "-c", "changed"])
        do { _ = try await f.client.synchronize(pull); XCTFail("stale pull accepted") } catch SynchronizationTransportFailure.repositoryChanged {}
        let branch = try await f.client.branch(); XCTAssertEqual(branch, "changed")
    }

    func testFetchAllUsesSelectedRemoteRemoteUpdateUsesAllAndPruneRemovesStaleRefs() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.server.run(["update-ref", "refs/heads/topic", f.base])
        _ = try await f.client.run(["remote", "add", "second", f.server.root.path])
        let all = try await f.client.synchronizationTransportPlan(options(.fetchAllBranches))
        _ = try await f.client.synchronize(all)
        let topic = try await hash(f.client, "refs/remotes/origin/topic"); XCTAssertEqual(topic, f.base)
        let absent = try await f.client.run(["show-ref", "--verify", "--quiet", "refs/remotes/second/main"], successfulExitCodes: 0...1); XCTAssertEqual(absent.exitCode, 1)
        let update = try await f.client.synchronizationTransportPlan(options(.remoteUpdate))
        _ = try await f.client.synchronize(update)
        let second = try await hash(f.client, "refs/remotes/second/main"); XCTAssertEqual(second, f.base)
        _ = try await f.server.run(["update-ref", "-d", "refs/heads/topic"])
        _ = try await f.client.synchronize(f.client.synchronizationTransportPlan(options(.prune)))
        let removed = try await f.client.run(["show-ref", "--verify", "--quiet", "refs/remotes/origin/topic"], successfulExitCodes: 0...1)
        let retained = try await hash(f.client, "refs/remotes/second/topic"), head = try await hash(f.client)
        XCTAssertEqual(removed.exitCode, 1); XCTAssertEqual(retained, f.base); XCTAssertEqual(head, f.base)
    }
    func testFetchHeadSingleMergeLineAndExplicitDeletionAuthorization() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        try Data("local\n".utf8).write(to: f.client.root.appendingPathComponent("local")); try await f.client.stage(["local"]); _ = try await f.client.commit(message: "local")
        let tip = try await hash(f.client), fetchHead = f.client.root.appendingPathComponent(".git/FETCH_HEAD")
        try Data((f.base + "\tnot-for-merge\tignored\n" + tip + "\t\tselected\n").utf8).write(to: fetchHead)
        var request = options(.push); request.localBranch = "FETCH_HEAD"; request.remoteBranch = "refs/heads/review"
        let plan = try await f.client.synchronizationTransportPlan(request)
        XCTAssertEqual(plan.arguments.last, tip + ":refs/heads/review"); XCTAssertFalse(plan.deletesDestination)
        _ = try await f.client.synchronize(plan)
        let pushed = try await hash(f.server, "refs/heads/review"); XCTAssertEqual(pushed, tip)
        try Data((f.base + "\t\tfirst\n" + tip + "\t\tsecond\n").utf8).write(to: fetchHead)
        let octopus = try await f.client.synchronizationTransportPlan(request)
        XCTAssertTrue(octopus.deletesDestination); XCTAssertEqual(octopus.arguments.last, ":refs/heads/review")
        do { _ = try await f.client.synchronize(octopus); XCTFail("deleted without confirmation") } catch SynchronizationTransportFailure.deletionNotAuthorized {}
        let retained = try await hash(f.server, "refs/heads/review"); XCTAssertEqual(retained, tip)
        _ = try await f.client.synchronize(octopus, deletionAuthorized: true)
        let removed = try await f.server.run(["show-ref", "--verify", "--quiet", "refs/heads/review"], successfulExitCodes: 0...1); XCTAssertEqual(removed.exitCode, 1)
        try Data((tip + "\0bad\t\tinvalid\n").utf8).write(to: fetchHead)
        do { _ = try await f.client.synchronizationTransportPlan(request); XCTFail("NUL from FETCH_HEAD accepted") } catch SynchronizationFailure.invalidInput {}
    }
    func testURLRebaseTargetIsPinnedAndAuthenticationCannotSwitchPullBranch() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let tip = try await advance(f)
        var url = options(.fetchAndRebase); url.remote = f.server.root.path
        let plan = try await f.client.synchronizationTransportPlan(url)
        let result = try await f.client.synchronize(plan)
        XCTAssertEqual(result.rebaseTarget, tip)
        try Data((f.base + "\t\treplaced\n").utf8).write(to: f.client.root.appendingPathComponent(".git/FETCH_HEAD"))
        XCTAssertEqual(result.rebaseTarget, tip)
        let pull = try await f.client.synchronizationTransportPlan(options(.pull))
        do {
            _ = try await f.client.synchronize(pull, prepareTransport: { _, _ in
                _ = try await f.client.run(["switch", "-c", "during-auth"]); return nil
            })
            XCTFail("authentication-time branch change accepted")
        } catch SynchronizationTransportFailure.repositoryChanged {}
        let branch = try await f.client.branch(), head = try await hash(f.client)
        XCTAssertEqual(branch, "during-auth"); XCTAssertEqual(head, f.base)
    }
    func testOctopusFetchRetainsSuccessfulOutputWhenRebaseTargetCannotBeChosen() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.server.run(["update-ref", "refs/heads/topic", f.base])
        _ = try await f.client.run(["config", "--add", "branch.main.merge", "refs/heads/topic"])
        var request = options(.fetchAndRebase); request.remoteBranch = ""
        let plan = try await f.client.synchronizationTransportPlan(request)
        do { _ = try await f.client.synchronize(plan); XCTFail("picked one member of an octopus fetch") }
        catch let failure as SynchronizationTransportFollowUpFailure {
            XCTAssertEqual(failure.command.exitCode, 0); XCTAssertFalse(failure.command.stderr.isEmpty)
        }
        let head = try await hash(f.client), topic = try await hash(f.client, "refs/remotes/origin/topic")
        XCTAssertEqual(head, f.base); XCTAssertEqual(topic, f.base)
    }
}
