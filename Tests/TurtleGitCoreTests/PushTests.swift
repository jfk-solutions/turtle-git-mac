import XCTest
@testable import TurtleGitCore

final class PushTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, GitRepository, String) {
        let (root, repo, path) = try await GitPatchTests().fixture()
        let remoteURL = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: true)
        let remote = GitRepository(root: remoteURL); _ = try await remote.run(["init", "--bare"])
        try await repo.saveRemote(name: "origin", fetchURL: remoteURL.path, pushURL: "", existing: false)
        return (root, repo, remote, path)
    }
    func testNamedDestinationUpstreamAndMixedChangesRemainUnchanged() async throws {
        let (root, repo, remote, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("index\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("later\n".utf8).write(to: root.appendingPathComponent(path))
        var options = PushOptions(); options.remote = "origin"; options.source = "refs/heads/main"; options.destination = "published"; options.setUpstream = true
        _ = try await repo.push(options)
        let head = try await repo.run(["rev-parse", "HEAD"]).text, received = try await remote.run(["rev-parse", "refs/heads/published"]).text
        let merge = try await repo.run(["config", "--get", "branch.main.merge"]).text
        let index = try await repo.run(["show", ":" + path]).text
        XCTAssertEqual(head, received); XCTAssertEqual(merge, "refs/heads/published\n"); XCTAssertEqual(index, "index\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "later\n")
    }
    func testTagScopedPushAndAllBranchesPlusTags() async throws {
        let (root, repo, remote, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["tag", "selected"]); _ = try await repo.run(["tag", "other"]); _ = try await repo.run(["branch", "topic"])
        var options = PushOptions(); options.remote = "origin"; options.source = "refs/tags/selected"
        _ = try await repo.push(options)
        let refs = try await remote.checkoutReferences(); XCTAssertEqual(refs.map(\.name), ["refs/tags/selected"])
        options.destination = "renamed-tag"; _ = try await repo.push(options)
        let renamed = try await remote.run(["cat-file", "-t", "refs/tags/renamed-tag"]).text; XCTAssertEqual(renamed, "commit\n")
        options.source = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); options.destination = "hash-target"
        _ = try await repo.push(options)
        let hashTarget = try await remote.run(["rev-parse", "refs/heads/hash-target"]).text
        let expected = try await repo.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(hashTarget, expected)
        options.allBranches = true; options.includeTags = true; _ = try await repo.push(options)
        let all = try await remote.checkoutReferences(); XCTAssertEqual(Set(all.map(\.name)), ["refs/heads/main", "refs/heads/topic", "refs/heads/hash-target", "refs/tags/selected", "refs/tags/other", "refs/tags/renamed-tag"])
    }
    func testRejectedDivergenceAndStaleLeasePreserveRemoteThenMatchingLeaseSucceeds() async throws {
        let (root, repo, remote, path) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = PushOptions(); options.remote = "origin"; options.source = "refs/heads/main"
        _ = try await repo.push(options); let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("remote next\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "remote next"); _ = try await repo.push(options)
        let remoteHead = try await remote.run(["rev-parse", "refs/heads/main"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["reset", "--hard", base])
        try Data("local divergence\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "local divergence")
        do { _ = try await repo.push(options); XCTFail("Non-fast-forward push must reject") } catch is PushExecutionFailure {}
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", base]); options.forceWithLease = true
        do { _ = try await repo.push(options); XCTFail("Stale lease must reject") } catch is PushExecutionFailure {}
        let unchanged = try await remote.run(["rev-parse", "refs/heads/main"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(unchanged, remoteHead)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", remoteHead]); _ = try await repo.push(options)
        let expected = try await repo.run(["rev-parse", "HEAD"]).text, received = try await remote.run(["rev-parse", "refs/heads/main"]).text
        XCTAssertEqual(expected, received)
    }
    func testAllRemotesReportsCompletedDestinationBeforeFailure() async throws {
        let (root, repo, remote, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["remote", "rename", "origin", "a-good"])
        try await repo.saveRemote(name: "z-bad", fetchURL: root.appendingPathComponent("missing.git").path, pushURL: "", existing: false)
        var options = PushOptions(); options.allRemotes = true; options.source = "refs/heads/main"
        do { _ = try await repo.push(options); XCTFail("Second destination must fail") }
        catch let failure as PushExecutionFailure { XCTAssertEqual(failure.completed, ["a-good"]); XCTAssertEqual(failure.failedRemote, "z-bad"); XCTAssertTrue(failure.output.contains("refs/heads/main")) }
        let received = try await remote.run(["rev-parse", "refs/heads/main"]).text; XCTAssertFalse(received.isEmpty)
    }
    func testURLPushSavedPushSettingsDeletionAndInvalidOption() async throws {
        let (root, repo, remote, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = PushOptions(); options.remote = remote.root.path; options.arbitraryURL = true; options.source = "refs/heads/main"; options.destination = "refs/heads/url-target"
        _ = try await repo.push(options)
        options.arbitraryURL = false; options.remote = "origin"; options.destination = "saved"; options.savePushRemote = true; options.savePushBranch = true
        _ = try await repo.push(options)
        let defaults = try await repo.pushDefaults(source: "refs/heads/main"); XCTAssertEqual(defaults.remote, "origin"); XCTAssertEqual(defaults.destination, "saved")
        options.savePushRemote = false; options.savePushBranch = false; options.source = ""; _ = try await repo.push(options)
        let refs = try await remote.checkoutReferences(); XCTAssertFalse(refs.contains { $0.name == "refs/heads/saved" })
        options.source = "refs/heads/main"; options.destination = "../invalid"
        do { _ = try await repo.push(options); XCTFail("Invalid target") } catch PushValidationFailure.destination {}
        options.destination = "valid"; options.pushOption = "line\nbreak"
        do { _ = try await repo.push(options); XCTFail("Invalid push option") } catch PushValidationFailure.pushOption {}
    }
    func testPushOptionIsPassedAsOneArgumentToReceiveHook() async throws {
        let (root, repo, remote, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await remote.run(["config", "receive.advertisePushOptions", "true"])
        let hook = remote.root.appendingPathComponent("hooks/pre-receive")
        try Data("#!/bin/sh\nprintf '%s' \"$GIT_PUSH_OPTION_0\" > \"$GIT_DIR/push-option.txt\"\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        var options = PushOptions(); options.remote = "origin"; options.source = "refs/heads/main"; options.pushOption = "review=two words; literal"
        _ = try await repo.push(options)
        XCTAssertEqual(try String(contentsOf: remote.root.appendingPathComponent("push-option.txt"), encoding: .utf8), options.pushOption)
    }
    func testPreCancelledPushPreservesRemoteAndSavedDefaults() async throws {
        let (root, repo, remote, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = PushOptions(); options.remote = "origin"; options.source = "refs/heads/main"; options.destination = "cancelled"
        options.savePushRemote = true; options.savePushBranch = true
        let before = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.push(options, cancellation: token); XCTFail("Pre-cancelled push must not execute") }
        catch OperationCancellationFailure.cancelled {}
        let refs = try await remote.checkoutReferences()
        XCTAssertTrue(refs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), before)
    }

    func testSubmissionValidationIsReadOnlyBeforeTransportOrSavedDefaults() async throws {
        let (root, repo, remote, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = PushOptions(); options.remote = "origin"; options.source = "refs/heads/main"; options.destination = "validated"
        options.savePushRemote = true; options.savePushBranch = true
        let before = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        try await repo.validatePushOptions(options)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), before)
        let refs = try await remote.checkoutReferences(); XCTAssertTrue(refs.isEmpty)
        options.destination = "../invalid"
        do { try await repo.validatePushOptions(options); XCTFail("Invalid branch must reject before history saving") }
        catch PushValidationFailure.destination {}
        options.destination = "validated"; options.setUpstream = true
        do { try await repo.validatePushOptions(options); XCTFail("Incompatible save/upstream settings must reject") }
        catch PushValidationFailure.combination {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), before)
    }

    func testCollidingShortBranchAndTagRejectBeforeSavingOrTransport() async throws {
        let (root, repo, remote, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "collision"]); _ = try await repo.run(["tag", "collision"])
        var options = PushOptions(); options.remote = "origin"; options.source = "collision"; options.destination = "published"
        options.savePushRemote = true; options.savePushBranch = true
        let before = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        do { try await repo.validatePushOptions(options); XCTFail("Colliding short name must reject") }
        catch PushValidationFailure.source {}
        do { _ = try await repo.push(options); XCTFail("Direct transport must also reject") }
        catch PushValidationFailure.source {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), before)
        let emptyRefs = try await remote.checkoutReferences(); XCTAssertTrue(emptyRefs.isEmpty)
        options.source = "refs/heads/collision"; options.savePushRemote = false; options.savePushBranch = false
        _ = try await repo.push(options)
        options.source = "refs/tags/collision"; options.destination = "published-tag"; _ = try await repo.push(options)
        let refs = try await remote.checkoutReferences()
        XCTAssertEqual(Set(refs.map(\.name)), ["refs/heads/published", "refs/tags/published-tag"])
    }

    func testBranchDefaultsSurviveSameNamedTagAndStripOnlyTrackedRefPrefix() async throws {
        let (root, repo, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["tag", "main"])
        _ = try await repo.run(["config", "branch.main.remote", "origin"])
        _ = try await repo.run(["config", "branch.main.merge", "refs/heads/tracked"])
        let defaults = try await repo.pushDefaults(source: "main")
        XCTAssertEqual(defaults.localBranch, "main"); XCTAssertEqual(defaults.remote, "origin"); XCTAssertEqual(defaults.destination, "tracked")
        _ = try await repo.run(["config", "branch.main.pushbranch", "refs/for/review"])
        let explicit = try await repo.pushDefaults(source: "refs/heads/main")
        XCTAssertEqual(explicit.destination, "refs/for/review")
        let tag = try await repo.pushDefaults(source: "refs/tags/main")
        XCTAssertNil(tag.localBranch)
    }

    func testFirstParentCounterAfterEachRemoteAndAllBranchesExclusion() async throws {
        let (root, repo, remote, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["checkout", "-b", "side"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "side one"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "side two"])
        _ = try await repo.run(["checkout", "main"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "main two"])
        _ = try await repo.run(["merge", "--no-ff", "side", "-m", "merge"])
        let count = try await repo.branchRevisionNumber("main")
        let total = try await repo.run(["rev-list", "--count", "main"]).text
        XCTAssertEqual(count, "3"); XCTAssertEqual(total, "5\n")
        _ = try await repo.run(["tag", "counter-tag"])
        let tagCount = try await repo.branchRevisionNumber("refs/tags/counter-tag")
        XCTAssertEqual(tagCount, "3")
        let otherURL = root.appendingPathComponent("other.git")
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
        let other = GitRepository(root: otherURL); _ = try await other.run(["init", "--bare"])
        try await repo.saveRemote(name: "other", fetchURL: otherURL.path, pushURL: "", existing: false)
        var options = PushOptions(); options.source = "main"; options.allRemotes = true; options.showBranchRevisionNumber = true
        let output = try await repo.push(options)
        XCTAssertEqual(output.split(separator: "\n").filter { $0 == "3" }.count, 2)
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        for destination in [remote, other] {
            let actual = try await destination.run(["rev-parse", "refs/heads/main"]).text
            XCTAssertEqual(actual, head)
        }
        options.allBranches = true
        let allOutput = try await repo.push(options)
        XCTAssertFalse(allOutput.split(separator: "\n").contains("3"))
        options.allBranches = false; options.showBranchRevisionNumber = false
        let normalOutput = try await repo.push(options)
        XCTAssertFalse(normalOutput.split(separator: "\n").contains("3"))
    }
    func testCounterFailureAfterRemoteDeletionReportsCompletedMutation() async throws {
        let (root, repo, remote, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = PushOptions(); options.remote = "origin"; options.source = "main"; options.destination = "delete-me"
        _ = try await repo.push(options)
        options.source = ""; options.showBranchRevisionNumber = true
        do { _ = try await repo.push(options); XCTFail("The source count has no revision after deletion") }
        catch let failure as PushExecutionFailure {
            XCTAssertEqual(failure.completed, ["origin"])
            XCTAssertEqual(failure.failedRemote, "origin")
        }
        let refs = try await remote.checkoutReferences()
        XCTAssertFalse(refs.contains { $0.name == "refs/heads/delete-me" })
    }

}
