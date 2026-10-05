import XCTest
@testable import TurtleGitCore

final class TextConflictTests: XCTestCase {
    func testExplicitOutputFormatsPreserveModesAndIndexUntilResolution() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent(path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: location.path)
        var document = try await repo.textConflictDocument(path: path)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let text = "Aé\r\nno end"
        for encoding in ComparisonTextEncoding.allCases {
            document = try await repo.saveTextConflict(document, result: text, markResolved: false, encoding: encoding)
            XCTAssertEqual(document.encoding, encoding)
            XCTAssertEqual(try Data(contentsOf: location), try encoding.encode(text))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: location.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        }
        let before = try Data(contentsOf: location)
        do { _ = try await repo.saveTextConflict(document, result: "雪🦎", markResolved: false, encoding: .windows1252); XCTFail("Lost Unicode") }
        catch FileComparisonEditFailure.encoding {}
        XCTAssertEqual(try Data(contentsOf: location), before)
        let reloaded = try await repo.textConflictDocument(path: path)
        XCTAssertEqual(reloaded.encoding, .utf32BE)
        XCTAssertEqual(reloaded.workingContents, before)
        _ = try await repo.saveTextConflict(reloaded, result: "雪🦎\r\nno end", markResolved: true, encoding: .utf16BEBOM)
        let staged = try await repo.run(["show", ":" + path]).stdout
        XCTAssertEqual(staged, try ComparisonTextEncoding.utf16BEBOM.encode("雪🦎\r\nno end"))
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(afterHead, head)
        let other = try await repo.run(["show", ":other.txt"]).text
        XCTAssertEqual(other, "other index\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "other working\n")
    }
    func testMixedUnicodeStageEncodingsDecodeWithoutLeakingBOMIntoResult() async throws {
        let (root, repo) = try await CommitSelectionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Unicode.txt", location = root.appendingPathComponent(path)
        func write(_ text: String, _ encoding: ComparisonTextEncoding) throws {
            try encoding.encode(text).write(to: location)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: location.path)
        }
        try write("base 雪🦎\r\n", .utf16LEBOM); try await repo.stage([path]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "side"])
        try write("theirs 雪🦎\r\n", .utf32BE); try await repo.stage([path]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"])
        try write("mine 雪🦎\r\n", .utf8BOM); try await repo.stage([path]); _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(["merge", "side"]); XCTFail("Expected conflict") } catch is GitFailure {}
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), before = try Data(contentsOf: location)
        let document = try await repo.textConflictDocument(path: path)
        XCTAssertEqual(document.base, "base 雪🦎\r\n"); XCTAssertEqual(document.mine, "mine 雪🦎\r\n"); XCTAssertEqual(document.theirs, "theirs 雪🦎\r\n")
        XCTAssertFalse(document.initialResult.contains("\u{feff}")); XCTAssertEqual(MergeText.conflicts(in: document.initialResult).count, 1)
        XCTAssertEqual(document.encoding, .utf8BOM)
        XCTAssertEqual(document.baseEncoding, .utf16LEBOM)
        XCTAssertEqual(document.mineEncoding, .utf8BOM)
        XCTAssertEqual(document.theirsEncoding, .utf32BE)
        XCTAssertEqual(try Data(contentsOf: location), before); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let result = try MergeText.applying(.theirs, block: 0, to: document.initialResult, document: document)
        _ = try await repo.saveTextConflict(document, result: result, markResolved: false)
        XCTAssertEqual(try Data(contentsOf: location), try ComparisonTextEncoding.utf8BOM.encode("theirs 雪🦎\r\n"))
    }
    func testEofBlockChoicesRetainSourceEndingsAndSeparateCombinedSides() async throws {
        for (mine, theirs, ending) in [("Mine 雪", "Theirs e\u{301}", "\n"), ("Mine\n", "Theirs", "\n"), ("Mine", "Theirs\n", "\n"), ("Mine\r\n", "Theirs", "\r\n"), ("Mine\r", "Theirs", "\n")] {
            let (root, repo) = try await CommitSelectionTests().fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let path = "EOF 雪.txt", prefix = "common" + ending
            func write(_ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
            try write(prefix + "Base" + ending); try await repo.stage([path]); _ = try await repo.commit(message: "base")
            _ = try await repo.run(["switch", "-c", "side"])
            try write(prefix + theirs); try await repo.stage([path]); _ = try await repo.commit(message: "theirs")
            _ = try await repo.run(["switch", "main"])
            try write(prefix + mine); try await repo.stage([path]); _ = try await repo.commit(message: "mine")
            do { _ = try await repo.run(["merge", "side"]); XCTFail("Expected EOF conflict") } catch is GitFailure {}
            let document = try await repo.textConflictDocument(path: path)
            let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
            let working = try Data(contentsOf: root.appendingPathComponent(path))
            XCTAssertTrue(MergeText.hasMarkers(document.initialResult))
            do { _ = try await repo.saveTextConflict(document, result: document.initialResult, markResolved: true); XCTFail("Allowed unresolved EOF markers") }
            catch TextConflictFailure.markers {}
            func joined(_ first: String, _ last: String) -> String { first + (first.utf8.last == 10 ? "" : ending) + last }
            for (choice, expected) in [(MergeBlockChoice.mine, mine), (.theirs, theirs), (.mineThenTheirs, joined(mine, theirs)), (.theirsThenMine, joined(theirs, mine))] {
                let result = try MergeText.applying(choice, block: 0, to: document.initialResult, document: document)
                XCTAssertEqual(Data(result.utf8), Data((prefix + expected).utf8), "\(choice): \(mine.debugDescription), \(theirs.debugDescription)")
            }
            // Trailing manual context keeps the marker-delimited line ending;
            // the EOF metadata must not merge that context into the chosen line.
            let appended = document.initialResult + "outside" + ending
            let selected = try MergeText.applying(.theirs, block: 0, to: appended, document: document)
            let rawTheirs = try XCTUnwrap(MergeText.conflicts(in: document.initialResult).first).theirs
            XCTAssertEqual(Data(selected.utf8), Data((prefix + rawTheirs + "outside" + ending).utf8))
            let afterIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
            XCTAssertEqual(afterIndex, index); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), working)
            let edited = prefix + "<<<<<<< Mine" + ending + "manual" + ending + "||||||| Base" + ending + "Base" + ending + "=======" + ending + rawTheirs + ">>>>>>> Theirs" + ending
            let editedChoice = try MergeText.applying(.mine, block: 0, to: edited, document: document)
            XCTAssertEqual(Data(editedChoice.utf8), Data((prefix + "manual" + ending).utf8))
            let head = try await repo.run(["rev-parse", "HEAD"]).stdout
            let refs = try await repo.run(["show-ref"]).stdout
            let mergeHead = try await repo.run(["rev-parse", "MERGE_HEAD"]).stdout
            let selectedTheirs = try MergeText.applying(.theirs, block: 0, to: document.initialResult, document: document)
            let saved = try await repo.saveTextConflict(document, result: selectedTheirs, markResolved: false)
            let afterUndoChoice = try MergeText.applying(.mine, block: 0, to: document.initialResult, document: saved)
            XCTAssertEqual(Data(afterUndoChoice.utf8), Data((prefix + mine).utf8), "Save must retain EOF metadata for Undo and reselect")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data((prefix + theirs).utf8))
            let savedIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
            XCTAssertEqual(savedIndex, index)
            _ = try await repo.saveTextConflict(saved, result: selectedTheirs, markResolved: true)
            let staged = try await repo.run(["show", ":" + path]).stdout
            let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
            let finalRefs = try await repo.run(["show-ref"]).stdout
            let finalMergeHead = try await repo.run(["rev-parse", "MERGE_HEAD"]).stdout
            XCTAssertEqual(staged, Data((prefix + theirs).utf8))
            XCTAssertEqual(finalHead, head); XCTAssertEqual(finalRefs, refs); XCTAssertEqual(finalMergeHead, mergeHead)
        }
    }
    func testSaveBeforeReloadRegeneratesConflictsWithoutDiscardingSavedWorkingBytes() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await repo.textConflictDocument(path: path)
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let refs = try await repo.run(["show-ref"]).stdout
        let draft = "reviewed 雪 e\u{301}\r\nno final newline"
        let saved = try await repo.saveTextConflict(original, result: draft, markResolved: false)
        let reloaded = try await repo.textConflictDocument(path: path)
        XCTAssertEqual(saved.initialResult, draft)
        XCTAssertEqual(reloaded.workingContents, Data(draft.utf8))
        XCTAssertEqual(Data(reloaded.initialResult.utf8), Data(original.initialResult.utf8))
        XCTAssertEqual(reloaded.entry.stages, original.entry.stages)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data(draft.utf8))
        let afterIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let afterRefs = try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(afterIndex, index); XCTAssertEqual(afterHead, head); XCTAssertEqual(afterRefs, refs)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "other working\n")
        let otherIndex = try await repo.run(["show", ":other.txt"]).text
        XCTAssertEqual(otherIndex, "other index\n")
        _ = try await repo.run(["rev-parse", "--verify", "MERGE_HEAD"])
    }
    func testStageExtractionAndEveryBlockChoiceRetainsOutsideContextAndUnicode() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let working = try Data(contentsOf: root.appendingPathComponent(path))
        let document = try await repo.textConflictDocument(path: path)
        XCTAssertEqual(document.base, "base\n"); XCTAssertEqual(document.mine, "mine\n"); XCTAssertEqual(document.theirs, "theirs\n")
        XCTAssertEqual(document.mineStage, 2); XCTAssertEqual(document.theirsStage, 3)
        let blocks = MergeText.conflicts(in: document.initialResult); XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.base, "base\n")
        for (choice, expected) in [(MergeBlockChoice.mine, "mine\n"), (.theirs, "theirs\n"), (.mineThenTheirs, "mine\ntheirs\n"), (.theirsThenMine, "theirs\nmine\n")] {
            let decorated = "🦎 雪\n" + document.initialResult + "outside\n"
            let result = try MergeText.applying(choice, block: 0, to: decorated)
            XCTAssertEqual(result, "🦎 雪\n" + expected + "outside\n"); XCTAssertFalse(MergeText.hasMarkers(result))
        }
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(before, after); XCTAssertEqual(working, try Data(contentsOf: root.appendingPathComponent(path)))
    }
    func testSaveThenMarkResolvedKeepsUnrelatedIndexWorkingHeadAndMergeState() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await repo.textConflictDocument(path: path)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout, index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let text = try MergeText.applying(.mineThenTheirs, block: 0, to: original.initialResult)
        let saved = try await repo.saveTextConflict(original, result: text, markResolved: false)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data(text.utf8))
        let savedIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout; XCTAssertEqual(index, savedIndex)
        _ = try await repo.saveTextConflict(saved, result: text, markResolved: true)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(head, afterHead); XCTAssertEqual(refs, afterRefs)
        let indexed = try await repo.run(["show", ":" + path]).text, other = try await repo.run(["show", ":other.txt"]).text
        XCTAssertEqual(indexed, text); XCTAssertEqual(other, "other index\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "other working\n")
        let conflicts = try await repo.conflicts(); XCTAssertTrue(conflicts.isEmpty)
        _ = try await repo.run(["rev-parse", "--verify", "MERGE_HEAD"])
    }
    func testStaleWorkingFileStagesAndPermissionsRejectBeforeSaving() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await repo.textConflictDocument(path: path), location = root.appendingPathComponent(path)
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        try Data("external review\n".utf8).write(to: location)
        do { _ = try await repo.saveTextConflict(document, result: "overwrite\n", markResolved: true); XCTFail("Overwrote external edit") } catch TextConflictFailure.changedWorkingFile {}
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout; XCTAssertEqual(index, after)
        XCTAssertEqual(try String(contentsOf: location), "external review\n")
        let refreshed = try await repo.textConflictDocument(path: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: location.path)
        do { _ = try await repo.saveTextConflict(refreshed, result: "overwrite\n", markResolved: false); XCTFail("Ignored mode change") } catch TextConflictFailure.changedWorkingFile {}
        let latest = try await repo.textConflictDocument(path: path)
        _ = try await repo.resolveConflicts([latest.entry], using: .mine)
        let resolved = try Data(contentsOf: location)
        do { _ = try await repo.saveTextConflict(latest, result: "overwrite\n", markResolved: false); XCTFail("Accepted stale stages") } catch ResolveFailure.stale {}
        XCTAssertEqual(resolved, try Data(contentsOf: location))
    }
    func testUnresolvedMarkersBinaryAndSymlinksAreRejectedWithoutMutations() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await repo.textConflictDocument(path: path), original = try Data(contentsOf: root.appendingPathComponent(path))
        do { _ = try await repo.saveTextConflict(document, result: document.initialResult, markResolved: true); XCTFail("Staged conflict markers") } catch TextConflictFailure.markers {}
        XCTAssertEqual(original, try Data(contentsOf: root.appendingPathComponent(path)))
        let saved = try await repo.saveTextConflict(document, result: document.initialResult, markResolved: false)
        XCTAssertEqual(saved.workingContents, Data(document.initialResult.utf8))
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(path).path, withDestinationPath: "other.txt")
        do { _ = try await repo.saveTextConflict(saved, result: "overwrite\n", markResolved: false); XCTFail("Followed working symlink") } catch TextConflictFailure.changedWorkingFile {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "other working\n")
        let (binaryRoot, binaryRepo, binaryPath) = try await ConflictResolutionTests().fixture(binary: true)
        defer { try? FileManager.default.removeItem(at: binaryRoot) }
        do { _ = try await binaryRepo.textConflictDocument(path: binaryPath); XCTFail("Decoded binary merge") } catch TextConflictFailure.encoding {}
    }
    func testFailedStageReturnsSavedDocumentForRetryWithoutLosingWorkingResult() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await repo.textConflictDocument(path: path), lock = root.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        var saved: TextConflictDocument?
        do { _ = try await repo.saveTextConflict(document, result: "reviewed result\n", markResolved: true); XCTFail("Staged with locked index") }
        catch let failure as TextConflictSaveFailure { saved = failure.savedDocument; XCTAssertTrue(failure.gitError.contains("index.lock")) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path)), "reviewed result\n")
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout; XCTAssertEqual(index, after)
        try FileManager.default.removeItem(at: lock)
        _ = try await repo.saveTextConflict(try XCTUnwrap(saved), result: "reviewed result\n", markResolved: true)
        let remaining = try await repo.conflicts(); XCTAssertTrue(remaining.isEmpty)
    }
    func testRebaseOrderAndExecutableUtf8BomCrLfSaving() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", "other.txt"])
        _ = try await repo.run(["merge", "--abort"])
        do { _ = try await repo.run(["rebase", "side"]); XCTFail("Expected conflict") } catch is GitFailure {}
        let location = root.appendingPathComponent(path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: location.path)
        let document = try await repo.textConflictDocument(path: path)
        XCTAssertEqual(document.mineStage, 3); XCTAssertEqual(document.mine, "mine\n")
        XCTAssertEqual(document.theirsStage, 2); XCTAssertEqual(document.theirs, "theirs\n")
        let result = "\u{feff}雪\r\nreviewed without final newline"
        _ = try await repo.saveTextConflict(document, result: result, markResolved: true)
        XCTAssertEqual(try Data(contentsOf: location), Data(result.utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: location.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        let stage = try await repo.run(["ls-files", "--stage", "-z", "--", path]).text
        XCTAssertTrue(stage.hasPrefix("100755 "))
        _ = try await repo.run(["rebase", "--abort"])
    }
    func testCrLfMultipleBlocksAndIncompleteMarkers() throws {
        let text = "intro 雪\r\n<<<<<<< Mine\r\nM1\r\n||||||| Base\r\nB1\r\n=======\r\nT1\r\n>>>>>>> Theirs\r\nbetween\r\n<<<<<<< Mine\r\nM2\r\n=======\r\nT2\r\n>>>>>>> Theirs"
        let blocks = MergeText.conflicts(in: text); XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].mine, "M1\r\n"); XCTAssertEqual(blocks[0].base, "B1\r\n"); XCTAssertEqual(blocks[1].base, "")
        let second = try MergeText.applying(.theirsThenMine, block: 1, to: text)
        XCTAssertTrue(second.hasSuffix("T2\r\nM2\r\n")); XCTAssertEqual(MergeText.conflicts(in: second).count, 1)
        let resolved = try MergeText.applying(.mine, block: 0, to: second)
        XCTAssertEqual(resolved, "intro 雪\r\nM1\r\nbetween\r\nT2\r\nM2\r\n")
        XCTAssertTrue(MergeText.hasMarkers("<<<<<<< Mine\nunfinished\n")); XCTAssertTrue(MergeText.conflicts(in: "<<<<<<< Mine\nunfinished\n").isEmpty)
        XCTAssertFalse(MergeText.hasMarkers("heading\n=======\n"))
    }
    func testAddAddConflictHasEmptyBaseAndCanResolveEitherSide() async throws {
        let (root, repo) = try await CommitSelectionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "new 雪.txt"
        try Data("seed\n".utf8).write(to: root.appendingPathComponent("seed.txt")); try await repo.stage(["seed.txt"]); _ = try await repo.commit(message: "seed")
        _ = try await repo.run(["switch", "-c", "side"])
        try Data("theirs\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "new theirs")
        _ = try await repo.run(["switch", "main"])
        try Data("mine\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "new mine")
        do { _ = try await repo.run(["merge", "side"]); XCTFail("Expected add/add conflict") } catch is GitFailure {}
        let document = try await repo.textConflictDocument(path: path)
        XCTAssertEqual(document.base, ""); XCTAssertEqual(document.entry.stages.map(\.number), [2, 3])
        let result = try MergeText.applying(.theirs, block: 0, to: document.initialResult)
        _ = try await repo.saveTextConflict(document, result: result, markResolved: true)
        let indexed = try await repo.run(["show", ":" + path]).text; XCTAssertEqual(indexed, "theirs\n")
    }

}
