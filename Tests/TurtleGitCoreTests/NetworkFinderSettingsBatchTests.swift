// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class NetworkFinderSettingsBatchTests: XCTestCase {
    func testProxyRoundTripsIPv6SchemesAndEscapedCredentials() throws {
        for server in ["proxy.example.invalid", "https://proxy.example.invalid", "socks5h://[::1]"] {
            var proxy = GitProxySettings(); proxy.enabled = true; proxy.server = server; proxy.port = "8080"; proxy.username = "Turtle 雪 @:/%"; proxy.password = "phrase @:/% $?"
            let value = try XCTUnwrap(proxy.value()), read = try GitProxySettings(configuration: value)
            XCTAssertEqual(read.port, proxy.port); XCTAssertEqual(read.username, proxy.username); XCTAssertEqual(read.password, proxy.password)
            XCTAssertEqual(try read.value(), value)
        }
        var disabled = GitProxySettings(); disabled.server = "retained.invalid"; disabled.password = "retained"; XCTAssertNil(try disabled.value())
    }
    func testInvalidProxyFieldsAndPortsAreRejected() throws {
        var proxy = GitProxySettings(); proxy.enabled = true; proxy.server = "proxy.example.invalid"
        for port in ["-1", "65536", "1x", "0x80"] { proxy.port = port; XCTAssertThrowsError(try proxy.value()) }
        proxy.port = ""
        for server in ["", "file:///tmp/proxy", "http://host/path", "http://host?query", "http://host#fragment", "http://user:pass@host"] { proxy.server = server; XCTAssertThrowsError(try proxy.value()) }
        proxy.server = "proxy.example.invalid"; proxy.password = "password"; XCTAssertThrowsError(try proxy.value())
    }
    func testProxyGlobalWritesPreserveLocalAndURLSpecificOverridesAndHideFailures() async throws {
        let (root, config, repo) = try GeneralSetupBatchTests().fixture("[http \"https://example.invalid\"]\nproxy = http://scoped.invalid\n[user]\nname = preserved\n")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["init", "--quiet"])
        _ = try await repo.run(["config", "--local", "http.proxy", "http://local.invalid"])
        var proxy = GitProxySettings(); proxy.enabled = true; proxy.server = "proxy.example.invalid"; proxy.port = "3128"; proxy.username = "fixture"; proxy.password = "private-fixture-phrase"
        try await repo.saveProxyConfiguration(proxy)
        let global = try await repo.proxyConfiguration(source: .global), effective = try await repo.proxyConfiguration()
        XCTAssertEqual(global, proxy); XCTAssertEqual(effective.server, "local.invalid")
        proxy.enabled = false; try await repo.saveProxyConfiguration(proxy)
        let local = try await repo.proxyConfiguration(); XCTAssertTrue(local.enabled); XCTAssertEqual(local.server, "local.invalid")
        let scoped = try await repo.run(["config", "--global", "--get", "http.https://example.invalid.proxy"]); XCTAssertEqual(scoped.text, "http://scoped.invalid\n")
        try Data().write(to: URL(fileURLWithPath: config.path + ".lock")); proxy.enabled = true
        do { try await repo.saveProxyConfiguration(proxy); XCTFail("Locked config saved") }
        catch { XCTAssertFalse(error.localizedDescription.contains(proxy.password)); XCTAssertFalse(error.localizedDescription.contains("private-fixture")) }
    }
    func testSSHSelectionPreservesOverridesAndAppStoreRuntime() throws {
        var ssh = SSHClientPreferences(); ssh.path = "/usr/bin/ssh"
        XCTAssertEqual(ssh.environment(existing: [:], appStore: false)["GIT_SSH"], "/usr/bin/ssh")
        XCTAssertEqual(ssh.environment(existing: ["GIT_SSH": "/custom/ssh"], appStore: false), [:])
        XCTAssertEqual(ssh.environment(existing: ["GIT_SSH_COMMAND": "command override"], appStore: false), [:])
        XCTAssertEqual(ssh.environment(existing: [:], appStore: true), [:])
        XCTAssertTrue(try ssh.version(cancellation: OperationCancellation()).hasPrefix("OpenSSH_"))
        let token = OperationCancellation(); token.cancel(); XCTAssertThrowsError(try ssh.version(cancellation: token))
    }
    func testOverlayMostSpecificRulesExactSuffixAndDriveOverrides() {
        var settings = FinderOverlaySettings(); settings.volumes = []
        settings.excludePaths = "/repo*\n/repo/allowed/blocked*\n/repo/exact?\n/repo/tie*\n"
        settings.includePaths = "/repo/allowed*\n/repo/exact/child*\n/repo/tie*\n"
        XCTAssertTrue(settings.valid)
        XCTAssertFalse(settings.allows("/repo", volume: .fixed)); XCTAssertFalse(settings.allows("/repo/file", volume: .fixed))
        XCTAssertTrue(settings.allows("/repo/allowed/file", volume: .network)); XCTAssertFalse(settings.allows("/repo/allowed/blocked/file", volume: .fixed))
        XCTAssertFalse(settings.allows("/repo/exact", volume: .fixed)); XCTAssertTrue(settings.allows("/repo/exact/child/file", volume: .fixed))
        XCTAssertTrue(settings.allows("/repo/tie/file", volume: .unknown)); XCTAssertFalse(settings.allows("/repository", volume: .fixed))
        settings.includePaths = "~?\n"; XCTAssertTrue(settings.valid)
        settings.excludePaths = "relative/path"; XCTAssertFalse(settings.valid)
    }
    func testOverlayProjectionDoesNotChangeMenuStatusAndHonorsUnversionedAndHandlers() {
        let snapshot = FinderSnapshot(roots: ["/repo"], states: ["/repo": .untracked, "/repo/new": .untracked, "/repo/tracked": .normal], overlayEntries: ["/repo/new": .untracked, "/repo/tracked": .normal])
        var settings = FinderOverlaySettings()
        var badges = settings.badges(snapshot: snapshot, volume: { _ in .fixed }, isDirectory: { _ in false })
        XCTAssertEqual(badges["/repo"], .normal); XCTAssertEqual(badges["/repo/new"], .untracked); XCTAssertEqual(snapshot.states["/repo"], .untracked)
        settings.unversionedAsModified = true; settings.hiddenStates = [.untracked]
        badges = settings.badges(snapshot: snapshot, volume: { _ in .fixed }, isDirectory: { _ in false })
        XCTAssertEqual(badges["/repo"], .modified); XCTAssertNil(badges["/repo/new"])
        settings.excludePaths = "/repo*\n"; settings.showExcludedAsNormal = true
        badges = settings.badges(snapshot: snapshot, volume: { _ in .fixed }, isDirectory: { _ in false })
        XCTAssertEqual(badges["/repo"], .normal); XCTAssertNil(badges["/repo/tracked"])
    }
    func testSubrepositoryOverlayPropagationAndNoneMode() {
        let childMetadata = FinderRepositoryMetadata(bare: false, bisectActive: false, mergeActive: false, hasStash: false, hasSubmoduleConfig: false, submoduleParentRoot: "/repo")
        let snapshot = FinderSnapshot(roots: ["/repo", "/repo/vendor/sub"], states: [:], repositories: ["/repo/vendor/sub": childMetadata], overlayEntries: ["/repo/tracked": .normal, "/repo/vendor/sub/changed": .modified])
        var settings = FinderOverlaySettings()
        var badges = settings.badges(snapshot: snapshot, volume: { _ in .fixed }, isDirectory: { _ in false })
        XCTAssertEqual(badges["/repo"], .normal); XCTAssertEqual(badges["/repo/vendor/sub"], .modified)
        settings.recurseSubmodules = true
        badges = settings.badges(snapshot: snapshot, volume: { _ in .fixed }, isDirectory: { _ in false })
        XCTAssertEqual(badges["/repo"], .modified)
        settings.cacheMode = .none
        badges = settings.badges(snapshot: snapshot, volume: { _ in .fixed }, isDirectory: { _ in false })
        XCTAssertEqual(badges["/repo"], .normal); XCTAssertNil(badges["/repo/vendor/sub/changed"])
    }
    func testOverlaySettingsAndLeafSnapshotRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), file = root.appendingPathComponent("overlays.json")
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = FinderOverlaySettings(); settings.hiddenStates = [.added]; settings.volumes = [.fixed, .network]; settings.includePaths = "/repo*\n"
        XCTAssertTrue(try settings.write(to: file)); XCTAssertEqual(FinderOverlaySettings.read(from: file), settings)
        let snapshot = FinderSnapshot(roots: ["/repo"], states: ["/repo": .normal], overlayEntries: ["/repo/a": .normal])
        let decoded = try JSONDecoder().decode(FinderSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.overlayEntries, snapshot.overlayEntries)
    }
}
