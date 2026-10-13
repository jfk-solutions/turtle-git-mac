import XCTest
@testable import TurtleGitCore

final class GitAskpassTests: XCTestCase {
    func testPromptMaskingAndResponseBoundaries() {
        XCTAssertFalse(GitAskpassPrompt("Username for 'https://example.invalid': ").secret)
        for prompt in ["Password for 'https://user@example.invalid': ", "Token: ", "Unknown authentication response:"] { XCTAssertTrue(GitAskpassPrompt(prompt).secret) }
        XCTAssertTrue(GitAskpassPrompt.validResponse("雪 fixture response"))
        for value in ["bad\nvalue", "bad\rvalue", "bad\0value", String(repeating: "x", count: 65_536)] { XCTAssertFalse(GitAskpassPrompt.validResponse(value)) }
    }
    func testExplicitHelperConfigurationAndHeadlessPrecedence() {
        let helper = URL(fileURLWithPath: "/Applications/TurtleGit for Mac.app/helper")
        XCTAssertTrue(GitAskpassRuntime.shouldInstall(arguments: ["fetch", "origin"], environment: [:], helper: helper))
        XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments: ["status"], environment: [:], helper: helper))
        XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments: ["show", "--", "fetch"], environment: [:], helper: helper))
        XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments: ["fetch"], environment: ["GIT_ASKPASS": "custom"], helper: helper))
        XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments: ["fetch"], environment: ["TURTLEGIT_DISABLE_ASKPASS": "1"], helper: helper))
        XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments: ["-c", "core.askPass=custom", "fetch"], environment: [:], helper: helper))
    }
    func testHelperPathReceivesRealGitUsernameAndPasswordPrompts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitAskpass-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper with space ' quote")
        try Data("#!/bin/sh\ncase \"$1\" in Username*) printf '%s\\n' 'fixture-user';; *) printf '%s\\n' 'fixture-password';; esac\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let task = Process(), input = Pipe(), output = Pipe(), error = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git"); task.currentDirectoryURL = root
        task.arguments = ["-c", "credential.helper=", "credential", "fill"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_ASKPASS"] = GitAskpassRuntime.command(helper); environment["GIT_TERMINAL_PROMPT"] = "0"; environment["LC_ALL"] = "C"
        task.environment = environment; task.standardInput = input; task.standardOutput = output; task.standardError = error
        try task.run(); try input.fileHandleForWriting.write(contentsOf: Data("protocol=https\nhost=fixture.invalid\n\n".utf8)); try input.fileHandleForWriting.close()
        let response = output.fileHandleForReading.readDataToEndOfFile(); _ = error.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("username=fixture-user")); XCTAssertTrue(text.contains("password=fixture-password"))
    }
    func testRepositoryInstallsDefaultWithoutReplacingCoreAskpass() async throws {
        if ProcessInfo.processInfo.environment["GIT_ASKPASS"] != nil || ProcessInfo.processInfo.environment["TURTLEGIT_DISABLE_ASKPASS"] == "1" { throw XCTSkip("Explicit host askpass policy takes precedence.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitAskpassEnv-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("git-wrapper")
        try Data("#!/bin/sh\nfor arg in \"$@\"; do if [ \"$arg\" = config ]; then exec /usr/bin/git \"$@\"; fi; done\nprintf '%s\\n' \"${GIT_ASKPASS:-absent}\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let real = GitRepository(root: root, askpass: nil); _ = try await real.run(["init"])
        let repo = GitRepository(root: root, executable: script, askpass: script)
        let environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        var response = try await repo.run(["fetch"], environmentOverrides: environment).text
        XCTAssertEqual(response.trimmingCharacters(in: .newlines), GitAskpassRuntime.command(script))
        _ = try await real.run(["config", "core.askPass", "custom-helper"])
        response = try await repo.run(["fetch"], environmentOverrides: environment).text
        XCTAssertEqual(response.trimmingCharacters(in: .newlines), "absent")
    }
}
