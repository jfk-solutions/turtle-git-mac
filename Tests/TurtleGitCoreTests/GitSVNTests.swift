import XCTest
@testable import TurtleGitCore

final class GitSVNTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, String, String) { try await GitSVNFixture.create() }
    func testFetchCapturedRangeAndFastForwardGuard() async throws {
        let (root, repo, old, next) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let fetch = try await repo.svnFetch()
        XCTAssertEqual(fetch.oldHash, old); XCTAssertEqual(fetch.newHash, next); XCTAssertEqual(fetch.range, old + ".." + next); XCTAssertTrue(fetch.changed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let plan = try await repo.svnRebasePlan(fetch); XCTAssertEqual(plan, .fastForward(next))
        try Data("local edit\n".utf8).write(to: root.appendingPathComponent("file"))
        do { _ = try await repo.svnFastForward(to: next, expectedHead: old); XCTFail("Dirty tree reset") } catch GitSVNFailure.changed { }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file"))
        _ = try await repo.svnFastForward(to: next, expectedHead: old)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")), Data("next\n".utf8))
        let complete = try await repo.svnRebasePlan(fetch); XCTAssertEqual(complete, .upToDate)
    }
    func testCommitTypeArgumentsIgnoreOverwriteAndFailurePreservation() async throws {
        let (root, repo, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await repo.svnCommitType(); XCTAssertNil(initial)
        try await repo.rememberSVNCommitType(removeEmptyDirectories: true)
        let remembered = try await repo.svnCommitType(); XCTAssertEqual(remembered, true)
        _ = try await repo.svnDCommit(removeEmptyDirectories: true)
        let log = try String(contentsOf: root.appendingPathComponent(".git/svn-qa-log")); XCTAssertTrue(log.contains("[\"svn\", \"dcommit\", \"--rmdir\"]"))
        let exclude = try await repo.svnIgnoreExcludeURL()
        try Data("original\n".utf8).write(to: exclude)
        _ = try await repo.svnImportIgnore(.exclude)
        XCTAssertEqual(try Data(contentsOf: exclude), Data("ignored*\n雪*\n".utf8))
        _ = try await repo.run(["config", "svn-test.fail", "true"])
        do { _ = try await repo.svnImportIgnore(.exclude); XCTFail("Failed import succeeded") } catch is GitFailure { }
        XCTAssertEqual(try Data(contentsOf: exclude), Data("ignored*\n雪*\n".utf8))
        _ = try await repo.svnImportIgnore(.gitignore)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".gitignore")), Data("created*\n".utf8))
    }
    func testStashOwnershipUntrackedAndInvalidRemote() async throws {
        let (root, repo, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("new"))
        let untrackedOnly = try await repo.svnTrackedChanges(); XCTAssertFalse(untrackedOnly)
        try Data("dirty\n".utf8).write(to: root.appendingPathComponent("file"))
        let dirty = try await repo.svnTrackedChanges(); XCTAssertTrue(dirty)
        let stash = try await repo.svnStash(); XCTAssertTrue(stash.created)
        let clean = try await repo.svnTrackedChanges(); XCTAssertFalse(clean)
        try Data("other dirty\n".utf8).write(to: root.appendingPathComponent("file")); _ = try await repo.svnStash()
        do { _ = try await repo.svnPopCreatedStash(try XCTUnwrap(stash.current)); XCTFail("Unrelated stash popped") } catch GitSVNFailure.stashChanged { }
        _ = try await repo.run(["config", "svn-remote.svn.fetch", "trunk:--option"])
        do { _ = try await repo.svnUpstream(); XCTFail("Invalid reference accepted") } catch GitSVNFailure.reference { }
    }
    func testMetadataMarkerBackwardsCompatibilityAndFinderConditions() async throws {
        let (root, repo, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try await repo.finderMetadata(); XCTAssertTrue(metadata.hasGitSVN)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any]); json.removeValue(forKey: "hasGitSVN")
        let legacy = try JSONDecoder().decode(FinderRepositoryMetadata.self, from: JSONSerialization.data(withJSONObject: json)); XCTAssertFalse(legacy.hasGitSVN)
        for action: RepositoryAction in [.svnDCommit, .svnRebase, .svnFetch, .svnIgnore] {
            XCTAssertTrue(metadata.allows(action)); XCTAssertFalse(legacy.allows(action)); XCTAssertTrue(action.requiresWorkingTree)
            XCTAssertTrue(FinderShellRules.allows(action, flags: [.folderInGit, .gitSVN, .onlyOne]))
        }
        XCTAssertFalse(FinderShellRules.allows(.svnRebase, flags: [.folderInGit, .gitSVN, .onlyOne, .merge]))
        XCTAssertTrue(FinderShellRules.allows(.svnFetch, flags: [.folderInGit, .gitSVN, .onlyOne, .merge]))
        XCTAssertEqual(FinderMenuEntry.allCases.filter(\.availableInFinder).count, 55)
    }
}
