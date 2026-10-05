import XCTest
@testable import TurtleGitCore

final class FileComparisonTests: XCTestCase {
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
