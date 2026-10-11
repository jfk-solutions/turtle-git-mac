// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class AuthenticationSettingsBatchTests: XCTestCase {
    func testCredentialParserKeepsOriginsURLCaseResetsAndBooleanPresence() throws {
        let root = URL(fileURLWithPath: "/fixture")
        let data = Data("global\0file:included.config\0credential.https://Host.invalid/a.b.helper\n\0global\0file:included.config\0credential.https://Host.invalid/a.b.helper\nosxkeychain\0global\0file:included.config\0credential.https://Host.invalid/a.b.usehttppath\0local\0file:/fixture/local\0credential.usehttppath\n\0".utf8)
        let snapshot = try GitCredentialSnapshot.parse(data, root: root)
        let scoped = try XCTUnwrap(snapshot.groups.first { !$0.url.isEmpty })
        XCTAssertEqual(scoped.url, "https://Host.invalid/a.b"); XCTAssertEqual(scoped.helpers, ["", "osxkeychain"])
        XCTAssertEqual(scoped.file?.path, "/fixture/included.config"); XCTAssertTrue(scoped.useHTTPPath)
        XCTAssertFalse(try XCTUnwrap(snapshot.groups.first { $0.url.isEmpty }).useHTTPPath)
        for malformed in [Data("global\0".utf8), Data("global\0file:/fixture\0wrong.key\nvalue\0".utf8), Data("global\0file:/fixture\0credential.helper\nvalue".utf8)] {
            XCTAssertThrowsError(try GitCredentialSnapshot.parse(malformed, root: root))
        }
    }
    func testAdvancedCredentialWritesPreserveOtherURLsUnknownFieldsAndIncludes() async throws {
        let (root, config, repo) = try GeneralSetupBatchTests().fixture("[include]\npath = included.config\n[credential \"https://Host.invalid/a.b\"]\nhelper = original\ncustom = retained\n[credential \"https://other.invalid\"]\nhelper = other\n[user]\nname = preserved\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let included = root.appendingPathComponent("included.config"), bytes = Data("[credential]\nhelper = inherited\nuseHttpPath = true\n".utf8)
        try bytes.write(to: included)
        let before = try await repo.credentialConfiguration()
        var draft = GitCredentialDraft(); draft.url = "https://Host.invalid/a.b"; draft.helpers = ["", "osxkeychain", "!literal helper '$()'"]; draft.username = "Turtle 雪"; draft.useHTTPPath = false
        try await repo.saveCredential(draft, file: config, expected: before)
        let after = try await repo.credentialConfiguration(), group = try XCTUnwrap(after.groups.first { $0.url == draft.url })
        XCTAssertEqual(group.helpers, draft.helpers); XCTAssertEqual(group.username, draft.username); XCTAssertFalse(group.useHTTPPath)
        XCTAssertEqual(group.entries.last { $0.field == "usehttppath" }?.value, "false")
        XCTAssertTrue(group.entries.contains { $0.field == "custom" && $0.value == "retained" })
        XCTAssertTrue(after.groups.contains { $0.url == "https://other.invalid" && $0.helpers == ["other"] })
        XCTAssertEqual(try Data(contentsOf: included), bytes)
        let name = try await repo.run(["config", "--get", "user.name"]); XCTAssertEqual(name.text, "preserved\n")
    }
    func testStaleAdvancedSaveAndRemoveLeaveConfigurationUntouched() async throws {
        let (root, config, repo) = try GeneralSetupBatchTests().fixture("[credential]\nhelper = original\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await repo.credentialConfiguration(), group = try XCTUnwrap(snapshot.groups.first)
        _ = try await repo.run(["config", "--global", "credential.username", "external"])
        let before = try Data(contentsOf: config)
        var draft = GitCredentialDraft(); draft.helpers = ["replacement"]
        do { try await repo.saveCredential(draft, file: config, expected: snapshot); XCTFail("Stale save succeeded") } catch GitCredentialFailure.changed {}
        do { try await repo.removeCredential(group, expected: snapshot); XCTFail("Stale removal succeeded") } catch GitCredentialFailure.changed {}
        XCTAssertEqual(try Data(contentsOf: config), before)
    }
    func testRemoveTargetsExactURLAndSimpleChoiceClearsCredentialsOnly() async throws {
        let (root, config, repo) = try GeneralSetupBatchTests().fixture("[credential]\nhelper = first\nhelper = second\n[credential \"https://example.invalid\"]\nhelper = scoped\nusername = scoped-user\ncustom = scoped-custom\n[fetch]\nprune = true\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await repo.credentialConfiguration(), scoped = try XCTUnwrap(initial.groups.first { !$0.url.isEmpty })
        try await repo.removeCredential(scoped, expected: initial)
        let after = try await repo.credentialConfiguration(); XCTAssertEqual(after.groups.count, 1); XCTAssertEqual(after.groups[0].helpers, ["first", "second"])
        try await repo.simplifyCredentials(expected: after, helper: "osxkeychain", file: config)
        let simple = try await repo.credentialConfiguration(); XCTAssertEqual(simple.entries.count, 1); XCTAssertEqual(simple.entries[0].value, "osxkeychain")
        try await repo.simplifyCredentials(expected: simple, helper: nil, file: nil)
        let none = try await repo.credentialConfiguration(); XCTAssertTrue(none.entries.isEmpty)
        let prune = try await repo.run(["config", "--get", "fetch.prune"]); XCTAssertEqual(prune.text, "true\n")
    }
    func testCredentialValidationIsBeforeWrites() async throws {
        let (root, config, repo) = try GeneralSetupBatchTests().fixture("[credential]\nhelper = original\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: config)
        var draft = GitCredentialDraft(); draft.helpers = ["bad\0helper"]
        do { try await repo.saveCredential(draft, file: config); XCTFail("Invalid helper saved") } catch GitConfigurationFailure.invalidValue {}
        XCTAssertEqual(try Data(contentsOf: config), before)
    }
    func testPlainKeyPublicationPermissionsFingerprintAndExistingPairRefusal() throws {
        let root = try SSHAgentSessionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("identity with spaces")
        var request = SSHKeyGenerationRequest(destination: destination); request.comment = "Turtle 雪 $()"
        let result = try SSHKeyGeneration.generate(request, executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"), askpass: nil, cancellation: OperationCancellation())
        XCTAssertTrue(result.publicText.hasPrefix("ssh-ed25519 ")); XCTAssertTrue(result.publicText.contains(request.comment)); XCTAssertTrue(result.fingerprint.contains("SHA256:"))
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let privateBytes = try Data(contentsOf: destination), publicBytes = try Data(contentsOf: result.publicKey)
        XCTAssertThrowsError(try SSHKeyGeneration.generate(request, executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"), askpass: nil, cancellation: OperationCancellation()))
        XCTAssertEqual(try Data(contentsOf: destination), privateBytes); XCTAssertEqual(try Data(contentsOf: result.publicKey), publicBytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("tg-keygen-") })
    }
    func testEncryptedGeneratedKeyLoadsThroughOneUseAgentChannel() throws {
        let root = try SSHAgentSessionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let helper = try SSHAskpassTests().helper(in: root)
        var request = SSHKeyGenerationRequest(destination: root.appendingPathComponent("encrypted")); request.passphrase = "fixture '$()' 雪"; request.comment = "encrypted-generation"
        let result = try SSHKeyGeneration.generate(request, executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"), askpass: helper, cancellation: OperationCancellation())
        let runtime = SSHAgentRuntime(agent: URL(fileURLWithPath: "/usr/bin/ssh-agent"), add: URL(fileURLWithPath: "/usr/bin/ssh-add"), askpass: helper)
        let session = try SSHAgentSession(runtime: runtime, temporaryRoot: root); defer { session.close() }
        XCTAssertThrowsError(try session.add(keys: [result.privateKey]))
        try session.add(keys: [result.privateKey], passphrase: request.passphrase)
        XCTAssertTrue(try session.publicIdentities().contains(request.comment))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("tg-keygen-") })
    }
    func testKeyGenerationCancelledOrInvalidRequestPublishesNothing() throws {
        let root = try SSHAgentSessionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var request = SSHKeyGenerationRequest(destination: root.appendingPathComponent("cancelled"))
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try SSHKeyGeneration.generate(request, executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"), askpass: nil, cancellation: token))
        request.passphrase = "invalid\nphrase"
        XCTAssertThrowsError(try SSHKeyGeneration.generate(request, executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"), askpass: nil, cancellation: OperationCancellation()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
