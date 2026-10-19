// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class ExactTextGitSettingsTests: XCTestCase {
    private let composed = "caf\u{00e9}"
    private let decomposed = "cafe\u{0301}"
    private func bytes(_ value: String) -> Data { Data(value.utf8) }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func fixture(_ contents: String = "") async throws -> (URL, URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-exact-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("private-global.config"), wrapper = root.appendingPathComponent("git")
        try bytes("[core]\nprecomposeunicode = true\n" + contents).write(to: config)
        let git = ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"
        let script = """
        #!/bin/sh
        unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM GIT_CONFIG GIT_DIR GIT_WORK_TREE
        export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=\(quote(config.path)) HOME=\(quote(root.path)) XDG_CONFIG_HOME=\(quote(root.path))
        exec \(quote(git)) "$@"
        """
        try bytes(script).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let repo = GitRepository(root: root, executable: wrapper)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "--local", "core.precomposeunicode", "true"])
        return (root, config, repo)
    }

    func testIdentityAndWizardPreserveSubmittedBytesWithPrecompositionEnabled() async throws {
        let (root, global, repo) = try await fixture("[unrelated]\nvalue = preserved\n")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(composed, decomposed) // Swift equality is deliberately insufficient.
        XCTAssertNotEqual(bytes(composed), bytes(decomposed))
        let inherited = root.appendingPathComponent("included.config"), includedBytes = bytes("[unrelated]\nincluded = literal\n")
        try includedBytes.write(to: inherited)
        _ = try await repo.run(["config", "--local", "include.path", inherited.path])
        var settings = GitConfigurationSettings()
        settings.name = .init(value: composed, inherit: false)
        settings.email = .init(value: composed + "@example.invalid", inherit: false)
        settings.signingKey = .init(value: "key-" + composed, inherit: false)
        try await repo.saveGitConfiguration(settings, destination: .local)
        let first = try await repo.gitConfiguration(source: .local)
        settings.name.value = decomposed; settings.email.value = decomposed + "@example.invalid"; settings.signingKey.value = "key-" + decomposed
        XCTAssertNotEqual(first, settings)
        try await repo.saveGitConfiguration(settings, destination: .local)
        let second = try await repo.gitConfiguration(source: .local)
        XCTAssertEqual(bytes(second.name.value), bytes(decomposed))
        XCTAssertEqual(bytes(second.email.value), bytes(decomposed + "@example.invalid"))
        XCTAssertEqual(bytes(second.signingKey.value), bytes("key-" + decomposed))
        try await repo.saveFirstStartIdentity(name: decomposed, email: decomposed + "@example.invalid")
        try await repo.saveFirstStartCredentialHelper("!helper " + decomposed)
        let wizard = try await repo.firstStartConfiguration()
        XCTAssertEqual(bytes(wizard.name), bytes(decomposed)); XCTAssertEqual(bytes(wizard.email), bytes(decomposed + "@example.invalid"))
        XCTAssertEqual(bytes(wizard.selectedHelper), bytes("!helper " + decomposed))
        XCTAssertEqual(try Data(contentsOf: inherited), includedBytes)
        XCTAssertTrue(try String(contentsOf: global, encoding: .utf8).contains("preserved"))
        let persisted = try await repo.run(["config", "--local", "--get", "core.precomposeunicode"])
        XCTAssertEqual(persisted.text, "true\n")
        let displayed = try await repo.gitConfigurationText(source: .effective)
        XCTAssertFalse(displayed.contains("command line:"), "Config viewer exposed the implementation's transient override")
        XCTAssertTrue(displayed.contains("core.precomposeunicode=true"))
        XCTAssertFalse(displayed.contains("core.precomposeunicode=false"))
        let config = root.appendingPathComponent(".git/config"), before = try Data(contentsOf: config)
        let cancellation = OperationCancellation(); cancellation.cancel()
        do { try await repo.saveGitConfiguration(first, destination: .local, cancellation: cancellation); XCTFail("Cancelled save mutated configuration") }
        catch is CancellationError {}
        catch { XCTAssertTrue(cancellation.isCancelled) }
        XCTAssertEqual(try Data(contentsOf: config), before)
    }

    func testCredentialGroupsAndDraftsUseExactTupleAndOrderedTextIdentity() throws {
        func record(_ origin: String, _ key: String, _ value: String?) -> Data {
            bytes("global\0file:" + origin + "\0" + key + (value.map { "\n" + $0 } ?? "") + "\0")
        }
        let urlA = "https://example.invalid/" + composed, urlB = "https://example.invalid/" + decomposed
        let originA = "/private/" + composed, originB = "/private/" + decomposed
        let data = record(originA, "credential." + urlA + ".helper", composed) +
            record(originA, "credential." + urlB + ".helper", decomposed) +
            record(originB, "credential." + urlA + ".username", decomposed)
        let snapshot = try GitCredentialSnapshot.parse(data, root: URL(fileURLWithPath: "/private"))
        XCTAssertEqual(snapshot.groups.count, 3)
        XCTAssertEqual(Set(snapshot.groups.map(\.id)).count, 3)
        for group in snapshot.groups {
            XCTAssertEqual(bytes(try XCTUnwrap(GitPathRowIdentity.decode(group.id))), bytes(group.scope + "\0" + group.origin + "\0" + group.url))
            XCTAssertEqual(bytes(try XCTUnwrap(group.file).path), bytes(String(group.origin.dropFirst(5))))
        }
        let relativeData = record("sub/../" + composed, "credential.helper", composed) + record("./" + decomposed, "credential.helper", decomposed)
        let relative = try GitCredentialSnapshot.parse(relativeData, root: URL(fileURLWithPath: "/private"))
        XCTAssertEqual(relative.groups.count, 2)
        XCTAssertEqual(Set(relative.groups.map { bytes($0.origin) }), Set([bytes("file:/private/" + composed), bytes("file:/private/" + decomposed)]))
        for path in ["/private/folder % # ?/" + decomposed, "//private/folder/" + composed] {
            let entry = GitCredentialEntry(scope: "global", origin: "file:" + path, key: "credential.helper", value: "", hasValue: true)
            let file = try XCTUnwrap(entry.file)
            XCTAssertTrue(file.isFileURL); XCTAssertTrue(file.host?.isEmpty != false)
            XCTAssertEqual(bytes(file.path), bytes(path))
        }
        let punctuation = try GitCredentialSnapshot.parse(record("folder % # ?/./nested/../" + decomposed, "credential.helper", ""), root: URL(fileURLWithPath: "/private"))
        XCTAssertEqual(bytes(try XCTUnwrap(punctuation.groups.first?.file).path), bytes("/private/folder % # ?/" + decomposed))
        let reversed = GitCredentialSnapshot(entries: Array(snapshot.entries.reversed()))
        XCTAssertEqual(reversed.groups.map(\.id), snapshot.groups.map(\.id))
        let original = try XCTUnwrap(snapshot.entries.first)
        XCTAssertNotEqual(original, GitCredentialEntry(scope: original.scope, origin: original.origin, key: original.key, value: decomposed, hasValue: original.hasValue))
        XCTAssertNotEqual(original, GitCredentialEntry(scope: original.scope, origin: original.origin, key: original.key, value: original.value, hasValue: false))
        var draft = GitCredentialDraft(); draft.url = urlA; draft.helpers = ["", composed]; draft.username = composed
        var edited = draft; edited.helpers = ["", decomposed]; edited.username = decomposed
        XCTAssertNotEqual(draft, edited); XCTAssertEqual(edited.changedFields(from: draft), [.helper, .username])
        edited = draft; edited.url = urlB
        XCTAssertNotEqual(draft, edited); XCTAssertTrue(edited.changedFields(from: draft).isEmpty)
        edited = draft; edited.helpers.reverse()
        XCTAssertNotEqual(draft, edited); XCTAssertEqual(edited.changedFields(from: draft), .helper)
    }

    func testCredentialMaskedSaveStaleRefusalAndExactRemovalPreserveOtherEntries() async throws {
        let (root, config, repo) = try await fixture("[unrelated]\nvalue = retained\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let include = root.appendingPathComponent("included.config"), includedBytes = bytes("[credential]\nhelper = inherited\n[unrelated]\nvalue = included\n")
        try includedBytes.write(to: include)
        _ = try await repo.run(["config", "--global", "include.path", include.path])
        let urlA = "https://example.invalid/" + composed, urlB = "https://example.invalid/" + decomposed
        var a = GitCredentialDraft(); a.url = urlA; a.helpers = ["", "!helper " + composed]; a.username = composed; a.useHTTPPath = true
        var b = a; b.url = urlB; b.helpers = ["!helper " + decomposed]; b.username = decomposed
        try await repo.saveCredential(a, file: config)
        try await repo.saveCredential(b, file: config)
        let literalPath = root.path + "/config % # ?-" + decomposed
        let literalFile = try XCTUnwrap(GitCredentialEntry(scope: "global", origin: "file:" + literalPath, key: "credential.helper", value: "", hasValue: true).file)
        try Data().write(to: literalFile)
        try await repo.saveCredential(b, file: literalFile)
        let literal = try await repo.run(["-c", "core.precomposeunicode=false", "config", "--file", literalFile.path, "--null", "--get", "credential." + urlB + ".helper"])
        XCTAssertEqual(literal.stdout, bytes(b.helpers[0] + "\0"))
        let before = try await repo.credentialConfiguration()
        let originalA = try XCTUnwrap(before.groups.first { GitReferenceName.equal($0.url, urlA) })
        let originalB = try XCTUnwrap(before.groups.first { GitReferenceName.equal($0.url, urlB) })
        XCTAssertNotEqual(originalA.id, originalB.id)
        XCTAssertEqual(originalA.helpers.map(bytes), a.helpers.map(bytes)); XCTAssertEqual(originalB.helpers.map(bytes), b.helpers.map(bytes))
        a.username = decomposed
        try await repo.saveCredential(a, file: config, expected: before, fields: .username)
        let after = try await repo.credentialConfiguration()
        let changedA = try XCTUnwrap(after.groups.first { $0.id == originalA.id })
        XCTAssertEqual(bytes(changedA.username), bytes(decomposed))
        XCTAssertEqual(changedA.entries.filter { $0.field != "username" }, originalA.entries.filter { $0.field != "username" })
        XCTAssertEqual(after.groups.first { $0.id == originalB.id }, originalB)
        let unchanged = try Data(contentsOf: config)
        do { try await repo.saveCredential(a, file: config, expected: before, fields: .helper); XCTFail("Canonically equivalent external edit accepted") }
        catch GitCredentialFailure.changed {}
        do { try await repo.removeCredential(originalB, expected: before); XCTFail("Stale removal accepted") }
        catch GitCredentialFailure.changed {}
        do { try await repo.simplifyCredentials(expected: before, helper: nil, file: nil); XCTFail("Stale simplification accepted") }
        catch GitCredentialFailure.changed {}
        XCTAssertEqual(try Data(contentsOf: config), unchanged)
        try await repo.removeCredential(changedA, expected: after)
        let removed = try await repo.credentialConfiguration()
        XCTAssertNil(removed.groups.first { $0.id == originalA.id }); XCTAssertEqual(removed.groups.first { $0.id == originalB.id }, originalB)
        // Public removal accepts an entry collection; byte-distinct keys must
        // not collapse when removing a collection from the same origin.
        try await repo.saveCredential(a, file: config)
        let combined = GitCredentialGroup(scope: originalA.scope, origin: originalA.origin, url: originalA.url, entries: originalA.entries + originalB.entries)
        try await repo.removeCredential(combined)
        let final = try await repo.credentialConfiguration()
        XCTAssertFalse(final.groups.contains { !$0.url.isEmpty })
        XCTAssertEqual(try Data(contentsOf: include), includedBytes)
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("retained"))
        let persisted = try await repo.run(["config", "--global", "--get", "core.precomposeunicode"])
        XCTAssertEqual(persisted.text, "true\n")
    }

    func testProxyAndSSHChangesRetainExactUserTextAndPrivatePreferences() async throws {
        let (root, config, repo) = try await fixture("[unrelated]\nvalue = retained\n")
        defer { try? FileManager.default.removeItem(at: root) }
        var proxy = GitProxySettings(); proxy.enabled = true; proxy.server = "proxy.invalid"; proxy.port = "8080"; proxy.username = composed; proxy.password = composed
        var changed = proxy; changed.username = decomposed; changed.password = decomposed
        XCTAssertNotEqual(proxy, changed)
        try await repo.saveProxyConfiguration(proxy)
        try await repo.saveProxyConfiguration(changed)
        let read = try await repo.proxyConfiguration(source: .global)
        XCTAssertEqual(bytes(read.username), bytes(decomposed)); XCTAssertEqual(bytes(read.password), bytes(decomposed))
        XCTAssertNotEqual(bytes(try XCTUnwrap(proxy.value())), bytes(try XCTUnwrap(changed.value())))
        var serverOnly = proxy; serverOnly.server = composed
        var serverAlias = serverOnly; serverAlias.server = decomposed
        XCTAssertNotEqual(serverOnly, serverAlias)
        var ssh = SSHClientPreferences(); ssh.path = "/private/ssh-" + composed; ssh.bookmark = Data([1, 2])
        var alias = ssh; alias.path = "/private/ssh-" + decomposed
        XCTAssertNotEqual(ssh, alias); alias = ssh; alias.bookmark = Data([1, 3]); XCTAssertNotEqual(ssh, alias)
        let suite = "TurtleGit.ExactSSH." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/private/ssh-" + decomposed, forKey: "TurtleGit.SSHClient"); defaults.set(ssh.bookmark, forKey: "TurtleGit.SSHClientBookmark")
        XCTAssertEqual(bytes(SSHClientPreferences.load(from: defaults).path), bytes("/private/ssh-" + decomposed))
        changed.enabled = false; try await repo.saveProxyConfiguration(changed)
        let disabled = try await repo.proxyConfiguration(source: .global)
        XCTAssertFalse(disabled.enabled)
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("retained"))
    }
}
