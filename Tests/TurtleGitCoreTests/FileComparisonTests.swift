import XCTest
@testable import TurtleGitCore

final class FileComparisonTests: XCTestCase {
    func testFollowedHistoryComparisonKeepsEachEndpointNameAndRawBytes() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = ":(literal) old 雪\n.txt", middle = "middle file", current = "new 雪\n.txt"
        let original = Data((0..<40).map { "original line \($0)\n" }.joined().utf8)
        try original.write(to: root.appendingPathComponent(old)); try await repo.stage([old]); _ = try await repo.commit(message: "file birth")
        let birth = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["mv", "--", old, middle]); _ = try await repo.commit(message: "first rename")
        _ = try await repo.run(["mv", "--", middle, current]); _ = try await repo.commit(message: "second rename")
        let renamed = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let latest = original + Data([0xff, 0x00, 0x0a])
        try latest.write(to: root.appendingPathComponent(current)); try await repo.stage([current]); _ = try await repo.commit(message: "raw edit")
        var options = HistoryOptions(); options.paths = [current]; options.walk.followRenames = true; options.limit = -1
        let rows = try await repo.history(options: options)
        let tip = try XCTUnwrap(rows.first).hash
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let pair = try await repo.followedHistoryComparison(path: current, entries: rows, from: .revision(birth), to: .revision(tip))
        let document = try await repo.comparisonFile(pair, path: current)
        XCTAssertEqual(document.base.path, old); XCTAssertEqual(document.base.bytes, original)
        XCTAssertEqual(document.destination.path, current); XCTAssertEqual(document.destination.bytes, latest)
        let renameRow = try XCTUnwrap(rows.first { $0.hash == renamed })
        let previous = try await repo.followedHistoryComparison(path: current, entries: rows, from: .revision(renameRow.parents[0]), to: .revision(renamed), parentOf: renamed)
        XCTAssertEqual(previous.files.first?.oldPath, middle)
        let beforeRename = try await repo.followedHistoryComparison(path: current, entries: rows, from: .revision(birth), to: .revision(renameRow.parents[0]))
        XCTAssertEqual(beforeRename.files.first?.path, middle); XCTAssertEqual(beforeRename.files.first?.oldPath, old)
        let working = latest + Data("working only\n".utf8); try working.write(to: root.appendingPathComponent(current))
        let live = try await repo.followedHistoryComparison(path: current, entries: rows, from: .revision(birth), to: .workingTree)
        let liveContent = try await repo.comparisonFile(live, path: current)
        XCTAssertEqual(liveContent.base.path, old); XCTAssertEqual(liveContent.base.bytes, original); XCTAssertEqual(liveContent.destination.bytes, working)
        let patch = try await repo.revisionComparisonPatchData(live)
        XCTAssertFalse(patch.isEmpty); XCTAssertNil(patch.range(of: Data("diff --git a/file.txt".utf8)))
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.followedHistoryComparison(path: current, entries: rows, from: .revision(birth), to: .revision(tip), cancellation: token); XCTFail("Cancelled follow read ran") } catch is OperationCancellationFailure {}
        do { _ = try await repo.followedHistoryPaths(path: "../escape", entries: rows, through: [tip]); XCTFail("Escaping history path accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(finalHead, tip)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(current)), working)
    }

    func testFollowedHistoryParentsRootAndMissingWorkingSide() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = "old.txt", new = "new.txt", contents = Data((0..<30).map { "unique file line \($0)\n" }.joined().utf8)
        try contents.write(to: root.appendingPathComponent(old)); try await repo.stage([old]); _ = try await repo.commit(message: "birth")
        let birth = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["branch", "side"])
        _ = try await repo.run(["mv", "--", old, new]); _ = try await repo.commit(message: "rename")
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "side"])
        try Data("unrelated branch\n".utf8).write(to: root.appendingPathComponent("unrelated")); try await repo.stage(["unrelated"]); _ = try await repo.commit(message: "side")
        _ = try await repo.run(["checkout", "main"]); _ = try await repo.run(["merge", "--no-ff", "--no-edit", "side"])
        let merge = try await repo.history().first!
        let rows = [merge] + (try await repo.history()).filter { $0.hash != merge.hash }
        let firstPair = try await repo.followedHistoryComparison(path: new, entries: rows, from: .revision(first), to: .revision(merge.hash), parentOf: merge.hash)
        XCTAssertEqual(firstPair.files.first?.oldPath, new)
        let secondPair = try await repo.followedHistoryComparison(path: new, entries: rows, from: .revision(merge.parents[1]), to: .revision(merge.hash), parentOf: merge.hash)
        XCTAssertEqual(secondPair.files.first?.oldPath, old)
        let secondContent = try await repo.comparisonFile(secondPair, path: new); XCTAssertEqual(secondContent.base.bytes, contents); XCTAssertEqual(secondContent.destination.bytes, contents)
        let filteredRows = try await repo.history(options: { var value = HistoryOptions(); value.paths = [new]; value.walk.followRenames = true; return value }())
        let birthPair = try await repo.followedHistoryComparison(path: new, entries: filteredRows, from: .emptyTree, to: .revision(birth), parentOf: birth)
        XCTAssertEqual(birthPair.files.first?.action, "A"); XCTAssertEqual(birthPair.files.first?.path, old)
        try FileManager.default.removeItem(at: root.appendingPathComponent(new))
        let deletion = try await repo.followedHistoryComparison(path: new, entries: filteredRows, from: .revision(first), to: .workingTree)
        XCTAssertEqual(deletion.files.first?.action, "D")
        let deleted = try await repo.comparisonFile(deletion, path: new); XCTAssertEqual(deleted.base.bytes, contents); XCTAssertTrue(deleted.destination.bytes.isEmpty)
        // The working-tree row compares actual HEAD, which need not occur in a
        // path-restricted log because that commit did not touch the file.
        let headPair = try await repo.followedHistoryComparison(path: new, entries: [], from: .revision(merge.hash), to: .workingTree)
        XCTAssertEqual(headPair.files.first?.action, "D")
    }

    func testChangeSetsCompareFirstParentPatchStreamsAndPreserveRepository() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootHash = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("first edit\n".utf8).write(to:root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.commit(message:"First edit")
        let first = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data([0xff,0x0a]).write(to:root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.commit(message:"Second raw edit")
        let second = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index")), config = try Data(contentsOf:root.appendingPathComponent(".git/config")), refs = try await repo.run(["show-ref"]).stdout
        let value = try await repo.commitChangeSets(first:second,second:first)
        let firstPatch = try await repo.run(["format-patch","--stdout",second + "~1.." + second,"--"]).stdout
        let secondPatch = try await repo.run(["format-patch","--stdout",first + "~1.." + first,"--"]).stdout
        XCTAssertEqual(value.document.base.bytes,firstPatch)
        XCTAssertEqual(value.document.destination.bytes,secondPatch)
        XCTAssertEqual(value.document.base.path,second + ".patch")
        XCTAssertEqual(value.document.destination.path,first + ".patch")
        XCTAssertEqual(value.snapshot.from,.revision(second))
        XCTAssertEqual(value.snapshot.to,.revision(first))
        XCTAssertNotNil(value.document.base.bytes.range(of:Data([0xff])))
        do { _ = try await repo.commitChangeSets(first:rootHash,second:first); XCTFail("Root format-patch range unexpectedly accepted") } catch is GitFailure {}
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { _ = try await repo.commitChangeSets(first:second,second:first,cancellation:cancelled); XCTFail("Cancelled comparison unexpectedly ran") } catch is OperationCancellationFailure {}
        let afterRefs = try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(afterRefs,refs)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/config")),config)
    }
    func testPreparedWorkingAndHistoricalSidesPreserveRawBytesPinRefsAndDoNotChangeIndex() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent(path)), literal = ":(glob)* prepared 雪\n.bin"
        let bytes = Data([0, 255, 13, 10]), working = Data([0xfd, 10])
        try bytes.write(to: root.appendingPathComponent(literal))
        try Data([0xfe, 10]).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try working.write(to: root.appendingPathComponent(path))
        let tree = try await repo.run(["write-tree"]).text.trimmingCharacters(in: .newlines)
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let moved = try await repo.run(["commit-tree", tree, "-p", head, "-m", "Moved mark ref"]).text.trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        _ = try await repo.run(["branch", "prepared-base", head])
        let forward = try await repo.preparedPathComparison(from: .revision("prepared-base"), fromPath: path, to: .workingTree, toPath: literal)
        let reverse = try await repo.preparedPathComparison(from: .workingTree, fromPath: literal, to: .revision("prepared-base"), toPath: path)
        let pair = try await repo.preparedPathComparison(from: .workingTree, fromPath: literal, to: .workingTree, toPath: path)
        XCTAssertEqual(forward.from, .revision(head)); XCTAssertEqual(reverse.to, .revision(head))
        _ = try await repo.run(["update-ref", "refs/heads/prepared-base", moved])
        let first = try await repo.comparisonFile(forward, path: literal), second = try await repo.comparisonFile(reverse, path: path), both = try await repo.comparisonFile(pair, path: path)
        XCTAssertEqual(first.base.bytes, original); XCTAssertEqual(first.destination.bytes, bytes)
        XCTAssertEqual(second.base.bytes, bytes); XCTAssertEqual(second.destination.bytes, original)
        XCTAssertEqual(both.base.bytes, bytes); XCTAssertEqual(both.destination.bytes, working)
        for (from, invalid) in [(ComparisonRevision.emptyTree, path), (.workingTree, "../outside"), (.workingTree, ".git/index"), (.workingTree, "missing")] {
            do { _ = try await repo.preparedPathComparison(from: from, fromPath: invalid, to: .workingTree, toPath: literal); XCTFail("Invalid prepared comparison") } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), working)
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(after, head)
    }
    func testHistoricalPreviewCopiesArePrivateReadOnlyAndKeepExactBlobBytes() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = ":(glob)* binary 雪\n.dat", link = "historical-link"
        let bytes = Data([0, 255, 13, 10, 1])
        try bytes.write(to: root.appendingPathComponent(binary))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(link).path, withDestinationPath: "/missing/outside/target")
        try await repo.stage([binary, link]); _ = try await repo.commit(message: "preview blobs")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try Data("later working contents".utf8).write(to: root.appendingPathComponent(path))
        for name in [path, binary, link] {
            let content = try await repo.historicalFile(revision: head, path: name)
            let first = try HistoricalFilePreview.create(content), second = try HistoricalFilePreview.create(content)
            defer { first.discard(); second.discard() }
            XCTAssertNotEqual(first.directory, second.directory)
            XCTAssertEqual(try Data(contentsOf: first.file), content.bytes)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.file.path)[.type] as? FileAttributeType, .typeRegular)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.file.path)[.posixPermissions] as? Int, 0o444)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: first.directory.path)[.posixPermissions] as? Int, 0o700)
            XCTAssertTrue(first.file.lastPathComponent.contains(String(head.prefix(7))))
            if name == binary { XCTAssertTrue(first.file.lastPathComponent.hasSuffix(".dat")); XCTAssertTrue(first.file.lastPathComponent.contains("雪\n")) }
            first.discard(); XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
            XCTAssertEqual(try Data(contentsOf: second.file), content.bytes)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("later working contents".utf8))
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(finalHead, head)
    }
    func testHistoricalPairUsesEachDeletedSideParentAndPinnedLiteralBlobs() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = ":(glob)* pair 雪\n.bin", link = "link"
        let binary = Data([0, 255, 13, 10])
        try binary.write(to: root.appendingPathComponent(other))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(link).path, withDestinationPath: "missing-target")
        try await repo.stage([other, link]); _ = try await repo.commit(message: "pair base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        _ = try await repo.run(["rm", "--", path])
        try Data([42]).write(to: root.appendingPathComponent(other)); try await repo.stage([other])
        _ = try await repo.commit(message: "delete and modify")
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        func file(_ path: String, _ action: String = "M", module: Bool = false) -> CommitFile { CommitFile(path: path, oldPath: nil, action: action, added: nil, removed: nil, hasStatistics: false, isSubmodule: module) }
        let snapshot = try await repo.historicalFilePairComparison(revision: "HEAD", files: [file(path, "D"), file(other)])
        XCTAssertEqual(snapshot.from, .revision(base)); XCTAssertEqual(snapshot.to, .revision(head))
        let value = try await repo.comparisonFile(snapshot, path: other)
        XCTAssertEqual(value.base.path, path); XCTAssertEqual(value.base.bytes, original)
        XCTAssertEqual(value.destination.path, other); XCTAssertEqual(value.destination.bytes, Data([42]))
        let reversed = try await repo.historicalFilePairComparison(revision: head, files: [file(other), file(path, "D")])
        let reverse = try await repo.comparisonFile(reversed, path: path)
        XCTAssertEqual(reverse.base.bytes, Data([42])); XCTAssertEqual(reverse.destination.bytes, original)
        let symlink = try await repo.historicalFilePairComparison(revision: head, files: [file(link), file(other)])
        let linkValue = try await repo.comparisonFile(symlink, path: other)
        XCTAssertEqual(linkValue.base.mode, "120000"); XCTAssertEqual(linkValue.base.bytes, Data("missing-target".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        try Data([99]).write(to: root.appendingPathComponent(other)); try await repo.stage([other]); _ = try await repo.commit(message: "advance")
        let pinned = try await repo.comparisonFile(snapshot, path: other); XCTAssertEqual(pinned.destination.bytes, Data([42]))
        for files in [[file(other)], [file(other), file(other)], [file(link, module: true), file(other)], [file("missing"), file(other)]] {
            do { _ = try await repo.historicalFilePairComparison(revision: head, files: files); XCTFail("Invalid pair accepted") } catch {}
        }
    }
    func testExternalWorkingMarkUsesLiveBytesAndPinnedHistoryAndEditsOnlyMarkedFile() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marked = outside.appendingPathComponent(":(glob)* 雪\n.txt")
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        let markedBytes = Data([0xef, 0xbb, 0xbf]) + Data("marked\r\n".utf8)
        try markedBytes.write(to: marked); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: marked.path)
        let comparison = try await repo.historicalWorkingFileComparison(revision: "HEAD", path: path, workingFile: marked)
        try Data("later staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        _ = try await repo.commit(message: "advance history")
        try Data("later working\n".utf8).write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let document = try await repo.comparisonFile(comparison)
        XCTAssertEqual(document.base.bytes, markedBytes); XCTAssertEqual(document.destination.bytes, original)
        XCTAssertEqual(document.base.revision, .workingTree); XCTAssertEqual(document.destination.revision, comparison.snapshot.to)
        let saved = try comparison.saveBase(document, text: "edited\r\n")
        XCTAssertEqual(saved.base.bytes, Data([0xef, 0xbb, 0xbf]) + Data("edited\r\n".utf8))
        XCTAssertEqual(saved.destination.bytes, original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("later working\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: marked.path)[.posixPermissions] as? NSNumber, 0o755)
        let reloaded = try await repo.comparisonFile(comparison)
        XCTAssertEqual(reloaded.base.bytes, saved.base.bytes); XCTAssertEqual(reloaded.destination.bytes, original)
        try Data("external change\n".utf8).write(to: marked)
        XCTAssertThrowsError(try comparison.saveBase(saved, text: "lost update"))
        try FileManager.default.removeItem(at: marked)
        do { _ = try await repo.comparisonFile(comparison); XCTFail("Missing external mark accepted") } catch {}
        for invalid in ["missing", "", "bad\0path"] {
            do { _ = try await repo.historicalWorkingFileComparison(revision: "HEAD", path: invalid, workingFile: marked); XCTFail("Invalid historical selection accepted") } catch {}
        }
    }
    func testMarkedHistoricalPathsCompareSameOrDifferentNamesAtPinnedRevisions() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        let other = ":(glob)* marked 雪\n.bin", bytes = Data([0, 255, 13, 10])
        try bytes.write(to: root.appendingPathComponent(other))
        try Data("selected contents\n".utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path, other]); _ = try await repo.commit(message: "marked comparison target")
        let after = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("staged later\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("working later\n".utf8).write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let same = try await repo.historicalPathComparison(fromRevision: before, fromPath: path, toRevision: "HEAD", toPath: path)
        let value = try await repo.comparisonFile(same, path: path)
        XCTAssertEqual(value.base.bytes, original); XCTAssertEqual(value.destination.bytes, Data("selected contents\n".utf8))
        let different = try await repo.historicalPathComparison(fromRevision: before, fromPath: path, toRevision: "HEAD", toPath: other)
        let pair = try await repo.comparisonFile(different, path: other)
        XCTAssertEqual(pair.base.path, path); XCTAssertEqual(pair.destination.path, other); XCTAssertEqual(pair.destination.bytes, bytes)
        XCTAssertEqual(same.from, .revision(before)); XCTAssertEqual(same.to, .revision(after))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data("working later\n".utf8))
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines); XCTAssertEqual(head, after)
        _ = try await repo.commit(message: "advance")
        let pinned = try await repo.comparisonFile(same, path: path); XCTAssertEqual(pinned.destination.bytes, Data("selected contents\n".utf8))
        for invalid in ["", "bad\0path", "missing"] {
            do { _ = try await repo.historicalPathComparison(fromRevision: before, fromPath: invalid, toRevision: after, toPath: path); XCTFail("Invalid mark accepted") } catch {}
        }
    }
    func testHistoricalPreviewRejectsUnpinnedAbsentAndNonBlobContents() {
        for (revision, mode, path) in [(ComparisonRevision.workingTree, "100644", "file.txt"), (.emptyTree, "100644", "file.txt"), (.revision("HEAD"), "100644", "file.txt"), (.revision(String(repeating: "a", count: 40)), "160000", "module"), (.revision(String(repeating: "a", count: 40)), "100644", "bad\0file")] {
            let content = ComparisonFileContent(path: path, revision: revision, bytes: Data(), mode: mode)
            do { let preview = try HistoricalFilePreview.create(content); preview.discard(); XCTFail("Reject non-blob preview") } catch {}
        }
    }
    func testWorkingFilePairUsesLiteralWorkingBytesAndPinnedDeletedSides() async throws {
        let (root, repo, tracked) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent(tracked))
        let other = ":(glob)* pair 雪\n.txt", link = "broken-link"
        let otherBytes = Data([0xff, 0xfe]) + "other\r\n".data(using: .utf16LittleEndian)!
        try otherBytes.write(to: root.appendingPathComponent(other))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(link).path, withDestinationPath: "/missing/pair-target")
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(tracked)); try await repo.stage([tracked])
        let working = Data([0, 255, 13, 10]); try working.write(to: root.appendingPathComponent(tracked))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let snapshot = try await repo.workingFilePairComparison(paths: [other, tracked])
        let value = try await repo.comparisonFile(snapshot, path: tracked)
        XCTAssertEqual(value.base.path, other); XCTAssertEqual(value.base.bytes, otherBytes)
        XCTAssertEqual(value.destination.bytes, working); XCTAssertNil(value.destination.text)
        let symlinkSnapshot = try await repo.workingFilePairComparison(paths: [link, other])
        let symlink = try await repo.comparisonFile(symlinkSnapshot, path: other)
        XCTAssertEqual(symlink.base.mode, "120000"); XCTAssertEqual(symlink.base.text, "/missing/pair-target")
        try FileManager.default.removeItem(at: root.appendingPathComponent(tracked))
        let deleted = try await repo.workingFilePairComparison(paths: [tracked, other])
        XCTAssertEqual(deleted.from, .revision(head)); XCTAssertEqual(deleted.to, .workingTree)
        let historical = try await repo.comparisonFile(deleted, path: other)
        XCTAssertEqual(historical.base.bytes, original); XCTAssertEqual(historical.destination.bytes, otherBytes)
        let reverse = try await repo.workingFilePairComparison(paths: [other, tracked])
        let reverseDocument = try await repo.comparisonFile(reverse, path: tracked)
        XCTAssertEqual(reverseDocument.base.bytes, otherBytes); XCTAssertEqual(reverseDocument.destination.bytes, original)
        XCTAssertEqual(reverse.to, .revision(head))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let unchangedHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(unchangedHead, head)
        try Data("advance\n".utf8).write(to: root.appendingPathComponent(tracked))
        try await repo.stage([tracked]); _ = try await repo.commit(message: "advance HEAD")
        let advancedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let pinned = try await repo.comparisonFile(deleted, path: other)
        XCTAssertEqual(pinned.base.bytes, original)
        for paths in [[other], [other, other], ["..", other], [".git/config", other], ["missing", other]] {
            do { _ = try await repo.workingFilePairComparison(paths: paths); XCTFail("Reject invalid pair: \(paths)") } catch {}
        }
        let directory = "directory"; try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: false)
        do { _ = try await repo.workingFilePairComparison(paths: [directory, other]); XCTFail("Reject directories") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), advancedIndex)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(other)), otherBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(link).path), "/missing/pair-target")
    }
    func testAlignmentRecoversExactSourcesAndGroupsReplacementsAndGaps() {
        for (a, b) in [("", "new\n"), ("old\n", ""), ("first\r\nold\nend", "first\r\nnew\nextra\nend"), ("é\n", "e\u{301}\n"), ("x\n", "x"), ("same\n", "same\n")] {
            let aligned = FileComparisonAlignment(base: a, destination: b)
            XCTAssertEqual(Data(aligned.rows.filter { $0.base.lineNumber != nil }.map(\.base.text).joined().utf8), Data(a.utf8))
            XCTAssertEqual(Data(aligned.rows.filter { $0.destination.lineNumber != nil }.map(\.destination.text).joined().utf8), Data(b.utf8))
            XCTAssertEqual(aligned.differences.flatMap { Array($0) }, aligned.rows.indices.filter { aligned.rows[$0].changed })
            XCTAssertEqual(aligned.differences.isEmpty, a.utf8.elementsEqual(b.utf8))
        }
    }
    func testPinnedRenameAddedDeletedBinaryAndSymlinkContent() async throws {
        let (root, repo, original) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: root.appendingPathComponent(original))
        try Data("removed\n".utf8).write(to: root.appendingPathComponent("deleted.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "old-target")
        try await repo.stage(["deleted.txt", "link"]); _ = try await repo.commit(message: "base contents")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let renamed = ":(glob)* new 雪\n.txt"
        _ = try await repo.run(["mv", "--", original, renamed])
        _ = try await repo.run(["rm", "--", "deleted.txt"])
        try Data([0, 1, 2, 255]).write(to: root.appendingPathComponent("binary.dat"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/outside/repository")
        try await repo.stage(["binary.dat", "link"]); _ = try await repo.commit(message: "new contents")
        let snapshot = try await repo.revisionComparison(from: .revision(base), to: .revision("HEAD"))
        try Data("later\n".utf8).write(to: root.appendingPathComponent(renamed)); try await repo.stage([renamed]); _ = try await repo.commit(message: "advance")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let rename = try await repo.comparisonFile(snapshot, path: renamed)
        XCTAssertEqual(rename.base.path, original); XCTAssertEqual(rename.base.bytes, before); XCTAssertEqual(rename.destination.bytes, before)
        let binary = try await repo.comparisonFile(snapshot, path: "binary.dat")
        XCTAssertTrue(binary.base.bytes.isEmpty); XCTAssertEqual(binary.destination.bytes, Data([0, 1, 2, 255])); XCTAssertNil(binary.destination.text)
        let deleted = try await repo.comparisonFile(snapshot, path: "deleted.txt")
        XCTAssertEqual(deleted.base.text, "removed\n"); XCTAssertTrue(deleted.destination.bytes.isEmpty)
        let link = try await repo.comparisonFile(snapshot, path: "link")
        XCTAssertEqual(link.base.text, "old-target"); XCTAssertEqual(link.destination.text, "/outside/repository"); XCTAssertEqual(link.destination.mode, "120000")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        do { _ = try await repo.comparisonFile(snapshot, path: "../outside"); XCTFail("Reject paths outside snapshot") } catch RevisionComparisonFailure.selection {}
    }
    func testWorkingContentsReverseAndUTF16RemainUnchanged() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        let bytes = Data([0xff, 0xfe]) + "working 雪\r\n".data(using: .utf16LittleEndian)!
        try bytes.write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let snapshot = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree)
        let value = try await repo.comparisonFile(snapshot, path: path)
        XCTAssertEqual(value.base.bytes, original); XCTAssertEqual(value.destination.bytes, bytes); XCTAssertEqual(value.destination.text, "working 雪\r\n")
        let reverse = try await repo.revisionComparison(from: .workingTree, to: .revision("HEAD"))
        let reversed = try await repo.comparisonFile(reverse, path: path)
        XCTAssertEqual(reversed.base.bytes, bytes); XCTAssertEqual(reversed.destination.bytes, original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
    }
}
