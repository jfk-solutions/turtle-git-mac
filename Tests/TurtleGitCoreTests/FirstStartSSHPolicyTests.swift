import Foundation
import XCTest
@testable import TurtleGitCore

final class FirstStartSSHPolicyTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-first-start-ssh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func client(_ root: URL, output: String) throws -> SSHClientPreferences {
        let file = root.appendingPathComponent("SSH client with spaces")
        try Data(("#!/bin/sh\nprintf '%s\\n' '" + output + "' >&2\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        var value = SSHClientPreferences(); value.path = file.path; return value
    }
    func testSavedClientAndAutomaticChoicePreserveUnrelatedSetupPreferences() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "TurtleGit.FirstStartSSH.Core." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set("private-helper", forKey: "fixture.credential"); prefs.set(false, forKey: "TurtleGit.FirstStartComplete")
        let selected = try client(root, output: "OpenSSH_fixture")
        XCTAssertEqual(try selected.version(cancellation: OperationCancellation()), "OpenSSH_fixture")
        try selected.save(to: prefs)
        XCTAssertEqual(SSHClientPreferences.load(from: prefs), selected)
        XCTAssertEqual(selected.environment(existing: [:])["GIT_SSH"], selected.path)
        XCTAssertTrue(selected.environment(existing: ["GIT_SSH_COMMAND": "repository-client"]).isEmpty)
        XCTAssertTrue(selected.environment(existing: [:], appStore: true).isEmpty)
        try SSHClientPreferences().save(to: prefs)
        XCTAssertTrue(SSHClientPreferences.load(from: prefs).path.isEmpty)
        XCTAssertEqual(prefs.string(forKey: "fixture.credential"), "private-helper")
        XCTAssertFalse(prefs.bool(forKey: "TurtleGit.FirstStartComplete"))
    }
    func testClientValidationRejectsNonOpenSSHAndCancelledInspection() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = try client(root, output: "unrelated executable")
        XCTAssertThrowsError(try selected.version(cancellation: OperationCancellation()))
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try selected.version(cancellation: token))
        var invalid = SSHClientPreferences(); invalid.path = root.path
        XCTAssertThrowsError(try invalid.version(cancellation: OperationCancellation()))
    }
}
