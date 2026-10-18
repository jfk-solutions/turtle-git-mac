// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class ReplayUserIdentityTests: XCTestCase {
    func testExplicitAuthorAndCommitterPrecedenceAndPinnedEmailOverride() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for (key, value) in [("user.name", "default name"), ("user.email", "default@example.invalid"), ("author.name", "author"), ("author.email", "author@example.invalid"), ("committer.name", "committer"), ("committer.email", "committer@example.invalid")] {
            _ = try await repo.run(["config", "--local", key, value])
        }
        let configured = try await repo.replayUserIdentity(environment: [:])
        XCTAssertEqual(configured, ReplayUserIdentity(authorName: "author", authorEmail: "author@example.invalid", committerName: "committer", committerEmail: "committer@example.invalid"))
        XCTAssertTrue(configured.complete)
        let environment = ["GIT_AUTHOR_NAME": "environment author", "GIT_AUTHOR_EMAIL": "environment@example.invalid", "GIT_COMMITTER_NAME": "environment committer", "GIT_COMMITTER_EMAIL": "other@example.invalid"]
        let overridden = try await repo.replayUserIdentity(environment: environment)
        XCTAssertEqual(overridden, ReplayUserIdentity(authorName: "environment author", authorEmail: "environment@example.invalid", committerName: "environment committer", committerEmail: "environment@example.invalid"))
    }
    func testMissingIdentityDoesNotAcceptGitSynthesizedFallbackAndEmptyOverridesFallThrough() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["config", "--local", "user.name", ""])
        _ = try await repo.run(["config", "--local", "user.email", ""])
        let missing = try await repo.replayUserIdentity(environment: [:])
        XCTAssertFalse(missing.complete)
        XCTAssertEqual(missing.authorName, ""); XCTAssertEqual(missing.committerEmail, "")
        _ = try await repo.run(["config", "--local", "user.name", "configured"])
        _ = try await repo.run(["config", "--local", "user.email", "configured@example.invalid"])
        _ = try await repo.run(["config", "--local", "author.name", ""])
        _ = try await repo.run(["config", "--local", "committer.email", ""])
        let fallback = try await repo.replayUserIdentity(environment: ["GIT_AUTHOR_NAME": "", "GIT_AUTHOR_EMAIL": "", "GIT_COMMITTER_NAME": ""])
        XCTAssertTrue(fallback.complete)
        XCTAssertEqual(fallback.authorName, "configured"); XCTAssertEqual(fallback.committerEmail, "configured@example.invalid")
    }
    func testInheritedConfigurationAndCancellationRemainReadOnly() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let include = root.appendingPathComponent("included-identity")
        try Data("[author]\nname = inherited\nemail = inherited@example.invalid\n[committer]\nname = other\nemail = other@example.invalid\n".utf8).write(to: include)
        _ = try await repo.run(["config", "--local", "include.path", include.path])
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let identity = try await repo.replayUserIdentity(environment: [:])
        XCTAssertEqual(identity.authorName, "inherited"); XCTAssertEqual(identity.committerEmail, "other@example.invalid")
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.replayUserIdentity(environment: [:], cancellation: token); XCTFail("Cancelled preflight returned identity") }
        catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), config)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(finalHead, head)
    }
}
