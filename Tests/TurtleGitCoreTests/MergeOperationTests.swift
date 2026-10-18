import XCTest
@testable import TurtleGitCore

final class MergeOperationTests: XCTestCase {
    func testMergeUsesConfiguredMessageEncodingAndSourceCommentSanitization() async throws {
        let (root, repo, _) = try await MergeTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["config", "i18n.commitencoding", "windows-1252"])
        _ = try await repo.run(["config", "core.commentchar", ";"])
        var options = MergeTests().options()
        options.noFastForward = true; options.requireIdentity = true
        options.stripComments = true; options.sanitizeMessage = true
        options.message = "  café  \r\n;remove this\n\n\nbody €  \r\n\n"
        _ = try await repo.merge(options)
        let raw = try await repo.run(["cat-file", "commit", "HEAD"]).stdout
        let separator = try XCTUnwrap(raw.range(of: Data("\n\n".utf8)))
        let message = Data(raw[separator.upperBound...])
        XCTAssertEqual(message, Data([99,97,102,0xe9,10,10,98,111,100,121,32,0x80,10]))
        XCTAssertTrue(String(decoding: raw.prefix(separator.lowerBound), as: UTF8.self).contains("encoding windows-1252"))
        let head = try await repo.rebaseCommit("HEAD")
        XCTAssertEqual(head.parents.count, 2)
    }

    func testUnsupportedEncodingFailsBeforeMergeAndSquashIgnoresDisabledMessage() async throws {
        let (root, repo, _) = try await MergeTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["config", "i18n.commitencoding", "UTF-16"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var options = MergeTests().options(); options.noFastForward = true; options.message = "Unsupported"
        do { _ = try await repo.merge(options); XCTFail("Invalid commit encoding reached merge") } catch is GitFailure {}
        let unchanged = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(unchanged, head); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/MERGE_HEAD").path))
        options.noFastForward = false; options.squash = true
        _ = try await repo.merge(options)
        let stillHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(stillHead, head)
        let staged = try await repo.diff(staged: true)
        XCTAssertTrue(staged.contains("feature.txt"))
    }

    func testUserMergeRechecksIdentityButInternalFastForwardDoesNotRequireIt() async throws {
        let (root, repo, _) = try await MergeTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Explicit empty overrides make the check independent of global config.
        for key in ["user.name", "user.email", "author.name", "author.email", "committer.name", "committer.email"] {
            _ = try await repo.run(["config", "--local", key, ""])
        }
        let explicitIdentity = try await repo.replayUserIdentity(environment: [:])
        XCTAssertFalse(explicitIdentity.complete)
        let preparation = try await repo.prepareMerge()
        // An explicitly supplied process identity has source precedence over config.
        // The internal fast-forward must succeed in either environment.
        var options = MergeTests().options(); options.fastForwardOnly = true; options.requireIdentity = true
        if !preparation.identity.complete {
            do { _ = try await repo.merge(options); XCTFail("User Merge skipped identity repair") } catch MergeFailure.identity {}
        }
        options.requireIdentity = false
        _ = try await repo.merge(options)
        let actual = try await repo.run(["rev-parse", "HEAD"]).stdout
        let expected = try await repo.run(["rev-parse", "feature"]).stdout
        XCTAssertEqual(actual, expected)
    }

    func testOwnedEditReplayRefusesMergeWithoutRecoveringOrMutatingSession() async throws {
        let (root, repo, _) = try await RebasePendingActionTests().paused()
        defer { try? FileManager.default.removeItem(at: root) }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let names = ["HEAD", "index", "rebase-merge/git-rebase-todo", "rebase-merge/done", "rebase-merge/turtlegit-replay-identities.json"]
        let before = try names.map { try Data(contentsOf: root.appendingPathComponent(".git/" + $0)) }
        let preparation = try await repo.prepareMerge()
        XCTAssertTrue(preparation.replayActive); XCTAssertTrue(preparation.identity.complete)
        var options = MergeOptions(); options.revision = "HEAD"; options.message = "Must not reach Git"
        do { _ = try await repo.merge(options); XCTFail("Owned replay allowed merge") } catch MergeFailure.activeReplay {}
        XCTAssertEqual(try names.map { try Data(contentsOf: root.appendingPathComponent(".git/" + $0)) }, before)
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(after, head)
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { _ = try await repo.prepareMerge(cancellation: cancelled); XCTFail("Cancelled preparation returned") } catch is OperationCancellationFailure {}
        do { _ = try await repo.makeCommitMessageFile("cancelled", cancellation: cancelled); XCTFail("Cancelled file was created") } catch is OperationCancellationFailure {}
    }
}
