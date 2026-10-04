import XCTest
@testable import TurtleGitCore

final class RevisionComparisonTests: XCTestCase {
    func testOrdinaryFileDiffIncludesStagedWorkingRenameAndExplicitUntrackedWithoutIndexWrites() async throws {
        let (root, repo, original) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let before = try Data(contentsOf: root.appendingPathComponent(original))
        let renamed = ":(glob)* moved 雪\n.txt", new = "new text.txt"
        _ = try await repo.run(["mv", "--", original, renamed])
        let staged = String(decoding: before, as: UTF8.self).replacingOccurrences(of: "line 2\n", with: "staged text\n")
        let working = staged.replacingOccurrences(of: "line 26\n", with: "working text\n")
        try Data(staged.utf8).write(to: root.appendingPathComponent(renamed)); try await repo.stage([renamed])
        try Data(working.utf8).write(to: root.appendingPathComponent(renamed))
        try Data("new working\n".utf8).write(to: root.appendingPathComponent(new))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let snapshot = try await repo.workingFileComparison(paths: [renamed, new, renamed])
        XCTAssertEqual(snapshot.from, .revision(head)); XCTAssertEqual(snapshot.to, .workingTree)
        XCTAssertEqual(Set(snapshot.files.map(\.path)), [renamed, new])
        let fresh = try await repo.comparisonFile(snapshot, path: new)
        XCTAssertTrue(fresh.base.bytes.isEmpty); XCTAssertEqual(fresh.destination.text, "new working\n")
        let tracked = try await repo.comparisonFile(snapshot, path: renamed)
        XCTAssertEqual(snapshot.files.first { $0.path == renamed }?.oldPath, original)
        XCTAssertEqual(tracked.base.bytes, before)
        XCTAssertEqual(tracked.destination.text, working)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(after, head)
        do { _ = try await repo.workingFileComparison(paths: ["../outside"]); XCTFail() } catch {}
    }
    func testOrdinaryDiffUnbornAndUnchangedSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        try Data("later working\n".utf8).write(to: root.appendingPathComponent("file"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let snapshot = try await repo.workingFileComparison(paths: ["file"])
        XCTAssertEqual(snapshot.from, .emptyTree)
        let document = try await repo.comparisonFile(snapshot, path: "file")
        XCTAssertTrue(document.base.bytes.isEmpty); XCTAssertEqual(document.destination.text, "later working\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let (other, otherRepo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: other) }
        let clean = try await otherRepo.workingFileComparison(paths: [path]); XCTAssertTrue(clean.files.isEmpty)
    }
    func testCommitComparisonAmendUsesPinnedFirstParentAndRootEmptyBase() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        let initial = try await repo.workingFileComparison(paths: [path], amendToParent: true)
        XCTAssertEqual(initial.from, .emptyTree)
        let initialDocument = try await repo.comparisonFile(initial, path: path)
        XCTAssertTrue(initialDocument.base.bytes.isEmpty); XCTAssertEqual(initialDocument.destination.bytes, original)
        try Data("last commit\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.commit(message: "second")
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("working\n".utf8).write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let amended = try await repo.workingFileComparison(paths: [path], amendToParent: true)
        XCTAssertEqual(amended.from, .revision(first))
        let amendedDocument = try await repo.comparisonFile(amended, path: path)
        XCTAssertEqual(amendedDocument.base.bytes, original); XCTAssertEqual(amendedDocument.destination.text, "working\n")
        let normal = try await repo.workingFileComparison(paths: [path])
        let normalDocument = try await repo.comparisonFile(normal, path: path)
        XCTAssertEqual(normalDocument.base.text, "last commit\n"); XCTAssertEqual(normalDocument.destination.text, "working\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }
    func testSelectedHistoricalFilesKeepRenameAndWorkingDiskContentsWithoutIndexWrites() async throws {
        let (root, repo, original) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let bytes = try Data(contentsOf: root.appendingPathComponent(original))
        let renamed = ":(glob)* renamed 雪\n.txt"
        _ = try await repo.run(["mv", "--", original, renamed]); _ = try await repo.commit(message: "rename")
        let second = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let historical = try await repo.revisionFileComparison(from: .revision(first), to: .revision(second), paths: [renamed, original])
        XCTAssertEqual(historical.files.count, 1); XCTAssertEqual(historical.files.first?.oldPath, original)
        let historyDocument = try await repo.comparisonFile(historical, path: renamed)
        XCTAssertEqual(historyDocument.base.bytes, bytes); XCTAssertEqual(historyDocument.destination.bytes, bytes)
        let clean = try await repo.revisionFileComparison(from: .revision(second), to: .workingTree, paths: [renamed])
        XCTAssertEqual(clean.files.count, 1)
        let cleanDocument = try await repo.comparisonFile(clean, path: renamed)
        XCTAssertEqual(cleanDocument.base.bytes, bytes); XCTAssertEqual(cleanDocument.destination.bytes, bytes)
        let missing = try await repo.revisionFileComparison(from: .revision(second), to: .workingTree, paths: ["absent"])
        XCTAssertTrue(missing.files.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        _ = try await repo.run(["rm", "--cached", "--", renamed])
        try Data("recreated working\n".utf8).write(to: root.appendingPathComponent(renamed))
        let removedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let disk = try await repo.revisionFileComparison(from: .revision(second), to: .workingTree, paths: [renamed])
        XCTAssertEqual(disk.files.first?.action, "M")
        let diskDocument = try await repo.comparisonFile(disk, path: renamed)
        XCTAssertEqual(diskDocument.base.bytes, bytes); XCTAssertEqual(diskDocument.destination.text, "recreated working\n")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), removedIndex)
        try FileManager.default.removeItem(at: root.appendingPathComponent(renamed))
        let deleted = try await repo.revisionFileComparison(from: .revision(second), to: .workingTree, paths: [renamed])
        XCTAssertEqual(deleted.files.first?.action, "D")
        let deletedDocument = try await repo.comparisonFile(deleted, path: renamed)
        XCTAssertEqual(deletedDocument.base.bytes, bytes); XCTAssertTrue(deletedDocument.destination.bytes.isEmpty)
        do { _ = try await repo.revisionFileComparison(from: .revision(second), to: .workingTree, paths: ["../outside"]); XCTFail() } catch {}
    }
    func testHistoricalSaveReadsExactPinnedBlobsAndRejectsMissingFiles() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = ":(glob)* binary 雪\n.dat", text = "bom.txt", link = "link"
        let binaryBytes = Data([0, 255, 13, 10, 1]), textBytes = Data([0xef, 0xbb, 0xbf]) + Data("text\r\nlast".utf8)
        try binaryBytes.write(to: root.appendingPathComponent(binary)); try textBytes.write(to: root.appendingPathComponent(text))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(link).path, withDestinationPath: "../literal target")
        try await repo.stage([binary, text, link]); _ = try await repo.commit(message: "export bytes")
        let hash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("working replacement".utf8).write(to: root.appendingPathComponent(binary))
        let saved = try await repo.historicalFile(revision: hash, path: binary)
        XCTAssertEqual(saved.revision, .revision(hash)); XCTAssertEqual(saved.bytes, binaryBytes)
        let bom = try await repo.historicalFile(revision: hash, path: text)
        XCTAssertEqual(bom.bytes, textBytes)
        let symlink = try await repo.historicalFile(revision: hash, path: link)
        XCTAssertEqual(symlink.mode, "120000"); XCTAssertEqual(symlink.bytes, Data("../literal target".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(binary)), Data("working replacement".utf8))
        for path in ["missing", "../outside"] {
            do { _ = try await repo.historicalFile(revision: hash, path: path); XCTFail() } catch {}
        }
    }
    func testHistoricalRenameBinaryAndLiteralNamesStayPinned() async throws {
        let (root, repo, original) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let renamed = ":(glob)* renamed 雪\n.txt", binary = "binary.dat"
        _ = try await repo.run(["mv", "--", original, renamed])
        try Data([0, 1, 2, 255]).write(to: root.appendingPathComponent(binary))
        try await repo.stage([binary]); _ = try await repo.commit(message: "rename and binary")
        let snapshot = try await repo.revisionComparison(from: .revision(base), to: .revision("HEAD"))
        let rename = try XCTUnwrap(snapshot.files.first { $0.path == renamed })
        XCTAssertEqual(rename.oldPath, original)
        XCTAssertNil(try XCTUnwrap(snapshot.files.first { $0.path == binary }).added)
        let patch = try await repo.revisionComparisonPatch(snapshot, paths: [renamed])
        XCTAssertTrue(patch.contains("rename from")); XCTAssertFalse(patch.contains("binary.dat"))
        try Data("later\n".utf8).write(to: root.appendingPathComponent(renamed))
        try await repo.stage([renamed]); _ = try await repo.commit(message: "advance HEAD")
        let pinned = try await repo.revisionComparisonPatch(snapshot, paths: [renamed])
        XCTAssertEqual(pinned, patch)
        do { _ = try await repo.revisionComparisonPatch(snapshot, paths: ["outside.txt"]); XCTFail("Unreviewed paths must fail") } catch RevisionComparisonFailure.selection {}
        let (other, otherRepo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: other) }
        do { _ = try await otherRepo.revisionComparisonPatch(snapshot); XCTFail("Another repository must fail") } catch RevisionComparisonFailure.selection {}
    }

