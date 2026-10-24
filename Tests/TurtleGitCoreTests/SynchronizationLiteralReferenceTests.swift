// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

private final class LiteralSyncReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SynchronizationCommandCompletion] = []
    func append(_ value: SynchronizationCommandCompletion) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [SynchronizationCommandCompletion] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class SynchronizationLiteralReferenceTests: XCTestCase {
    private let cli = GitLibGit2Configuration(enabled: false)
    private let nfd = "cafe\u{301}", nfc = "café"
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private struct Fixture {
        let directory: URL, client: GitRepository, server: GitRepository, author: GitRepository
        let base: String, tip: String, command: URL, environment: String
    }
    private func executable(_ path: URL, _ script: String) throws {
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sync-literal-雪-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let config = directory.appendingPathComponent("global.config"); try Data().write(to: config)
            let environment = "unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=" + quote(config.path) + " XDG_CONFIG_HOME=" + quote(directory.path) + "\n"
            let command = directory.appendingPathComponent("private-git")
            let git = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"
            try executable(command, "#!/bin/sh\n" + environment + "exec " + quote(git) + " \"$@\"\n")
            let author = GitRepository(root: directory.appendingPathComponent("author"), executable: command, askpass: nil, libgit2Configuration: cli)
            let server = GitRepository(root: directory.appendingPathComponent("remote.git"), executable: command, askpass: nil, libgit2Configuration: cli)
            let client = GitRepository(root: directory.appendingPathComponent("client"), executable: command, askpass: nil, libgit2Configuration: cli)
            try FileManager.default.createDirectory(at: author.root, withIntermediateDirectories: true)
            _ = try await author.run(["init", "--template=", "-b", "main"])
            for (key, value) in [("user.name", "Sync Literal QA"), ("user.email", "literal@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "false")] { _ = try await author.run(["config", key, value]) }
            try Data("base\n".utf8).write(to: author.root.appendingPathComponent("file")); _ = try await author.run(["add", "file"]); _ = try await author.run(["commit", "-m", "base"])
            let base = try await hash(author, "HEAD")
            _ = try await author.run(["clone", "--bare", "--template=", "--", author.root.path, server.root.path])
            _ = try await author.run(["clone", "--template=", "--", server.root.path, client.root.path])
            try Data("tip\n".utf8).write(to: author.root.appendingPathComponent("new-file")); _ = try await author.run(["add", "new-file"]); _ = try await author.run(["commit", "-m", "literal tip"])
            let tip = try await hash(author, "HEAD")
            _ = try await author.run(["push", "--", server.root.path, "main"])
            _ = try await client.run(["fetch", "origin"])
            for (key, value) in [("user.name", "Sync Literal QA"), ("user.email", "literal@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "true"), ("pull.rebase", "false"), ("pull.ff", "only")] { _ = try await client.run(["config", key, value]) }
            try await packed(client, [("refs/heads/" + nfd, tip), ("refs/heads/" + nfc, base), ("refs/remotes/origin/" + nfd, base), ("refs/remotes/origin/" + nfc, tip)])
            try await packed(server, [("refs/heads/" + nfd, base), ("refs/heads/" + nfc, tip)])
            for (branch, destination) in [(nfd, nfd), (nfc, nfc)] {
                _ = try await client.run(["-c", "core.precomposeunicode=false", "config", "branch." + branch + ".remote", "origin"])
                _ = try await client.run(["-c", "core.precomposeunicode=false", "config", "branch." + branch + ".merge", "refs/heads/" + destination])
            }
            return Fixture(directory: directory, client: client, server: server, author: author, base: base, tip: tip, command: command, environment: environment)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    private func hash(_ repo: GitRepository, _ ref: String) async throws -> String {
        try await repo.run(["-c", "core.precomposeunicode=false", "rev-parse", "--verify", "--end-of-options", ref]).text.trimmingCharacters(in: .newlines)
    }
    private func packed(_ repo: GitRepository, _ replacements: [(String, String)]) async throws {
        let data = try await repo.run(["for-each-ref", "--format=%(objectname)%00%(refname)"]).stdout
        var values: [GitReferenceName: String] = [:]
        for line in data.split(separator: 10) {
            let fields = line.split(separator: 0)
            guard fields.count == 2 else { throw SynchronizationFailure.invalidInput }
            values[GitReferenceName(String(decoding: fields[1], as: UTF8.self))] = String(decoding: fields[0], as: UTF8.self)
        }
        for (name, oid) in replacements { values[GitReferenceName(name)] = oid }
        let lines = values.keys.sorted { $0.rawValue.utf8.lexicographicallyPrecedes($1.rawValue.utf8) }.map { values[$0]! + " " + $0.rawValue + "\n" }
        let path = try await repo.run(["rev-parse", "--git-path", "packed-refs"]).text.trimmingCharacters(in: .newlines)
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.root.appendingPathComponent(path)
        try Data(("# pack-refs with: peeled fully-peeled sorted \n" + lines.joined()).utf8).write(to: url)
    }
    private func options(_ action: SynchronizationTransportAction, local: String? = nil, target: String? = nil) -> SynchronizationTransportOptions {
        var value = SynchronizationTransportOptions(action: action); value.localBranch = local ?? nfd; value.remote = "origin"; value.remoteBranch = target ?? nfd; return value
    }
    private func config(_ repo: GitRepository, _ key: String) async throws -> String {
        try await repo.run(["-c", "core.precomposeunicode=false", "config", "--get", key]).text.trimmingCharacters(in: .newlines)
    }
    private func storedPolicy(_ f: Fixture) async throws {
        // --local reads the durable file, excluding the invocation-only -c
        // override deliberately used by literal-reference commands.
        let value = try await f.client.run(["config", "--local", "--get", "core.precomposeunicode"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(value, "true")
    }

    func testBranchCatalogAndTrackingWritesKeepDistinctConfigKeysAndSourcePrefixRules() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let decomposed = try await f.client.synchronizationBranches(localBranch: nfd), composed = try await f.client.synchronizationBranches(localBranch: nfc)
        XCTAssertTrue(decomposed.trackedBranch.utf8.elementsEqual(nfd.utf8)); XCTAssertTrue(composed.trackedBranch.utf8.elementsEqual(nfc.utf8))
        XCTAssertTrue(decomposed.localBranches.contains { $0.utf8.elementsEqual(nfd.utf8) }); XCTAssertTrue(decomposed.localBranches.contains { $0.utf8.elementsEqual(nfc.utf8) })
        try await f.client.setSynchronizationTracking(localBranch: nfd, remote: "literal-origin", remoteBranch: "refs/tags/destination/" + nfd + "\t ")
        let remote = try await config(f.client, "branch." + nfd + ".remote"), merge = try await config(f.client, "branch." + nfd + ".merge")
        let neighbor = try await config(f.client, "branch." + nfc + ".merge")
        XCTAssertEqual(remote, "literal-origin"); XCTAssertTrue(merge.utf8.elementsEqual(("refs/heads/tags/destination/" + nfd).utf8))
        XCTAssertTrue(neighbor.utf8.elementsEqual(("refs/heads/" + nfc).utf8))
        // Source writes the approved local string without requiring branch membership.
        try await f.client.setSynchronizationTracking(localBranch: "FETCH_HEAD", remote: "origin", remoteBranch: "refs/heads/" + nfd)
        let detached = try await config(f.client, "branch.FETCH_HEAD.merge"); XCTAssertTrue(detached.utf8.elementsEqual(("refs/heads/" + nfd).utf8))
        try await storedPolicy(f)
    }

    func testOutgoingIncomingAndReferenceSnapshotsResolvePackedSpellingsIndependently() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let configBytes = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")), index = try Data(contentsOf: f.client.root.appendingPathComponent(".git/index"))
        let outgoing = try await f.client.synchronizationOutgoing(localBranch: nfd, remote: "origin", remoteBranch: nfd)
        XCTAssertEqual(outgoing.localHash, f.tip); XCTAssertEqual(outgoing.remoteHash, f.base); XCTAssertEqual(outgoing.disposition, .outgoing)
        XCTAssertEqual(outgoing.commits.map(\.hash), [f.tip])
        let other = try await f.client.synchronizationOutgoing(localBranch: nfc, remote: "origin", remoteBranch: nfc)
        XCTAssertEqual(other.localHash, f.base); XCTAssertEqual(other.remoteHash, f.tip); XCTAssertEqual(other.disposition, .needsForce)
        let incoming = try await f.client.synchronizationIncoming(from: "refs/heads/" + nfc, to: "refs/heads/" + nfd)
        XCTAssertEqual(incoming.commits.map(\.hash), [f.tip])
        let snapshot = try await f.client.synchronizationReferenceSnapshot()
        XCTAssertEqual(snapshot.references[GitReferenceName("refs/heads/" + nfd)], f.tip)
        XCTAssertEqual(snapshot.references[GitReferenceName("refs/heads/" + nfc)], f.base)
        _ = try await f.client.run(["-c", "core.precomposeunicode=false", "update-ref", "refs/heads/" + nfd, f.base])
        XCTAssertEqual(snapshot.references[GitReferenceName("refs/heads/" + nfd)], f.tip)
        XCTAssertEqual(outgoing.localHash, f.tip); XCTAssertEqual(incoming.commits.map(\.hash), [f.tip])
        XCTAssertEqual(configBytes, try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")))
        XCTAssertEqual(index, try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")))
    }

    func testEmailExportsExactPackedBranchRangeWithoutChangingRepositoryState() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let refs = try await f.client.run(["show-ref"]).stdout, index = try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")), configBytes = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config"))
        let result = try await f.client.synchronizationEmailPatches(localBranch: nfd, remote: "origin", remoteBranch: nfd)
        let paths = result.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        XCTAssertEqual(paths.count, 1)
        let patch = try SerialPatch(file: XCTUnwrap(paths.first)); XCTAssertEqual(patch.subject, "[PATCH] literal tip")
        let afterRefs = try await f.client.run(["show-ref"]).stdout
        XCTAssertEqual(afterRefs, refs); XCTAssertEqual(index, try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")))
        XCTAssertEqual(configBytes, try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")))
    }

    func testSeparateAndInlinePullCheckoutAttachLiteralBranchThenPullItsConfiguredSource() async throws {
        for separate in [true, false] {
            let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            try await packed(f.client, [("refs/heads/" + nfd, f.base), ("refs/heads/" + nfc, f.tip)])
            try await packed(f.server, [("refs/heads/" + nfd, f.tip), ("refs/heads/" + nfc, f.base)])
            // The two packed spellings remain distinct, but a normalizing
            // filesystem cannot create their loose-ref lockfiles concurrently.
            // Pull's omitted field must use the selected narrow configured map.
            _ = try await f.client.run(["-c", "core.precomposeunicode=false", "config", "--replace-all", "remote.origin.fetch", "+refs/heads/" + nfd + ":refs/remotes/origin/" + nfd])
            let configBytes = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config"))
            let plan = try await f.client.synchronizationTransportPlan(options(.pull))
            XCTAssertTrue(try XCTUnwrap(plan.checkoutBranch).utf8.elementsEqual(nfd.utf8))
            let result: SynchronizationTransportResult
            if separate {
                let checkout = try await f.client.synchronizationPullCheckout(plan, checkoutAuthorized: true)
                let attachment = try await f.client.branch(); XCTAssertTrue(attachment.utf8.elementsEqual(nfd.utf8))
                let before = try await hash(f.client, "HEAD"); XCTAssertEqual(before, f.base)
                result = try await f.client.synchronize(checkout, backend: cli)
            } else { result = try await f.client.synchronize(plan, checkoutAuthorized: true, backend: cli) }
            let attachment = try await f.client.branch(), head = try await hash(f.client, "HEAD")
            XCTAssertTrue(attachment.utf8.elementsEqual(nfd.utf8)); XCTAssertEqual(head, f.tip)
            XCTAssertEqual(result.executedArguments, ["pull", "-v", "--progress", "--", "origin"])
            XCTAssertEqual(result.command.exitCode, 0)
            XCTAssertEqual(configBytes, try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")))
            try await storedPolicy(f)
        }
    }

    func testPullRebasePolicyReadsExactSelectedBranchConfigAndRetainsPinnedTarget() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.client.run(["-c", "core.precomposeunicode=false", "config", "branch." + nfd + ".rebase", "merges"])
        _ = try await f.client.run(["-c", "core.precomposeunicode=false", "config", "branch." + nfc + ".rebase", "false"])
        let selected = try await f.client.synchronizationTransportPlan(options(.pull)), neighbor = try await f.client.synchronizationTransportPlan(options(.pull, local: nfc, target: nfc))
        XCTAssertEqual(selected.rebaseMode, .preserveMerges); XCTAssertEqual(selected.arguments.first, "fetch")
        XCTAssertEqual(neighbor.rebaseMode, .none); XCTAssertEqual(neighbor.arguments.first, "pull")
        let state = try await f.client.synchronizationRebaseState(target: "refs/heads/" + nfd)
        XCTAssertEqual(state.target, f.tip); XCTAssertTrue(state.canFastForward)
        _ = try await f.client.run(["-c", "core.precomposeunicode=false", "update-ref", "refs/heads/" + nfd, f.base])
        let merge = try await f.client.synchronizationFastForward(state)
        XCTAssertEqual(merge.exitCode, 0)
        let head = try await hash(f.client, "HEAD"); XCTAssertEqual(head, f.tip)
        try await storedPolicy(f)
    }

    func testPushUsesLiteralPackedSourceAndDestinationWhileRetainingRawReceipt() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let destination = "result/" + nfd, configBytes = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")), receipts = LiteralSyncReceipts()
        let plan = try await f.client.synchronizationTransportPlan(options(.push, target: destination))
        let result = try await f.client.synchronize(plan, onCommandFinished: receipts.append, backend: cli)
        let remote = try await hash(f.server, "refs/heads/" + destination)
        XCTAssertEqual(remote, f.tip, "NFC source points at the other commit")
        XCTAssertTrue(try XCTUnwrap(result.executedArguments.last).utf8.elementsEqual((nfd + ":" + destination).utf8))
        XCTAssertFalse(result.executedArguments.contains("core.precomposeunicode=false"))
        XCTAssertEqual(receipts.values.count, 1); XCTAssertEqual(receipts.values.first?.success, true)
        XCTAssertEqual(configBytes, try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")))
    }

    func testSelectedFetchPersistsExactQualifiedMappingAndUsesAlreadyLoadedConfiguration() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let actual = try XCTUnwrap(GitLibGit2Configuration(mask: 4).executor(for: .fetch)), helper = f.directory.appendingPathComponent("private-libgit2")
        try executable(helper, "#!/bin/sh\n" + f.environment + "exec " + quote(actual.path) + " \"$@\"\n")
        _ = try await f.client.run(["config", "--replace-all", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main"])
        let plan = try await f.client.synchronizationTransportPlan(options(.fetchAndRebase))
        let result = try await f.client.synchronize(plan, backend: .init(mask: 4, helperURL: helper))
        let specs = try await f.client.run(["-c", "core.precomposeunicode=false", "config", "--get-all", "remote.origin.fetch"]).text.split(separator: "\n").map(String.init)
        let added = "refs/heads/" + nfd + ":refs/remotes/origin/" + nfd
        XCTAssertEqual(specs.count, 2); XCTAssertTrue(specs[1].utf8.elementsEqual(added.utf8))
        XCTAssertEqual(result.rebaseTarget, f.base, "Source first Fetch still uses the already-loaded main-only configuration")
        XCTAssertTrue(try XCTUnwrap(result.executedArguments.last).utf8.elementsEqual(added.utf8))
        XCTAssertFalse(result.executedArguments.contains("core.precomposeunicode=false"))
        try await storedPolicy(f)
    }

    func testStaleCheckoutAndLatePreparationRejectByteDistinctAttachmentAtSameCommit() async throws {
        for duringPreparation in [false, true] {
            let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
            try await packed(f.client, [("refs/heads/" + nfd, f.base), ("refs/heads/" + nfc, f.base)])
            let plan = try await f.client.synchronizationTransportPlan(options(.pull)), receipts = LiteralSyncReceipts()
            let checkout = try await f.client.synchronizationPullCheckout(plan, checkoutAuthorized: true)
            let configBytes = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config"))
            let preparation: SSHTransportPreparation?
            if duringPreparation {
                let neighbor = nfc
                preparation = { _, _ in _ = try await f.client.run(["-c", "core.precomposeunicode=false", "switch", "--no-guess", "--", neighbor]); return nil }
            } else {
                _ = try await f.client.run(["-c", "core.precomposeunicode=false", "switch", "--no-guess", "--", nfc]); preparation = nil
            }
            do { _ = try await f.client.synchronize(checkout, prepareTransport: preparation, onCommandFinished: receipts.append, backend: cli); XCTFail("Byte-distinct same-commit branch change accepted") }
            catch SynchronizationTransportFailure.repositoryChanged { }
            XCTAssertTrue(receipts.values.isEmpty)
            let head = try await hash(f.client, "HEAD"); XCTAssertEqual(head, f.base)
            XCTAssertEqual(configBytes, try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")))
        }
    }

    func testCancellationAndStructuralRefusalPreserveStateAndEngineFailuresKeepPublicArguments() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let configBytes = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")), refs = try await f.client.run(["show-ref"]).stdout
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { try await f.client.setSynchronizationTracking(localBranch: nfd, remote: "changed", remoteBranch: nfd, cancellation: cancelled); XCTFail("Cancelled config write ran") } catch OperationCancellationFailure.cancelled { }
        do { try await f.client.setSynchronizationTracking(localBranch: nfd, remote: "changed", remoteBranch: "bad\0value"); XCTFail("NUL config write ran") } catch SynchronizationFailure.invalidInput { }
        let plan = try await f.client.synchronizationTransportPlan(options(.push)), receipts = LiteralSyncReceipts()
        do { _ = try await f.client.synchronize(plan, cancellation: cancelled, onCommandFinished: receipts.append, backend: cli); XCTFail("Cancelled Push ran") } catch OperationCancellationFailure.cancelled { }
        XCTAssertTrue(receipts.values.isEmpty)
        let invalid = try await f.client.synchronizationTransportPlan(options(.push, target: "bad..destination"))
        do { _ = try await f.client.synchronize(invalid, onOutput: { _ in }, onCommandFinished: receipts.append, backend: cli); XCTFail("Malformed destination accepted") }
        catch let failure as GitFailure {
            XCTAssertEqual(failure.arguments, invalid.arguments); XCTAssertFalse(failure.arguments.contains("core.precomposeunicode=false"))
            XCTAssertTrue(failure.outputWasDelivered); XCTAssertFalse(failure.diagnosticText.isEmpty)
            XCTAssertEqual(receipts.values.last?.exitCode, failure.code)
        }
        let finalRefs = try await f.client.run(["show-ref"]).stdout
        XCTAssertEqual(finalRefs, refs); XCTAssertEqual(configBytes, try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")))
    }
}
