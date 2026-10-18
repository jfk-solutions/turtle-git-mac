import XCTest
@testable import TurtleGitCore

final class MergeReflectedPatchTests: XCTestCase {
    private let git = URL(fileURLWithPath: "/usr/bin/git")
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitReflectedPatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func repository(_ root: URL) async throws {
        _ = try await GitRepository(root: root, executable: git).run(["init", "--quiet"])
    }
    private func content(_ text: String) -> ComparisonFileContent {
        .init(path: "temporary", revision: .workingTree, bytes: Data(text.utf8), mode: "100644", isDeleted: false)
    }
    func testReflectedRepositoryLabelsCreateApplicablePatchWithoutReadingReflectedFiles() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try await repository(root)
        let file = root.appendingPathComponent("nested/file.txt")
        let rawOld = root.path + "/missing/é.txt", rawNew = root.path + "/missing/e\u{301}.txt"
        let literal = try await MergeReflectedPatch.labels(baseReflectedName: rawOld, destinationReflectedName: rawNew, executable: git)
        XCTAssertEqual(Array((literal?.base ?? "").utf8), Array("missing/é.txt".utf8))
        XCTAssertEqual(Array((literal?.destination ?? "").utf8), Array("missing/e\u{301}.txt".utf8))
        // Reflected files need not exist. They describe where the selected
        // temporary inputs came from, rather than replacing either input.
        let generated = try await MergeUnifiedPatch.create(base: content("old\n"), destination: content("new\n"),
            baseLabel: "before.tmp", destinationLabel: "after.tmp", executable: git)
        let patch = try await MergeReflectedPatch.rewrite(generated, baseReflectedName: file.path,
            destinationReflectedName: file.path, executable: git)
        let text = String(decoding: patch, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("diff --git \"a/nested/file.txt\" \"b/nested/file.txt\"\nindex "))
        XCTAssertTrue(text.contains("\n--- \"a/nested/file.txt\"\n+++ \"b/nested/file.txt\"\n@@ "))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old\n".utf8).write(to: file)
        let output = root.appendingPathComponent("generated.diff"); try patch.write(to: output)
        _ = try await GitRepository(root: root, executable: git).run(["apply", "--", output.path])
        XCTAssertEqual(try Data(contentsOf: file), Data("new\n".utf8))
    }
    func testSeparateRepositoriesMissingAndAdministrativePathsRetainOriginalHeaders() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try await repository(first); try await repository(second)
        let generated = try await MergeUnifiedPatch.create(base: content("old\n"), destination: content("new\n"),
            baseLabel: "before.tmp", destinationLabel: "after.tmp", executable: git)
        let pairs: [(String?, String?)] = [(nil,first.appendingPathComponent("a").path),
                                        (first.appendingPathComponent("a").path,second.appendingPathComponent("a").path),
                                        ("relative/a",first.appendingPathComponent("a").path),
                                        (first.appendingPathComponent(".git/HEAD").path,first.appendingPathComponent("a").path),
                                        (root.appendingPathComponent("outside/a").path,root.appendingPathComponent("outside/b").path)]
        for pair in pairs {
            let unchanged = try await MergeReflectedPatch.rewrite(generated, baseReflectedName: pair.0,
                destinationReflectedName: pair.1, executable: git)
            XCTAssertEqual(unchanged, generated)
        }
    }
    func testHunksAndIndexRemainByteExactWhileQuotedNamesKeepLiteralUTF8Spelling() {
        let prefix = Data("diff --git a/before b/after\nindex abc..def 100644\n--- a/before\n+++ b/after\n".utf8)
        let hunk = Data("@@ -1 +1 @@\n-".utf8) + Data([0xe9,13,10]) + Data("+--- a/before\r\n\\ No newline at end of file\n".utf8)
        let nfc = "dir/é \"tab\tline\n\\.txt", nfd = "dir/e\u{301} \"tab\tline\n\\.txt"
        let patch = MergeReflectedPatch.rewritingHeaders(in: prefix + hunk, labels: .init(base: nfc, destination: nfd))
        XCTAssertEqual(patch.suffix(hunk.count), hunk)
        let header = String(decoding: patch.prefix(patch.count-hunk.count), as: UTF8.self)
        XCTAssertTrue(header.contains("a/dir/\\303\\251 \\\"tab\\tline\\n\\\\.txt"))
        XCTAssertTrue(header.contains("b/dir/e\\314\\201 \\\"tab\\tline\\n\\\\.txt"))
        XCTAssertTrue(header.contains("\nindex abc..def 100644\n"))
    }
    func testModeBinaryAddedDeletedAndUnrecognisedLayoutsStayByteExact() {
        let labels = MergeReflectedPatch.Labels(base: "file", destination: "file")
        let samples = ["", "diff --git a/before b/after\nold mode 100644\nnew mode 100755\n",
            "diff --git a/before b/after\nindex abc..def 100644\nBinary files a/before and b/after differ\n",
            "diff --git a/before b/after\nnew file mode 100644\nindex 000..abc\n--- /dev/null\n+++ b/after\n@@ -0,0 +1 @@\n+new\n",
            "diff --git a/before b/after\ndeleted file mode 100644\nindex abc..000\n--- a/before\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n",
            "diff --git a/before b/after\nindex abc..def\n--- a/before\n+++ b/after\nnot a hunk\n"]
        for sample in samples {
            let bytes = Data(sample.utf8)
            XCTAssertEqual(MergeReflectedPatch.rewritingHeaders(in: bytes, labels: labels), bytes)
        }
    }
    func testDifferentLinkedWorktreesDoNotShareLabels() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main"), linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true); try await repository(main)
        let repository = GitRepository(root: main, executable: git)
        _ = try await repository.run(["-c", "user.name=Private Fixture", "-c", "user.email=fixture@invalid", "commit", "--allow-empty", "--no-gpg-sign", "--no-verify", "-m", "fixture"])
        _ = try await repository.run(["worktree", "add", "--detach", linked.path, "HEAD"])
        let pair = try await MergeReflectedPatch.labels(baseReflectedName: main.appendingPathComponent("a").path,
            destinationReflectedName: linked.appendingPathComponent("a").path, executable: git)
        XCTAssertNil(pair)
        let same = try await MergeReflectedPatch.labels(baseReflectedName: linked.appendingPathComponent("a").path,
            destinationReflectedName: linked.appendingPathComponent("b").path, executable: git)
        XCTAssertEqual(same?.base, "a"); XCTAssertEqual(same?.destination, "b")
    }
    func testCancellationDoesNotStartDiscoveryEvenForEligiblePatch() async throws {
        let token = OperationCancellation(); token.cancel()
        let bytes = Data("diff --git a/before b/after\nindex abc..def\n--- a/before\n+++ b/after\n@@ -1 +1 @@\n-old\n+new\n".utf8)
        do {
            _ = try await MergeReflectedPatch.rewrite(bytes, baseReflectedName: "/unused/a", destinationReflectedName: "/unused/b",
                executable: URL(fileURLWithPath: "/missing/git"), cancellation: token)
            XCTFail("Expected owned cancellation")
        } catch { XCTAssertTrue(error is OperationCancellationFailure) }
    }
}
