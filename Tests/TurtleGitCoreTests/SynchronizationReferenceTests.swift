// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class SynchronizationReferenceTests: XCTestCase {
    private func fixture() async throws -> GitRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-sync-refs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/git")
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "--template=", "-b", "main"])
        for (key, value) in [("user.name", "Ref QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        return repo
    }
    private func commit(_ repo: GitRepository, tree: String, parent: String? = nil, time: Int, message: String) async throws -> String {
        var args = ["commit-tree", tree]; if let parent { args += ["-p", parent] }; args += ["-m", message]
        let date = "@\(time) +0000"
        return String(decoding: try await repo.run(args, environmentOverrides: ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func testPinnedAllRefChangesSourceClassificationsAndTagTargets() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.root) }
        let tree = String(decoding: try await repo.run(["write-tree"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let base = try await commit(repo, tree: tree, time: 1700000000, message: "base\n\nbody")
        let first = try await commit(repo, tree: tree, parent: base, time: 1700000010, message: "first")
        let tip = try await commit(repo, tree: tree, parent: first, time: 1700000020, message: "tip")
        let older = try await commit(repo, tree: tree, time: 1699999990, message: "unrelated older")
        let equalTime = try await commit(repo, tree: tree, time: 1700000000, message: "unrelated equal time")
        let newer = try await commit(repo, tree: tree, time: 1700000030, message: "unrelated newer")
        let oldValues = ["refs/heads/main": base, "refs/heads/forward": base, "refs/heads/rewind": tip,
                         "refs/heads/deleted": first, "refs/remotes/origin/newer": older,
                         "refs/remotes/origin/older": newer, "refs/remotes/origin/equal": base,
                         "refs/qa/noncommit": tree]
        for (name, hash) in oldValues { _ = try await repo.run(["update-ref", name, hash]) }
        _ = try await repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/newer"])
        _ = try await repo.run(["tag", "-a", "-m", "annotation one", "annotated", base])
        _ = try await repo.run(["tag", "lightweight", base])
        _ = try await repo.run(["tag", "-a", "-m", "nested annotation", "nested", "annotated"])
        let annotationObject = String(decoding: try await repo.run(["rev-parse", "refs/tags/annotated"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        // APFS loose refs normalize these names. Valid packed refs preserve
        // byte-distinct names and exercise dictionary identity without collision.
        let packed = repo.root.appendingPathComponent(".git/packed-refs")
        func writePacked(_ second: String) throws {
            try Data(("# pack-refs with: sorted\n" + base + " refs/qa/cafe\u{301}\n" + second + " refs/qa/café\n").utf8).write(to: packed)
        }
        try writePacked(base)
        let old = try await repo.synchronizationReferenceSnapshot()
        XCTAssertEqual(old.references[GitReferenceName("refs/tags/annotated^{}")], base)
        XCTAssertNil(old.references[GitReferenceName("refs/tags/annotated")])
        XCTAssertEqual(old.references[GitReferenceName("refs/tags/nested^{}")], annotationObject)
        XCTAssertEqual(old.references[GitReferenceName("refs/remotes/origin/HEAD")], older)
        XCTAssertEqual(old.references.keys.filter { $0.rawValue.hasPrefix("refs/qa/caf") }.count, 2)
        let newValues = ["refs/heads/forward": tip, "refs/heads/rewind": base, "refs/heads/new": tip,
                         "refs/remotes/origin/newer": newer, "refs/remotes/origin/older": older,
                         "refs/remotes/origin/equal": equalTime, "refs/qa/noncommit": base]
        for (name, hash) in newValues { _ = try await repo.run(["update-ref", name, hash]) }
        _ = try await repo.run(["update-ref", "-d", "refs/heads/deleted"])
        _ = try await repo.run(["tag", "-f", "-a", "-m", "annotation two", "annotated", base])
        _ = try await repo.run(["update-ref", "refs/tags/lightweight", tip])
        try writePacked(tip)
        let new = try await repo.synchronizationReferenceSnapshot()
        let refs = try await repo.run(["show-ref"]).stdout, config = try Data(contentsOf: repo.root.appendingPathComponent(".git/config"))
        let rows = try await repo.synchronizationReferenceChanges(from: old, to: new)
        func row(_ name: String) -> SynchronizationReferenceChange { rows.first { $0.name == GitReferenceName(name) }! }
        XCTAssertEqual(row("refs/heads/forward").kind, .forward); XCTAssertEqual(row("refs/heads/forward").count, 2)
        XCTAssertEqual(row("refs/heads/forward").oldMessage, "base"); XCTAssertEqual(row("refs/heads/forward").newMessage, "tip")
        XCTAssertEqual(row("refs/heads/rewind").kind, .rewind); XCTAssertEqual(row("refs/heads/rewind").count, 2)
        XCTAssertEqual(row("refs/heads/new").kind, .new); XCTAssertEqual(row("refs/heads/deleted").kind, .deleted)
        XCTAssertEqual(row("refs/remotes/origin/newer").kind, .newerTime)
        XCTAssertEqual(row("refs/remotes/origin/older").kind, .olderTime)
        XCTAssertEqual(row("refs/remotes/origin/equal").kind, .sameTime)
        XCTAssertEqual(row("refs/qa/noncommit").kind, .unknown); XCTAssertEqual(row("refs/qa/noncommit").oldMessage, "")
        XCTAssertEqual(row("refs/heads/main").kind, .same)
        XCTAssertEqual(row("refs/tags/annotated^{}").kind, .same); XCTAssertEqual(row("refs/tags/annotated^{}").shortName, "annotated")
        XCTAssertEqual(row("refs/tags/lightweight").kind, .forward)
        XCTAssertEqual(row("refs/qa/café").kind, .forward); XCTAssertEqual(row("refs/qa/cafe\u{301}").kind, .same)
        XCTAssertEqual(row("refs/remotes/origin/newer").typeName, "Remote branch")
        XCTAssertEqual(rows.map(\.kind.rawValue), rows.map(\.kind.rawValue).sorted())
        let after = try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(after, refs); XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent(".git/config")), config)
        _ = try await repo.run(["update-ref", "refs/heads/forward", base])
        XCTAssertEqual(row("refs/heads/forward").newHash, tip)
    }
    func testEmptySnapshotsCancellationAndRepositoryIdentity() async throws {
        let repo = try await fixture(); defer { try? FileManager.default.removeItem(at: repo.root) }
        let empty = try await repo.synchronizationReferenceSnapshot()
        XCTAssertTrue(empty.references.isEmpty)
        let rows = try await repo.synchronizationReferenceChanges(from: empty, to: empty); XCTAssertTrue(rows.isEmpty)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.synchronizationReferenceSnapshot(cancellation: token); XCTFail("cancel ignored") } catch OperationCancellationFailure.cancelled {}
        do { _ = try await repo.synchronizationReferenceChanges(from: empty, to: empty, cancellation: token); XCTFail("cancel ignored") } catch OperationCancellationFailure.cancelled {}
        let other = GitRepository(root: repo.root.appendingPathComponent("other"))
        do { _ = try await other.synchronizationReferenceChanges(from: empty, to: empty); XCTFail("cross-repository accepted") } catch SynchronizationTransportFailure.repositoryChanged {}
    }
}
