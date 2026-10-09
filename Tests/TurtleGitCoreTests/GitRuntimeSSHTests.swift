import Foundation
import XCTest
@testable import TurtleGitCore

final class GitRuntimeSSHTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tg-git-ssh-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func executable(_ path: URL, text: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    private func run(_ executable: URL, _ arguments: [String], environment: [String:String]) throws -> Int32 {
        let process = Process(); process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); return process.terminationStatus
    }
    func testAppStoreRequiresClientAlongsideBundledGit() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Fixture app.bundle")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":"org.turtlegit.fixture.ssh", "CFBundlePackageType":"BNDL"], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let git = url.appendingPathComponent("Contents/Helpers/Git/bin/git")
        try executable(git,text:"#!/bin/sh\nexit 0\n")
        let bundle = try XCTUnwrap(Bundle(url:url))
        XCTAssertThrowsError(try GitRuntime.executable(bundle:bundle,appStore:true)) { error in
            guard case GitRuntimeFailure.bundledSSHMissing = error else { return XCTFail("Unexpected failure: \(error)") }
        }
        XCTAssertEqual(try GitRuntime.executable(bundle:bundle,appStore:false),git)
        let ssh = url.appendingPathComponent("Contents/Helpers/OpenSSH/bin/ssh")
        try executable(ssh,text:"#!/bin/sh\nexit 0\n")
        XCTAssertEqual(try GitRuntime.executable(bundle:bundle,appStore:true),git)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:ssh.path)
        XCTAssertThrowsError(try GitRuntime.executable(bundle:bundle,appStore:true))
    }
    func testExternalGitEnvironmentRemainsUnchanged() {
        XCTAssertTrue(GitRuntime.environment(executable:URL(fileURLWithPath:"/usr/bin/git")).isEmpty)
    }
    func testMissingDevelopmentClientDoesNotAdvertiseSSHDirectory() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let git = root.appendingPathComponent("Git/bin/git")
        XCTAssertEqual(GitRuntime.environment(executable:git)["PATH"],git.deletingLastPathComponent().path+":/usr/bin:/bin:/usr/sbin:/sbin")
    }
    func testActualGitDefaultAndExplicitSSHPrecedenceWithoutNetwork() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let helpers = root.appendingPathComponent("Fixture app/Contents/Helpers")
        let git = helpers.appendingPathComponent("Git/bin/git")
        try FileManager.default.createDirectory(at:git.deletingLastPathComponent(),withIntermediateDirectories:true)
        let engine = ProcessInfo.processInfo.environment["TURTLEGIT_QA_GIT"] ?? "/usr/bin/git"
        try FileManager.default.createSymbolicLink(at:git,withDestinationURL:URL(fileURLWithPath:engine))
        let ssh = helpers.appendingPathComponent("OpenSSH/bin/ssh")
        let configured = root.appendingPathComponent("configured ssh"), override = root.appendingPathComponent("override ssh")
        for (path,name) in [(ssh,"bundled"),(configured,"configured"),(override,"override")] {
            try executable(path,text:"#!/bin/sh\nprintf '%s\\n' '\(name)' \"$SSH_AUTH_SOCK\" > \"$TG_SSH_TRACE\"\nexit 23\n")
        }
        let repo = root.appendingPathComponent("repository"), trace = root.appendingPathComponent("trace")
        try FileManager.default.createDirectory(at:repo,withIntermediateDirectories:false)
        var env = ["HOME":root.path,"PATH":"/usr/bin:/bin","LANG":"C","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_GLOBAL":"/dev/null","GIT_TERMINAL_PROMPT":"0", "TG_SSH_TRACE":trace.path,"SSH_AUTH_SOCK":root.appendingPathComponent("private fixture socket").path]
        XCTAssertEqual(try run(URL(fileURLWithPath:"/usr/bin/git"),["init","--quiet",repo.path],environment:env),0)
        env.merge(GitRuntime.environment(executable:git)) { _,runtime in runtime }
        XCTAssertNil(env["GIT_SSH_COMMAND"]); XCTAssertNil(env["GIT_SSH"])
        func transport(_ expected: String) throws {
            try? FileManager.default.removeItem(at:trace)
            XCTAssertEqual(try run(git,["-C",repo.path,"ls-remote","ssh://fixture.invalid/repository"],environment:env),128)
            XCTAssertEqual(try String(contentsOf:trace,encoding:.utf8),expected+"\n"+env["SSH_AUTH_SOCK"]!+"\n")
        }
        try transport("bundled")
        func quote(_ path: URL) -> String { "'"+path.path.replacingOccurrences(of:"'",with:"'\\''")+"'" }
        XCTAssertEqual(try run(git,["-C",repo.path,"config","core.sshCommand",quote(configured)],environment:env),0)
        try transport("configured")
        env["GIT_SSH_COMMAND"] = quote(override); try transport("override")
        env.removeValue(forKey:"GIT_SSH_COMMAND")
        XCTAssertEqual(try run(git,["-C",repo.path,"config","--unset","core.sshCommand"],environment:env),0)
        env["GIT_SSH"] = override.path; try transport("override")
    }
}
