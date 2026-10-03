import XCTest
@testable import TurtleGitCore

final class GitRepositoryTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let repo = GitRepository(root: url)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Port Tests"])
        _ = try await repo.run(["config", "user.email", "port@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        return (url, repo)
    }
    private func write(_ text: String, path: String, root: URL) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }
    func testPorcelainRenameAndConflictParsing() {
        let entries = StatusEntry.parse(Data("R  destination name\0original name\0UU conflict\0?? space\n雪.txt\0!! ignored\0".utf8))
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].path, "destination name")
        XCTAssertEqual(entries[0].originalPath, "original name")
        XCTAssertTrue(entries[0].staged)
        XCTAssertEqual(entries[1].state, .conflicted)
        XCTAssertEqual(entries[2].path, "space\n雪.txt")
        XCTAssertEqual(entries[3].state, .ignored)
    }
    func testStageCommitLogAndDiff() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = "file with spaces 雪\n.txt"
        try write("before\n", path: path, root: root)
        var status = try await repo.status()
        XCTAssertEqual(status.first?.state, .untracked)
        try await repo.stage([path])
        status = try await repo.status()
        XCTAssertTrue(status[0].staged)
        _ = try await repo.commit(message: "Initial commit\n\nBody")
        let history = try await repo.log()
        XCTAssertEqual(history.first?.subject, "Initial commit")
        XCTAssertEqual(history.first?.author, "Port Tests")
        try write("after\n", path: path, root: root)
        let diff = try await repo.diff(path: path)
        XCTAssertTrue(diff.contains("+after"))
        try await repo.stage([path]); try await repo.unstage([path])
        status = try await repo.status()
        XCTAssertFalse(status[0].staged)
        XCTAssertEqual(status[0].state, .modified)
    }
    func testUnstageOnUnbornBranchKeepsFile() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("contents", path: "new.txt", root: root)
        try await repo.stage(["new.txt"]); try await repo.unstage(["new.txt"])
        let status = try await repo.status()
        XCTAssertEqual(status.first?.state, .untracked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
    }
    func testLiteralPathspecDoesNotStageOtherFiles() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("literal", path: "*.txt", root: root)
        try write("other", path: "other.txt", root: root)
        try await repo.stage(["*.txt"])
        let status = try await repo.status()
        XCTAssertTrue(status.first { $0.path == "*.txt" }!.staged)
        XCTAssertFalse(status.first { $0.path == "other.txt" }!.staged)
    }
    func testWorktreeAndIgnoredPaths() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("secret\n", path: ".gitignore", root: root)
        try write("ignored", path: "secret", root: root)
        try await repo.stage([".gitignore"]); _ = try await repo.commit(message: "Ignore")
        let status = try await repo.status()
        XCTAssertEqual(status.first { $0.path == "secret" }?.state, .ignored)
        let linked = root.appendingPathComponent("linked worktree", isDirectory: true)
        _ = try await repo.run(["worktree", "add", "-b", "linked", linked.path])
        let linkedRepo = GitRepository(root: linked)
        let resolved = try await linkedRepo.discoverRoot()
        XCTAssertEqual(resolved.resolvingSymlinksInPath(), linked.resolvingSymlinksInPath())
    }
    func testLargeOutputAndFailure() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write(String(repeating: "large output\n", count: 20000), path: "large.txt", root: root)
        try await repo.stage(["large.txt"])
        let diff = try await repo.diff(staged: true)
        XCTAssertGreaterThan(diff.utf8.count, 200000)
        do { _ = try await repo.run(["rev-parse", "--verify", "does-not-exist"]); XCTFail("Expected failure") }
        catch let failure as GitFailure { XCTAssertNotEqual(failure.code, 0); XCTAssertFalse(failure.message.isEmpty) }
    }
    func testUnbornLogIsEmptyButInvalidRepositoryFails() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try await repo.log()
        XCTAssertTrue(log.isEmpty)
        // Use a sibling directory outside the fixture repository.
        let sibling = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        do { _ = try await GitRepository(root: sibling).log(); XCTFail("Expected repository error") }
        catch let failure as GitFailure { XCTAssertNotEqual(failure.code, 1) }
    }
    func testBlankCommitRejected() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repo.commit(message: " \n"); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("message")) }
    }
    func testBadgeAggregationAndRootBoundary() {
        let root = URL(fileURLWithPath: "/repositories/demo")
        let changes = StatusEntry.parse(Data(" M folder/a.txt\0UU folder/b.txt\0?? c.txt\0".utf8))
        let snapshot = FinderSnapshot.build(root: root, tracked: ["clean.txt", "folder/a.txt", "folder/b.txt"], changes: changes)
        XCTAssertEqual(snapshot.states[root.appendingPathComponent("clean.txt").path], .normal)
        XCTAssertEqual(snapshot.states[root.appendingPathComponent("folder").path], .conflicted)
        XCTAssertEqual(snapshot.states[root.path], .conflicted)
        XCTAssertNil(snapshot.states["/repositories"])
    }
    func testArgumentBuildersAgainstGit() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try write("hello", path: "a", root: root); try await repo.stage(["a"]); _ = try await repo.commit(message: "Initial")
        for action in [RepositoryAction.branch, .tag] { _ = try await repo.run(action.arguments(value: "example")!) }
        _ = try await repo.run(RepositoryAction.switchBranch.arguments(value: "example")!)
        let branch = try await repo.branch()
        XCTAssertEqual(branch, "example")
        _ = try await repo.run(RepositoryAction.merge.arguments(value: "main")!)
        _ = try await repo.run(RepositoryAction.rebase.arguments(value: "main")!)
    }
}
