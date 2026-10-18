// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class CredentialAdvancedEditingTests: XCTestCase {
    func testUsernameApplyPreservesRawHelperBooleanAndOtherOrigins() async throws {
        let (root, config, repository) = try GeneralSetupBatchTests().fixture("[include]\npath = included.config\n[credential \"https://Host.invalid/path\"]\nhelper =\nhelper = !helper --literal '$()'\nusername = first\nusername = second\nuseHttpPath\nuseHttpPath = yes\ncustom = untouched\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let included = root.appendingPathComponent("included.config"), content = Data("[credential]\nhelper = inherited\nuseHttpPath = true\n".utf8)
        try content.write(to: included)
        let before = try await repository.credentialConfiguration(), original = try XCTUnwrap(before.groups.first { !$0.url.isEmpty })
        var draft = GitCredentialDraft(); draft.url = original.url; draft.helpers = original.helpers; draft.username = "updated 雪"
        try await repository.saveCredential(draft, file: config, expected: before, fields: .username)
        let snapshot = try await repository.credentialConfiguration(), updated = try XCTUnwrap(snapshot.groups.first { $0.id == original.id })
        XCTAssertEqual(updated.entries.filter { $0.field != "username" }, original.entries.filter { $0.field != "username" })
        XCTAssertEqual(updated.entries.filter { $0.field == "username" }.map(\.value), ["updated 雪"])
        XCTAssertEqual(try Data(contentsOf: included), content)
        XCTAssertEqual(snapshot.entries.filter { $0.file == included }, before.entries.filter { $0.file == included })
    }

    func testHelperOnlyEditPreservesRepeatedUsernamesAndExplicitEmptyBoolean() async throws {
        let (root, config, repository) = try GeneralSetupBatchTests().fixture("[credential]\nhelper = original\nusername = first\nusername = second\nuseHttpPath =\ncustom = untouched\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repository.credentialConfiguration()
        var draft = GitCredentialDraft(); draft.helpers = ["", "osxkeychain"]
        try await repository.saveCredential(draft, file: config, expected: before, fields: .helper)
        let after = try await repository.credentialConfiguration()
        XCTAssertEqual(after.entries.filter { $0.field != "helper" }, before.entries.filter { $0.field != "helper" })
        XCTAssertEqual(after.groups.first?.helpers, ["", "osxkeychain"])
        // Clearing an edited helper is source unset, while an untouched empty
        // helper in a loaded chain remains a Git inheritance reset.
        draft.helpers = []
        try await repository.saveCredential(draft, file: config, expected: after, fields: .helper)
        let cleared = try await repository.credentialConfiguration()
        XCTAssertTrue(try XCTUnwrap(cleared.groups.first).helpers.isEmpty)
        XCTAssertEqual(cleared.entries.filter { $0.field != "helper" }, after.entries.filter { $0.field != "helper" })
    }

    func testHelperlessGroupAndUncheckedHTTPPathRestoreInheritedSetting() async throws {
        let (root, config, repository) = try GeneralSetupBatchTests().fixture("[credential]\nuseHttpPath = true\n[credential \"https://helperless.invalid\"]\nusername = previous\nuseHttpPath = on\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repository.credentialConfiguration()
        var draft = GitCredentialDraft(); draft.url = "https://helperless.invalid"; draft.username = "next"
        XCTAssertTrue(draft.fieldsValid); XCTAssertFalse(draft.valid)
        try await repository.saveCredential(draft, file: config, expected: before, fields: [.username, .useHTTPPath])
        let after = try await repository.credentialConfiguration(), group = try XCTUnwrap(after.groups.first { $0.url == draft.url })
        XCTAssertEqual(group.username, "next"); XCTAssertTrue(group.helpers.isEmpty)
        XCTAssertFalse(group.entries.contains { $0.field == "usehttppath" })
        let effective = try await repository.run(["config", "--get-urlmatch", "credential.useHttpPath", draft.url])
        XCTAssertEqual(effective.text, "true\n")
        draft.username = ""
        try await repository.saveCredential(draft, file: config, expected: after, fields: .username)
        let cleared = try await repository.credentialConfiguration()
        XCTAssertFalse(cleared.groups.contains { $0.url == draft.url })
    }

    func testMaskedWritesRejectStaleSnapshotAndInvalidMaskBeforeMutation() async throws {
        let (root, config, repository) = try GeneralSetupBatchTests().fixture("[credential]\nusername = initial\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await repository.credentialConfiguration()
        var draft = GitCredentialDraft(); draft.username = "replacement"
        _ = try await repository.run(["config", "--global", "credential.username", "external"])
        let bytes = try Data(contentsOf: config)
        do { try await repository.saveCredential(draft, file: config, expected: before, fields: .username); XCTFail("Stale masked save succeeded") }
        catch GitCredentialFailure.changed {}
        do { try await repository.saveCredential(draft, file: config, fields: .init(rawValue: 8)); XCTFail("Unknown mask succeeded") }
        catch GitConfigurationFailure.invalidValue {}
        XCTAssertEqual(try Data(contentsOf: config), bytes)
    }
}
