import XCTest
@testable import TurtleGitCore

final class WorkingTreePatchReviewTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitReview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Review"]); _ = try await repo.run(["config", "user.email", "review@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("one\ntwo\nthree\nfour\n".utf8).write(to: root.appendingPathComponent("--old 雪"))
        try Data("delete\n".utf8).write(to: root.appendingPathComponent("delete"))
        try Data([0, 1, 2, 3, 4]).write(to: root.appendingPathComponent("binary"))
        try Data("unrelated\n".utf8).write(to: root.appendingPathComponent("other"))
        try await repo.stage(["--old 雪", "delete", "binary", "other"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["mv", "--", "--old 雪", "--new 雪"])
        try Data("one\ntwo changed\nthree\nfour\n".utf8).write(to: root.appendingPathComponent("--new 雪"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("--new 雪").path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("delete"))
        try Data([0, 4, 3, 2, 1, 255]).write(to: root.appendingPathComponent("binary"))
        try Data("added\n".utf8).write(to: root.appendingPathComponent("added"))
        _ = try await repo.run(["add", "-A"])
        let bytes = try await repo.run(["diff", "--cached", "--binary", "--no-ext-diff", "--no-color", "-M"]).stdout
        _ = try await repo.run(["reset", "--hard", "HEAD"])
        return (root, repo, bytes)
    }
    func testReviewAndApplyTextBinaryRenameModesAddDeleteAndReverse() async throws {
        let (root, repo, bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let review = try await repo.reviewWorkingTreePatch(bytes)
        XCTAssertTrue(review.canApply); XCTAssertEqual(review.document.bytes, bytes)
        XCTAssertEqual(review.files.count, 4)
        XCTAssertTrue(review.files.first { $0.path == "binary" }?.isBinary == true)
        XCTAssertTrue(review.files.contains { $0.path == "--new 雪" })
        XCTAssertEqual(review.files.first { $0.path == "added" }?.additions, 1)
        XCTAssertEqual(review.files.first { $0.path == "delete" }?.deletions, 1)
        XCTAssertTrue(review.statistics.contains("binary")); XCTAssertTrue(review.summary.contains("rename")); XCTAssertTrue(review.summary.contains("mode"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("--old 雪")), Data("one\ntwo\nthree\nfour\n".utf8))
        _ = try await repo.applyWorkingTreePatch(review)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("--new 雪")), Data("one\ntwo changed\nthree\nfour\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("binary")), Data([0, 4, 3, 2, 1, 255]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("delete").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("added")), Data("added\n".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("--new 雪").path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o111, 0o111)
        let appliedHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(head, appliedHead); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let reverse = try await repo.reviewWorkingTreePatch(bytes, reversed: true); XCTAssertTrue(reverse.canApply)
        _ = try await repo.applyWorkingTreePatch(reverse)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("--old 雪")), Data("one\ntwo\nthree\nfour\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("binary")), Data([0, 1, 2, 3, 4]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("delete").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("added").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testStaleReviewRejectsWholePatchAndPreservesUnrelatedChanges() async throws {
        let (root, repo, bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let review = try await repo.reviewWorkingTreePatch(bytes)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("local change\n".utf8).write(to: root.appendingPathComponent("--old 雪"))
        try Data("unrelated local change\n".utf8).write(to: root.appendingPathComponent("other"))
        let failed = try await repo.reviewWorkingTreePatch(bytes)
        XCTAssertFalse(failed.canApply); XCTAssertNotNil(failed.validationError)
        do { _ = try await repo.applyWorkingTreePatch(review); XCTFail("Stale patch applied") } catch is GitFailure {}
        do { _ = try await repo.applyWorkingTreePatch(failed); XCTFail("Failed review applied") } catch WorkingTreePatchFailure.review {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("--old 雪")), Data("local change\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("added").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("binary")), Data([0, 1, 2, 3, 4]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        try Data("one\ntwo\nthree\nfour\n".utf8).write(to: root.appendingPathComponent("--old 雪"))
        _ = try await repo.applyWorkingTreePatch(review)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("other")), Data("unrelated local change\n".utf8))
    }
    func testUnsafePathsAndRepositoryMismatchAreRejected() async throws {
        let (root, repo, bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        for path in ["../outside", ".git/config"] {
            let malicious = Data("diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1 @@\n+malicious\n".utf8)
            let review = try await repo.reviewWorkingTreePatch(malicious); XCTAssertFalse(review.canApply)
            do { _ = try await repo.applyWorkingTreePatch(review); XCTFail("Unsafe patch applied") } catch WorkingTreePatchFailure.review {}
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
        let review = try await repo.reviewWorkingTreePatch(bytes)
        let (other, otherRepo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: other) }
        do { _ = try await otherRepo.applyWorkingTreePatch(review); XCTFail("Different repository accepted") } catch WorkingTreePatchFailure.review {}
    }
    func testInvalidInputAndZeroStripPlainPatch() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repo.reviewWorkingTreePatch(Data(), stripCount: -1); XCTFail("Invalid strip count accepted") } catch WorkingTreePatchFailure.stripCount {}
        for data in [Data(), Data("not a patch".utf8)] {
            do { _ = try await repo.reviewWorkingTreePatch(data); XCTFail("Invalid patch accepted") } catch is GitFailure {}
        }
        let plain = Data("--- other\n+++ other\n@@ -1 +1 @@\n-unrelated\n+plain changed\n".utf8)
        let review = try await repo.reviewWorkingTreePatch(plain, stripCount: 0); XCTAssertTrue(review.canApply)
        _ = try await repo.applyWorkingTreePatch(review)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("other")), Data("plain changed\n".utf8))
    }
    func testRealNumstatPreservesTabsNewlinesUnicodeAndReverseCounts() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let names = ["tabs\tfile\n雪", "-dash space😀"]
        for name in names { try Data("base\n".utf8).write(to: root.appendingPathComponent(name)) }
        try await repo.stage(names); _ = try await repo.commit(message: "unusual paths")
        for name in names { try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent(name)) }
        let bytes = try await repo.run(["diff", "--binary", "--no-ext-diff", "--no-color", "--"] + names).stdout
        let reverse = try await repo.reviewWorkingTreePatch(bytes, reversed: true)
        XCTAssertTrue(reverse.canApply); XCTAssertEqual(Set(reverse.files.map(\.path)), Set(names))
        XCTAssertTrue(reverse.files.allSatisfy { $0.additions == 1 && $0.deletions == 2 && !$0.isBinary })
        _ = try await repo.run(["restore", "--"] + names)
        let review = try await repo.reviewWorkingTreePatch(bytes)
        XCTAssertTrue(review.canApply); XCTAssertEqual(review.document.bytes, bytes)
        XCTAssertEqual(Set(review.files.map(\.pathBytes)), Set(names.map { Data($0.utf8) }))
        XCTAssertEqual(review.files.map(\.id), [0, 1])
        XCTAssertTrue(review.files.allSatisfy { $0.additions == 2 && $0.deletions == 1 && !$0.isBinary })
        _ = try await repo.applyWorkingTreePatch(review)
        for name in names { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data("one\ntwo\n".utf8)) }
    }
    func testMetadataRetainsRawNonUTF8PathsAndRejectsIncompleteRecords() throws {
        let rawPath = Data([0xff, 9, 10, 0xfe])
        let binary = try WorkingTreePatchReview.parseFiles(Data("-\t-\t".utf8) + rawPath + Data([0]))
        XCTAssertEqual(binary.count, 1); XCTAssertEqual(binary[0].pathBytes, rawPath); XCTAssertTrue(binary[0].isBinary)
        for malformed in [Data("1\t2\tpath".utf8), Data("1\t-\tpath\0".utf8), Data("1\t2\t\0".utf8)] {
            XCTAssertThrowsError(try WorkingTreePatchReview.parseFiles(malformed))
        }
    }

}