    func testWorkingTreeIncludesStagedAndUnstagedChangesWithoutWritesAndReverses() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("working\n".utf8).write(to: root.appendingPathComponent(path))
        let stagedOnly = "staged-only.txt"
        try Data("added\n".utf8).write(to: root.appendingPathComponent(stagedOnly)); try await repo.stage([stagedOnly])
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("untracked.txt"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let comparison = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree)
        XCTAssertEqual(Set(comparison.files.map(\.path)), Set([path, stagedOnly]))
        let patch = try await repo.revisionComparisonPatch(comparison, paths: [path])
        XCTAssertTrue(patch.contains("+working")); XCTAssertFalse(patch.contains("+staged"))
        let reverse = try await repo.revisionComparison(from: .workingTree, to: .revision("HEAD"))
        let reversed = try await repo.revisionComparisonPatch(reverse, paths: [path])
        XCTAssertTrue(reversed.contains("-working")); XCTAssertTrue(reversed.contains("+line 1"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path)), "working\n")
        do { _ = try await repo.revisionComparison(from: .workingTree, to: .workingTree); XCTFail("Two working trees must fail") } catch RevisionComparisonFailure.range {}
    }

    func testEmptyTreeAndWhitespaceOptionsAgreeWithPatch() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let added = try await repo.revisionComparison(from: .emptyTree, to: .revision("HEAD"))
        XCTAssertEqual(added.files.first?.status, "Added"); XCTAssertEqual(added.files.first?.added, 30)
        let removed = try await repo.revisionComparison(from: .revision("HEAD"), to: .emptyTree)
        XCTAssertEqual(removed.files.first?.status, "Deleted"); XCTAssertEqual(removed.files.first?.removed, 30)
        let text = try String(contentsOf: root.appendingPathComponent(path))
        try Data(text.replacingOccurrences(of: "line 2\n", with: "line   2  \n").utf8).write(to: root.appendingPathComponent(path))
        var options = RevisionDiffOptions(); options.ignoreAllSpace = true
        let ignored = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree, options: options)
        XCTAssertTrue(ignored.files.isEmpty)
        let patch = try await repo.revisionComparisonPatch(ignored); XCTAssertTrue(patch.isEmpty)
        options.ignoreAllSpace = false; options.ignoreSpaceAtEnd = true
        let visible = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree, options: options)
        XCTAssertEqual(visible.files.map(\.path), [path])
    }

    func testCommonAncestorPreservesUpstreamDirectComparisonForDivergentCommits() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "other"])
        try Data("main branch\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "main change")
        let main = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "other"])
        try Data("other branch\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "other change")
        var options = RevisionDiffOptions(); options.commonAncestor = true
        let snapshot = try await repo.revisionComparison(from: .revision(main), to: .revision("HEAD"), options: options)
        XCTAssertEqual(snapshot.from, .revision(main))
        let patch = try await repo.revisionComparisonPatch(snapshot)
        XCTAssertTrue(patch.contains("-main branch")); XCTAssertTrue(patch.contains("+other branch"))
        let identical = try await repo.revisionComparison(from: .revision(main), to: .revision(main))
        XCTAssertTrue(identical.files.isEmpty)
    }
    func testRevisionDetailsUsePinnedCommitAndMailmapAndAllReferences() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["config", "core.abbrev", "12"])
        try Data("Mapped Author <mapped@example.invalid> Patch Tests <patch@example.invalid>\n".utf8).write(to: root.appendingPathComponent(".mailmap"))
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let baseTimeText = try await repo.run(["show", "-s", "--format=%ct", base]).text.trimmingCharacters(in: .newlines)
        let baseTime = try XCTUnwrap(Int(baseTimeText))
        _ = try await repo.run(["update-ref", "refs/custom/comparison", base])
        let standard = try await repo.checkoutReferences(), all = try await repo.checkoutReferences(includeAll: true)
        XCTAssertFalse(standard.contains { $0.name == "refs/custom/comparison" })
        XCTAssertTrue(all.contains { $0.name == "refs/custom/comparison" })
        try Data("next\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.run(["commit", "-m", "Subject 雪", "-m", "Body after subject"], environmentOverrides: ["GIT_AUTHOR_DATE": "@\(baseTime + 3600) +0000", "GIT_COMMITTER_DATE": "@\(baseTime + 7200) +0000"])
        let snapshot = try await repo.revisionComparison(from: .revision("refs/custom/comparison"), to: .revision("HEAD"))
        let old = try XCTUnwrap(snapshot.fromDetails), new = try XCTUnwrap(snapshot.toDetails)
        XCTAssertEqual(old.shortHash, String(base.prefix(12))); XCTAssertEqual(old.subject, "base")
        XCTAssertEqual(new.subject, "Subject 雪"); XCTAssertEqual(new.author, "Mapped Author")
        XCTAssertEqual(new.committerDate?.timeIntervalSince(new.authorDate!), 3600)
        XCTAssertGreaterThan(new.committerDate!, old.committerDate!)
        let working = try await repo.revisionComparison(from: .emptyTree, to: .workingTree)
        XCTAssertNil(working.fromDetails); XCTAssertNil(working.toDetails)
        _ = try await repo.run(["update-ref", "refs/custom/comparison", "HEAD"])
        XCTAssertEqual(snapshot.from, .revision(base)); XCTAssertEqual(snapshot.fromDetails?.subject, "base")
    }

}
