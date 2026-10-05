import XCTest
@testable import TurtleGitCore

final class GitWorktreeTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitWorktrees-" + UUID().uuidString)
        let root = base.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Worktree Test"])
        _ = try await repo.run(["config", "user.email", "worktree@example.invalid"])
        try Data("original\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try await repo.stage(["file.txt"])
        _ = try await repo.commit(message: "Initial")
        return (base, repo)
    }

    func testHeadDefaultsToDirectoryBranchAndPreservesMainIndexAndFiles() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try Data("staged\n".utf8).write(to: repo.root.appendingPathComponent("file.txt"))
        try await repo.stage(["file.txt"])
        try Data("working\n".utf8).write(to: repo.root.appendingPathComponent("file.txt"))
        let before = try await repo.run(["rev-parse", "HEAD"]).text
        let path = base.appendingPathComponent("topic")
        _ = try await repo.createWorktree(at: path)
        let records = try await repo.worktrees()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records[0].isMain)
        XCTAssertEqual(records[1].branch, "refs/heads/topic")
        let after = try await repo.run(["rev-parse", "HEAD"]).text
        let index = try await repo.run(["show", ":file.txt"]).text
        XCTAssertEqual(before, after); XCTAssertEqual(index, "staged\n")
        XCTAssertEqual(try String(contentsOf: repo.root.appendingPathComponent("file.txt"), encoding: .utf8), "working\n")
        XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("file.txt"), encoding: .utf8), "original\n")
        let fromLinked = try await GitRepository(root: path).worktrees()
        XCTAssertEqual(records, fromLinked)
    }

    func testDetachedNoCheckoutAndNewBranchAtHistoricalRevision() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let initial = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("later\n".utf8).write(to: repo.root.appendingPathComponent("file.txt"))
        try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Later")
        var options = WorktreeCreationOptions(); options.detach = true; options.checkout = false
        let detached = base.appendingPathComponent("detached")
        _ = try await repo.createWorktree(at: detached, options: options)
        XCTAssertFalse(FileManager.default.fileExists(atPath: detached.appendingPathComponent("file.txt").path))
        var records = try await repo.worktrees()
        XCTAssertTrue(try XCTUnwrap(records.first(where: { $0.path.lastPathComponent == "detached" })).isDetached)
        options.detach = false; options.checkout = true; options.newBranch = "historical"; options.revision = initial
        let historical = base.appendingPathComponent("historical-files")
        _ = try await repo.createWorktree(at: historical, options: options)
        records = try await repo.worktrees()
        let record = try XCTUnwrap(records.first(where: { $0.path.lastPathComponent == "historical-files" }))
        XCTAssertEqual(record.head, initial); XCTAssertEqual(record.branch, "refs/heads/historical")
        XCTAssertEqual(try String(contentsOf: historical.appendingPathComponent("file.txt"), encoding: .utf8), "original\n")
    }

    func testNewlinePathsAndLockReasonsRoundTripAndLockedRemovalFails() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("turtle ü\n checkout")
        var options = WorktreeCreationOptions(); options.detach = true
        _ = try await repo.createWorktree(at: path, options: options)
        _ = try await repo.lockWorktree(at: path, reason: "Portable disk\nnot connected")
        var records = try await repo.worktrees()
        let record = try XCTUnwrap(records.first(where: { !$0.isMain }))
        XCTAssertEqual(record.path.path, path.standardizedFileURL.path)
        XCTAssertEqual(record.lockReason, "Portable disk\nnot connected")
        do { _ = try await repo.removeWorktree(at: path, force: true); XCTFail("A single Force must not override a lock") } catch is GitFailure {}
        _ = try await repo.unlockWorktree(at: path)
        records = try await repo.worktrees(); XCTAssertNil(records.last?.lockReason)
        _ = try await repo.removeWorktree(at: path)
        records = try await repo.worktrees(); XCTAssertEqual(records.count, 1)
    }

    func testDirtyRemovalRequiresForceAndMainAndUnregisteredPathsAreProtected() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("dirty")
        _ = try await repo.createWorktree(at: path)
        try Data("untracked".utf8).write(to: path.appendingPathComponent("new.txt"))
        do { _ = try await repo.removeWorktree(at: path); XCTFail("Dirty worktree requires Force") } catch is GitFailure {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("new.txt").path))
        for target in [repo.root, base] {
            do { _ = try await repo.removeWorktree(at: target, force: true); XCTFail("Not a linked checkout") } catch WorktreeFailure.notLinkedWorktree {}
            do { _ = try await repo.lockWorktree(at: target); XCTFail("Not a linked checkout") } catch WorktreeFailure.notLinkedWorktree {}
            do { _ = try await repo.unlockWorktree(at: target); XCTFail("Not a linked checkout") } catch WorktreeFailure.notLinkedWorktree {}
        }
        _ = try await repo.removeWorktree(at: path, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.path))
    }

    func testPruneProtectsLockedMissingWorktreesAndUnlockWorksForMissingPaths() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let locked = base.appendingPathComponent("locked"), missing = base.appendingPathComponent("missing")
        _ = try await repo.createWorktree(at: locked); _ = try await repo.createWorktree(at: missing)
        _ = try await repo.lockWorktree(at: locked)
        try FileManager.default.removeItem(at: locked); try FileManager.default.removeItem(at: missing)
        _ = try await repo.pruneWorktrees()
        var records = try await repo.worktrees(); XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.last?.lockReason, "")
        _ = try await repo.unlockWorktree(at: locked); _ = try await repo.pruneWorktrees()
        records = try await repo.worktrees(); XCTAssertEqual(records.count, 1)
    }

    func testForceNeverResetsExistingBranchAndInvalidOptionsDoNotCreateDirectories() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let path = base.appendingPathComponent("target")
        let before = try await repo.run(["rev-parse", "main"]).text
        var options = WorktreeCreationOptions(); options.force = true; options.newBranch = "main"
        do { _ = try await repo.createWorktree(at: path, options: options); XCTFail("Force is not -B") } catch is GitFailure {}
        options.newBranch = "--help"
        do { _ = try await repo.createWorktree(at: path, options: options); XCTFail("Invalid name") } catch WorktreeFailure.invalidBranch {}
        options.newBranch = "valid"; options.detach = true
        do { _ = try await repo.createWorktree(at: path, options: options); XCTFail("Contradictory options") } catch WorktreeFailure.conflictingOptions {}
        options.detach = false; options.revision = "--help"
        do { _ = try await repo.createWorktree(at: path, options: options); XCTFail("Invalid revision") } catch WorktreeFailure.invalidRevision {}
        let after = try await repo.run(["rev-parse", "main"]).text
        XCTAssertEqual(before, after); XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        // An explicit existing branch remains checked out elsewhere unless Force is enabled.
        options.newBranch = nil; options.revision = "main"; options.force = false
        do { _ = try await repo.createWorktree(at: path, options: options); XCTFail("Branch already checked out") } catch is GitFailure {}
        options.force = true; _ = try await repo.createWorktree(at: path, options: options)
        let branch = try await GitRepository(root: path).branch(); XCTAssertEqual(branch, "main")
    }

    func testBareMainAndUnknownPorcelainAttributes() {
        let records = GitWorktree.parse(Data("worktree /repo.git\0bare\0\0worktree /linked\0HEAD abc\0branch refs/heads/main\0future attribute\0prunable missing\0\0".utf8))
        XCTAssertEqual(records.count, 2); XCTAssertTrue(records[0].isMain); XCTAssertTrue(records[0].isBare)
        XCTAssertFalse(records[1].isMain); XCTAssertEqual(records[1].pruneReason, "missing")
    }

    func testBareRepositoryCanCreateAndManageLinkedCheckout() async throws {
        let (base, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let barePath = base.appendingPathComponent("source.git")
        _ = try await repo.run(["clone", "--bare", "--", repo.root.path, barePath.path])
        let bare = GitRepository(root: barePath), linked = base.appendingPathComponent("from-bare")
        _ = try await bare.createWorktree(at: linked)
        let records = try await bare.worktrees()
        XCTAssertEqual(records.count, 2); XCTAssertTrue(records[0].isMain); XCTAssertTrue(records[0].isBare)
        XCTAssertEqual(records[1].branch, "refs/heads/from-bare")
        _ = try await bare.lockWorktree(at: linked)
        _ = try await bare.unlockWorktree(at: linked)
        _ = try await bare.removeWorktree(at: linked)
        let remaining = try await bare.worktrees(); XCTAssertEqual(remaining.count, 1)
    }
}
