// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class GeneralSetupBatchTests: XCTestCase {
    func fixture(_ contents: String) throws -> (URL, URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("global.config"), executable = root.appendingPathComponent("git")
        try Data(contents.utf8).write(to: config)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let script = "#!/bin/sh\nunset GIT_CONFIG_COUNT GIT_CONFIG_SYSTEM GIT_CONFIG\nexport GIT_CONFIG_NOSYSTEM=1\nexport GIT_CONFIG_GLOBAL=" + quote(config.path) + "\nexport HOME=" + quote(root.path) + "\nexport XDG_CONFIG_HOME=" + quote(root.path) + "\nexec /usr/bin/git \"$@\"\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, config, GitRepository(root: root, executable: executable))
    }

    func testWizardIdentityPreservesIncludesAndCredentials() async throws {
        let (root, _, repo) = try fixture("[include]\npath = included.config\n[user]\nname = old\nemail = old@example.invalid\n[credential]\nhelper = !custom helper\n[credential \"https://example.invalid\"]\nhelper = scoped-helper\n[fetch]\nprune = true\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let included = root.appendingPathComponent("included.config")
        let bytes = Data("[user]\nsigningKey = signing-key\n".utf8); try bytes.write(to: included)
        try await repo.saveFirstStartIdentity(name: "  Turtle 雪  ", email: " turtle@example.invalid \n")
        let configuration = try await repo.firstStartConfiguration()
        XCTAssertEqual(configuration.name, "Turtle 雪"); XCTAssertEqual(configuration.email, "turtle@example.invalid")
        XCTAssertTrue(configuration.advancedCredentials); XCTAssertEqual(configuration.selectedHelper, "!custom helper")
        let scoped = try await repo.run(["config", "--get", "credential.https://example.invalid.helper"])
        let signing = try await repo.run(["config", "--get", "user.signingKey"])
        let prune = try await repo.run(["config", "--get", "fetch.prune"])
        XCTAssertEqual(scoped.text, "scoped-helper\n"); XCTAssertEqual(signing.text, "signing-key\n"); XCTAssertEqual(prune.text, "true\n")
        XCTAssertEqual(try Data(contentsOf: included), bytes)
    }

    func testWizardValidationRunsBeforeEitherIdentityWrite() async throws {
        let (root, config, repo) = try fixture("[user]\nname = original\nemail = original@example.invalid\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: config)
        for (name, email) in [("replacement", "  "), ("bad\0name", "valid@example.invalid"), ("", "valid@example.invalid")] {
            do { try await repo.saveFirstStartIdentity(name: name, email: email); XCTFail("Invalid identity saved") }
            catch GitConfigurationFailure.invalidValue {}
        }
        XCTAssertEqual(try Data(contentsOf: config), before)
    }

    func testNoneOnlyRemovesUnscopedGlobalHelperAndIsIdempotent() async throws {
        let (root, _, repo) = try fixture("[credential]\nhelper = first\nhelper = second\n[credential \"https://example.invalid\"]\nhelper = scoped\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await repo.firstStartConfiguration(); XCTAssertTrue(original.advancedCredentials)
        try await repo.saveFirstStartCredentialHelper(""); try await repo.saveFirstStartCredentialHelper("")
        let missing = try await repo.run(["config", "--get-all", "credential.helper"], successfulExitCodes: 0...1)
        let scoped = try await repo.run(["config", "--get", "credential.https://example.invalid.helper"])
        XCTAssertEqual(missing.exitCode, 1); XCTAssertEqual(scoped.text, "scoped\n")
        try await repo.saveFirstStartCredentialHelper("osxkeychain")
        let selected = try await repo.run(["config", "--get-all", "credential.helper"])
        XCTAssertEqual(selected.text, "osxkeychain\n")
    }

    func testEngineSelectionPersistenceAndPATHIsolation() throws {
        let suite = "TurtleGit.SetupTest." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var draft = GitEnginePreferences(); draft.choice = .system; draft.extraPath = "/opt/git helpers:/opt/bin"
        try draft.save(to: preferences)
        XCTAssertEqual(GitEnginePreferences.load(from: preferences), draft)
        XCTAssertEqual(try GitRuntime.executable(preferences: preferences).path, "/usr/bin/git")
        let environment = GitRuntime.environment(executable: URL(fileURLWithPath: "/usr/bin/git"), preferences: preferences)
        XCTAssertTrue(environment["PATH"]!.hasPrefix("/usr/bin:/opt/git helpers:/opt/bin:"))
        XCTAssertEqual(GitRuntime.environment(executable: URL(fileURLWithPath: "/usr/bin/git"), preferences: preferences, appStore: true), [:])
        for invalid in ["relative", ":/absolute", "/absolute:", "/absolute::/second", "/bad\0path"] {
            draft.extraPath = invalid; XCTAssertFalse(draft.valid)
            XCTAssertThrowsError(try draft.save(to: preferences))
        }
        XCTAssertEqual(GitEnginePreferences.load(from: preferences).extraPath, "/opt/git helpers:/opt/bin")
    }

    func testVersionOrderingIncludesLargePrereleaseNumbers() throws {
        let versions = ["1.2.3-alpha", "1.2.3-alpha.1", "1.2.3-alpha.2", "1.2.3-alpha.10", "1.2.3-alpha.999999999999999999999999999999", "1.2.3-beta", "1.2.3", "1.2.3.1", "1.3.0"]
        let parsed = try versions.map { try XCTUnwrap(ReleaseVersion($0)) }
        XCTAssertEqual(parsed.sorted(), parsed)
        XCTAssertEqual(ReleaseVersion("v1.2.3+build.7"), ReleaseVersion("1.2.3.0"))
        for invalid in ["", "v", "1", "1..3", "1.2.3-", "1.2.3-alpha..1", "1.2.3-01", "1.2.3+", "1.2.3+x+y"] { XCTAssertNil(ReleaseVersion(invalid), invalid) }
    }

    func testReleaseFeedFiltersAndSortsAndRejectsUnexpectedLinks() throws {
        let repository = "jfk-solutions/turtle-git-mac"
        func release(_ tag: String, draft: Bool = false, preview: Bool = false, url: String? = nil) -> [String: Any] {
            ["tag_name": tag, "html_url": url ?? "https://github.com/\(repository)/releases/tag/\(tag)", "draft": draft, "prerelease": preview]
        }
        let data = try JSONSerialization.data(withJSONObject: [release("v1.0.0"), release("v3.0.0", draft: true), release("v2.0.0-rc.1", preview: true), release("v1.1.0")])
        XCTAssertEqual(try ReleaseUpdateFeed.releases(data, repository: repository, includePreview: false).map(\.tag), ["v1.1.0", "v1.0.0"])
        XCTAssertEqual(try ReleaseUpdateFeed.releases(data, repository: repository, includePreview: true).first?.tag, "v2.0.0-rc.1")
        for url in ["https://example.invalid/releases/tag/v4.0.0", "http://github.com/\(repository)/releases/tag/v4.0.0", "https://github.com/other/repo/releases/tag/v4.0.0"] {
            XCTAssertThrowsError(try ReleaseUpdateFeed.releases(JSONSerialization.data(withJSONObject: [release("v4.0.0", url: url)]), repository: repository, includePreview: true))
        }
    }
}
