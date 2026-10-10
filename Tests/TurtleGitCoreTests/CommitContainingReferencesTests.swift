import XCTest
@testable import TurtleGitCore

final class CommitContainingReferencesTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, String, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Original Author"), ("user.email", "original@example.invalid"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.abbrev", "12")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Root")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["branch", "old", base])
        try Data("next\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Descendant")
        let next = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["tag", "-a", "inner", "-m", "Inner", next]); _ = try await repo.run(["tag", "-a", "outer", "-m", "Outer", "inner"])
        let blob = try await repo.run(["rev-parse", "HEAD:file.txt"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["tag", "blob-tag", blob])
        _ = try await repo.run(["tag", "light", next]); _ = try await repo.run(["tag", "root-tag", base])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", next]); _ = try await repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        _ = try await repo.run(["update-ref", "refs/notes/nonbranch", next])
        return (root, repo, base, next)
    }
    func testContainingDescendantsNestedTagsSymbolicRemoteAndMappedMetadataPreserveRepository() async throws {
        let (root, repo, base, next) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("Mapped Author <mapped@example.invalid> Original Author <original@example.invalid>\n".utf8).write(to: root.appendingPathComponent(".mailmap"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let before = try await repo.run(["status", "--porcelain=v1", "-z"]).stdout
        let rootResult = try await repo.commitContainingReferences(base)
        let wanted = Set(["refs/heads/main", "refs/heads/old", "refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/tags/inner", "refs/tags/outer", "refs/tags/light", "refs/tags/root-tag"].map { GitReferenceName($0) })
        XCTAssertEqual(Set(rootResult.references), wanted)
        XCTAssertEqual(rootResult.filtered(""), rootResult.references)
        let descendant = try await repo.commitContainingReferences("outer")
        XCTAssertEqual(descendant.hash, next); XCTAssertEqual(descendant.abbreviatedHash, String(next.prefix(12))); XCTAssertEqual(descendant.subject, "Descendant"); XCTAssertEqual(descendant.author, "Mapped Author"); XCTAssertFalse(descendant.bare)
        XCTAssertFalse(descendant.references.contains("refs/heads/old")); XCTAssertFalse(descendant.references.contains("refs/tags/root-tag"))
        XCTAssertTrue(descendant.completion.contains("refs/tags/blob-tag")); XCTAssertFalse(descendant.references.contains("refs/tags/blob-tag"))
        XCTAssertTrue(descendant.completion.contains("refs/notes/nonbranch")); XCTAssertFalse(descendant.references.contains("refs/notes/nonbranch"))
        let after = try await repo.run(["status", "--porcelain=v1", "-z"]).stdout, head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(before, after); XCTAssertEqual(head, next)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
    }
    func testLiteralFilterKeepsDistinctUnicodeNamesAndDetachedHeadIsNotAReference() async throws {
        let (root, repo, base, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        // Canonically equivalent loose APFS paths alias. Packed refs preserve both byte spellings.
        _ = try await repo.run(["pack-refs", "--all", "--prune"])
        let packed = root.appendingPathComponent(".git/packed-refs")
        var bytes = try Data(contentsOf: packed)
        bytes.append(Data(["refs/heads/café2", "refs/heads/cafe\u{301}2", "refs/heads/café10"].map { base + " " + $0 + "\n" }.joined().utf8))
        // Remove the sorted declaration: the newly appended fixture refs are intentionally not sorted.
        let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "# pack-refs with: peeled fully-peeled sorted", with: "# pack-refs with: peeled fully-peeled")
        try Data(text.utf8).write(to: packed)
        _ = try await repo.run(["checkout", "--detach", base])
        let result = try await repo.commitContainingReferences("HEAD")
        XCTAssertEqual(result.filtered("café").map(\.rawValue), ["refs/heads/café2", "refs/heads/café10"])
        XCTAssertEqual(result.filtered("cafe\u{301}").map(\.rawValue), ["refs/heads/cafe\u{301}2"])
        XCTAssertTrue(result.filtered("CAFÉ").isEmpty); XCTAssertTrue(result.references.allSatisfy { $0.rawValue.hasPrefix("refs/") })
    }
    func testBareInvalidAndCancelledReads() async throws {
        let (root, repo, _, next) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bare = root.appendingPathExtension("bare"); defer { try? FileManager.default.removeItem(at: bare) }
        _ = try await repo.run(["clone", "--bare", "--", root.path, bare.path])
        let bareRepo = GitRepository(root: bare, executable: repo.executable), result = try await bareRepo.commitContainingReferences("HEAD")
        XCTAssertTrue(result.bare); XCTAssertEqual(result.hash, next)
        for invalid in ["", "--all", "missing"] { do { _ = try await repo.commitContainingReferences(invalid); XCTFail("Accepted invalid revision") } catch {} }
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.commitContainingReferences("HEAD", cancellation: token); XCTFail("Accepted cancellation") } catch { XCTAssertTrue(token.isCancelled) }
    }
}
