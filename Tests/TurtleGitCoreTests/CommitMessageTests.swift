import XCTest
@testable import TurtleGitCore

final class CommitMessageTests: XCTestCase {
    func testTemplateAndOperationMessagesAppendWithoutChangingRepository() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "template 雪.txt", "Subject\r\n\r\nBody\r\n\r\n")
        _ = try await repo.run(["config", "commit.template", "template 雪.txt"])
        try helper.write(root, ".git/SQUASH_MSG", "Squash\r\n")
        try helper.write(root, ".git/MERGE_MSG", "Merge\n\n")
        try helper.write(root, "tracked.txt", "staged\n"); try await repo.stage(["tracked.txt"])
        try helper.write(root, "tracked.txt", "working\n")
        let before = try await repo.status(), index = try await repo.diff(staged: true), working = try await repo.diff()
        let seed = try await repo.commitMessageSeed()
        XCTAssertEqual(seed.template, "Subject\n\nBody\n")
        XCTAssertEqual(seed.message, "Subject\n\nBody\nSquash\nMerge\n")
        XCTAssertTrue(seed.warnings.isEmpty)
        let recommit = try await repo.commitMessageSeed(includeOperationMessages: false)
        XCTAssertEqual(recommit.message, seed.template)
        let after = try await repo.status(), afterIndex = try await repo.diff(staged: true), afterWorking = try await repo.diff()
        XCTAssertEqual(before.map(\.path), after.map(\.path)); XCTAssertEqual(index, afterIndex); XCTAssertEqual(working, afterWorking)
    }

    func testAbsentAndUnreadableTemplateKeepOperationMessageAvailable() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = try await repo.commitMessageSeed()
        XCTAssertEqual(absent.message, ""); XCTAssertEqual(absent.template, ""); XCTAssertTrue(absent.warnings.isEmpty)
        _ = try await repo.run(["config", "commit.template", "missing.txt"])
        try helper.write(root, ".git/MERGE_MSG", "Merge draft\n")
        let missing = try await repo.commitMessageSeed()
        XCTAssertEqual(missing.template, ""); XCTAssertEqual(missing.message, "Merge draft\n")
        XCTAssertEqual(missing.warnings.count, 1); XCTAssertTrue(missing.warnings[0].contains("missing.txt"))
        try Data([0xFF, 0xFE, 0xFF]).write(to: root.appendingPathComponent("invalid.txt"))
        _ = try await repo.run(["config", "commit.template", "invalid.txt"])
        let invalid = try await repo.commitMessageSeed()
        XCTAssertEqual(invalid.message, "Merge draft\n"); XCTAssertTrue(invalid.warnings[0].contains("UTF-8"))
    }

    func testLinkedWorktreeReadsOwnMessagesAndAbsoluteTemplate() async throws {
        let helper = CommitSelectionTests(), (root, repo) = try await helper.fixture()
        let worktree = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: worktree); try? FileManager.default.removeItem(at: root) }
        try helper.write(root, "base.txt", "base\n"); try await repo.stage(["base.txt"]); _ = try await repo.commit(message: "base")
        let template = root.appendingPathComponent("template\n雪.txt")
        try Data("\u{FEFF}Template\n".utf8).write(to: template)
        _ = try await repo.run(["config", "commit.template", template.path])
        try helper.write(root, ".git/MERGE_MSG", "Main tree message\n")
        _ = try await repo.run(["worktree", "add", "-b", "linked", worktree.path])
        let linked = GitRepository(root: worktree)
        let admin = try await linked.run(["rev-parse", "--path-format=absolute", "--git-path", "MERGE_MSG"]).text
        try Data("Linked tree message\n".utf8).write(to: URL(fileURLWithPath: String(admin.dropLast())))
        let seed = try await linked.commitMessageSeed()
        XCTAssertEqual(seed.message, "Template\nLinked tree message\n"); XCTAssertTrue(seed.warnings.isEmpty)
        let mainSeed = try await repo.commitMessageSeed()
        XCTAssertEqual(mainSeed.message, "Template\nMain tree message\n")
    }
}
