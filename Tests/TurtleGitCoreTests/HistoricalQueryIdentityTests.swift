// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

/// Raw objects and packed refs avoid relying on filesystem normalization rules.
final class HistoricalQueryIdentityTests: XCTestCase {
    private let nfc = "Café", nfd = "Cafe\u{301}"
    private struct Fixture {
        let root: URL, repo: GitRepository
        let initial: String, first: String, second: String
        let config: Data, index: Data, packed: Data
    }
    private func fixture() async throws -> Fixture {
        let (root, repo, _) = try await GitPatchTests().fixture()
        do {
            _ = try await repo.run(["config", "core.precomposeunicode", "true"])
            func blob(_ value: String) async throws -> String {
                try await repo.run(["hash-object", "-w", "--stdin"], input: Data(value.utf8)).text.trimmingCharacters(in: .newlines)
            }
            func tree(_ records: [(String, String, String)]) async throws -> String {
                let bytes = records.map { "\($0.0) \($0.0 == "040000" ? "tree" : "blob") \($0.1)\t\($0.2)\0" }.joined()
                return try await repo.run(["mktree", "-z"], input: Data(bytes.utf8)).text.trimmingCharacters(in: .newlines)
            }
            let old = try await blob("old\n"), a = try await blob("NFC change\n"), b = try await blob("NFD change\n")
            let nested = try await tree([("100644", old, "child")])
            func commit(_ left: String, _ right: String, parent: String?, title: String) async throws -> String {
                let object = try await tree([("100644", old, nfc), ("040000", nested, nfd),
                    ("100644", left, nfc + ".txt"), ("100644", right, nfd + ".txt")])
                return try await repo.run(["commit-tree", object] + (parent.map { ["-p", $0] } ?? []) + ["-m", title]).text.trimmingCharacters(in: .newlines)
            }
            let initial = try await commit(old, old, parent: nil, title: "raw base")
            let first = try await commit(a, old, parent: initial, title: "NFC only")
            let second = try await commit(a, b, parent: first, title: "NFD only")
            _ = try await repo.run(["update-ref", "HEAD", second])
            let refs = [("refs/tags/" + nfc, first), ("refs/tags/" + nfd, second)].sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
            let packed = Data(("# pack-refs with: sorted\n" + refs.map { $0.1 + " " + $0.0 + "\n" }.joined()).utf8)
            try packed.write(to: root.appendingPathComponent(".git/packed-refs"))
            return Fixture(root: root, repo: repo, initial: initial, first: first, second: second,
                config: try Data(contentsOf: root.appendingPathComponent(".git/config")),
                index: try Data(contentsOf: root.appendingPathComponent(".git/index")), packed: packed)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    private func preserved(_ fixture: Fixture) async throws {
        let head = try await fixture.repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(head, fixture.second)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(".git/config")), fixture.config)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")), fixture.index)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(".git/packed-refs")), fixture.packed)
        let setting = try await fixture.repo.run(["config", "--get", "core.precomposeunicode"]).text
        XCTAssertEqual(setting, "true\n")
    }
    func testScopedHistoryAndPathKindsPreserveRawQueryBytes() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for (path, changed) in [(nfc + ".txt", f.first), (nfd + ".txt", f.second)] {
            var options = HistoryOptions(); options.paths = [path]; options.useMailmap = false
            let entries = try await f.repo.history(options: options)
            XCTAssertEqual(entries.map(\.hash), [changed, f.initial], path)
        }
        let scopes = try await f.repo.historyPathScopes(paths: [nfc, nfd], revision: "HEAD")
        XCTAssertEqual(scopes.map { Data($0.path.utf8) }, [Data(nfc.utf8), Data(nfd.utf8)])
        XCTAssertEqual(scopes.map(\.isDirectory), [false, true])
        let followsFile = try await f.repo.canFollowHistory(paths: [nfc], revision: "HEAD")
        let followsDirectory = try await f.repo.canFollowHistory(paths: [nfd], revision: "HEAD")
        XCTAssertTrue(followsFile); XCTAssertFalse(followsDirectory)
        try await preserved(f)
    }
    func testNamedRangesAndBrowserQueriesKeepDistinctPackedReferences() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let left = "refs/tags/" + nfc, right = "refs/tags/" + nfd
        var options = HistoryOptions(); options.useMailmap = false
        options.revisionRange = HistoryRevisionRange(from: left, to: right)
        let forward = try await f.repo.history(options: options)
        XCTAssertEqual(forward.map(\.hash), [f.second])
        options.revisionRange = HistoryRevisionRange(from: right, to: left)
        let reverse = try await f.repo.history(options: options)
        XCTAssertTrue(reverse.isEmpty)
        for (reference, hash, contents) in [(left, f.first, "old\n"), (right, f.second, "NFD change\n")] {
            options.revisionRange = nil; options.endRevision = reference; options.paths = [nfd + ".txt"]
            let entries = try await f.repo.history(options: options)
            XCTAssertEqual(entries.first?.hash, hash == f.first ? f.initial : f.second)
            let snapshot = try await f.repo.browseRepository(revision: reference)
            XCTAssertEqual(snapshot.objectID, hash)
            XCTAssertEqual(Data(snapshot.revision.utf8), Data(reference.utf8))
            let entry = try XCTUnwrap(snapshot.entries.first { GitReferenceName.equal($0.path, nfd + ".txt") })
            let content = try await f.repo.materializedRepositoryBrowserFile(snapshot, entry: entry, backend: .init(enabled: false))
            XCTAssertEqual(content.bytes, Data(contents.utf8))
        }
        try await preserved(f)
    }
}
