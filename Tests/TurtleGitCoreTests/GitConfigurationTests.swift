// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class GitConfigurationTests: XCTestCase {
    func testLocalRoundTripAndInheritedIncludeSurvivesClearingOverrides() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let include = root.appendingPathComponent("identity.config")
        try Data("[user]\nname = inherited\nemail = inherited@example.invalid\n[fetch]\nprune = true\n".utf8).write(to: include)
        _ = try await repo.run(["config", "--local", "include.path", include.path])
        var settings = GitConfigurationSettings()
        settings.name = .init(value: "Turtle 雪", inherit: false)
        settings.email = .init(value: "turtle@example.invalid", inherit: false)
        settings.signingKey = .init(value: "key with spaces", inherit: false)
        settings.quotePath = .disabled; settings.prune = .disabled
        settings.autoCRLF = "input"; settings.safeCRLF = "warn"
        try await repo.saveGitConfiguration(settings, destination: .local)
        let actual = try await repo.gitConfiguration(source: .local)
        // The fixture's existing identity section precedes include.path, so
        // Git correctly lets the later included identity win when reading.
        var expected = settings
        expected.name = .init(value: "inherited", inherit: false)
        expected.email = .init(value: "inherited@example.invalid", inherit: false)
        XCTAssertEqual(actual, expected)
        let stored = try await repo.run(["config", "--local", "--no-includes", "--get", "user.name"])
        XCTAssertEqual(stored.text, "Turtle 雪\n")
        let includeBytes = try Data(contentsOf: include)
        try await repo.saveGitConfiguration(GitConfigurationSettings(), destination: .local)
        let inherited = try await repo.gitConfiguration(source: .local)
        XCTAssertEqual(inherited.name.value, "inherited")
        XCTAssertEqual(inherited.prune, .enabled)
        XCTAssertEqual(inherited.quotePath, .inherit)
        XCTAssertEqual(try Data(contentsOf: include), includeBytes)
        let missing = try await repo.run(["config", "--local", "--no-includes", "--get", "user.name"], successfulExitCodes: 0...1)
        XCTAssertEqual(missing.exitCode, 1)
    }

    func testBooleanNormalizationAndRepeatedValuesAreReplaced() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for (key, value) in [("core.quotepath", "yes"), ("fetch.prune", "0"), ("core.autocrlf", "INPUT"), ("core.safecrlf", "WARN")] {
            _ = try await repo.run(["config", "--local", key, value])
        }
        var settings = try await repo.gitConfiguration(source: .local)
        XCTAssertEqual(settings.quotePath, .enabled); XCTAssertEqual(settings.prune, .disabled)
        XCTAssertEqual(settings.autoCRLF, "input"); XCTAssertEqual(settings.safeCRLF, "warn")
        _ = try await repo.run(["config", "--local", "--add", "user.name", "duplicate"])
        settings.name = .init(value: "one", inherit: false)
        try await repo.saveGitConfiguration(settings, destination: .local)
        let names = try await repo.run(["config", "--local", "--get-all", "user.name"])
        XCTAssertEqual(names.text, "one\n")
    }

    func testInvalidAndCancelledSaveDoNotAlterRepositoryConfiguration() async throws {
        let (root, repo) = try await ReferenceBrowserTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".git/config")
        let before = try Data(contentsOf: config)
        var settings = GitConfigurationSettings(); settings.name = .init(value: "new", inherit: false)
        for destination in [GitConfigurationSource.effective, .system] {
            do { try await repo.saveGitConfiguration(settings, destination: destination); XCTFail("Read-only destination saved") }
            catch GitConfigurationFailure.destination {}
        }
        settings.safeCRLF = "invalid"
        do { try await repo.saveGitConfiguration(settings, destination: .local); XCTFail("Invalid value saved") }
        catch GitConfigurationFailure.invalidValue {}
        settings.safeCRLF = ""; settings.name.value = "bad\0name"
        do { try await repo.saveGitConfiguration(settings, destination: .local); XCTFail("NUL value saved") }
        catch GitConfigurationFailure.invalidValue {}
        settings.name.value = "new"
        let token = OperationCancellation(); token.cancel()
        do { try await repo.saveGitConfiguration(settings, destination: .local, cancellation: token); XCTFail("Cancelled save ran") }
        catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(try Data(contentsOf: config), before)
    }
}
