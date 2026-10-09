import XCTest
@testable import TurtleGitCore

final class RemoteTagTests: XCTestCase {
    func testRemoteTagCatalogSortingPeeledUnicodeDeletionAndNoLocalMutation() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["v2", "v10"] { _ = try await repo.run(["-c", "core.precomposeunicode=false", "tag", name], cancellation: OperationCancellation()) }
        _ = try await repo.run(["pack-refs", "--all", "--prune"])
        let oid = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines), packed = root.appendingPathComponent(".git/packed-refs")
        let records = try String(contentsOf: packed).split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init) + [oid + " refs/tags/Cafe\u{301}", oid + " refs/tags/Caf\u{e9}"]
        try Data(("# pack-refs with: sorted\n" + records.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.joined(separator: "\n") + "\n").utf8).write(to: packed)
        _ = try await repo.run(["tag", "-a", "annotated", "-m", "message"])
        let bareRoot = root.appendingPathComponent("remote.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path]); _ = try await repo.run(["remote", "add", "origin", bareRoot.path])
        let head = try Data(contentsOf: root.appendingPathComponent(".git/HEAD")), index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let tags = try await repo.remoteTags(remote: "origin"); XCTAssertEqual(tags.count, 5); XCTAssertFalse(tags.contains { $0.name.rawValue.hasSuffix("^{}") }); XCTAssertEqual(Set(tags.map(\.name)).count, 5)
        XCTAssertLessThan(try XCTUnwrap(tags.firstIndex { $0.name == "v2" }), try XCTUnwrap(tags.firstIndex { $0.name == "v10" }))
        let reverse = try await repo.remoteTags(remote: "origin", reversed: true); XCTAssertEqual(reverse.map(\.name), tags.reversed().map(\.name))
        let urlTags = try await repo.remoteTags(remote: bareRoot.path); XCTAssertEqual(urlTags.map(\.name), tags.map(\.name))
        try await repo.deleteRemoteTags(remote: "origin", tags: ["annotated", "Cafe\u{301}", "v2"])
        let after = try await repo.remoteTags(remote: "origin"); XCTAssertEqual(Set(after.map(\.name)), ["Caf\u{e9}", "v10"])
        let local = try await repo.referenceBrowser(); XCTAssertEqual(local.references.filter { $0.name.browserIsFrom("refs/tags") }.count, 5)
        XCTAssertEqual(head, try Data(contentsOf: root.appendingPathComponent(".git/HEAD"))); XCTAssertEqual(index, try Data(contentsOf: root.appendingPathComponent(".git/index"))); XCTAssertEqual(config, try Data(contentsOf: root.appendingPathComponent(".git/config")))
        XCTAssertEqual(RemoteTagConfirmation.message(["v2"]), "Do you really want to delete \"v2\"?")
        XCTAssertEqual(RemoteTagConfirmation.message(["v2", "v10"]), "Do you really want to permanently delete the 2 selected refs? It can NOT be recovered!")
    }
    func testRemoteTagValidationCancellationAndRejectedPushPreserveTags() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["tag", "keep"]); let bare = root.appendingPathComponent("remote.git"); _ = try await repo.run(["clone", "--bare", root.path, bare.path]); _ = try await repo.run(["remote", "add", "origin", bare.path])
        for tags: [GitReferenceName] in [[], ["keep", "keep"], ["keep", "bad..name"], ["keep", GitReferenceName("bad\0name")]] {
            do { try await repo.deleteRemoteTags(remote: "origin", tags: tags); XCTFail("Invalid tag batch ran") } catch {}
        }
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { _ = try await repo.remoteTags(remote: "origin", cancellation: cancelled); XCTFail("Cancelled catalog ran") } catch OperationCancellationFailure.cancelled {}
        do { try await repo.deleteRemoteTags(remote: "origin", tags: ["keep"], cancellation: cancelled); XCTFail("Cancelled deletion ran") } catch OperationCancellationFailure.cancelled {}
        let hook = bare.appendingPathComponent("hooks/pre-receive"); try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try await GitRepository(root: bare, executable: repo.executable).run(["config", "--unset", "core.hooksPath"], successfulExitCodes: 0...5)
        do { try await repo.deleteRemoteTags(remote: "origin", tags: ["keep"]); XCTFail("Rejected push succeeded") } catch is GitFailure {}
        let after = try await repo.remoteTags(remote: "origin"); XCTAssertEqual(after.map(\.name), ["keep"])
    }
}
