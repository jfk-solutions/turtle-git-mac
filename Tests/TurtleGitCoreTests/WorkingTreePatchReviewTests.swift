import XCTest
@testable import TurtleGitCore

final class WorkingTreePatchReviewTests: XCTestCase {
    func fixture(format: String = "sha1") async throws -> (URL, GitRepository, Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitReview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_TEST_GIT"] ?? "/usr/bin/git"))
        _ = try await repo.run(["init", "-b", "main", "--object-format=" + format])
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

    func testSelectedRenameBinaryAndRemainingFilesPreserveIndex() async throws {
        let (root, repo, bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let review = try await repo.reviewWorkingTreePatch(bytes)
        let rename = try await repo.reviewWorkingTreePatchFiles(review, fileIDs: [review.files.first { $0.path == "--new 雪" }!.id])
        XCTAssertTrue(rename.canApply); XCTAssertEqual(rename.files.count, 1); XCTAssertEqual(rename.document.bytes, bytes)
        _ = try await repo.applyWorkingTreePatch(rename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("--new 雪").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("delete").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("added").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("binary")), Data([0, 1, 2, 3, 4]))
        let binary = try await repo.reviewWorkingTreePatchFiles(review, fileIDs: [review.files.first { $0.isBinary }!.id])
        XCTAssertTrue(binary.canApply); _ = try await repo.applyWorkingTreePatch(binary)
        let remaining = Set(review.files.filter { ["added", "delete"].contains($0.path) }.map(\.id))
        let rest = try await repo.reviewWorkingTreePatchFiles(review, fileIDs: remaining)
        XCTAssertTrue(rest.canApply); _ = try await repo.applyWorkingTreePatch(rest)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let reversed = try await repo.reviewWorkingTreePatch(bytes, reversed: true)
        let reverseRename = try await repo.reviewWorkingTreePatchFiles(reversed, fileIDs: [reversed.files.first { $0.path == "--old 雪" }!.id])
        _ = try await repo.applyWorkingTreePatch(reverseRename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("--old 雪").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("binary")), Data([0, 4, 3, 2, 1, 255]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testLiteralSelectionDoesNotMatchGlobNeighborsOrConflictingFiles() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let selectedNames = ["wild*.txt", "question?.txt", "[ab].txt", "slash\\name.txt", "dir/file?.txt", "stars*\t雪\nfile"]
        let neighbors = ["wild1.txt", "question1.txt", "a.txt", "slashname.txt", "dir/file1.txt"]
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        for name in selectedNames + neighbors { try Data("base\n".utf8).write(to: root.appendingPathComponent(name)) }
        try await repo.stage(selectedNames + neighbors); _ = try await repo.commit(message: "glob paths")
        for name in selectedNames + neighbors { try Data("changed\n".utf8).write(to: root.appendingPathComponent(name)) }
        let bytes = try await repo.run(["diff", "--no-ext-diff", "--no-color", "--"] + selectedNames + neighbors).stdout
        _ = try await repo.run(["restore", "--"] + selectedNames + neighbors)
        try Data("conflicting local change\n".utf8).write(to: root.appendingPathComponent("wild1.txt"))
        let review = try await repo.reviewWorkingTreePatch(bytes); XCTAssertFalse(review.canApply)
        let ids = Set(review.files.filter { selectedNames.contains($0.path) }.map(\.id))
        let selected = try await repo.reviewWorkingTreePatchFiles(review, fileIDs: ids)
        XCTAssertTrue(selected.canApply); XCTAssertEqual(Set(selected.files.map(\.path)), Set(selectedNames))
        _ = try await repo.applyWorkingTreePatch(selected)
        for name in selectedNames { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data("changed\n".utf8)) }
        for name in neighbors {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data((name == "wild1.txt" ? "conflicting local change\n" : "base\n").utf8))
        }
        for invalid in [Set<Int>(), Set([99999])] {
            do { _ = try await repo.reviewWorkingTreePatchFiles(review, fileIDs: invalid); XCTFail("Invalid selection accepted") } catch WorkingTreePatchFailure.selection {}
        }
    }

    func testDuplicateFileRecordsCannotBePartiallySelected() async throws {
        let (root, repo, bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let review = try await repo.reviewWorkingTreePatch(bytes + bytes)
        XCTAssertEqual(review.files.count, 8)
        let first = review.files[0]
        XCTAssertEqual(review.files.filter { $0.pathBytes == first.pathBytes }.count, 2)
        do { _ = try await repo.reviewWorkingTreePatchFiles(review, fileIDs: [first.id]); XCTFail("Unchecked repeated record selected") } catch WorkingTreePatchFailure.selection {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("added").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("--old 雪").path))
    }

