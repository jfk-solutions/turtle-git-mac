// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class RemoteSettingsTests: XCTestCase {
    func testRawConfigurationChangedFieldsAndTriState() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var settings = RemoteSettings(name: "team/nested"); settings.url = "alias:repository"; settings.pushURL = "C:\\push\\repository"; settings.tags = .all; settings.prune = .enabled; settings.pushDefault = true; settings.puttyKeyFile = "C:\\identity.ppk"
        _ = try await repo.run(["config", "url./expanded/.insteadOf", "alias:"])
        try await repo.applyRemoteSettings(settings, changed: .all)
        let read = try await repo.remoteSettings(name: settings.name)
        XCTAssertEqual(read.url, "alias:repository"); XCTAssertEqual(read.pushURL, "C:/push/repository"); XCTAssertEqual(read.puttyKeyFile, settings.puttyKeyFile); XCTAssertEqual(read.tags, .all); XCTAssertEqual(read.prune, .enabled); XCTAssertTrue(read.pushDefault)
        let expanded = try await repo.remoteURLs(name: settings.name); XCTAssertEqual(expanded.fetch, "/expanded/repository")
        _ = try await repo.run(["config", "--add", "remote.team/nested.fetch", "+refs/tags/*:refs/tags/*"])
        let mappings = try await repo.run(["config", "--get-all", "remote.team/nested.fetch"]).stdout
        settings.url = "should-not-be-written"; settings.puttyKeyFile = ""; settings.prune = .disabled
        try await repo.applyRemoteSettings(settings, changed: [.prune])
        let disabled = try await repo.remoteSettings(name: settings.name); XCTAssertEqual(disabled.prune, .disabled); XCTAssertEqual(disabled.url, read.url); XCTAssertEqual(disabled.puttyKeyFile, read.puttyKeyFile)
        settings.prune = .configured; settings.tags = .reachable; settings.pushDefault = false
        try await repo.applyRemoteSettings(settings, changed: [.prune, .tags, .pushDefault, .puttyKeyFile])
        let cleared = try await repo.remoteSettings(name: settings.name); XCTAssertEqual(cleared.prune, .configured); XCTAssertEqual(cleared.tags, .reachable); XCTAssertFalse(cleared.pushDefault); XCTAssertEqual(cleared.puttyKeyFile, "")
        let after = try await repo.run(["config", "--get-all", "remote.team/nested.fetch"]).stdout; XCTAssertEqual(after, mappings)
        _ = try await repo.run(["config", "remote.team/nested.prune", "yes"])
        let nonLiteral = try await repo.remoteSettings(name: settings.name); XCTAssertEqual(nonLiteral.prune, .configured, "Source recognizes literal true/false only")
    }
    func testInheritedUnsetAndMultipleValuesFailWithoutRollback() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["remote", "add", "origin", "old"])
        let include = root.appendingPathComponent("inherited.config"); try Data("[remote \"origin\"]\n\tprune = true\n".utf8).write(to: include)
        _ = try await repo.run(["config", "include.path", include.path]); _ = try await repo.run(["config", "remote.origin.prune", "false"])
        var settings = RemoteSettings(name: "origin"); settings.url = "new"; settings.prune = .configured
        do { try await repo.applyRemoteSettings(settings, changed: [.url, .prune]); XCTFail("Inherited clear silently succeeded") }
        catch RemoteSettingsFailure.inheritedValue(let key, let value) { XCTAssertEqual(key, "remote.origin.prune"); XCTAssertEqual(value, "") }
        let partial = try await repo.remoteSettings(name: "origin"); XCTAssertEqual(partial.url, "new"); XCTAssertEqual(partial.prune, .enabled)
        _ = try await repo.run(["config", "--add", "remote.origin.url", "second"])
        let before = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        do { try await repo.applyRemoteSettings(settings, changed: [.url]); XCTFail("Multiple URLs overwritten") } catch is GitFailure {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/config")), before)
        _ = try await repo.run(["config", "remote.pushdefault", "other"])
        try await repo.applyRemoteSettings(settings, changed: [.pushDefault])
        let pushDefault = try await repo.run(["config", "--get", "remote.pushdefault"]).text; XCTAssertEqual(pushDefault, "other\n")
    }
    func testCollisionBoundaryOwnMappingAndSVN() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repo.run(["remote", "add", "team", root.path])
        let own = try await repo.remoteNameCollidesWithRefspec("team"); XCTAssertFalse(own)
        _ = try await repo.run(["config", "remote.other.fetch", "+refs/heads/*:refs/remotes/team-extra/*"])
        let boundary = try await repo.remoteNameCollidesWithRefspec("team"); XCTAssertFalse(boundary)
        _ = try await repo.run(["config", "svn-remote.bridge.branches", "branches/*:refs/remotes/team/*"])
        let svn = try await repo.remoteNameCollidesWithRefspec("team"); XCTAssertTrue(svn)
        _ = try await repo.run(["config", "--unset", "svn-remote.bridge.branches"])
        _ = try await repo.run(["config", "remote.other.fetch", "+refs/heads/main:refs/remotes/team"])
        let exact = try await repo.remoteNameCollidesWithRefspec("team"); XCTAssertTrue(exact)
        _ = try await repo.run(["config", "remote.other.fetch", "+refs/heads/*:refs/remotes/Caf\u{e9}/*"], cancellation: OperationCancellation())
        let decomposed = try await repo.remoteNameCollidesWithRefspec("Cafe\u{301}"); XCTAssertFalse(decomposed)
        let composed = try await repo.remoteNameCollidesWithRefspec("Caf\u{e9}"); XCTAssertTrue(composed)
    }
    func testRenameRemoveCancellationAndExplicitOverwrite() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var settings = RemoteSettings(name: "origin"); settings.url = root.path
        try await repo.applyRemoteSettings(settings, changed: .all)
        _ = try await repo.run(["fetch", "origin"]); _ = try await repo.run(["config", "branch.main.remote", "origin"]); _ = try await repo.run(["config", "branch.main.merge", "refs/heads/main"])
        let before = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        do { try await repo.applyRemoteSettings(settings, changed: .all); XCTFail("Existing remote implicitly overwritten") } catch is GitFailure {}
        XCTAssertEqual(before, try Data(contentsOf: root.appendingPathComponent(".git/config")))
        settings.tags = .none; try await repo.applyRemoteSettings(settings, changed: RemoteSettingsFields.all.subtracting(.name))
        try await repo.renameRemote(from: "origin", to: "team/nested")
        let renamed = try await repo.remoteSettings(name: "team/nested"); XCTAssertEqual(renamed.tags, .none)
        let tracking = try await repo.run(["config", "--get", "branch.main.remote"]).text; XCTAssertEqual(tracking, "team/nested\n")
        _ = try await repo.run(["show-ref", "--verify", "refs/remotes/team/nested/main"])
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { try await repo.removeRemote(name: "team/nested", cancellation: cancelled); XCTFail("Cancelled removal ran") } catch OperationCancellationFailure.cancelled {}
        do { _ = try await repo.remoteSettings(name: "team/nested", cancellation: cancelled); XCTFail("Cancelled read ran") } catch OperationCancellationFailure.cancelled {}
        do { try await repo.renameRemote(from: "team/nested", to: "later", cancellation: cancelled); XCTFail("Cancelled rename ran") } catch OperationCancellationFailure.cancelled {}
        do { try await repo.applyRemoteSettings(settings, changed: [.tags], cancellation: cancelled); XCTFail("Cancelled apply ran") } catch OperationCancellationFailure.cancelled {}
        try await repo.removeRemote(name: "team/nested")
        let names = try await repo.remoteNames(); XCTAssertTrue(names.isEmpty)
        let ref = try await repo.run(["show-ref", "--verify", "--quiet", "refs/remotes/team/nested/main"], successfulExitCodes: 0...1); XCTAssertEqual(ref.exitCode, 1)
    }
}
