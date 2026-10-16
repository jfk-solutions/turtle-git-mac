import XCTest
@testable import TurtleGitCore

final class RevisionComparisonTests: XCTestCase {
    func testChangedFilesLiteralFilterUsesBothRenamePathsAndSourceGrammar() {
        func matches(_ text: String, _ path: String = "Sources/new file.swift", _ old: String? = "Legacy/old file.swift") -> Bool {
            ComparisonPathFilter(text).matches(path: path, oldPath: old)
        }
        XCTAssertTrue(matches("sources legacy"))
        XCTAssertTrue(matches("\"new file\""))
        XCTAssertTrue(matches("missing +legacy"))
        XCTAssertFalse(matches("sources -legacy"))
        XCTAssertFalse(matches("!legacy"))
        XCTAssertTrue(matches("!missing"))
        XCTAssertTrue(matches(""))
        XCTAssertFalse(matches(".*")) // Literal query, never a regex.
        XCTAssertTrue(matches("雪", "雪\n?.txt", nil))
        XCTAssertFalse(matches("legacy", "Sources/file.swift", nil))
    }

    func testDiffDetectionPreferenceBoundariesAndCapturedSession() throws {
        let suite = "TurtleGit.DiffDetection." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        XCTAssertEqual(GitDiffDetection.load(from: prefs).percentage, 50)
        for (raw, expected) in [(-1, 50), (0, 0), (100, 100), (101, 50), (Int(UInt32.max), 50)] {
            prefs.set(raw, forKey: "DiffSimilarityIndexThreshold")
            XCTAssertEqual(GitDiffDetection.load(from: prefs).percentage, expected)
        }
        prefs.set("35", forKey: "DiffSimilarityIndexThreshold")
        let repo = GitRepository(root: URL(fileURLWithPath: "/tmp"), diffDetection: .load(from: prefs))
        prefs.set(90, forKey: "DiffSimilarityIndexThreshold")
        XCTAssertEqual(repo.diffDetection.percentage, 35)
        XCTAssertEqual(GitDiffDetection(percentage: 0).historyArguments, ["--no-renames"])
        XCTAssertEqual(GitDiffDetection(percentage: 0).comparisonArguments, ["-M0%", "-C0%"])
    }

    func testSimilarityConnectsStatusStagingWorkingAndPinnedComparisonPatches() async throws {
        let (root, seed, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = "similar old\n雪.txt", new = "similar new\n雪.txt"
        let original = (0..<80).map { "original numbered line \($0)\n" }.joined()
        try Data(original.utf8).write(to: root.appendingPathComponent(old)); try await seed.stage([old]); _ = try await seed.commit(message: "similarity base")
        _ = try await seed.run(["config", "diff.renames", "false"])
        _ = try await seed.run(["mv", "--", old, new])
        let edited = original.replacingOccurrences(of: (0..<20).map { "original numbered line \($0)\n" }.joined(), with: (0..<20).map { "replacement with different contents \($0)\n" }.joined())
        try Data(edited.utf8).write(to: root.appendingPathComponent(new)); try await seed.stage([new])
        let low = GitRepository(root: root, diffDetection: .init(percentage: 30)), high = GitRepository(root: root, diffDetection: .init(percentage: 100))
        let lowStatus = try await low.status(refreshIndex: false), highStatus = try await high.status(refreshIndex: false)
        XCTAssertEqual(lowStatus.first(where: { $0.path == new })?.originalPath, old)
        XCTAssertNil(highStatus.first(where: { $0.path == new })?.originalPath)
        let rows = try await low.stagingFiles(staged: true), strict = try await high.stagingFiles(staged: true)
        XCTAssertEqual(rows.first(where: { $0.path == new })?.oldPath, old)
        XCTAssertTrue(strict.contains(where: { $0.path == old && $0.action == "D" }))
        let workingRows = try await low.workingTreeFiles()
        XCTAssertEqual(workingRows.first(where: { $0.path == new })?.oldPath, old)
        let snapshot = try await low.revisionComparison(from: .revision("HEAD"), to: .workingTree)
        let patch = try await high.revisionComparisonPatchData(snapshot)
        XCTAssertNotNil(patch.range(of: Data("rename from ".utf8)), "A different repository session must honor the snapshot's detection policy")
        XCTAssertEqual(snapshot.diffDetection.percentage, 30)
        let stagedPatch = try await low.patchData(paths: [old, new], staged: true)
        let workingPatch = try await low.workingTreeDiffData(paths: [old, new])
        XCTAssertNotNil(stagedPatch.range(of: Data("rename from ".utf8)))
        XCTAssertNotNil(workingPatch.range(of: Data("rename from ".utf8)))
        let token = OperationCancellation(); token.cancel()
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        do { _ = try await low.revisionComparisonPatchData(snapshot, cancellation: token); XCTFail("Cancelled pinned comparison ran") } catch is OperationCancellationFailure {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(new)), Data(edited.utf8))
    }