    func testFileComparisonsUseCurrentBytesWithoutTouchingWorktreeOrIndex() async throws {
        let (root, repo, bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let review = try await repo.reviewWorkingTreePatch(bytes)
        var comparisons: [String: WorkingTreePatchFileComparison] = [:]
        for file in review.files {
            let value = try await repo.compareWorkingTreePatchFile(review, fileID: file.id)
            XCTAssertEqual(value.fileID, file.id); comparisons[file.path] = value
        }
        let rename = comparisons["--new 雪"]!.document
        XCTAssertEqual(rename.base.path, "--old 雪"); XCTAssertEqual(rename.destination.path, "--new 雪")
        XCTAssertEqual(rename.base.bytes, Data("one\ntwo\nthree\nfour\n".utf8))
        XCTAssertEqual(rename.destination.bytes, Data("one\ntwo changed\nthree\nfour\n".utf8))
        XCTAssertEqual(rename.base.mode, "100644"); XCTAssertEqual(rename.destination.mode, "100755")
        XCTAssertNil(comparisons["added"]!.document.base.mode)
        XCTAssertEqual(comparisons["added"]!.document.destination.bytes, Data("added\n".utf8))
        XCTAssertNil(comparisons["delete"]!.document.destination.mode)
        XCTAssertEqual(comparisons["delete"]!.document.base.bytes, Data("delete\n".utf8))
        XCTAssertEqual(comparisons["binary"]!.document.base.bytes, Data([0, 1, 2, 3, 4]))
        XCTAssertEqual(comparisons["binary"]!.document.destination.bytes, Data([0, 4, 3, 2, 1, 255]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("--old 雪")), rename.base.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("--new 雪").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let unchangedHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(unchangedHead, head)
        _ = try await repo.applyWorkingTreePatch(review)
        let reverse = try await repo.reviewWorkingTreePatch(bytes, reversed: true)
        for file in reverse.files {
            let value = try await repo.compareWorkingTreePatchFile(reverse, fileID: file.id)
            let forward = comparisons[file.path == "--old 雪" ? "--new 雪" : file.path]!.document
            XCTAssertEqual(value.document.base.bytes, forward.destination.bytes)
            XCTAssertEqual(value.document.destination.bytes, forward.base.bytes)
            XCTAssertEqual(value.document.destination.mode, forward.base.mode)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testFileComparisonLiteralPathsLocalPolicyAndSymlinkBytes() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let name = "wild*?[]\\\t雪\nfile"
        try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent(name))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "missing-before")
        try await repo.stage([name, "link"]); _ = try await repo.commit(message: "paths and link")
        try Data("one\nchanged   \n".utf8).write(to: root.appendingPathComponent(name))
        try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "missing-after")
        let bytes = try await repo.run(["diff", "--binary", "--no-ext-diff", "--no-color"]).stdout
        _ = try await repo.run(["restore", "--", name, "link"])
        _ = try await repo.run(["config", "apply.whitespace", "fix"])
        let review = try await repo.reviewWorkingTreePatch(bytes)
        let text = try await repo.compareWorkingTreePatchFile(review, fileID: review.files.first { $0.path == name }!.id)
        XCTAssertEqual(text.document.destination.bytes, Data("one\nchanged\n".utf8))
        let link = try await repo.compareWorkingTreePatchFile(review, fileID: review.files.first { $0.path == "link" }!.id)
        XCTAssertEqual(link.document.base.mode, "120000"); XCTAssertEqual(link.document.destination.mode, "120000")
        XCTAssertEqual(link.document.base.bytes, Data("missing-before".utf8)); XCTAssertEqual(link.document.destination.bytes, Data("missing-after".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("link").path), "missing-before")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data("one\ntwo\n".utf8))
    }
    func testFileComparisonRefusesStaleUnsafeAndForeignReviews() async throws {
        let (root, repo, bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let review = try await repo.reviewWorkingTreePatch(bytes), file = review.files.first { $0.path == "--new 雪" }!
        try Data("local conflict\n".utf8).write(to: root.appendingPathComponent("--old 雪"))
        do { _ = try await repo.compareWorkingTreePatchFile(review, fileID: file.id); XCTFail("Stale comparison accepted") } catch WorkingTreePatchFailure.review {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("--old 雪")), Data("local conflict\n".utf8))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("actual"), withIntermediateDirectories: true)
        try Data("before\n".utf8).write(to: root.appendingPathComponent("actual/file"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "actual")
        let throughLink = Data("diff --git a/alias/file b/alias/file\n--- a/alias/file\n+++ b/alias/file\n@@ -1 +1 @@\n-before\n+after\n".utf8)
        let aliasReview = try await repo.reviewWorkingTreePatch(throughLink)
        do { _ = try await repo.compareWorkingTreePatchFile(aliasReview, fileID: aliasReview.files[0].id); XCTFail("Symlink parent preview accepted") } catch WorkingTreePatchFailure.review { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("actual/file")), Data("before\n".utf8))
        let (other, otherRepo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: other) }
        do { _ = try await otherRepo.compareWorkingTreePatchFile(review, fileID: file.id); XCTFail("Foreign review accepted") } catch WorkingTreePatchFailure.selection {}
        for path in ["../outside", ".git/config"] {
            let unsafe = Data("diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1 @@\n+unsafe\n".utf8)
            let rejected = try await repo.reviewWorkingTreePatch(unsafe)
            do { _ = try await repo.compareWorkingTreePatchFile(rejected, fileID: rejected.files[0].id); XCTFail("Unsafe preview accepted") } catch WorkingTreePatchFailure.review {}
        }
    }

    func testEditedRenameSaveAndZeroLineRemovalPreserveHeadAndIndex() async throws {
        let (root, repo, bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let review = try await repo.reviewWorkingTreePatch(bytes)
        let rename = try await repo.compareWorkingTreePatchFile(review, fileID: review.files.first { $0.path == "--new 雪" }!.id)
        let saved = try await repo.saveWorkingTreePatchFile(rename, text: "edited\nno final newline", autoAddNewFiles: false)
        XCTAssertNil(saved.addError)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("--new 雪")), Data("edited\nno final newline".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("--old 雪").path))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("--new 雪").path)[.posixPermissions] as! NSNumber).intValue & 0o111, 0o111)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(head, afterHead)
        let added = try await repo.compareWorkingTreePatchFile(review, fileID: review.files.first { $0.path == "added" }!.id)
        _ = try await repo.saveWorkingTreePatchFile(added, text: "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("added").path))
        let plain = Data("--- other\n+++ other\n@@ -1 +1 @@\n-unrelated\n+changed\n".utf8)
        let deletionReview = try await repo.reviewWorkingTreePatch(plain, stripCount: 0)
        let deletion = try await repo.compareWorkingTreePatchFile(deletionReview, fileID: deletionReview.files[0].id)
        _ = try await repo.saveWorkingTreePatchFile(deletion, text: "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("other").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testEditedSaveAutoAddAndFailureKeepSavedBytesAndRejectStaleCollision() async throws {
        let (root, repo, bytes) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let review = try await repo.reviewWorkingTreePatch(bytes), id = review.files.first { $0.path == "added" }!.id
        let comparison = try await repo.compareWorkingTreePatchFile(review, fileID: id)
        try Data("collision\n".utf8).write(to: root.appendingPathComponent("added"))
        do { _ = try await repo.saveWorkingTreePatchFile(comparison, text: "edited\n"); XCTFail("Collision overwritten") } catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("added")), Data("collision\n".utf8))
        try FileManager.default.removeItem(at: root.appendingPathComponent("added"))
        let saved = try await repo.saveWorkingTreePatchFile(comparison, text: "edited\n")
        XCTAssertNil(saved.addError)
        let staged = try await repo.run(["show", ":added"]).stdout; XCTAssertEqual(staged, Data("edited\n".utf8))
        _ = try await repo.run(["reset", "--hard", "HEAD"])
        try Data("added\n".utf8).write(to: root.appendingPathComponent(".git/info/exclude"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let failure = try await repo.saveWorkingTreePatchFile(comparison, text: "saved despite Add failure\n")
        XCTAssertNotNil(failure.addError)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("added")), Data("saved despite Add failure\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let (foreign, foreignRepo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: foreign) }
        do { _ = try await foreignRepo.saveWorkingTreePatchFile(comparison, text: "foreign"); XCTFail("Foreign save accepted") } catch FileComparisonEditFailure.unsupported {}
    }
    func testEditedSaveKeepsUTF16BOMCRLFAndWhitespaceInSHA256Repository() async throws {
        let (root, repo, _) = try await fixture(format: "sha256"); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("wild*?,雪\t\nfile")
        try ComparisonTextEncoding.utf16LEBOM.encode("before\r\n").write(to: file)
        try await repo.stage([file.lastPathComponent]); _ = try await repo.commit(message: "UTF16")
        try ComparisonTextEncoding.utf16LEBOM.encode("proposed\r\n").write(to: file)
        let bytes = try await repo.run(["diff", "--binary", "--no-ext-diff", "--no-color"]).stdout
        _ = try await repo.run(["restore", "--", file.lastPathComponent])
        _ = try await repo.run(["config", "apply.whitespace", "fix"])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let review = try await repo.reviewWorkingTreePatch(bytes), comparison = try await repo.compareWorkingTreePatchFile(review, fileID: review.files[0].id)
        XCTAssertEqual(comparison.document.destination.encoding, .utf16LEBOM)
        _ = try await repo.saveWorkingTreePatchFile(comparison, text: "edited   \r\nlast", autoAddNewFiles: false)
        XCTAssertEqual(try Data(contentsOf: file), try ComparisonTextEncoding.utf16LEBOM.encode("edited   \r\nlast"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }

}
