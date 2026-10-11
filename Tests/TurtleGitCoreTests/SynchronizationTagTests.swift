import XCTest
@testable import TurtleGitCore

final class SynchronizationTagTests: XCTestCase {
    private struct Fixture {
        let directory: URL, client: GitRepository, author: GitRepository, server: GitRepository, base: String
    }
    private func hash(_ repo: GitRepository, _ ref: String = "HEAD") async throws -> String {
        String(decoding: try await repo.run(["rev-parse", "--verify", "--end-of-options", ref]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-sync-tags-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let git = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/git")
        let parent = GitRepository(root: directory, executable: git), server = GitRepository(root: directory.appendingPathComponent("server.git"), executable: git), author = GitRepository(root: directory.appendingPathComponent("author"), executable: git), client = GitRepository(root: directory.appendingPathComponent("client"), executable: git)
        _ = try await parent.run(["init", "--bare", "--template=", "-b", "main", server.root.path])
        _ = try await parent.run(["init", "--template=", "-b", "main", author.root.path])
        for (key, value) in [("user.name", "Tag QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "false")] { _ = try await author.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: author.root.appendingPathComponent("file")); try await author.stage(["file"]); _ = try await author.commit(message: "base message")
        _ = try await author.run(["remote", "add", "origin", server.root.path]); _ = try await author.run(["push", "-u", "origin", "main"])
        _ = try await parent.run(["clone", "--template=", "--", server.root.path, client.root.path])
        for (key, value) in [("user.name", "Tag QA"), ("user.email", "qa@example.invalid"), ("tag.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "false")] { _ = try await client.run(["config", key, value]) }
        _ = try await server.run(["config", "core.hooksPath", "/dev/null"])
        return Fixture(directory: directory, client: client, author: author, server: server, base: try await hash(client))
    }
    func testSourceRowsRawAndImmediateNestedTargetsAndNoFetchForMetadata() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        for name in ["same", "local"] { _ = try await f.client.run(["tag", "--", name, f.base]) }
        // APFS cannot hold both loose spellings; Git's packed-refs can.
        let packedURL = f.client.root.appendingPathComponent(".git/packed-refs")
        var packed = (try? String(contentsOf: packedURL, encoding: .utf8)) ?? ""
        packed = packed.replacingOccurrences(of: " sorted", with: "")
        packed += f.base + " refs/tags/café\n" + f.base + " refs/tags/cafe\u{301}\n"
        try Data(packed.utf8).write(to: packedURL)
        _ = try await f.client.run(["tag", "-a", "-m", "inner annotation", "inner", f.base])
        let inner = try await hash(f.client, "refs/tags/inner")
        _ = try await f.client.run(["tag", "-a", "-m", "outer annotation", "outer", "refs/tags/inner"])
        let outer = try await hash(f.client, "refs/tags/outer")
        _ = try await f.client.run(["push", "origin", "refs/tags/same", "refs/tags/outer"])
        _ = try await f.author.run(["tag", "different", f.base]); _ = try await f.author.run(["push", "origin", "refs/tags/different"])
        try Data("new\n".utf8).write(to: f.author.root.appendingPathComponent("remote-file")); try await f.author.stage(["remote-file"]); _ = try await f.author.commit(message: "remote unseen")
        let unseen = try await hash(f.author)
        _ = try await f.author.run(["tag", "remote", unseen]); _ = try await f.author.run(["push", "origin", "main", "refs/tags/remote"])
        _ = try await f.client.run(["tag", "different", inner])
        let refs = try await f.client.run(["show-ref"]).stdout, index = try Data(contentsOf: f.client.root.appendingPathComponent(".git/index")), config = try Data(contentsOf: f.client.root.appendingPathComponent(".git/config"))
        let snapshot = try await f.client.synchronizationTags(remote: "origin")
        func row(_ name: String) -> SynchronizationTagRow { snapshot.rows.first { $0.name == GitReferenceName(name) }! }
        XCTAssertEqual(row("same").kind, .same); XCTAssertEqual(row("same").localMessage, "base message")
        XCTAssertEqual(row("local").kind, .onlyLocal); XCTAssertEqual(row("remote").kind, .onlyRemote); XCTAssertEqual(row("remote").remoteMessage, "")
        XCTAssertEqual(row("different").kind, .differ); XCTAssertEqual(row("different").localMessage, "")
        XCTAssertEqual(row("outer").localHash, outer); XCTAssertEqual(row("outer").remoteHash, outer)
        XCTAssertEqual(row("outer^{}").localHash, inner); XCTAssertEqual(row("outer^{}").remoteHash, f.base); XCTAssertEqual(row("outer^{}").kind, .differ)
        XCTAssertEqual(row("outer^{}").localMessage, ""); XCTAssertEqual(row("outer^{}").remoteMessage, "base message"); XCTAssertEqual(row("outer^{}").tag, GitReferenceName("outer"))
        XCTAssertNotEqual(row("café").name, row("cafe\u{301}").name)
        let advertised = try await f.client.remoteTags(remote: "origin")
        XCTAssertFalse(advertised.contains { $0.name.rawValue.hasSuffix("^{}") })
        let after = try await f.client.run(["show-ref"]).stdout
        XCTAssertEqual(refs, after); XCTAssertEqual(index, try Data(contentsOf: f.client.root.appendingPathComponent(".git/index"))); XCTAssertEqual(config, try Data(contentsOf: f.client.root.appendingPathComponent(".git/config")))
        let absent = try await f.client.run(["cat-file", "-e", unseen], successfulExitCodes: 0...128)
        XCTAssertNotEqual(absent.exitCode, 0)
    }
    func testSourceFetchWithoutForcePushWithForceAndConfirmedFriendlyDeletion() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.author.run(["tag", "-a", "-m", "remote annotation", "remote", f.base]); _ = try await f.author.run(["push", "origin", "refs/tags/remote"])
        let initial = try await f.client.synchronizationTags(remote: "origin"), remote = initial.rows.first { $0.name.rawValue == "remote^{}" }!
        _ = try await f.client.synchronizeTag(.fetch, row: remote, snapshot: initial)
        let fetched = try await hash(f.client, "refs/tags/remote"), remoteObject = try await hash(f.author, "refs/tags/remote")
        XCTAssertEqual(fetched, remoteObject)
        _ = try await f.client.run(["tag", "-f", "remote", f.base])
        let changed = try await f.client.synchronizationTags(remote: "origin"), changedRow = changed.rows.first { $0.name.rawValue == "remote" }!
        do { _ = try await f.client.synchronizeTag(.fetch, row: changedRow, snapshot: changed); XCTFail("fetch overwrote changed tag") } catch is GitFailure {}
        let stillLocal = try await hash(f.client, "refs/tags/remote"); XCTAssertEqual(stillLocal, f.base)
        _ = try await f.client.synchronizeTag(.push, row: changedRow, snapshot: changed)
        let pushed = try await hash(f.server, "refs/tags/remote"); XCTAssertEqual(pushed, f.base)
        _ = try await f.client.run(["tag", "-a", "-f", "-m", "local annotation", "remote", f.base])
        let annotated = try await f.client.synchronizationTags(remote: "origin"), peeled = annotated.rows.first { $0.name.rawValue == "remote^{}" }!
        do { _ = try await f.client.synchronizeTag(.deleteLocal, row: peeled, snapshot: annotated); XCTFail("unconfirmed deletion") } catch SynchronizationTransportFailure.deletionNotAuthorized {}
        _ = try await f.client.synchronizeTag(.deleteLocal, row: peeled, snapshot: annotated, deletionAuthorized: true)
        let localRows = try await f.client.run(["for-each-ref", "refs/tags/remote"]).stdout; XCTAssertTrue(localRows.isEmpty)
        let deletion = try await f.client.synchronizationTags(remote: "origin"), remoteOnly = deletion.rows.first { $0.name.rawValue == "remote" }!
        do { _ = try await f.client.synchronizeTag(.deleteRemote, row: remoteOnly, snapshot: deletion); XCTFail("unconfirmed remote deletion") } catch SynchronizationTransportFailure.deletionNotAuthorized {}
        _ = try await f.client.synchronizeTag(.deleteRemote, row: remoteOnly, snapshot: deletion, deletionAuthorized: true)
        let gone = try await f.server.run(["for-each-ref", "refs/tags/remote"]).stdout; XCTAssertTrue(gone.isEmpty)
    }
    func testStaleOrForeignSnapshotAndCancellationDoNotWriteTags() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = try await f.client.run(["tag", "local", f.base])
        let snapshot = try await f.client.synchronizationTags(remote: "origin"), row = snapshot.rows.first { $0.name.rawValue == "local" }!
        let foreign = GitRepository(root: f.client.root, executable: f.client.executable)
        do { _ = try await foreign.synchronizeTag(.push, row: row, snapshot: snapshot); XCTFail("foreign actor") } catch SynchronizationTransportFailure.repositoryChanged {}
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { _ = try await f.client.synchronizationTags(remote: "origin", cancellation: cancelled); XCTFail("cancelled read") } catch OperationCancellationFailure.cancelled {}
        do { _ = try await f.client.synchronizeTag(.push, row: row, snapshot: snapshot, cancellation: cancelled); XCTFail("cancelled write") } catch OperationCancellationFailure.cancelled {}
        do {
            _ = try await f.client.synchronizeTag(.push, row: row, snapshot: snapshot, prepareTransport: { _, _ in
                _ = try await f.client.run(["tag", "-a", "-f", "-m", "changed during authentication", "local", f.base]); return nil
            }); XCTFail("stale tag pushed")
        } catch SynchronizationTransportFailure.repositoryChanged {}
        let remote = try await f.client.remoteTags(remote: "origin"); XCTAssertTrue(remote.isEmpty)
        do { _ = try await f.client.synchronizationTags(remote: "bad\0remote"); XCTFail("NUL remote") } catch RemoteTagFailure.selection {}
    }
}
