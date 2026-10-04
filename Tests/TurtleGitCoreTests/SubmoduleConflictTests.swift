import XCTest
@testable import TurtleGitCore

final class SubmoduleConflictTests: XCTestCase {
    func testInitializedBaseUsesCheckoutHeadAndPreservesCapturedStages() async throws {
        let (root, source, repo, optionalChild, path) = try await ConflictResolutionTests().submoduleFixture(initialized: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let child = try XCTUnwrap(optionalChild), before = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let details = try await repo.submoduleConflictDetails(path: path)
        let head = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(details.base.revision, head); XCTAssertEqual(details.base.subject, "mine")
        XCTAssertNotEqual(details.entry.stages.first { $0.number == 1 }?.object, head)
        XCTAssertEqual(details.mine.change, .identical); XCTAssertEqual(details.mine.subject, "mine")
        XCTAssertEqual(details.theirs.subject, "theirs"); XCTAssertTrue(details.theirs.canShowLog)
        XCTAssertEqual(details.mine.choice, .mine); XCTAssertEqual(details.theirs.choice, .theirs)
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout; XCTAssertEqual(before, after)
        _ = try await child.run(["checkout", "--detach", details.entry.stages.first { $0.number == 1 }!.object])
        let forward = try await repo.submoduleConflictDetails(path: path)
        XCTAssertEqual(forward.mine.change, .fastForward); XCTAssertEqual(forward.theirs.change, .fastForward)
        // Child checkout advances independently: index stages remain unchanged.
        try Data("next\n".utf8).write(to: child.root.appendingPathComponent("file.txt")); try await child.stage(["file.txt"])
        _ = try await child.run(["-c", "user.name=QA", "-c", "user.email=qa@example.test", "commit", "-m", "next"])
        // Choose a direct ancestor as Mine by checking out its descendant.
        _ = try await child.run(["checkout", "--detach", details.mine.revision!])
        try Data("descendant\n".utf8).write(to: child.root.appendingPathComponent("file.txt")); try await child.stage(["file.txt"])
        _ = try await child.run(["-c", "user.name=QA", "-c", "user.email=qa@example.test", "commit", "-m", "descendant"])
        let rewind = try await repo.submoduleConflictDetails(path: path); XCTAssertEqual(rewind.mine.change, .rewind)
    }
    func testUninitializedChooserDisablesHistoryButCanResolveExactSide() async throws {
        let (root, source, repo, _, path) = try await ConflictResolutionTests().submoduleFixture(initialized: false)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let details = try await repo.submoduleConflictDetails(path: path), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertNil(details.checkout); XCTAssertEqual(details.base.subject, "not initialized")
        for side in [details.base, details.mine, details.theirs] { XCTAssertFalse(side.canShowLog); XCTAssertFalse(side.available) }
        _ = try await repo.resolveConflicts([details.entry], using: try XCTUnwrap(details.theirs.choice))
        let indexed = try await repo.run(["ls-files", "--stage", "-z", "--", path]).text
        XCTAssertEqual(indexed, "160000 " + details.theirs.revision! + " 0\t" + path + "\0")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(head, after)
        do { _ = try await repo.submoduleConflictDetails(path: path); XCTFail("Accepted resolved entry") } catch ResolveFailure.stale {}
    }
    func testRebaseSwapsDisplayedSidesWithoutChangingStageChoices() async throws {
        let (root, source, repo, _, path) = try await ConflictResolutionTests().submoduleFixture(initialized: false)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        _ = try await repo.run(["merge", "--abort"])
        do { _ = try await repo.run(["rebase", "side"]); XCTFail("Expected conflict") } catch is GitFailure {}
        let details = try await repo.submoduleConflictDetails(path: path)
        XCTAssertEqual(details.mine.stage, 3); XCTAssertEqual(details.mine.choice, .theirs)
        XCTAssertEqual(details.theirs.stage, 2); XCTAssertEqual(details.theirs.choice, .mine)
        XCTAssertEqual(details.mine.revision, details.entry.stages.first { $0.number == 3 }?.object)
        _ = try await repo.resolveConflicts([details.entry], using: try XCTUnwrap(details.mine.choice))
        let indexed = try await repo.run(["ls-files", "--stage", "-z", "--", path]).text
        XCTAssertEqual(indexed, "160000 " + details.mine.revision! + " 0\t" + path + "\0")
        _ = try await repo.run(["rebase", "--abort"])
    }
    func testOrdinaryConflictCannotOpenSubmoduleChooser() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repo.submoduleConflictDetails(path: path); XCTFail("Accepted regular file") } catch SubmoduleConflictFailure.unsupported {}
    }
    func deletionFixture() async throws -> (URL, URL, GitRepository, String) {
        let (root, source, repo, _, path) = try await ConflictResolutionTests().submoduleFixture(initialized: true)
        _ = try await repo.run(["merge", "--abort"])
        let base = try await repo.run(["rev-parse", "HEAD^"]).text.trimmingCharacters(in: .newlines)
        let mine = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["switch", "-c", "deleted", base])
        _ = try await repo.run(["update-index", "--force-remove", "--", path]); _ = try await repo.commit(message: "delete module")
        let deleted = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["switch", "main"])
        _ = try await repo.run(["read-tree", "-m", base, mine, deleted])
        return (root, source, repo, path)
    }
    func testDeletionAbortPreservesUnregisteredCheckoutAndIndex() async throws {
        let (root, source, repo, path) = try await deletionFixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let details = try await repo.submoduleConflictDetails(path: path)
        XCTAssertEqual(details.theirs.change, .deleteSubmodule); XCTAssertFalse(details.theirs.canShowLog)
        let index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let file = root.appendingPathComponent(path).appendingPathComponent("file.txt"), contents = try Data(contentsOf: file)
        do {
            _ = try await repo.resolveConflicts([details.entry], using: .theirs, confirmSubmoduleDeletion: { request in
                XCTAssertEqual(request.path, path); XCTAssertEqual(request.location, root.appendingPathComponent(path))
                XCTAssertFalse(request.gitError.isEmpty); return false
            }); XCTFail("Ignored Abort")
        } catch ResolveFailure.cancelled {}
        let after = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(index, after); XCTAssertEqual(contents, try Data(contentsOf: file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).appendingPathComponent(".git").path))
    }
    func testDeletionRevalidatesStagesAfterConfirmationSuspendsActor() async throws {
        let (root, source, repo, path) = try await deletionFixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let entries = try await repo.conflicts(), entry = try XCTUnwrap(entries.first)
        do {
            _ = try await repo.resolveConflicts([entry], using: .theirs, confirmSubmoduleDeletion: { _ in
                // An external action resolves to Mine while the question is open.
                _ = try? await repo.resolveConflicts([entry], using: .mine)
                return true
            }); XCTFail("Deleted after stale confirmation")
        } catch ResolveFailure.stale {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).appendingPathComponent("file.txt").path))
        let remaining = try await repo.conflicts(); XCTAssertTrue(remaining.isEmpty)
    }
    func testFileToUninitializedGitlinkCreatesDirectoryAndPreservesOtherChanges() async throws {
        let (root, source, repo, _, path) = try await ConflictResolutionTests().submoduleFixture(initialized: false)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        _ = try await repo.run(["merge", "--abort"])
        let base = try await repo.run(["rev-parse", "HEAD^"]).text.trimmingCharacters(in: .newlines)
        let theirs = try await repo.run(["rev-parse", "side"]).text.trimmingCharacters(in: .newlines)
        let blobPath = "blob.txt"; try Data("regular file\n".utf8).write(to: root.appendingPathComponent(blobPath))
        let blob = try await repo.run(["hash-object", "-w", "--", blobPath]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-index", "--cacheinfo", "100644," + blob + "," + path]); _ = try await repo.commit(message: "replace with file")
        let mine = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path)); try Data("regular file\n".utf8).write(to: root.appendingPathComponent(path))
        _ = try await repo.run(["update-index", "--refresh"])
        _ = try await repo.run(["read-tree", "-m", base, mine, theirs])
        try Data("working file\n".utf8).write(to: root.appendingPathComponent(path))
        let entries = try await repo.conflicts(), entry = try XCTUnwrap(entries.first)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        _ = try await repo.resolveConflicts([entry], using: .theirs)
        var directory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &directory)); XCTAssertTrue(directory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).appendingPathComponent(".git").path))
        let target = entry.stages.first { $0.number == 3 }!.object
        let indexed = try await repo.run(["ls-files", "--stage", "-z"]).text
        XCTAssertEqual(indexed, "160000 " + target + " 0\t" + path + "\0")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(head, after)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(blobPath)), "regular file\n")
    }

    func testDeletionMovesCompleteCheckoutToRecoverableTrashAndResolvesOnlyIndex() async throws {
        let (root, source, repo, path) = try await deletionFixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let entries = try await repo.conflicts(), entry = try XCTUnwrap(entries.first)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let location = root.appendingPathComponent(path), file = location.appendingPathComponent("file.txt")
        let contents = try Data(contentsOf: file)
        let output = try await repo.resolveConflicts([entry], using: .theirs, confirmSubmoduleDeletion: { _ in true })
        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix("Moved to Trash: ") })
        let trashed = URL(fileURLWithPath: String(line.dropFirst("Moved to Trash: ".count)))
        defer { try? FileManager.default.moveItem(at: trashed, to: location) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
        XCTAssertEqual(contents, try Data(contentsOf: trashed.appendingPathComponent("file.txt")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.appendingPathComponent(".git").path))
        let indexed = try await repo.run(["ls-files", "--stage", "-z"]).stdout, afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        XCTAssertTrue(indexed.isEmpty); XCTAssertEqual(head, afterHead); XCTAssertEqual(refs, afterRefs)
    }

    func testDivergentCommitTimeTypesUseCommitterTimeDeterministically() async throws {
        let (root, source, repo, optionalChild, path) = try await ConflictResolutionTests().submoduleFixture(initialized: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: source) }
        let child = try XCTUnwrap(optionalChild), details = try await repo.submoduleConflictDetails(path: path)
        let timestamp = try await child.run(["show", "-s", "--format=%ct", details.mine.revision!, "--"]).text.trimmingCharacters(in: .newlines)
        _ = try await child.run(["checkout", "--orphan", "unrelated"])
        _ = try await child.run(["-c", "user.name=QA", "-c", "user.email=qa@example.test", "commit", "-m", "unrelated"], environmentOverrides: ["GIT_AUTHOR_DATE": "@" + timestamp + " +0000", "GIT_COMMITTER_DATE": "@" + timestamp + " +0000"])
        let same = try await repo.submoduleConflictDetails(path: path); XCTAssertEqual(same.mine.change, .sameTime)
        for (delta, expected) in [(Int64(-100), SubmoduleChangeType.newerTime), (100, .olderTime)] {
            let date = "@" + String(try XCTUnwrap(Int64(timestamp)) + delta) + " +0000"
            _ = try await child.run(["-c", "user.name=QA", "-c", "user.email=qa@example.test", "commit", "--amend", "--no-edit"], environmentOverrides: ["GIT_COMMITTER_DATE": date])
            let next = try await repo.submoduleConflictDetails(path: path); XCTAssertEqual(next.mine.change, expected)
        }
        let after = try await repo.conflicts(); XCTAssertEqual(after, [details.entry])
    }

}
