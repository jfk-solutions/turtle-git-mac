import XCTest
@testable import TurtleGitCore

final class GitCommandPresentationTests: XCTestCase {
    func preferences() -> UserDefaults {
        let name = "TurtleGit.CommandPresentation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testSourceDefaultsCapturedOverridesAndDormantLineLimit() {
        let defaults = preferences(), original = GitCommandPresentation(defaults: defaults)
        XCTAssertTrue(original.fetchVerbose); XCTAssertTrue(original.animateActivity); XCTAssertEqual(original.outputLimit, 2048 * 1024)
        defaults.set(false, forKey: "FetchVerbose"); defaults.set(false, forKey: "DownloadAnimation"); defaults.set(1, forKey: "ProgressDlgLinesLimit")
        let changed = GitCommandPresentation(defaults: defaults)
        XCTAssertFalse(changed.fetchVerbose); XCTAssertFalse(changed.animateActivity); XCTAssertEqual(changed.outputLimit, original.outputLimit)
        XCTAssertTrue(original.fetchVerbose && original.animateActivity)
        defaults.removeObject(forKey: "FetchVerbose"); defaults.removeObject(forKey: "DownloadAnimation")
        XCTAssertEqual(GitCommandPresentation(defaults: defaults), original)
    }
    func testByteLimitMatchesSourceSignedDwordAndBoundsWithoutRewritingPreference() {
        let defaults = preferences()
        for (raw, expected) in [(Int64(0),16),(1,16),(16,16),(8192,8192),(102401,102400),(2147483647,102400),(2147483648,16),(4294967295,16),(-1,16)] {
            defaults.set(NSNumber(value: raw), forKey: "GitOutputLimitinKiB")
            XCTAssertEqual(GitCommandPresentation(defaults: defaults).outputLimit, expected * 1024)
            XCTAssertEqual((defaults.object(forKey: "GitOutputLimitinKiB") as? NSNumber)?.int64Value, raw)
        }
    }
    private func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func testRealFetchAndRebaseHonorCapturedVerbosityWithoutChangingHeadOrIndex() async throws {
        let (root, _, _, consumer, _) = try await FetchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("record-git"), record = root.appendingPathComponent("arguments")
        let script = "#!/bin/sh\nif [ \"$4\" = fetch ]; then printf '%s\\000' \"$@\" > " + quoted(record.path) + "; fi\nexec " + quoted(consumer.executable.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let repo = GitRepository(root: consumer.root, executable: helper)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: consumer.root.appendingPathComponent(".git/index"))
        var options = FetchOptions(); options.remote = "origin"; options.branch = "main"
        for verbose in [false,true] {
            options.verbose = verbose
            _ = try await repo.fetch(options)
            let args = try Data(contentsOf: record).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(args.contains("--verbose"), verbose); XCTAssertTrue(args.contains("--progress")); XCTAssertTrue(args.contains("origin"))
            _ = try await repo.fetchForRebase(options)
            let replayArgs = try Data(contentsOf: record).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(replayArgs.contains("--verbose"), verbose); XCTAssertTrue(replayArgs.contains("--progress"))
        }
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(finalHead, head); XCTAssertEqual(try Data(contentsOf: consumer.root.appendingPathComponent(".git/index")), index)
    }
    func testSynchronizationFetchPreferenceDoesNotMuteSourcePullOrPush() async throws {
        let (root, _, _, repo, _) = try await FetchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for action in [SynchronizationTransportAction.fetch,.fetchAndRebase,.fetchAllBranches,.pull,.push] {
            var options = SynchronizationTransportOptions(action: action)
            options.localBranch = "main"; options.remote = "origin"; options.remoteBranch = "main"; options.fetchVerbose = false
            let plan = try await repo.synchronizationTransportPlan(options)
            XCTAssertEqual(plan.arguments.contains("-v"), action == .pull || action == .push)
            XCTAssertTrue(plan.arguments.contains("--progress"))
        }
    }
}
