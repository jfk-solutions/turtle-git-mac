// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

private final class SyncBackendReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SynchronizationCommandCompletion] = []
    func add(_ value: SynchronizationCommandCompletion) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [SynchronizationCommandCompletion] { lock.lock(); defer { lock.unlock() }; return storage }
}
final class SyncLibGit2Tests: XCTestCase {
    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private struct Fixture {
        let root: URL, source: GitRepository, remote: GitRepository, client: GitRepository, helper: URL
        var backend: GitLibGit2Configuration { .init(mask: 4, helperURL: helper) }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-Sync-LibGit2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let actualGit = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let selected = try XCTUnwrap(GitLibGit2Configuration(mask: 4).executor(for: .fetch))
        let global = root.appendingPathComponent("global.config"); try Data().write(to: global)
        let environment = "unset GIT_DIR GIT_WORK_TREE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=" + quote(global.path) + " HOME=" + quote(root.path) + " XDG_CONFIG_HOME=" + quote(root.path) + "\n"
        let git = root.appendingPathComponent("private git"), helper = root.appendingPathComponent("private libgit2")
        for (path, command) in [(git, environment + "exec " + quote(actualGit.path) + " \"$@\"\n"), (helper, environment + "printf '%s\\0' \"$@\" > \"$0.argv\"\nexec " + quote(selected.path) + " \"$@\"\n")] {
            try Data(("#!/bin/sh\n" + command).utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let sourceURL = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let source = GitRepository(root: sourceURL, executable: git, askpass: nil)
        _ = try await source.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Private Sync"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await source.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: sourceURL.appendingPathComponent("file")); try await source.stage(["file"]); _ = try await source.commit(message: "base")
        let remoteURL = root.appendingPathComponent("repo.git"), clientURL = root.appendingPathComponent("client")
        _ = try await source.run(["clone", "--bare", "--", sourceURL.path, remoteURL.path])
        _ = try await source.run(["clone", "--", remoteURL.path, clientURL.path])
        return Fixture(root: root, source: source, remote: GitRepository(root: remoteURL, executable: git, askpass: nil), client: GitRepository(root: clientURL, executable: git, askpass: nil), helper: helper)
    }
    func testSyncFetchUsesCapturedBackendAndActualSettledReceiptWithoutChangingCheckout() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await f.client.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")), config = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config"))
        try Data("private working edit\n".utf8).write(to: f.client.root.appendingPathComponent("file"))
        try Data("remote update\n".utf8).write(to: f.source.root.appendingPathComponent("file")); try await f.source.stage(["file"]); _ = try await f.source.commit(message: "new remote tip")
        _ = try await f.source.run(["push", "--", f.remote.root.path, "main"])
        let tip = try await f.remote.run(["rev-parse", "HEAD"]).stdout
        var options = SynchronizationTransportOptions(action: .fetchAndRebase); options.remote = "origin"; options.remoteBranch = "main"; options.localBranch = "main"
        let plan = try await f.client.synchronizationTransportPlan(options), receipts = SyncBackendReceipts()
        let suite = "TurtleGit.Sync.Backend." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(4, forKey: "UseLibgit2_mask")
        let captured = GitLibGit2Configuration.load(from: defaults, helperURL: f.helper)
        let result = try await f.client.synchronize(plan, prepareTransport: { _, _ in defaults.set(false, forKey: "UseLibgit2"); return nil }, onCommandFinished: receipts.add, backend: captured)
        XCTAssertEqual(result.command.exitCode, 0); XCTAssertEqual(result.rebaseTarget, String(decoding: tip, as: UTF8.self).trimmingCharacters(in: .newlines))
        XCTAssertEqual(receipts.values.count, 1); XCTAssertTrue(receipts.values.first?.success == true)
        let argv = try Data(contentsOf: URL(fileURLWithPath: f.helper.path + ".argv")).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(Array(argv.dropFirst(3)), result.executedArguments)
        let after = try await f.client.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(after, before); XCTAssertEqual(try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")), config)
        XCTAssertEqual(try String(contentsOf: f.client.root.appendingPathComponent("file"), encoding: .utf8), "private working edit\n")
        XCTAssertFalse(GitLibGit2Configuration.load(from: defaults).requests(.fetch))
    }
    func testSyncTagFetchUsesTransientConfigAndMissingBackendCannotFallBack() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.remote.run(["update-ref", "refs/tags/new-tag", "HEAD"])
        let snapshot = try await f.client.synchronizationTags(remote: "origin")
        let row = try XCTUnwrap(snapshot.rows.first { $0.name.rawValue == "new-tag" })
        let head = try await f.client.run(["rev-parse", "HEAD"]).stdout, config = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config"))
        let missing = GitLibGit2Configuration(mask: 4, helperURL: f.root.appendingPathComponent("missing"))
        do { _ = try await f.client.synchronizeTag(.fetch, row: row, snapshot: snapshot, backend: missing); XCTFail("Missing requested libgit2 silently used CLI") }
        catch GitLibGit2Failure.runtimeMissing {}
        let absent = try await f.client.run(["rev-parse", "--verify", "refs/tags/new-tag"], successfulExitCodes: 0...128)
        XCTAssertNotEqual(absent.exitCode, 0)
        let result = try await f.client.synchronizeTag(.fetch, row: row, snapshot: snapshot, backend: f.backend)
        XCTAssertEqual(result.exitCode, 0)
        let target = try await f.client.run(["rev-parse", "refs/tags/new-tag"]).stdout
        XCTAssertEqual(target, head)
        let argv = try Data(contentsOf: URL(fileURLWithPath: f.helper.path + ".argv")).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(Array(argv.dropFirst(3).prefix(3)), ["-c", "core.precomposeunicode=false", "fetch"])
        XCTAssertEqual(try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")), config)
        let after = try await f.client.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
    }
}
