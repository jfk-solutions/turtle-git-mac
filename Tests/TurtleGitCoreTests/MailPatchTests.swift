import XCTest
@testable import TurtleGitCore

final class MailPatchTests: XCTestCase {
    func fixture(conflict: Bool = false) async throws -> (URL, GitRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TURTLEGIT_MAIL_TEST_GIT"] ?? "/usr/bin/git")
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Importer"]); _ = try await repo.run(["config", "user.email", "importer@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "feature"])
        try Data("feature\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        _ = try await repo.run(["-c", "user.name=Author 雪", "-c", "user.email=author@example.invalid", "commit", "--date=2020-01-02T03:04:05+00:00", "-m", "Feature subject\n\nFeature body"])
        let patch = root.appendingPathComponent("--mail 雪.patch")
        try await repo.run(["format-patch", "-1", "--stdout", "HEAD"]).stdout.write(to: patch)
        _ = try await repo.run(["switch", "main"])
        if conflict { try Data("ours\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "ours") }
        return (root, repo, patch)
    }
    func testImportPreservesAuthorDateMessageAndSignoff() async throws {
        let (root, repo, patch) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = MailPatchOptions(); options.signOff = true
        _ = try await repo.importMailPatch(patch, options: options)
        let metadata = try await repo.run(["show", "-s", "--format=%an%n%ae%n%aI%n%B", "HEAD"]).text
        let lines = metadata.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Author 雪"); XCTAssertEqual(lines[1], "author@example.invalid")
        XCTAssertEqual(ISO8601DateFormatter().date(from: lines[2]), ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z"))
        XCTAssertTrue(metadata.contains("Feature body")); XCTAssertTrue(metadata.contains("Signed-off-by: Importer <importer@example.invalid>"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")), Data("feature\n".utf8))
        let session = try await repo.mailPatchSession(); XCTAssertEqual(session, .none)
    }
    func testConflictRecoveryAbortSkipAndResolved() async throws {
        for action in MailPatchRecovery.allCases {
            let (root, repo, patch) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
            let before = try await repo.run(["rev-parse", "HEAD"]).stdout
            do { _ = try await repo.importMailPatch(patch); XCTFail("Expected conflict") } catch is GitFailure {}
            let active = try await repo.mailPatchSession(); XCTAssertEqual(active, .applying)
            do { _ = try await repo.importMailPatch(patch); XCTFail("Started a second import") } catch MailPatchFailure.activeSession {}
            if action == .resolved { try Data("resolved\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]) }
            _ = try await repo.recoverMailPatch(action)
            let session = try await repo.mailPatchSession(); XCTAssertEqual(session, .none)
            let after = try await repo.run(["rev-parse", "HEAD"]).stdout
            if action == .resolved { XCTAssertNotEqual(before, after); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")), Data("resolved\n".utf8)) }
            else { XCTAssertEqual(before, after); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")), Data("ours\n".utf8)) }
        }
    }
    func testRejectsInvalidFileNoSessionAndActiveRebaseWithoutMutation() async throws {
        let (root, repo, patch) = try await fixture(conflict: true); defer { try? FileManager.default.removeItem(at: root) }
        for file in [root, root.appendingPathComponent("missing")] {
            do { _ = try await repo.importMailPatch(file); XCTFail("Invalid file accepted") } catch MailPatchFailure.file {}
        }
        do { _ = try await repo.recoverMailPatch(.abort); XCTFail("No session accepted") } catch MailPatchFailure.noSession {}
        _ = try await repo.run(["switch", "feature"])
        do { _ = try await repo.run(["rebase", "--apply", "main"]); XCTFail("Expected rebase conflict") } catch is GitFailure {}
        let session = try await repo.mailPatchSession(); XCTAssertEqual(session, .rebase)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try await repo.run(["ls-files", "-s"]).stdout
        do { _ = try await repo.importMailPatch(patch); XCTFail("Imported during rebase") } catch MailPatchFailure.rebase {}
        do { _ = try await repo.recoverMailPatch(.abort); XCTFail("Aborted a rebase as am") } catch MailPatchFailure.rebase {}
        let nextHead = try await repo.run(["rev-parse", "HEAD"]).stdout, nextIndex = try await repo.run(["ls-files", "-s"]).stdout
        XCTAssertEqual(head, nextHead); XCTAssertEqual(index, nextIndex)
        _ = try await repo.run(["rebase", "--abort"])
    }
    func testLinkedWorktreeSessionIsSeparateAndAbortKeepsParentRepository() async throws {
        let (root, repo, patch) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let linkedRoot = root.appendingPathComponent("linked")
        _ = try await repo.run(["worktree", "add", "-b", "linked", linkedRoot.path, "main"])
        let linked = GitRepository(root: linkedRoot, executable: await repo.executable)
        try Data("ours\n".utf8).write(to: linkedRoot.appendingPathComponent("file")); try await linked.stage(["file"]); _ = try await linked.commit(message: "linked ours")
        let before = try await repo.run(["rev-parse", "HEAD"]).stdout
        do { _ = try await linked.importMailPatch(patch); XCTFail("Expected linked conflict") } catch is GitFailure {}
        let parentState = try await repo.mailPatchSession(), linkedState = try await linked.mailPatchSession()
        XCTAssertEqual(parentState, .none); XCTAssertEqual(linkedState, .applying)
        _ = try await linked.recoverMailPatch(.abort)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file")), Data("base\n".utf8))
    }
    func testPreCancellationAndNonFileURLLeaveRepositoryUnchanged() async throws {
        let (root, repo, patch) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repo.run(["rev-parse", "HEAD"]).stdout
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { _ = try await repo.importMailPatch(patch, cancellation: cancellation); XCTFail("Cancelled import ran") } catch OperationCancellationFailure.cancelled {}
        do { _ = try await repo.importMailPatch(URL(string: "https://example.invalid/patch")!); XCTFail("Non-file URL accepted") } catch MailPatchFailure.file {}
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; XCTAssertEqual(before, after)
        let state = try await repo.mailPatchSession(); XCTAssertEqual(state, .none)
    }

}
