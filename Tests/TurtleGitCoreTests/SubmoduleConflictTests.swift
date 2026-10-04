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
}
