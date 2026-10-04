import XCTest
@testable import TurtleGitCore

final class DeleteConflictTests: XCTestCase {
    func testKeepUsesCurrentWorkingContentsWithBothDeletedSides() async throws {
        for deletedMine in [true, false] {
            let (root, repo, path) = try await ConflictResolutionTests().fixture(deletedMine: deletedMine, deletedTheirs: !deletedMine)
            defer { try? FileManager.default.removeItem(at: root) }
            let details = try await repo.deleteConflictDetails(path: path)
            XCTAssertEqual(details.first.status, deletedMine ? "Deleted" : "Modified")
            XCTAssertEqual(details.second.status, deletedMine ? "Modified" : "Deleted")
            XCTAssertEqual(details.keepTitle, "Modified"); XCTAssertTrue(details.canCompare)
            XCTAssertNotNil(details.first.commit); XCTAssertNotNil(details.second.commit)
            let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
            try Data("reviewed working contents\n".utf8).write(to: root.appendingPathComponent(path))
            let diff = try await repo.deleteConflictChanges(details.entry)
            XCTAssertTrue(diff.contains("-base")); XCTAssertTrue(diff.contains("+reviewed working contents"))
            _ = try await repo.resolveDeleteConflict(details.entry, deleting: false)
            let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
            let indexed = try await repo.run(["show", ":" + path]).text, other = try await repo.run(["show", ":other.txt"]).text
            XCTAssertEqual(head, afterHead); XCTAssertEqual(refs, afterRefs); XCTAssertEqual(indexed, "reviewed working contents\n")
            XCTAssertEqual(other, "other index\n"); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "other working\n")
            let remaining = try await repo.conflicts(); XCTAssertTrue(remaining.isEmpty)
            _ = try await repo.run(["rev-parse", "--verify", "MERGE_HEAD"])
        }
    }
    func testDeleteUsesOrdinaryGitRemovalAndKeepsUnrelatedChanges() async throws {
        for deletedMine in [true, false] {
            let (root, repo, path) = try await ConflictResolutionTests().fixture(deletedMine: deletedMine, deletedTheirs: !deletedMine)
            defer { try? FileManager.default.removeItem(at: root) }
            let details = try await repo.deleteConflictDetails(path: path), head = try await repo.run(["rev-parse", "HEAD"]).stdout
            _ = try await repo.resolveDeleteConflict(details.entry, deleting: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
            let tracked = try await repo.trackedPaths(), remaining = try await repo.conflicts(), after = try await repo.run(["rev-parse", "HEAD"]).stdout
            let other = try await repo.run(["show", ":other.txt"]).text
            XCTAssertFalse(tracked.contains(path)); XCTAssertTrue(remaining.isEmpty); XCTAssertEqual(head, after)
            XCTAssertEqual(other, "other index\n"); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "other working\n")
        }
    }
    func testStaleAndUnsupportedConflictsCannotBeMutatedByDeleteDialog() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture(deletedMine: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let details = try await repo.deleteConflictDetails(path: path)
        _ = try await repo.resolveDeleteConflict(details.entry, deleting: false)
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout, working = try Data(contentsOf: root.appendingPathComponent(path))
        do { _ = try await repo.resolveDeleteConflict(details.entry, deleting: true); XCTFail("Accepted stale conflict") } catch ResolveFailure.stale {}
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(index, after); XCTAssertEqual(working, try Data(contentsOf: root.appendingPathComponent(path)))
        let (textRoot, textRepo, textPath) = try await ConflictResolutionTests().fixture(); defer { try? FileManager.default.removeItem(at: textRoot) }
        do { _ = try await textRepo.deleteConflictDetails(path: textPath); XCTFail("Opened delete dialog for text merge") } catch DeleteConflictFailure.unsupported {}
        let textEntry = try await textRepo.conflicts()[0]
        do { _ = try await textRepo.resolveDeleteConflict(textEntry, deleting: true); XCTFail("Deleted text merge through wrong dialog") } catch DeleteConflictFailure.unsupported {}
    }
    func testRebaseDisplayOrderAndSideScopedHistory() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture(deletedMine: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let merge = try await repo.deleteConflictDetails(path: path), head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        var history = HistoryOptions(); history.endRevision = try XCTUnwrap(merge.second.commit); history.paths = [path]; history.allBranches = true
        let entries = try await repo.history(options: history)
        XCTAssertEqual(entries.first?.hash, merge.second.commit); XCTAssertFalse(entries.contains { $0.hash == head })
        history.endRevision = "--all"
        do { _ = try await repo.history(options: history); XCTFail("Accepted option as history revision") } catch is GitFailure {}
        _ = try await repo.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", "other.txt"])
        _ = try await repo.run(["merge", "--abort"])
        do { _ = try await repo.run(["rebase", "side"]); XCTFail("Expected rebase conflict") } catch is GitFailure {}
        let details = try await repo.deleteConflictDetails(path: path)
        XCTAssertEqual(details.first.stage, 3); XCTAssertEqual(details.first.status, "Deleted")
        XCTAssertEqual(details.first.reference, "Commit being replayed")
        XCTAssertEqual(details.second.stage, 2); XCTAssertEqual(details.second.status, "Modified")
        XCTAssertEqual(details.second.reference, "Branch being rebased onto")
        _ = try await repo.run(["rebase", "--abort"])
    }
    func testFileDirectoryConflictUsesCreatedChoiceWithoutBaseComparison() async throws {
        let (root, repo) = try await CommitSelectionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("seed\n".utf8).write(to: root.appendingPathComponent("seed.txt")); try await repo.stage(["seed.txt"]); _ = try await repo.commit(message: "seed")
        _ = try await repo.run(["switch", "-c", "side"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("new"), withIntermediateDirectories: true)
        try Data("inside directory\n".utf8).write(to: root.appendingPathComponent("new/file.txt")); try await repo.stage(["new/file.txt"]); _ = try await repo.commit(message: "new directory")
        _ = try await repo.run(["switch", "main"])
        try Data("new regular file\n".utf8).write(to: root.appendingPathComponent("new")); try await repo.stage(["new"]); _ = try await repo.commit(message: "new file")
        do { _ = try await repo.run(["merge", "side"]); XCTFail("Expected file-directory conflict") } catch is GitFailure {}
        let entries = try await repo.conflicts(), entry = try XCTUnwrap(entries.first { $0.isDeleteModify })
        let details = try await repo.deleteConflictDetails(path: entry.path)
        XCTAssertEqual(details.keepTitle, "Created"); XCTAssertFalse(details.canCompare)
        XCTAssertEqual(Set([details.first.status, details.second.status]), Set(["Created", "Deleted"]))
        do { _ = try await repo.deleteConflictChanges(entry); XCTFail("Compared absent base") } catch DeleteConflictFailure.unsupported {}
        _ = try await repo.resolveDeleteConflict(entry, deleting: false)
        let indexed = try await repo.run(["show", ":" + entry.path]).text
        XCTAssertEqual(indexed, "new regular file\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new/file.txt")), "inside directory\n")
    }

}
