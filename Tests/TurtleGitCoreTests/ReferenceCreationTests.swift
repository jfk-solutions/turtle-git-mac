import XCTest
@testable import TurtleGitCore

final class ReferenceCreationTests: XCTestCase {
    func testBranchDescriptionAndMixedChangesArePreservedWithoutSwitching() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("index\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path])
        try Data("worktree\n".utf8).write(to: root.appendingPathComponent(path))
        var options = ReferenceCreationOptions(); options.name = "topic"; options.message = "  first\r\nsecond  "
        _ = try await repo.createReference(options)
        let branch = try await repo.branch(), index = try await repo.run(["show", ":" + path]).text
        let description = try await repo.run(["config", "--get", "branch.topic.description"]).text
        XCTAssertEqual(branch, "main"); XCTAssertEqual(index, "index\n"); XCTAssertEqual(description, "first\nsecond\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "worktree\n")
    }
    func testLightweightAnnotatedAndForcedTagsRespectUncheckedSigning() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["config", "tag.gpgSign", "true"])
        var options = ReferenceCreationOptions(); options.isTag = true; options.name = "light"
        _ = try await repo.createReference(options)
        let light = try await repo.run(["cat-file", "-t", "refs/tags/light"]).text; XCTAssertEqual(light, "commit\n")
        options.name = "release"; options.message = "release\n\nDetails"
        _ = try await repo.createReference(options)
        let annotated = try await repo.run(["cat-file", "-t", "refs/tags/release"]).text; XCTAssertEqual(annotated, "tag\n")
        do { _ = try await repo.createReference(options); XCTFail("Existing tag requires force") } catch ReferenceCreationFailure.exists {}
        options.force = true; options.message = "updated"; _ = try await repo.createReference(options)
        let message = try await repo.run(["for-each-ref", "--format=%(contents)", "refs/tags/release"]).text; XCTAssertTrue(message.contains("updated"))
        options.name = "signed"; options.sign = true; options.message = ""
        do { _ = try await repo.createReference(options); XCTFail("Signed tag needs message") } catch ReferenceCreationFailure.signingMessageRequired {}
    }
    func testRemoteBranchTrackingAndCrossTypeNameConflict() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["remote", "add", "origin", root.path]); _ = try await repo.run(["update-ref", "refs/remotes/origin/topic", "HEAD"])
        var options = ReferenceCreationOptions(); options.name = "topic"; options.revision = "refs/remotes/origin/topic"; options.tracking = .track
        _ = try await repo.createReference(options)
        let upstream = try await repo.run(["config", "--get", "branch.topic.merge"]).text; XCTAssertEqual(upstream, "refs/heads/topic\n")
        options.isTag = true
        do { _ = try await repo.createReference(options); XCTFail("Shared name needs Continue") } catch ReferenceCreationFailure.nameConflict {}
        options.allowNameConflict = true; _ = try await repo.createReference(options)
        let branch = try await repo.branch(); XCTAssertEqual(branch, "main")
    }
    func testInvalidRevisionAndCheckedOutBranchForceDoNotMoveHead() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repo.run(["rev-parse", "HEAD"]).text
        var options = ReferenceCreationOptions(); options.name = "new"; options.revision = "--help"
        do { _ = try await repo.createReference(options); XCTFail("Option is not revision") } catch ReferenceCreationFailure.invalidRevision {}
        options.revision = "HEAD"; options.name = "--bad"
        do { _ = try await repo.createReference(options); XCTFail("Option is not name") } catch ReferenceCreationFailure.invalidName {}
        options.name = "main"; options.force = true
        do { _ = try await repo.createReference(options); XCTFail("Git must refuse force on checked out branch") } catch {}
        let after = try await repo.run(["rev-parse", "HEAD"]).text; XCTAssertEqual(before, after)
    }
}
