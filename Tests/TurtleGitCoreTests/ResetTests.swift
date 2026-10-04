import XCTest
@testable import TurtleGitCore

final class ResetTests: XCTestCase {
    func fixture() async throws -> (URL, GitRepository, String, String) {
        let (root, repo) = try await CommitSelectionTests().fixture()
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["tag", "base-tag"])
        try Data("latest\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "latest")
        let latest = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("indexed\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"])
        try Data("working\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("keep.txt"))
        return (root, repo, base, latest)
    }
    func testResetModesHaveExactHeadIndexAndWorkingTreeEffects() async throws {
        for mode in ResetMode.allCases {
            let (root, repo, base, latest) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let plan = try await repo.prepareReset(to: "refs/tags/base-tag", mode: mode)
            XCTAssertEqual(plan.revision, base); XCTAssertEqual(plan.originalHead, latest)
            _ = try await repo.reset(plan)
            let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
            let index = try await repo.run(["show", ":file.txt"]).text
            let oldHead = try await repo.run(["rev-parse", "ORIG_HEAD"]).text.trimmingCharacters(in: .newlines)
            let branch = try await repo.branch(), tag = try await repo.run(["rev-parse", "base-tag"]).text.trimmingCharacters(in: .newlines)
            XCTAssertEqual(head, base); XCTAssertEqual(oldHead, latest); XCTAssertEqual(branch, "main"); XCTAssertEqual(tag, base)
            XCTAssertEqual(index, mode == .soft ? "indexed\n" : "base\n")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), mode == .hard ? "base\n" : "working\n")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("keep.txt")), "untracked\n")
        }
    }
    func testChangedHeadOrBranchAndInvalidRevisionRejectWithoutReset() async throws {
        let (root, repo, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let initialIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let blob = try await repo.run(["rev-parse", "HEAD:file.txt"]).text.trimmingCharacters(in: .newlines)
        for revision in ["", "--hard", "missing-revision", blob, "bad\0revision"] {
            do { _ = try await repo.prepareReset(to: revision, mode: .hard); XCTFail("Accepted invalid revision") } catch ResetFailure.invalidRevision {}
        }
        let plan = try await repo.prepareReset(to: "HEAD^", mode: .hard)
        _ = try await repo.run(["switch", "-c", "same-head"])
        let refs = try await repo.run(["show-ref"]).stdout
        do { _ = try await repo.reset(plan); XCTFail("Accepted changed branch") } catch ResetFailure.changedHead {}
        let afterRefs = try await repo.run(["show-ref"]).stdout, index = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        XCTAssertEqual(refs, afterRefs); XCTAssertEqual(index, initialIndex)
        let second = try await repo.prepareReset(to: "HEAD^", mode: .hard)
        _ = try await repo.commit(message: "new head from staged contents")
        let changedHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        do { _ = try await repo.reset(second); XCTFail("Accepted changed head") } catch ResetFailure.changedHead {}
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(head, changedHead); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "working\n")
    }
    func testBareRepositoryOnlyAllowsSoftAndDetachedResetDoesNotMoveBranch() async throws {
        let (root, repo, base, latest) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bareRoot = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bareRoot) }
        _ = try await repo.run(["clone", "--bare", "--", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot)
        for mode in [ResetMode.mixed, .hard] {
            do { _ = try await bare.prepareReset(to: base, mode: mode); XCTFail("Bare non-soft reset") } catch ResetFailure.workingTreeRequired {}
        }
        let plan = try await bare.prepareReset(to: base, mode: .soft); _ = try await bare.reset(plan)
        let bareHead = try await bare.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(bareHead, base)
        _ = try await repo.run(["restore", "--source=HEAD", "--staged", "--worktree", "--", "file.txt"])
        _ = try await repo.run(["checkout", "--detach", latest])
        let detached = try await repo.prepareReset(to: base, mode: .mixed); XCTAssertNil(detached.originalReference)
        _ = try await repo.reset(detached)
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines), main = try await repo.run(["rev-parse", "main"]).text.trimmingCharacters(in: .newlines)
        XCTAssertEqual(head, base); XCTAssertEqual(main, latest)
    }
}
