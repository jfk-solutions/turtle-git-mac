import XCTest
@testable import TurtleGitCore

final class ReferenceCreationTests: XCTestCase {
    func testCancelledCreationPropagatesWithoutChangingReferencesOrConfig() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let refs = try await repo.run(["show-ref"]).stdout, config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let token = OperationCancellation(); token.cancel()
        for isTag in [false, true] {
            var options = ReferenceCreationOptions(); options.name = "cancelled"; options.isTag = isTag; options.message = "description"
            do { _ = try await repo.createReference(options, cancellation: token); XCTFail("Cancelled creation ran") } catch OperationCancellationFailure.cancelled {}
        }
        let after = try await repo.run(["show-ref"]).stdout
        XCTAssertEqual(refs, after); XCTAssertEqual(config, try Data(contentsOf: root.appendingPathComponent(".git/config")))
    }
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
    func testDeferredDescriptionCanRecoverForeignConfigLockWithoutRecreatingReference() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = ReferenceCreationOptions(); options.name = "deferred"; options.message = "  first\r\nsecond  "
        _ = try await repo.createReference(options, writeDescription: false)
        let reference = try await repo.run(["rev-parse", "refs/heads/deferred"]).stdout
        let before = try await repo.run(["config", "--get", "branch.deferred.description"], successfulExitCodes: 0...1); XCTAssertEqual(before.exitCode, 1)
        let lock = root.appendingPathComponent(".git/config.lock"); try Data("foreign lock".utf8).write(to: lock)
        do { try await repo.updateBranchDescription("deferred", message: options.message); XCTFail("Foreign lock") } catch is GitFailure {}
        XCTAssertEqual(try Data(contentsOf: lock), Data("foreign lock".utf8))
        try FileManager.default.removeItem(at: lock); try await repo.updateBranchDescription("deferred", message: options.message)
        let after = try await repo.run(["rev-parse", "refs/heads/deferred"]).stdout, value = try await repo.run(["config", "--get", "branch.deferred.description"]).text
        XCTAssertEqual(reference, after); XCTAssertEqual(value, "first\nsecond\n")
    }
    func testWhitespaceDescriptionRemovesExistingValueAndAcceptsAbsentValue() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = ReferenceCreationOptions(); options.name = "description"; options.message = "old description"
        _ = try await repo.createReference(options)
        let ref = try await repo.run(["rev-parse", "refs/heads/description"]).stdout
        try await repo.updateBranchDescription("description", message: " \r\n\t ")
        try await repo.updateBranchDescription("description", message: " \r\n ")
        let value = try await repo.run(["config", "--get", "branch.description.description"], successfulExitCodes: 0...1)
        let after = try await repo.run(["rev-parse", "refs/heads/description"]).stdout
        XCTAssertEqual(value.exitCode, 1); XCTAssertEqual(after, ref)
    }

}
