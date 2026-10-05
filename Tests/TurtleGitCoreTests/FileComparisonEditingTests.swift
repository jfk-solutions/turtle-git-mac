import XCTest
@testable import TurtleGitCore

final class FileComparisonEditingTests: XCTestCase {
    func testTransfersUseBothPendingDraftsAndExplicitDestination() throws {
        let base = ComparisonFileContent(path: "base", revision: .workingTree, bytes: Data("base original\n".utf8), mode: "100644")
        let mine = ComparisonFileContent(path: "mine", revision: .workingTree, bytes: Data("mine original\r\n".utf8), mode: "100644")
        var drafts = FileComparisonDrafts(FileComparisonDocument(base: base, destination: mine))
        drafts.setEditing(true, base: true)
        try drafts.update(text: "base pending\n", base: true)
        try drafts.update(text: "mine pending\r\n", base: false)
        let alignment = FileComparisonAlignment(base: try XCTUnwrap(drafts.text(base: true)), destination: try XCTUnwrap(drafts.text(base: false)))
        for (choice, expected) in [(FileComparisonEditing.BlockChoice.otherThenCurrent, "mine pending\nbase pending\n"), (.other, "mine pending\n"), (.currentThenOther, "base pending\nmine pending\n")] {
            let edit = try FileComparisonEditing.takingOtherRows(alignment, rows: alignment.rows.indices, targetBase: true, choice: choice)
            XCTAssertEqual(edit.text, expected)
        }
        let edit = try FileComparisonEditing.takingOtherRows(alignment, rows: alignment.rows.indices, targetBase: false)
        try drafts.update(text: edit.text, base: false)
        XCTAssertEqual(drafts.text(base: false), "base pending\r\n")
        XCTAssertEqual(drafts.text(base: true), "base pending\n")
        XCTAssertEqual(drafts.dirtySides, [false, true])
    }
    func testIndependentDraftsSaveOneSideAndExportOtherWithoutIndexMutation() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let right = outside.appendingPathComponent("right.txt"), initial = Data([0xff, 0xfe]) + "right\r\n".data(using: .utf16LittleEndian)!
        try initial.write(to: right); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: right.path)
        let pair = try WorkingFileComparison(base: root.appendingPathComponent(path), destination: right)
        var document = try pair.read(), drafts = FileComparisonDrafts(document)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertFalse(drafts.preferredBase); XCTAssertTrue(drafts.editingEnabled(base: false)); XCTAssertFalse(drafts.editingEnabled(base: true))
        try drafts.update(text: "left draft\n", base: true); drafts.setEditing(true, base: true)
        try drafts.update(text: "right draft\r\n", base: false)
        drafts.update(annotations: .init(marked: [0]), base: true)
        XCTAssertEqual(drafts.dirtySides, [false, true]); XCTAssertEqual(drafts.text(base: true), "left draft\n")
        XCTAssertEqual(try drafts.exported(base: false), Data([0xff, 0xfe]) + "right draft\r\n".data(using: .utf16LittleEndian)!)
        document = try pair.save(document, base: true, text: XCTUnwrap(drafts.text(base: true)))
        try drafts.didSave(document.base, base: true)
        XCTAssertFalse(drafts.isDirty(base: true)); XCTAssertTrue(drafts.isDirty(base: false))
        XCTAssertEqual(drafts.annotations(base: true).marked, [0]); XCTAssertEqual(drafts.annotations(base: false).marked, [])
        XCTAssertEqual(try Data(contentsOf: right), initial)
        document = try pair.save(document, base: false, text: XCTUnwrap(drafts.text(base: false)))
        try drafts.didSave(document.destination, base: false)
        XCTAssertTrue(drafts.dirtySides.isEmpty)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: right.path)[.posixPermissions] as? NSNumber, 0o755)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
    }
    func testImmutablePanesAndAnnotationRealignmentDoNotLoseIndependentDrafts() throws {
        let historical = ComparisonFileContent(path: "old", revision: .revision(String(repeating: "a", count: 40)), bytes: Data("old\n".utf8), mode: "100644")
        let working = ComparisonFileContent(path: "working", revision: .workingTree, bytes: Data("one\ntwo\n".utf8), mode: "100644", permissions: 0o644)
        var drafts = FileComparisonDrafts(FileComparisonDocument(base: working, destination: historical))
        XCTAssertTrue(drafts.preferredBase); XCTAssertFalse(drafts.editingEnabled(base: true))
        XCTAssertThrowsError(try drafts.update(text: "changed history", base: false))
        XCTAssertEqual(try drafts.exported(base: false), historical.bytes)
        drafts.update(annotations: .init(marked: [1]), base: true)
        try drafts.didSave(working, base: true)
        let old = FileComparisonAlignment(base: "one\ntwo\n", destination: "one\ntwo\n")
        let new = FileComparisonAlignment(base: "one\ntwo\n", destination: "extra\none\ntwo\n")
        drafts.remapAnnotations(from: old, to: new, base: true)
        XCTAssertFalse(drafts.isDirty(base: true)); XCTAssertEqual(drafts.annotations(base: true).marked, [2])
        let binary = ComparisonFileContent(path: "binary", revision: .workingTree, bytes: Data([0, 255]), mode: "100644", permissions: 0o644)
        var immutable = FileComparisonDrafts(FileComparisonDocument(base: binary, destination: historical))
        immutable.setEditing(true, base: true); XCTAssertFalse(immutable.editingEnabled(base: true))
        XCTAssertThrowsError(try immutable.update(text: "replacement", base: true)); XCTAssertEqual(try immutable.exported(base: true), binary.bytes)
    }
    func testStandaloneWorkingPairReadsLiteralBytesAndSavesEitherSideWithoutIndexChanges() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let left = root.appendingPathComponent(path), right = otherRoot.appendingPathComponent(":(glob)* 雪\n.txt")
        let original = try Data(contentsOf: left), bytes = Data([0xff, 0xfe]) + "right\r\n".data(using: .utf16LittleEndian)!
        try bytes.write(to: right); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: right.path)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let comparison = try WorkingFileComparison(base: left, destination: right), document = try comparison.read()
        XCTAssertEqual(document.base.bytes, original); XCTAssertEqual(document.destination.bytes, bytes)
        XCTAssertEqual(document.destination.text, "right\r\n"); XCTAssertEqual(document.destination.mode, "100755")
        let saved = try comparison.save(document, base: false, text: "edited\r\n")
        XCTAssertEqual(saved.destination.bytes, Data([0xff, 0xfe]) + "edited\r\n".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: right.path)[.posixPermissions] as? NSNumber, 0o755)
        XCTAssertEqual(try Data(contentsOf: left), original)
        _ = try comparison.save(saved, base: true, text: "left edited\n")
        XCTAssertEqual(try Data(contentsOf: left), Data("left edited\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: otherRoot.path).contains { $0.hasPrefix(".TurtleGitDiff-") })
    }
    func testStandaloneWorkingPairRejectsChangedContentsModesLinksAndForeignDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right"), binary = Data([0, 255])
        try binary.write(to: left); try Data("right\n".utf8).write(to: right)
        let comparison = try WorkingFileComparison(base: left, destination: right), document = try comparison.read()
        XCTAssertEqual(document.base.bytes, binary); XCTAssertNil(document.base.text)
        XCTAssertThrowsError(try comparison.save(document, base: true, text: "text"))
        try Data("external\n".utf8).write(to: right)
        XCTAssertThrowsError(try comparison.save(document, base: false, text: "lost update"))
        XCTAssertEqual(try Data(contentsOf: right), Data("external\n".utf8))
        let fresh = try comparison.read()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: right.path)
        XCTAssertThrowsError(try comparison.save(fresh, base: false, text: "mode changed"))
        try FileManager.default.removeItem(at: right)
        try FileManager.default.createSymbolicLink(atPath: right.path, withDestinationPath: "missing target 雪")
        let link = try comparison.read()
        XCTAssertEqual(link.destination.mode, "120000"); XCTAssertEqual(link.destination.bytes, Data("missing target 雪".utf8))
        XCTAssertThrowsError(try comparison.save(link, base: false, text: "replace link"))
        let reversed = try WorkingFileComparison(base: right, destination: left)
        XCTAssertThrowsError(try reversed.save(document, base: false, text: "foreign document"))
        XCTAssertThrowsError(try WorkingFileComparison(base: root, destination: left).read())
        XCTAssertThrowsError(try WorkingFileComparison(base: URL(string: "https://example.invalid/file")!, destination: left))
        XCTAssertEqual(try Data(contentsOf: left), binary)
    }
    func testLeaveOnlyMarkedKeepsMarkedAndTypedRowsButTakesUnmarkedSourceAndGaps() throws {
        let comparison = FileComparisonAlignment(base: "base one\ncommon\nbase two\nremoved\nend", destination: "local one\r\ncommon\r\nlocal two\r\nend")
        let flags = FileComparisonEditing.Annotations(marked: [0], edited: [2, 3])
        XCTAssertEqual(try FileComparisonEditing.leavingOnlyMarked(comparison, targetBase: false, annotations: flags), "local one\r\ncommon\r\nlocal two\r\nend")
        XCTAssertEqual(try FileComparisonEditing.leavingOnlyMarked(comparison, targetBase: false, annotations: .init()), "base one\r\ncommon\r\nbase two\r\nremoved\r\nend")
        XCTAssertEqual(try FileComparisonEditing.leavingOnlyMarked(comparison, targetBase: true, annotations: .init(marked: [0])), "base one\ncommon\nlocal two\nend")
        XCTAssertThrowsError(try FileComparisonEditing.leavingOnlyMarked(comparison, targetBase: false, annotations: .init(marked: [99])))
        let eof = FileComparisonAlignment(base: "base\nextra", destination: "typed")
        XCTAssertEqual(try FileComparisonEditing.leavingOnlyMarked(eof, targetBase: false, annotations: .init(edited: [0])), "typed\nextra")
    }
    func testAnnotationsFollowInsertedReplacedDeletedAndRealignedLines() throws {
        let source = "a\nb\nc\nend"
        let old = FileComparisonAlignment(base: source, destination: "a\nlocal\nc\nend")
        let new = FileComparisonAlignment(base: source, destination: "intro\na\ntyped\nc\nend")
        let flags = FileComparisonEditing.Annotations(marked: [1, 2], edited: [1])
        let moved = flags.remapped(from: old, to: new, targetBase: false, typing: true)
        XCTAssertEqual(moved.marked, [2, 3])
        XCTAssertEqual(moved.edited, [0, 2])
        let deleted = FileComparisonAlignment(base: source, destination: "a\nc\nend")
        let removed = flags.remapped(from: old, to: deleted, targetBase: false, typing: true)
        XCTAssertEqual(removed.marked, [1, 2])
        XCTAssertEqual(removed.edited, [1])
        XCTAssertEqual(try FileComparisonEditing.leavingOnlyMarked(deleted, targetBase: false, annotations: removed), "a\nc\nend")
        let reversedOld = FileComparisonAlignment(base: "a\nlocal\nc\nend", destination: source)
        let reversedNew = FileComparisonAlignment(base: "intro\na\ntyped\nc\nend", destination: source)
        XCTAssertEqual(flags.remapped(from: reversedOld, to: reversedNew, targetBase: true, typing: true), moved)
    }
    func testSelectedRowsIncludeEndpointAndCopyExcludesAlignmentArtifacts() throws {
        let alignment = FileComparisonAlignment(base: "removed\r\n🐢keep\r\nend", destination: "🐢keep\r\nend")
        let cells = alignment.rows.map(\.destination)
        // Display is a gap followed by two rows, with LF display separators.
        XCTAssertEqual(try FileComparisonEditing.selectedRows(NSRange(location: 1, length: 7), cells: cells), 1..<3)
        XCTAssertEqual(try FileComparisonEditing.selectedRows(NSRange(location: 2, length: 2), cells: cells), 1..<2)
        XCTAssertNil(try FileComparisonEditing.selectedRows(NSRange(location: 1, length: 0), cells: cells))
        XCTAssertEqual(try FileComparisonEditing.selectedText(NSRange(location: 0, length: 1), cells: cells), "")
        XCTAssertEqual(try FileComparisonEditing.selectedText(NSRange(location: 1, length: 7), cells: cells), "🐢keep\r\n")
        XCTAssertEqual(try FileComparisonEditing.selectedText(NSRange(location: 0, length: 12), cells: cells), "🐢keep\r\nend")
        XCTAssertEqual(try FileComparisonEditing.selectedRows(NSRange(location: 0, length: 12), cells: cells), 0..<3)
        XCTAssertThrowsError(try FileComparisonEditing.selectedRows(NSRange(location: 13, length: 0), cells: cells))
        XCTAssertThrowsError(try FileComparisonEditing.selectedText(NSRange(location: 11, length: 2), cells: cells))
    }
    func testRangeTransfersSpanUnchangedRowsAndNormalizeTargetEndings() throws {
        let alignment = FileComparisonAlignment(base: "start\nold\nkeep\nremoved\nend", destination: "start\nnew\nkeep\nend")
        XCTAssertEqual(try FileComparisonEditing.takingOtherRows(alignment, rows: 1..<4, targetBase: false).text, "start\nold\nkeep\nremoved\nend")
        XCTAssertEqual(try FileComparisonEditing.takingOtherRows(alignment, rows: 1..<4, targetBase: true).text, "start\nnew\nkeep\nend")
        XCTAssertThrowsError(try FileComparisonEditing.takingOtherRows(alignment, rows: 0..<0, targetBase: false))
        XCTAssertThrowsError(try FileComparisonEditing.takingOtherRows(alignment, rows: -1..<2, targetBase: false))
        XCTAssertThrowsError(try FileComparisonEditing.takingOtherRows(alignment, rows: 0..<99, targetBase: false))
        let mixed = FileComparisonAlignment(base: "old\nlast", destination: "new\r\nfinal")
        XCTAssertEqual(try FileComparisonEditing.takingOtherRows(mixed, rows: mixed.rows.indices, targetBase: false).text, "old\r\nlast")
        XCTAssertEqual(try FileComparisonEditing.takingOtherRows(mixed, rows: mixed.rows.indices, targetBase: true).text, "new\nfinal")
        XCTAssertEqual(try FileComparisonEditing.takingOtherRows(mixed, rows: mixed.rows.indices, targetBase: false, choice: .currentThenOther).text, "new\r\nfinal\r\nold\r\nlast")
    }
    func testBlockTransfersHandleReplacementInsertionDeletionReverseAndBothOrders() throws {
        let a = "common\r\nold\r\nend", b = "common\r\nnew\r\nextra\r\nend"
        let alignment = FileComparisonAlignment(base: a, destination: b)
        XCTAssertEqual(try FileComparisonEditing.takingOtherBlock(alignment, difference: 0, targetBase: false).text, a)
        XCTAssertEqual(try FileComparisonEditing.takingOtherBlock(alignment, difference: 0, targetBase: true).text, b)
        XCTAssertEqual(try FileComparisonEditing.takingOtherBlock(alignment, difference: 0, targetBase: false, choice: .otherThenCurrent).text, "common\r\nold\r\nnew\r\nextra\r\nend")
        XCTAssertEqual(try FileComparisonEditing.takingOtherBlock(alignment, difference: 0, targetBase: false, choice: .currentThenOther).text, "common\r\nnew\r\nextra\r\nold\r\nend")
        for (old, new) in [("", "added\n"), ("removed\n", ""), ("old", "new"), ("é\n", "e\u{301}\n")] {
            let comparison = FileComparisonAlignment(base: old, destination: new)
            XCTAssertEqual(Data(try FileComparisonEditing.takingOtherBlock(comparison, difference: 0, targetBase: false).text.utf8), Data(old.utf8))
            XCTAssertEqual(Data(try FileComparisonEditing.takingOtherBlock(comparison, difference: 0, targetBase: true).text.utf8), Data(new.utf8))
        }
        let noEnd = FileComparisonAlignment(base: "old", destination: "new")
        XCTAssertEqual(try FileComparisonEditing.takingOtherBlock(noEnd, difference: 0, targetBase: false, choice: .otherThenCurrent).text, "old\nnew")
        XCTAssertThrowsError(try FileComparisonEditing.takingOtherBlock(alignment, difference: 99, targetBase: false))
    }
    func testExportRetainsRawBinaryAndUsesDraftEncodingWithoutSourceChanges() throws {
        let binary = ComparisonFileContent(path: "binary", revision: .revision("pinned"), bytes: Data([0, 1, 255]), mode: "100644")
        XCTAssertEqual(try FileComparisonEditing.exported(binary), binary.bytes)
        let utf16 = ComparisonFileContent(path: "text", revision: .workingTree, bytes: Data([0xff, 0xfe]) + "before\r\n".data(using: .utf16LittleEndian)!, mode: "100644")
        XCTAssertEqual(try FileComparisonEditing.exported(utf16, editedText: "draft 雪"), Data([0xff, 0xfe]) + "draft 雪".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(utf16.text, "before\r\n")
    }
    func testAlignedEditsExcludeGapsAndPreserveEndingsAndEOF() throws {
        let aligned = FileComparisonAlignment(base: "removed\r\nkeep\r\nend", destination: "keep\r\nend")
        let cells = aligned.rows.map(\.destination)
        let gap = try FileComparisonEditing.applying("", range: NSRange(location: 0, length: 1), cells: cells)
        XCTAssertEqual(gap.text, "keep\r\nend")
        let inserted = try FileComparisonEditing.applying("insert\n", range: NSRange(location: 0, length: 0), cells: cells)
        XCTAssertEqual(inserted.text, "insert\r\nkeep\r\nend")
        let replacement = try FileComparisonEditing.applying("X", range: NSRange(location: 2, length: 3), cells: cells)
        XCTAssertEqual(replacement.text, "kX\r\nend")
        let ending = try FileComparisonEditing.applying("", range: NSRange(location: 5, length: 1), cells: cells)
        XCTAssertEqual(ending.text, "keepend")
        let eof = try FileComparisonEditing.applying("!", range: NSRange(location: 9, length: 0), cells: cells)
        XCTAssertEqual(eof.text, "keep\r\nend!")
        XCTAssertEqual(FileComparisonEditing.displayOffset(sourceOffset: 9, cells: cells), 9)
        XCTAssertThrowsError(try FileComparisonEditing.applying("oops", range: NSRange(location: 100, length: 1), cells: cells))
    }
    func testSavingPreservesBOMEncodingPermissionsAndIndexAndSupportsReverseSide() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        for (prefix, encoding) in [(Data([0xef, 0xbb, 0xbf]), String.Encoding.utf8), (Data([0xff, 0xfe]), .utf16LittleEndian), (Data([0xfe, 0xff]), .utf16BigEndian)] {
            let location = root.appendingPathComponent(path)
            try (prefix + "work\r\nend".data(using: encoding)!).write(to: location)
            try FileManager.default.setAttributes([.posixPermissions: 0o751], ofItemAtPath: location.path)
            let snapshot = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree)
            let document = try await repo.comparisonFile(snapshot, path: path)
            let saved = try await repo.saveComparisonFile(snapshot, document: document, base: false, text: "edited 雪\r\nend")
            XCTAssertEqual(saved.destination.text, "edited 雪\r\nend")
            XCTAssertEqual(try Data(contentsOf: location), prefix + "edited 雪\r\nend".data(using: encoding)!)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: location.path)[.posixPermissions] as? NSNumber)?.intValue, 0o751)
            let reverse = try await repo.revisionComparison(from: .workingTree, to: .revision("HEAD"))
            let reversed = try await repo.comparisonFile(reverse, path: path)
            let updated = try await repo.saveComparisonFile(reverse, document: reversed, base: true, text: "reverse")
            XCTAssertEqual(updated.base.text, "reverse")
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(after, head)
    }
    func testExternalTextModeAndSymlinkChangesAreRejectedWithoutOverwrites() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent(path)
        try Data("working".utf8).write(to: location)
        let snapshot = try await repo.revisionComparison(from: .revision("HEAD"), to: .workingTree)
        let document = try await repo.comparisonFile(snapshot, path: path)
        try Data("external".utf8).write(to: location)
        do { _ = try await repo.saveComparisonFile(snapshot, document: document, base: false, text: "overwrite"); XCTFail() } catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try String(contentsOf: location), "external")
        try document.destination.bytes.write(to: location)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: location.path)
        do { _ = try await repo.saveComparisonFile(snapshot, document: document, base: false, text: "overwrite"); XCTFail() } catch FileComparisonEditFailure.changed {}
        let readOnly = try await repo.comparisonFile(snapshot, path: path)
        do { _ = try await repo.saveComparisonFile(snapshot, document: readOnly, base: false, text: "overwrite"); XCTFail() } catch FileComparisonEditFailure.readOnly {}
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createSymbolicLink(atPath: location.path, withDestinationPath: "/outside/repository")
        do { _ = try await repo.saveComparisonFile(snapshot, document: document, base: false, text: "overwrite"); XCTFail() } catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: location.path), "/outside/repository")
    }
}
