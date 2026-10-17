import XCTest
import Darwin
@testable import TurtleGitCore

final class HistoryFileCacheTests: XCTestCase {
    struct Fixture {
        let root: URL, repository: GitRepository, cache: HistoryFileCache, calls: URL
        func diffCalls() -> Int { ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").count }
    }
    func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-Cache-\n雪-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let calls = root.appendingPathComponent("calls"), wrapper = root.appendingPathComponent("git-wrapper")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let engine = ProcessInfo.processInfo.environment["TURTLEGIT_CACHE_TEST_GIT"] ?? "/usr/bin/git"
        let script = "#!/bin/sh\nfor arg in \"$@\"; do\nif [ \"$arg\" = diff-tree ]; then echo diff >> " + quote(calls.path) + "; fi\ndone\nexec " + quote(engine) + " \"$@\"\n"
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let repository = GitRepository(root: root, executable: wrapper, askpass: nil)
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Cache Fixture"), ("user.email", "cache@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "false")] {
            _ = try await repository.run(["config", key, value])
        }
        try Data("one\n".utf8).write(to: root.appendingPathComponent("file\n.txt"))
        _ = try await repository.run(["add", "--", "file\n.txt"]); _ = try await repository.run(["commit", "-m", "root"])
        try Data("two\nthree\n".utf8).write(to: root.appendingPathComponent("file\n.txt"))
        _ = try await repository.run(["add", "--", "file\n.txt"]); _ = try await repository.run(["commit", "-m", "changed"])
        return Fixture(root: root, repository: repository, cache: HistoryFileCache(root: root.appendingPathComponent("cache")), calls: calls)
    }
    func testPersistentHitsWithNewlineMetadataAndAttributeInvalidation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let history = try await f.repository.history()
        let entry = try XCTUnwrap(history.first)
        let global = f.root.appendingPathComponent("global-attributes\n")
        try Data("*.txt -diff\n".utf8).write(to: global)
        _ = try await f.repository.run(["config", "core.attributesfile", global.path])
        let first = try await f.repository.files(in: entry, cache: f.cache)
        XCTAssertNil(first.first?.added); XCTAssertEqual(f.diffCalls(), 3)
        let reopened = HistoryFileCache(root: f.cache.root)
        let second = try await GitRepository(root: f.root, executable: f.repository.executable, askpass: nil).files(in: entry, cache: reopened)
        XCTAssertEqual(first, second); XCTAssertEqual(f.diffCalls(), 3, "Reopened cache must avoid all diff-tree commands")
        try Data("*.txt diff\n".utf8).write(to: global)
        let changed = try await f.repository.files(in: entry, cache: reopened)
        XCTAssertEqual(changed.first?.added, 2); XCTAssertEqual(f.diffCalls(), 6)
        _ = try await f.repository.run(["update-index", "--assume-unchanged", "--", "file\n.txt"])
        let indexed = try await f.repository.files(in: entry, cache: reopened)
        XCTAssertEqual(indexed, changed); XCTAssertEqual(f.diffCalls(), 9, "Index change must invalidate reuse")
        let hits = try await f.repository.files(in: entry, cache: reopened)
        XCTAssertEqual(hits, indexed); XCTAssertEqual(f.diffCalls(), 9)
    }
    func testCorruptAndSymlinkRecordsFallBackAndCancellationRunsNoGit() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let history = try await f.repository.history()
        let entry = try XCTUnwrap(history.first)
        let expected = try await f.repository.files(in: entry, cache: f.cache)
        let key = try await f.repository.historyFileCacheContext(entry, cancellation: nil).key
        try Data("broken JSON".utf8).write(to: f.cache.url(key))
        let repaired = try await f.repository.files(in: entry, cache: f.cache)
        XCTAssertEqual(repaired, expected); XCTAssertEqual(f.diffCalls(), 6)
        let external = f.root.appendingPathComponent("external-record")
        try FileManager.default.moveItem(at: f.cache.url(key), to: external)
        try FileManager.default.createSymbolicLink(at: f.cache.url(key), withDestinationURL: external)
        let externalBytes = try Data(contentsOf: external)
        let safe = try await f.repository.files(in: entry, cache: f.cache)
        XCTAssertEqual(safe, expected); XCTAssertEqual(f.diffCalls(), 9)
        XCTAssertEqual(try Data(contentsOf: external), externalBytes)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await f.repository.files(in: entry, cache: f.cache, cancellation: token); XCTFail("Cancelled lookup succeeded") } catch is OperationCancellationFailure {}
        XCTAssertEqual(f.diffCalls(), 9)
        XCTAssertNil(f.cache.read(key, cancellation: token))
    }
    func testRootParentGroupsAndReplaceTreeInvalidation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let entries = try await f.repository.history(), entry = try XCTUnwrap(entries.first), root = try XCTUnwrap(entries.last)
        let groups = try await f.repository.logFileGroups(in: root, cache: f.cache)
        XCTAssertEqual(groups.count, 1); XCTAssertNil(groups[0].parent); XCTAssertEqual(groups[0].files.first?.action, "A")
        _ = try await f.repository.files(in: entry, cache: f.cache)
        let before = f.diffCalls()
        _ = try await f.repository.run(["replace", entry.hash, root.hash])
        let replaced = try await f.repository.files(in: entry, cache: f.cache)
        let direct = try await f.repository.files(in: entry)
        XCTAssertEqual(replaced, direct); XCTAssertTrue(replaced.isEmpty); XCTAssertEqual(f.diffCalls(), before + 6)
    }
    func testEvictionClearModesAndNamespace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cache-Evict-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HistoryFileCache(root: root), foreign = root.appendingPathComponent("preferences.json")
        try Data("foreign".utf8).write(to: foreign)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: foreign.path)
        for index in 0..<1025 { try Data("old".utf8).write(to: root.appendingPathComponent(String(format: "%064x", index) + ".json")) }
        let key = String(repeating: "f", count: 64)
        cache.write(.init(key: key, context: "context", attributes: "attributes", files: []))
        XCTAssertEqual(try cache.savedRecordCount(), 1024); XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: cache.url(key).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try cache.clear(); XCTAssertEqual(try cache.savedRecordCount(), 0); XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }
    func testBoundedReadersRejectFIFOAndOversizedRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Cache-Bounds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HistoryFileCache(root: root), key = String(repeating: "a", count: 64), file = cache.url(key)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0); XCTAssertNil(cache.read(key)); try FileManager.default.removeItem(at: file)
        try Data(repeating: 1, count: 8 * 1024 * 1024 + 1).write(to: file); XCTAssertNil(cache.read(key))
        XCTAssertThrowsError(try HistoryFileCache.readFile(file.path, limit: 10, cancellation: nil))
        cache.write(.init(key: "../escape", context: "", attributes: "", files: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape.json").path))
    }
}