    func testHistoryCacheThresholdCopyClassificationAndZeroBackendBehavior() async throws {
        let (root, seed, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = "history old", new = "history new", source = "copy source", copy = "copy target"
        let text = (0..<80).map { "history source line \($0)\n" }.joined()
        let copyText = (0..<80).map { "copy source distinctive line \($0)\n" }.joined()
        try Data(text.utf8).write(to: root.appendingPathComponent(old)); try Data(copyText.utf8).write(to: root.appendingPathComponent(source))
        try await seed.stage([old, source]); _ = try await seed.commit(message: "history base")
        let base = try await seed.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await seed.run(["mv", "--", old, new])
        try Data(text.replacingOccurrences(of: "history source line 0\n", with: "edited history line\n").utf8).write(to: root.appendingPathComponent(new))
        try Data(copyText.utf8).write(to: root.appendingPathComponent(copy))
        try Data((copyText + "extra line\n").utf8).write(to: root.appendingPathComponent(source))
        try await seed.stage([new, source, copy]); _ = try await seed.commit(message: "rename and copy")
        let low = GitRepository(root: root, diffDetection: .init(percentage: 30)), high = GitRepository(root: root, diffDetection: .init(percentage: 100)), zero = GitRepository(root: root, diffDetection: .init(percentage: 0))
        let entries = try await low.history()
        let entry = try XCTUnwrap(entries.first)
        let cache = HistoryFileCache(root: root.appendingPathComponent("cache"))
        let initial = try await low.files(in: entry, cache: cache)
        XCTAssertEqual(initial.first(where: { $0.path == new })?.oldPath, old)
        XCTAssertTrue(initial.first(where: { $0.path == copy })?.action.hasPrefix("C") == true)
        let strict = try await high.files(in: entry, cache: cache)
        XCTAssertNil(strict.first(where: { $0.path == new })?.oldPath, "Cached classification ignored the new threshold")
        let disabled = try await zero.files(in: entry, cache: cache)
        XCTAssertTrue(disabled.allSatisfy { $0.oldPath == nil })
        let batched = try await low.revisionChanges(in: [entry])
        XCTAssertTrue(batched[entry.hash]?.first(where: { $0.path == copy })?.action.hasPrefix("C") == true)
        let patch = try await low.revisionFileDiffData(entry, files: initial)
        XCTAssertNotNil(patch.range(of: Data("copy from ".utf8)))
        XCTAssertNotNil(patch.range(of: Data("rename from ".utf8)))
        let comparison = try await low.revisionComparison(from: .revision(base), to: .revision(entry.hash))
        XCTAssertTrue(comparison.files.first(where: { $0.path == copy })?.action.hasPrefix("C") == true)
        let copyPreview = try await low.workingTreePatch(paths: [source, copy], base: base)
        XCTAssertTrue(copyPreview.files.contains { $0.header.contains { $0.hasPrefix("copy from ") } && !$0.supportsPartialChanges }, "Copy preview must retain the whole-file gate")
        var options = RevisionDiffOptions(); options.detectCopies = false
        let withoutCopies = try await low.revisionComparison(from: .revision(base), to: .revision(entry.hash), options: options)
        XCTAssertEqual(withoutCopies.files.first(where: { $0.path == copy })?.action, "A")
    }

    func testPinnedComparisonRawPatchKeepsBytesAndSelectedScopeAfterHeadMoves() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Data([0xff, 0x0a]), after = Data([0xfe, 0x0a])
        try before.write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.commit(message: "raw base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try after.write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.commit(message: "raw destination")
        let snapshot = try await repo.revisionComparison(from: .revision(base), to: .revision("HEAD"))
        let original = try await repo.revisionComparisonPatchData(snapshot, paths: [path])
        XCTAssertNotNil(original.range(of: Data([0x2d, 0xff, 0x0a])))
        XCTAssertNotNil(original.range(of: Data([0x2b, 0xfe, 0x0a])))
        let preview = try UnifiedDiffPreview.create(original); defer { preview.discard() }
        _ = try await repo.run(["apply", "--reverse", "--check", "--", preview.file.path])
        try Data("later unrelated\n".utf8).write(to: root.appendingPathComponent("later.txt"))
        try await repo.stage(["later.txt"]); _ = try await repo.commit(message: "move HEAD")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let repeated = try await repo.revisionComparisonPatchData(snapshot, paths: [path])
        XCTAssertEqual(original, repeated)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), after)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        do { _ = try await repo.revisionComparisonPatchData(snapshot, paths: ["later.txt"]); XCTFail("Accepted a path absent from pinned snapshot") }
        catch RevisionComparisonFailure.selection {}
    }
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
    func testExplicitIgnoredFilesAndCachedRemovalReadActualWorkingBytesWithoutIndexWrites() async throws {
        let (root, repo, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent(tracked))
        try Data("ignored-dir/\n*.ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ignored-dir"), withIntermediateDirectories: false)
        let ignored = "ignored-dir/:(glob)* 雪\n.txt", binary = "bytes.ignored", link = "link.ignored"
        let text = Data([239, 187, 191]) + Data("ignored source\r\n".utf8), bytes = Data([0, 255, 13, 10, 128])
        try text.write(to: root.appendingPathComponent(ignored)); try bytes.write(to: root.appendingPathComponent(binary))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(link).path, withDestinationPath: "missing target 雪")
        _ = try await repo.run(["rm", "--cached", "--", tracked])
        let working = Data("kept on disk\n".utf8); try working.write(to: root.appendingPathComponent(tracked))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let snapshot = try await repo.workingFileComparison(paths: [ignored, binary, link, tracked])
        XCTAssertEqual(Set(snapshot.files.map(\.path)), [ignored, binary, link, tracked])
        XCTAssertEqual(snapshot.files.first { $0.path == tracked }?.action, "M")
        for (path, expected) in [(ignored, text), (binary, bytes), (link, Data("missing target 雪".utf8))] {
            let document = try await repo.comparisonFile(snapshot, path: path)
            XCTAssertTrue(document.base.bytes.isEmpty); XCTAssertEqual(document.destination.bytes, expected)
        }
        let kept = try await repo.comparisonFile(snapshot, path: tracked)
        XCTAssertEqual(kept.base.bytes, original); XCTAssertEqual(kept.destination.bytes, working)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ignored)), text)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(binary)), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(tracked)), working)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(link).path), "missing target 雪")
    }
    func testStatusListBaseComparisonGateSeparatesUnversionedPreviewFromTrackedMenu() {
        for code in ["??", "!!"] {
            XCTAssertFalse(StatusEntry.parse(Data((code + " file\0").utf8))[0].canCompareWithBaseFromStatusList)
        }
        for code in [" M", "M ", "A ", " D", "D ", "UU", "MM"] {
            XCTAssertTrue(StatusEntry.parse(Data((code + " file\0").utf8))[0].canCompareWithBaseFromStatusList)
        }
        let retained = StatusEntry.parse(Data("D  file\0?? file\0".utf8))[0]
        XCTAssertTrue(retained.hasUnversionedCopy); XCTAssertFalse(retained.canCompareWithBaseFromStatusList)
    }
    func testCheckboxTargetsPreserveHighlightAndExcludeStaleAndHeaderIDs() {
        let entries = StatusEntry.parse(Data(" M a\0?? new 雪\n.txt\0 M other\0".utf8))
        let highlighted: Set<String> = [entries[0].id, entries[1].id, "\0group:modified", "stale"]
        XCTAssertEqual(StatusListSelection.checkboxEntries(entry: entries[0], entries: entries, highlighted: highlighted).map(\.path), ["a", "new 雪\n.txt"])
        XCTAssertEqual(StatusListSelection.checkboxEntries(entry: entries[2], entries: entries, highlighted: highlighted).map(\.path), ["other"])
        XCTAssertEqual(StatusListSelection.checkboxEntries(entry: entries[0], entries: entries, highlighted: []).map(\.path), ["a"])
        XCTAssertTrue(StatusListSelection.checkboxEntries(entry: entries[0], entries: [entries[2]], highlighted: highlighted).isEmpty)
    }
    func testFirstRequestContextMarkUsesClickedRowAndPreservesExistingMixedAnchor() {
        let entries = StatusEntry.parse(Data("?? new\0 M tracked\0 M other\0".utf8))
        let clicked = StatusListSelection.mark(entries: entries, requested: ["tracked"], highlighted: ["new"], focusedPath: "new")
        XCTAssertEqual(clicked?.path, "tracked"); XCTAssertTrue(clicked?.canCompareWithBaseFromStatusList == true)
        let untracked = StatusListSelection.mark(entries: entries, requested: ["new"], highlighted: ["tracked"], focusedPath: "tracked")
        XCTAssertEqual(untracked?.path, "new"); XCTAssertFalse(untracked?.canCompareWithBaseFromStatusList == true)
        let mixed = StatusListSelection.mark(entries: entries, requested: ["new", "tracked"], highlighted: ["new", "tracked"], focusedPath: "tracked")
        XCTAssertEqual(mixed?.path, "tracked")
        let outside = StatusListSelection.mark(entries: entries, requested: ["tracked"], highlighted: ["tracked"], focusedPath: "new")
        XCTAssertEqual(outside?.path, "new")
        XCTAssertNil(StatusListSelection.mark(entries: entries, requested: [], highlighted: [], focusedPath: nil))
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

    func testComparisonRevertBatchContinuesAfterCopyBasePreparationFailure() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = Data((1...32).map { "copy context \($0)\n" }.joined().utf8)
        try original.write(to: root.appendingPathComponent("source")); try Data("good base\n".utf8).write(to: root.appendingPathComponent("z-good"))
        try await repo.stage(["source", "z-good"]); _ = try await repo.commit(message: "copy base")
        let base = String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        try original.write(to: root.appendingPathComponent("a-copy")); try (original + Data("source changed\n".utf8)).write(to: root.appendingPathComponent("source")); try Data("good new\n".utf8).write(to: root.appendingPathComponent("z-good"))
        try await repo.stage(["a-copy", "source", "z-good"]); _ = try await repo.commit(message: "copy changes")
        let snapshot = try await repo.revisionComparison(from: .revision(base), to: .revision("HEAD"))
        let copy = try XCTUnwrap(snapshot.files.first { $0.path == "a-copy" }), good = try XCTUnwrap(snapshot.files.first { $0.path == "z-good" })
        XCTAssertTrue(copy.action.hasPrefix("C"))
        let batch = try await repo.prepareComparisonRevertBatch(snapshot, files: [copy, good], base: true)
        do { _ = try await repo.prepareComparisonRevertFile(batch, file: copy); XCTFail("Base has no copied destination") } catch RevisionComparisonFailure.selection {}
        let target = try await repo.prepareComparisonRevertFile(batch, file: good); _ = try await repo.revertComparisonFile(target, recycle: false)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("z-good")), Data("good base\n".utf8)); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("a-copy")), original)
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.prepareComparisonRevertFile(batch, file: good, cancellation: token); XCTFail("Cancelled preparation") } catch is OperationCancellationFailure {}
    }
    func testComparisonRevertEmptyTreeHistoricalAndWorkingSemantics() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "initial", "initial\n"); try await repo.stage(["initial"]); _ = try await repo.commit(message: "root")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let historical = try await repo.revisionComparison(from: .emptyTree, to: .revision("HEAD"))
        let plan = try await repo.prepareComparisonRevert(historical, files: historical.files, base: true)
        for target in plan { _ = try await repo.revertComparisonFile(target, recycle: false) }
        let untracked = try await repo.run(["ls-files"]).stdout; XCTAssertTrue(untracked.isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("initial").path))
        _ = try await repo.run(["reset", "--hard", "HEAD"])
        let working = try await repo.revisionComparison(from: .emptyTree, to: .workingTree)
        let livePlan = try await repo.prepareComparisonRevert(working, files: working.files, base: true)
        for target in livePlan { _ = try await repo.revertComparisonFile(target, recycle: false) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("initial").path))
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(finalHead, head)
    }
    func testComparisonExportDoesNotReadMissingBaseBlob() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let object = String(decoding: try await repo.run(["rev-parse", base + ":" + path]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let blob = root.appendingPathComponent(".git/objects/" + object.prefix(2) + "/" + object.dropFirst(2)), saved = try Data(contentsOf: blob)
        let destination = Data([0, 255, 13, 10]); try destination.write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "binary destination")
        let snapshot = try await repo.revisionComparison(from: .revision(base), to: .revision("HEAD")), file = try XCTUnwrap(snapshot.files.first { $0.path == path })
        let folder = root.appendingPathComponent("export"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: blob); defer { try? saved.write(to: blob) }
        let plan = try await repo.prepareComparisonExport(snapshot, files: [file], to: folder)
        try await repo.exportComparisonFile(plan, path: path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path)); XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(path)), destination)
    }
    func testComparisonRevertHistoricalRenameAndWorkingAddedRenameMatchSourceWithoutMovingHEAD() async throws {
        let (root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let renamed="renamed :(glob)* 雪\n.txt"
        _ = try await repo.run(["mv","--",path,renamed]);try Data("new\n".utf8).write(to:root.appendingPathComponent("added"));try await repo.stage(["added"]);_ = try await repo.commit(message:"rename and add")
        let tip=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let comparison=try await repo.revisionComparison(from:.revision(base),to:.revision(tip))
        let rename=try XCTUnwrap(comparison.files.first{$0.path==renamed}),addition=try XCTUnwrap(comparison.files.first{$0.path=="added"})
        let plan=try await repo.prepareComparisonRevert(comparison,files:[rename,addition],base:true)
        for target in plan {_ = try await repo.revertComparisonFile(target,recycle:false)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path));XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(renamed).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("added").path))
        let cached=try await repo.run(["ls-files","-z"]).stdout
        XCTAssertFalse(cached.split(separator:0).contains(Data("added".utf8)))
        _ = try await repo.run(["reset","--hard",tip])
        let moved="working rename 雪.txt";_ = try await repo.run(["mv","--",renamed,moved])
        try Data("staged addition\n".utf8).write(to:root.appendingPathComponent("new-working"));try await repo.stage(["new-working"])
        let working=try await repo.revisionComparison(from:.revision(tip),to:.workingTree)
        let selected=working.files.filter{$0.path==moved || $0.path=="new-working"};XCTAssertEqual(selected.count,2)
        let workingPlan=try await repo.prepareComparisonRevert(working,files:selected,base:true)
        for target in workingPlan {_ = try await repo.revertComparisonFile(target,recycle:false)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(renamed).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(moved).path));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("new-working").path))
        let final=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);XCTAssertEqual(final,tip)
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_ = try await repo.prepareComparisonRevert(comparison,files:[rename],base:true,cancellation:cancelled);XCTFail("Cancelled restore preparation accepted")}catch is OperationCancellationFailure{}
        do {_ = try await repo.prepareComparisonRevert(comparison,files:[CommitFile(path:"../escape",oldPath:nil,action:"M",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)],base:true);XCTFail("Foreign path accepted")}catch{}
    }
    func testComparisonExportPinnedTreesRawBytesWorkingContentsAndDestinationPreflight() async throws {
        let (root,repo,path)=try await GitPatchTests().fixture();defer{try? FileManager.default.removeItem(at:root)}
        let raw=Data([0,255,13,10]),name="folder/:(glob)* 雪\n.bin"
        try FileManager.default.createDirectory(at:root.appendingPathComponent("folder"),withIntermediateDirectories:true);try raw.write(to:root.appendingPathComponent(name));try await repo.stage([name]);_ = try await repo.commit(message:"binary export")
        let tree=try await repo.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
        let snapshot=try await repo.revisionComparison(from:.emptyTree,to:.revision(tree)),selected=try XCTUnwrap(snapshot.files.first{$0.path==name})
        let folder=root.deletingLastPathComponent().appendingPathComponent("comparison-export-"+UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:folder)}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let export=try await repo.prepareComparisonExport(snapshot,files:[selected],to:folder);try await repo.exportComparisonFile(export,path:name)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(name)),raw)
        do {_ = try await repo.prepareComparisonExport(snapshot,files:[selected],to:root);XCTFail("Source overwrite accepted")}catch is WorkingFileExportFailure{}
        do {_ = try await repo.prepareComparisonExport(snapshot,files:[selected],to:root.appendingPathComponent(".git"));XCTFail("Git export accepted")}catch is WorkingFileExportFailure{}
        let working=Data([0xfe,10]);try working.write(to:root.appendingPathComponent(path))
        let range=try await repo.revisionComparison(from:.revision("HEAD"),to:.workingTree),file=try XCTUnwrap(range.files.first{$0.path==path})
        let live=try await repo.prepareComparisonExport(range,files:[file],to:folder);try await repo.exportComparisonFile(live,path:path)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(path)),working)
        let cancelled=OperationCancellation();cancelled.cancel()
        do {try await repo.exportComparisonFile(live,path:path,cancellation:cancelled);XCTFail("Cancelled export accepted")}catch is OperationCancellationFailure{}
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
    }

}
