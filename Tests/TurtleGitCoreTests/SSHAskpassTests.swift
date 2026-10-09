// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class SSHAskpassTests: XCTestCase {
    func helper(in root: URL) throws -> URL {
        if let supplied = ProcessInfo.processInfo.environment["TURTLEGIT_QA_ASKPASS"] { return URL(fileURLWithPath: supplied) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/TurtleGitSSHAskpass/main.swift")
        let executable = root.appendingPathComponent("askpass")
        let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); compile.arguments = ["swiftc",source.path,"-o",executable.path]; compile.standardOutput = FileHandle.nullDevice
        try compile.run(); compile.waitUntilExit(); guard compile.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
        return executable
    }
    func run(_ helper: URL, file: URL, root: URL) throws -> (Int32, Data, Data) {
        let stdout = root.appendingPathComponent(UUID().uuidString), stderr = root.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: stdout.path, contents: nil); FileManager.default.createFile(atPath: stderr.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: stdout); try? FileManager.default.removeItem(at: stderr) }
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr); defer { try? out.close(); try? err.close() }
        let process = Process(); process.executableURL = helper; process.environment = ["TURTLEGIT_SSH_CREDENTIAL_FILE":file.path]; process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        try process.run(); process.waitUntilExit(); return (process.terminationStatus, try Data(contentsOf: stdout), try Data(contentsOf: stderr))
    }
    func testOneUseHelperLiteralUTF8AndMalformedFileRefusal() throws {
        let root = try SSHAgentSessionTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let helper = try helper(in: root), directory = root.appendingPathComponent("tg-agent-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        let file = directory.appendingPathComponent("credential-fixture"), magic = Data("TurtleGitSSHAskpass\0".utf8), value = Data("fixture ' $() Cafe\u{301} ☃".utf8)
        try (magic + value).write(to: file); try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: file.path)
        let accepted = try run(helper,file:file,root:root); XCTAssertEqual(accepted.0,0); XCTAssertTrue(accepted.1 == value + Data([10])); XCTAssertTrue(accepted.2.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        let twice = try run(helper,file:file,root:root); XCTAssertNotEqual(twice.0,0); XCTAssertTrue(twice.1.isEmpty && twice.2.isEmpty)
        for body in [Data("not-an-envelope".utf8), magic + Data("invalid\nline".utf8), magic + Data([0xff])] {
            try body.write(to:file); try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:file.path)
            let refusal = try run(helper,file:file,root:root); XCTAssertNotEqual(refusal.0,0); XCTAssertTrue(refusal.1.isEmpty && refusal.2.isEmpty); XCTAssertEqual(try Data(contentsOf:file),body)
        }
        try (magic + value).write(to:file); try FileManager.default.setAttributes([.posixPermissions:0o644], ofItemAtPath:file.path)
        let worldReadable = try run(helper,file:file,root:root); XCTAssertNotEqual(worldReadable.0,0); XCTAssertTrue(worldReadable.1.isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        try FileManager.default.removeItem(at:file); let target = root.appendingPathComponent("target"); try (magic + value).write(to:target); try FileManager.default.createSymbolicLink(at:file, withDestinationURL:target)
        let symlink = try run(helper,file:file,root:root); XCTAssertNotEqual(symlink.0,0); XCTAssertTrue(symlink.1.isEmpty && symlink.2.isEmpty); XCTAssertEqual(try Data(contentsOf:target),magic + value)
    }
    func testRealEncryptedIdentityCorrectWrongAndNoCredentialResidue() throws {
        let root = try SSHAgentSessionTests().fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let helper = try helper(in:root), key = root.appendingPathComponent("encrypted"), phrase = "fixture passphrase ' ☃"
        try SSHAgentSessionTests().command("/usr/bin/ssh-keygen", ["-q","-t","ed25519","-N",phrase,"-C","encrypted-fixture","-f",key.path])
        let runtime = SSHAgentRuntime(agent:URL(fileURLWithPath:"/usr/bin/ssh-agent"),add:URL(fileURLWithPath:"/usr/bin/ssh-add"),askpass:helper)
        let session = try SSHAgentSession(runtime:runtime,temporaryRoot:root); defer { session.close() }
        XCTAssertThrowsError(try session.add(keys:[key],passphrase:"wrong fixture response"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:session.directory.path).contains { $0.hasPrefix("credential-") })
        try session.add(keys:[key],passphrase:phrase); let identities = try session.publicIdentities(); XCTAssertTrue(identities.contains("encrypted-fixture"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:session.directory.path).contains { $0.hasPrefix("credential-") })
        for invalid in ["invalid\nline","invalid\0value",String(repeating:"x",count:65_536)] { XCTAssertThrowsError(try session.add(keys:[key],passphrase:invalid)) }
        let cancelled = OperationCancellation(); cancelled.cancel(); XCTAssertThrowsError(try session.add(keys:[key],passphrase:phrase,cancellation:cancelled))
        XCTAssertEqual(try session.publicIdentities(),identities)
        let files = try FileManager.default.contentsOfDirectory(at:session.directory,includingPropertiesForKeys:nil)
        for file in files where file.lastPathComponent != "s" { let bytes = try Data(contentsOf:file); XCTAssertFalse(bytes.range(of:Data(phrase.utf8)) != nil) }
    }
    func testForcedCloseDuringCredentialLoadingRemovesEnvelopeAndChildren() async throws {
        let root = try SSHAgentSessionTests().fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let askpass = try helper(in:root), slow = root.appendingPathComponent("slow-add"), marker = URL(fileURLWithPath:slow.path+".started")
        let script = """
        #!/bin/sh
        /bin/sleep 30 &
        task_child=$!
        trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
        printf '%s %s\\n' "$$" "$task_child" > "$0.started"
        wait "$task_child"
        exec /usr/bin/ssh-add "$@"
        """
        try Data(script.utf8).write(to:slow); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:slow.path)
        let session = try SSHAgentSession(runtime:SSHAgentRuntime(agent:URL(fileURLWithPath:"/usr/bin/ssh-agent"),add:slow,askpass:askpass),temporaryRoot:root); defer { session.close() }
        let task = Task.detached { Result { try session.add(keys:[root.appendingPathComponent("fixture-key")],passphrase:"pending fixture response") } }
        for _ in 0..<500 { if FileManager.default.fileExists(atPath:marker.path) { break }; try await Task.sleep(nanoseconds:10_000_000) }
        let ids = try String(contentsOf:marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
        XCTAssertEqual(ids.count,2); XCTAssertTrue(ids.allSatisfy { kill($0,0)==0 })
        let envelope = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at:session.directory,includingPropertiesForKeys:nil).first { $0.lastPathComponent.hasPrefix("credential-") })
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:envelope.path)[.posixPermissions] as? Int,0o600)
        session.close(); let result = await task.value
        if case .success = result { XCTFail("Forced-close credential load succeeded") }
        XCTAssertTrue(ids.allSatisfy { kill($0,0) != 0 }); XCTAssertFalse(FileManager.default.fileExists(atPath:envelope.path)); XCTAssertFalse(FileManager.default.fileExists(atPath:session.directory.path))
    }

}
