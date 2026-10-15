import XCTest
@testable import TurtleGitCore

final class ConflictTitlesTests: XCTestCase {
    func testMergeGuessPriorityTagsAndDisabledGuessPreserveSnapshots() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = try await repo.run(["rev-parse", "MERGE_HEAD"]).text.trimmingCharacters(in: .newlines)
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/first", incoming])
        _ = try await repo.run(["tag", "-a", "label", "-m", "tag", incoming])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), working = try Data(contentsOf: root.appendingPathComponent(path))
        let names = try await repo.conflictTitles()
        XCTAssertFalse(names.rebase); XCTAssertEqual(names.mine.title, "HEAD"); XCTAssertEqual(names.mine.commit, head)
        XCTAssertEqual(names.theirs.title, "MERGE_HEAD (side, " + incoming.prefix(8) + ")"); XCTAssertEqual(names.theirs.commit, incoming)
        _ = try await repo.run(["update-ref", "-d", "refs/heads/side"])
        let remote = try await repo.conflictTitles()
        XCTAssertEqual(remote.theirs.title, "MERGE_HEAD (origin/first, " + incoming.prefix(8) + ")")
        _ = try await repo.run(["update-ref", "-d", "refs/remotes/origin/first"])
        let tag = try await repo.conflictTitles()
        XCTAssertEqual(tag.theirs.title, "MERGE_HEAD (label, " + incoming.prefix(8) + ")")
        let disabled = try await repo.conflictTitles(options: .init(guessBranchNames: false))
        XCTAssertEqual(disabled.theirs.title, "MERGE_HEAD (" + incoming.prefix(8) + ")")
        XCTAssertEqual(disabled.theirs.commit, incoming)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), working)
    }
    func testCherryPickAndRevertNeverGuessAndUseEightDigitIdentity() async throws {
        let (root, repo, _) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = try await repo.run(["rev-parse", "MERGE_HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", "other.txt"])
        _ = try await repo.run(["merge", "--abort"])
        _ = try await repo.run(["config", "core.abbrev", "12"])
        for name in ["CHERRY_PICK_HEAD", "REVERT_HEAD"] {
            _ = try await repo.run(["update-ref", name, incoming])
            let value = try await repo.conflictTitles()
            XCTAssertEqual(value.stage3.commit, incoming)
            XCTAssertEqual(value.stage3.title, name == "REVERT_HEAD" ? "Parent of " + incoming.prefix(8) : name + " (" + incoming.prefix(8) + ")")
            _ = try await repo.run(["update-ref", "-d", name])
        }
        let idle = try await repo.conflictTitles()
        XCTAssertEqual(idle.theirs.title, "changes to-be-integrated"); XCTAssertNil(idle.theirs.commit)
    }
    func testRebaseMetadataAndEverySourceMappingUseOriginalStages() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", "other.txt"])
        _ = try await repo.run(["merge", "--abort"])
        do { _ = try await repo.run(["rebase", "side"]); XCTFail("Expected replay conflict") } catch is GitFailure {}
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), working = try Data(contentsOf: root.appendingPathComponent(path))
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let replay = try await repo.run(["rev-parse", "REBASE_HEAD"]).text.trimmingCharacters(in: .newlines)
        let titles = try await repo.conflictTitles()
        XCTAssertTrue(titles.rebase); XCTAssertEqual(titles.mine.title, "main"); XCTAssertEqual(titles.mine.commit, replay)
        XCTAssertEqual(titles.theirs.title, "side, " + head.prefix(8)); XCTAssertEqual(titles.theirs.commit, head)
        let disabled = try await repo.conflictTitles(options: .init(guessBranchNames: false))
        XCTAssertEqual(disabled.mine.title, "main"); XCTAssertEqual(disabled.theirs.title, "Branch being rebased onto")
        let text = try await repo.textConflictDocument(path: path), external = try await repo.externalMergeInputs(path: path)
        XCTAssertEqual(text.conflictTitles, titles); XCTAssertEqual(external.conflictTitles, titles)
        XCTAssertEqual(text.mineStage, 3); XCTAssertEqual(text.theirsStage, 2)
        XCTAssertEqual(external.mine, Data(text.mine.utf8)); XCTAssertEqual(external.theirs, Data(text.theirs.utf8))
        let saved = try await repo.saveTextConflict(text, result: "resolved\n", markResolved: false)
        XCTAssertEqual(saved.conflictTitles, titles)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        // Only the explicit Save writes working contents; title/preview reads do not.
        XCTAssertNotEqual(try Data(contentsOf: root.appendingPathComponent(path)), working)
        _ = try await repo.run(["rebase", "--abort"])
    }
    func testKnownRebaseNamesSurviveDisabledGuessAndMissingMetadataFallsBack() async throws {
        let (root, repo) = try await CommitSelectionTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".git/tgitrebase.active")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("release/target\n".utf8).write(to: directory.appendingPathComponent("onto"))
        try Data("refs/heads/feature/雪\n".utf8).write(to: directory.appendingPathComponent("head-name"))
        let known = try await repo.conflictTitles(rebase: true, options: .init(guessBranchNames: false))
        XCTAssertEqual(known.stage2.title, "release/target"); XCTAssertEqual(known.stage3.title, "feature/雪")
        XCTAssertNil(known.stage2.commit); XCTAssertNil(known.stage3.commit)
        try FileManager.default.removeItem(at: directory)
        let missing = try await repo.conflictTitles(rebase: true)
        XCTAssertEqual(missing.stage2.title, "Branch being rebased onto"); XCTAssertEqual(missing.stage3.title, "Branch being rebased")
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.conflictTitles(cancellation: token); XCTFail("Canceled identity read accepted") } catch is OperationCancellationFailure {}
    }
    func testDeleteAndSubmoduleShareIdentitiesAndPreferenceWithoutChangingLogPointers() async throws {
        let (root, repo, path) = try await ConflictResolutionTests().fixture(deletedMine: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let titles = try await repo.conflictTitles(), details = try await repo.deleteConflictDetails(path: path)
        XCTAssertEqual(details.first.reference, titles.mine.title); XCTAssertEqual(details.second.reference, titles.theirs.title)
        XCTAssertEqual(details.first.commit, titles.mine.commit); XCTAssertEqual(details.second.commit, titles.theirs.commit)
        let (parent, source, parentRepo, _, childPath) = try await ConflictResolutionTests().submoduleFixture(initialized: true)
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: source) }
        let shared = try await parentRepo.conflictTitles(), module = try await parentRepo.submoduleConflictDetails(path: childPath)
        XCTAssertEqual(module.mine.title, shared.mine.title); XCTAssertEqual(module.theirs.title, shared.theirs.title)
        let plain = try await parentRepo.conflictTitles(options: .init(guessBranchNames: false))
        let unguessed = try await parentRepo.submoduleConflictDetails(path: childPath, identityOptions: .init(guessBranchNames: false))
        XCTAssertEqual(unguessed.theirs.title, plain.theirs.title)
        XCTAssertEqual(module.mine.revision, unguessed.mine.revision); XCTAssertEqual(module.theirs.revision, unguessed.theirs.revision)
    }
    func testImageIdentitySurvivesSelectionAndRebaseSwap() async throws {
        let (root, repo, bytes) = try await ImageConflictTests().fixture(rebase: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = try await repo.imageConflictDocument(path: "picture.dat")
        let image = try XCTUnwrap(captured), titles = try await repo.conflictTitles()
        XCTAssertEqual(image.conflictTitles, titles); XCTAssertEqual(image.mineStage, 3); XCTAssertEqual(image.theirsStage, 2)
        XCTAssertEqual(image.contents[.mine], bytes[1]); XCTAssertEqual(image.contents[.theirs], bytes[2])
        let saved = try await repo.selectImageConflict(image, side: .mine)
        XCTAssertEqual(saved.conflictTitles, titles)
    }
}
