import XCTest
@testable import TurtleGitCore

final class GitAskpassTests: XCTestCase {
    func testSSHModeHintsAndUTF8ReadBoundary() {
        let password = GitAskpassPrompt("user@host's password:", ssh: true)
        XCTAssertTrue(password.secret)
        XCTAssertTrue(password.accepts(String(repeating: "x", count: 1023)))
        XCTAssertFalse(password.accepts(String(repeating: "x", count: 1024)))
        XCTAssertTrue(password.accepts(String(repeating: "雪", count: 341)))
        XCTAssertFalse(password.accepts(String(repeating: "雪", count: 342)))
        for text in ["Are you sure you want to continue connecting (yes/no/[fingerprint])?", "Please type 'yes', 'no' or the fingerprint: "] {
            let prompt = GitAskpassPrompt(text, ssh: true)
            XCTAssertTrue(prompt.confirmation); XCTAssertFalse(prompt.secret)
        }
        XCTAssertTrue(GitAskpassPrompt("Permit key use?", ssh: true, hint: "confirm").confirmation)
        let notice = GitAskpassPrompt("Confirm user presence", ssh: true, hint: "none")
        XCTAssertTrue(notice.notification); XCTAssertFalse(notice.secret); XCTAssertFalse(notice.confirmation)
        XCTAssertFalse(GitAskpassPrompt("Permit key use?", hint: "confirm").confirmation)
    }
    func testSSHAliasAndCallerPolicyPrecedence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit SSH alias ' " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("TurtleGitGitAskpass")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        XCTAssertTrue(GitAskpassRuntime.sshEnvironment(arguments: ["fetch"], environment: [:], helper: helper).isEmpty)
        let alias = root.appendingPathComponent("TurtleGitOpenSSHAskpass")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: helper.lastPathComponent)
        XCTAssertEqual(GitAskpassRuntime.sshEnvironment(arguments: ["fetch"], environment: [:], helper: helper), ["SSH_ASKPASS": alias.path, "SSH_ASKPASS_REQUIRE": "force"])
        for policy in [["SSH_ASKPASS": "private-agent-helper"], ["SSH_ASKPASS": ""], ["SSH_ASKPASS_REQUIRE": "never"], ["TURTLEGIT_DISABLE_ASKPASS": "1"]] {
            XCTAssertTrue(GitAskpassRuntime.sshEnvironment(arguments: ["push"], environment: policy, helper: helper).isEmpty)
        }
        XCTAssertEqual(GitAskpassRuntime.sshEnvironment(arguments: ["fetch"], environment: ["SSH_ASKPASS_REQUIRE": "prefer"], helper: helper), ["SSH_ASKPASS": alias.path])
        XCTAssertTrue(GitAskpassRuntime.sshEnvironment(arguments: ["show", "--", "fetch"], environment: [:], helper: helper).isEmpty)
    }
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
