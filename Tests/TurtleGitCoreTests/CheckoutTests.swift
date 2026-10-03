import XCTest
@testable import TurtleGitCore

final class CheckoutTests: XCTestCase {
    func testLocalSwitchRetainsIndexAndLaterWorktreeEdits() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "other"])
        try Data("staged\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("later edit\n".utf8).write(to: root.appendingPathComponent(path))
        var options = CheckoutOptions(); options.revision = "refs/heads/other"
        _ = try await repo.checkout(options)
        let branch = try await repo.branch(), index = try await repo.run(["show", ":" + path]).text
        XCTAssertEqual(branch, "other"); XCTAssertEqual(index, "staged\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "later edit\n")
    }
    func testAnnotatedTagAndCommitDetachAndCreateBranch() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["tag", "-a", "v1", "-m", "release"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        var options = CheckoutOptions(); options.target = .tag; options.revision = "refs/tags/v1"
        _ = try await repo.checkout(options)
        let detached = try await repo.branch(), actual = try await repo.run(["rev-parse", "HEAD"]).text
        XCTAssertEqual(detached, ""); XCTAssertEqual(actual, head)
        options.target = .commit; options.revision = head.trimmingCharacters(in: .newlines)
        options.createBranch = true; options.branchName = "from-commit"
        _ = try await repo.checkout(options)
        let branch = try await repo.branch(); XCTAssertEqual(branch, "from-commit")
    }
    func testRemoteTrackingAndHierarchicalNames() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["remote", "add", "origin", root.path])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/team/topic", "HEAD"])
        let refs = try await repo.checkoutReferences()
        XCTAssertEqual(refs.first { $0.name == "refs/remotes/origin/team/topic" }?.suggestedBranch, "team/topic")
        var options = CheckoutOptions(); options.revision = "refs/remotes/origin/team/topic"; options.createBranch = true
        for (name, tracking) in [("automatic", CheckoutTracking.automatic), ("explicit", .track), ("independent", .noTrack)] {
            options.branchName = name; options.tracking = tracking; _ = try await repo.checkout(options)
            let branch = try await repo.branch(); XCTAssertEqual(branch, name)
            if tracking == .noTrack {
                do { _ = try await repo.run(["config", "--get", "branch." + name + ".remote"]); XCTFail("No tracking requested") } catch {}
            } else {
                let remote = try await repo.run(["config", "--get", "branch." + name + ".remote"]).text
                let merge = try await repo.run(["config", "--get", "branch." + name + ".merge"]).text
                XCTAssertEqual(remote, "origin\n"); XCTAssertEqual(merge, "refs/heads/team/topic\n")
            }
        }
        options.createBranch = false; _ = try await repo.checkout(options)
        let detached = try await repo.branch(); XCTAssertEqual(detached, "")
    }
    func testExistingBranchAndTagConflictsDoNotMutateUntilEnabled() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "existing"])
        try Data("next\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "next")
        let before = try await repo.run(["rev-parse", "existing"]).text
        var options = CheckoutOptions(); options.revision = "refs/heads/main"; options.createBranch = true; options.branchName = "existing"
        do { _ = try await repo.checkout(options); XCTFail("Existing branch must fail") } catch CheckoutFailure.branchExists {}
        let after = try await repo.run(["rev-parse", "existing"]).text; XCTAssertEqual(before, after)
        options.overrideBranch = true; _ = try await repo.checkout(options)
        let replaced = try await repo.run(["rev-parse", "existing"]).text, head = try await repo.run(["rev-parse", "main"]).text
        XCTAssertEqual(replaced, head)
        _ = try await repo.run(["tag", "same-name"])
        options.overrideBranch = false; options.branchName = "same-name"
        do { _ = try await repo.checkout(options); XCTFail("Tag conflict must fail") } catch CheckoutFailure.tagNameConflict {}
        let unchanged = try await repo.branch(); XCTAssertEqual(unchanged, "existing")
        options.allowTagNameConflict = true; _ = try await repo.checkout(options)
        let created = try await repo.branch(); XCTAssertEqual(created, "same-name")
    }
    func testDirtyCheckoutRejectsAndForceExplicitlyReplacesChanges() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "old"])
        try Data("next\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "next")
        try Data("local\n".utf8).write(to: root.appendingPathComponent(path))
        var options = CheckoutOptions(); options.revision = "refs/heads/old"
        do { _ = try await repo.checkout(options); XCTFail("Dirty file would be overwritten") } catch {}
        let branch = try await repo.branch(); XCTAssertEqual(branch, "main")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "local\n")
        options.overwriteChanges = true; _ = try await repo.checkout(options)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).contains("line 1\n"))
    }
    func testMergeCarriesConflictingWorktreeChangesIntoConflictStages() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["branch", "old"])
        try Data("next\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "next")
        try Data("local\n".utf8).write(to: root.appendingPathComponent(path))
        var options = CheckoutOptions(); options.revision = "refs/heads/old"; options.merge = true
        _ = try await repo.checkout(options)
        let branch = try await repo.branch(), conflicts = try await repo.run(["ls-files", "--unmerged"]).text
        XCTAssertEqual(branch, "old"); XCTAssertFalse(conflicts.isEmpty)
        let contents = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        XCTAssertTrue(contents.contains("<<<<<<<")); XCTAssertTrue(contents.contains("local\n"))
    }
    func testInvalidNamesAndRevisionsPreserveRepository() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var options = CheckoutOptions(); options.target = .commit; options.revision = "--help"
        do { _ = try await repo.checkout(options); XCTFail("Option is not a revision") } catch CheckoutFailure.invalidRevision {}
        options.revision = "HEAD"; options.createBranch = true
        for name in ["--force", "@{-1}", "invalid..name", ""] {
            options.branchName = name
            do { _ = try await repo.checkout(options); XCTFail("Invalid name: " + name) } catch CheckoutFailure.invalidBranch {}
        }
        let branch = try await repo.branch(); XCTAssertEqual(branch, "main")
    }
}
