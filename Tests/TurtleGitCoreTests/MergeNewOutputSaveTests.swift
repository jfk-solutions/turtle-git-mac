import XCTest
@testable import TurtleGitCore

final class MergeNewOutputSaveTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitNewMergeOutput-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testCapturedAncestorCreatesLiteralNestedOutputAndPreservesFormatModeAndBackup() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested 雪/second\ttab/result\nname.txt")
        let plan = try MergeOutputDirectories(capturing: file)
        XCTAssertEqual(plan.ancestor.path, root.path)
        let before = try MergeToolOutputTarget(capturing: file, absentPermissions: 0o755)
        let text = "雪🦎\r\nlast"
        let saved = try before.save(text: text, encoding: .utf16LEBOM, options: .init(outputDirectories: plan))
        XCTAssertEqual(saved.content.bytes, try ComparisonTextEncoding.utf16LEBOM.encode(text))
        XCTAssertEqual(saved.content.permissions, 0o755)
        XCTAssertEqual(saved.content.mode, "100755")
        let next = try saved.save(text: "next\n", encoding: .utf8, options: .init(backupOriginal: true))
        XCTAssertEqual(next.content.bytes, Data("next\n".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file.path + ".bak")), saved.content.bytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path + ".bak")[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).allSatisfy { !$0.hasPrefix(".TurtleGit") })
    }
    func testDirectoryReceiptRejectsReplacedAncestorAndInjectedSuffixWithoutEscaping() throws {
        let root = try folder(), outside = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let anchor = root.appendingPathComponent("anchor")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: false)
        let file = anchor.appendingPathComponent("new/result")
        let plan = try MergeOutputDirectories(capturing: file), target = try MergeToolOutputTarget(capturing: file)
        try FileManager.default.moveItem(at: anchor, to: root.appendingPathComponent("retired"))
        try FileManager.default.createSymbolicLink(at: anchor, withDestinationURL: outside)
        XCTAssertThrowsError(try target.save(text: "must not escape", options: .init(outputDirectories: plan)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
        try FileManager.default.removeItem(at: anchor)
        try FileManager.default.moveItem(at: root.appendingPathComponent("retired"), to: anchor)
        let nextPlan = try MergeOutputDirectories(capturing: file)
        try FileManager.default.createSymbolicLink(at: anchor.appendingPathComponent("new"), withDestinationURL: outside)
        XCTAssertThrowsError(try target.save(text: "must not follow suffix", options: .init(outputDirectories: nextPlan)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("result").path))
    }
    func testCancelledPreparationRemovesOnlyOwnedEmptyDirectoriesAndDeletionCreatesNone() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a/b/result"), plan = try MergeOutputDirectories(capturing: root.appendingPathComponent("a/b/result"))
        var validations = 0
        XCTAssertThrowsError(try MergeWorkingFileSave.write(at: file, original: nil, permissions: 0o644, bytes: Data("new".utf8), delete: false, backup: false, outputDirectories: plan) {
            validations += 1
            // Interrupt once the first owned directory actually exists.
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path) { throw OperationCancellationFailure.cancelled }
        })
        XCTAssertGreaterThan(validations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
        let missing = try MergeToolOutputTarget(capturing: file)
        let deleted = try missing.save(text: "", options: .init(emptyResult: .delete, outputDirectories: plan))
        XCTAssertTrue(deleted.content.isDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
    }
    func testDirectoryFailureNeverRemovesPeerContentsOrPublishesPartialFile() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a/b/result"), peer = root.appendingPathComponent("a/peer")
        let plan = try MergeOutputDirectories(capturing: file)
        XCTAssertThrowsError(try MergeWorkingFileSave.write(at: file, original: nil, permissions: 0o644, bytes: Data("new".utf8), delete: false, backup: false, outputDirectories: plan) {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path) {
                try Data("peer".utf8).write(to: peer)
                throw OperationCancellationFailure.cancelled
            }
        })
        XCTAssertEqual(try Data(contentsOf: peer), Data("peer".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testReceiptRequiresActualNewNondeletedFileAndRejectsLaterReplacement() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("result"), before = try MergeToolOutputTarget(capturing: root.appendingPathComponent("result"))
        let saved = try before.save(text: "saved\n")
        let receipt = try XCTUnwrap(MergeNewOutputReceipt.capture(before: before.content, after: saved.content, at: file))
        try receipt.validate()
        XCTAssertNil(try MergeNewOutputReceipt.capture(before: saved.content, after: saved.content, at: file))
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("retired-result"))
        try Data("saved\n".utf8).write(to: file)
        XCTAssertThrowsError(try receipt.validate(), "An identical-byte replacement must not inherit the prior saved file identity")
        let replacement = try MergeToolOutputTarget(capturing: file)
        let deleted = try replacement.save(text: "", options: .init(emptyResult: .delete))
        XCTAssertNil(try MergeNewOutputReceipt.capture(before: before.content, after: deleted.content, at: file))
        XCTAssertEqual(saved.content.bytes, Data("saved\n".utf8), "Add failure cannot invalidate the successful Save receipt")
    }
    func testAutoAddStagesOnlyLiteralNewResultPreservesPeerIndexAndRejectsOutsideRoot() async throws {
        let (root, repository, tracked) = try await GitPatchTests().fixture()
        let outside = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try Data("peer staged\n".utf8).write(to: root.appendingPathComponent(tracked)); try await repository.stage([tracked])
        let peerBefore = try await repository.run(["ls-files", "--stage", "-z", "--", tracked]).stdout
        let path = "new 雪/:(glob)*\tresult\n.txt", file = root.appendingPathComponent("new 雪/:(glob)*\tresult\n.txt")
        let missing = try MergeToolOutputTarget(capturing: file), saved = try missing.save(text: "new output\n")
        let receipt = try XCTUnwrap(MergeNewOutputReceipt.capture(before: missing.content, after: saved.content, at: file))
        let untracked = try await repository.run(["ls-files", "--stage", "-z", "--", path]).stdout
        XCTAssertTrue(untracked.isEmpty, "A disk save alone must not stage; native policy owns configured AutoAdd admission")
        try await repository.addNewMergeOutput(receipt)
        let staged = try await repository.run(["show", ":" + path]).stdout
        XCTAssertEqual(staged, saved.content.bytes)
        let peerAfter = try await repository.run(["ls-files", "--stage", "-z", "--", tracked]).stdout
        XCTAssertEqual(peerAfter, peerBefore)
        let other = outside.appendingPathComponent("result"), absentOther = try MergeToolOutputTarget(capturing: outside.appendingPathComponent("result"))
        let writtenOther = try absentOther.save(text: "outside")
        let outsideReceipt = try XCTUnwrap(MergeNewOutputReceipt.capture(before: absentOther.content, after: writtenOther.content, at: other))
        do { try await repository.addNewMergeOutput(outsideReceipt); XCTFail("Outside-root Add admitted") } catch FileComparisonEditFailure.unsupported {}
        XCTAssertEqual(try Data(contentsOf: other), Data("outside".utf8))
    }
    func testFailedAndCancelledAddRetainsSavedBytesAndAllowsExplicitRetryOnlyWhileExact() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("new-result"), before = try MergeToolOutputTarget(capturing: root.appendingPathComponent("new-result"))
        let saved = try before.save(text: "durable\n")
        let receipt = try XCTUnwrap(MergeNewOutputReceipt.capture(before: before.content, after: saved.content, at: file))
        let lock = root.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        do { try await repository.addNewMergeOutput(receipt); XCTFail("Locked index Add succeeded") } catch {}
        try saved.validate(); try receipt.validate()
        XCTAssertEqual(try Data(contentsOf: file), saved.content.bytes)
        try FileManager.default.removeItem(at: lock)
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { try await repository.addNewMergeOutput(receipt, cancellation: cancelled); XCTFail("Cancelled Add succeeded") } catch OperationCancellationFailure.cancelled {}
        try saved.validate()
        try await repository.addNewMergeOutput(receipt)
        let staged = try await repository.run(["show", ":new-result"]).stdout
        XCTAssertEqual(staged, saved.content.bytes)
        try Data("external edit\n".utf8).write(to: file)
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        do { try await repository.addNewMergeOutput(receipt); XCTFail("Changed output admitted for Add retry") } catch FileComparisonEditFailure.changed {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), indexBefore)
    }
    func testPendingNewIntentRefreshesAfterOrdinaryResaveAndDoesNotReplaceRacedIndexContent() async throws {
        let (root, repository, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("pending-result"), before = try MergeToolOutputTarget(capturing: root.appendingPathComponent("pending-result"))
        let first = try before.save(text: "first\n")
        let original = try XCTUnwrap(MergeNewOutputReceipt.capture(before: before.content, after: first.content, at: file))
        let second = try first.save(text: "revised\n")
        let refreshed = try XCTUnwrap(original.refreshingSavedOutput(second.content))
        XCTAssertThrowsError(try original.validate())
        try refreshed.validate()
        // A peer stages different target content after the original absence.
        try Data("peer staged\n".utf8).write(to: file); try await repository.stage(["pending-result"])
        try second.content.bytes.write(to: file)
        // Re-capture the accepted disk save for this exact file identity.
        let accepted = try XCTUnwrap(refreshed.refreshingSavedOutput(second.content))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        do { try await repository.addNewMergeOutput(accepted); XCTFail("Different staged content was overwritten") } catch MergeNewOutputFailure.indexChanged {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: file), second.content.bytes)
        try await repository.unstage(["pending-result"])
        try await repository.addNewMergeOutput(accepted)
        let published = try await repository.run(["show", ":pending-result"]).stdout
        XCTAssertEqual(published, second.content.bytes)
        let exactIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try await repository.addNewMergeOutput(accepted)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), exactIndex, "An exact already-staged result is an index no-op")
        let deleted = try second.save(text: "", options: .init(emptyResult: .delete))
        XCTAssertNil(try accepted.refreshingSavedOutput(deleted.content))
    }

}
