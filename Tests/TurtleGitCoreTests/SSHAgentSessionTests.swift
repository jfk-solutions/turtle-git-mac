// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class SSHAgentSessionTests: XCTestCase {
    func command(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tg-ssh-qa-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return root
    }
    func testActualPrivateAgentMultipleIdentitiesLiteralPathsAndCleanup() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("agent")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$0.pid\"\nexec /usr/bin/ssh-agent \"$@\"\n".utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let runtime = SSHAgentRuntime(agent: helper, add: URL(fileURLWithPath: "/usr/bin/ssh-add"))
        let first = root.appendingPathComponent("key ' ; $(touch sentinel)"), second = root.appendingPathComponent("second")
        for (key, comment) in [(first,"first"),(second,"second")] { try command("/usr/bin/ssh-keygen", ["-q","-t","ed25519","-N","","-C",comment,"-f",key.path]) }
        let agent = try SSHAgentSession(runtime: runtime, temporaryRoot: root); defer { agent.close() }
        let pid = try XCTUnwrap(Int32(String(contentsOf: URL(fileURLWithPath: helper.path + ".pid")).trimmingCharacters(in: .newlines)))
        XCTAssertEqual(kill(pid,0), 0); XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: agent.directory.path)[.posixPermissions] as? Int, 0o700)
        let empty = try agent.publicIdentities(); XCTAssertTrue(empty.contains("no identities"))
        try agent.add(keys: [first,second]); let identities = try agent.publicIdentities()
        XCTAssertTrue(identities.contains("first")); XCTAssertTrue(identities.contains("second")); XCTAssertEqual(identities.split(separator: "\n").count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sentinel").path))
        agent.close(); XCTAssertNotEqual(kill(pid,0), 0); XCTAssertFalse(FileManager.default.fileExists(atPath: agent.directory.path))
        XCTAssertThrowsError(try agent.publicIdentities())
    }
    func testStartupFailurePreCancellationAndDeinitReap() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SSHAgentRuntime(agent: URL(fileURLWithPath: "/usr/bin/ssh-agent"), add: URL(fileURLWithPath: "/usr/bin/ssh-add"))
        let cancelled = OperationCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try SSHAgentSession(runtime: runtime, temporaryRoot: root, cancellation: cancelled))
        XCTAssertThrowsError(try SSHAgentSession(runtime: SSHAgentRuntime(agent: root.appendingPathComponent("missing"), add: runtime.add), temporaryRoot: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        var session: SSHAgentSession? = try SSHAgentSession(runtime: runtime, temporaryRoot: root)
        let directory = try XCTUnwrap(session?.directory); session = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertThrowsError(try SSHAgentRuntime.resolve(appStore: true))
    }
    func testEncryptedFailureKeepsEarlierKeyAndCancellation() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = SSHAgentRuntime(agent: URL(fileURLWithPath: "/usr/bin/ssh-agent"), add: URL(fileURLWithPath: "/usr/bin/ssh-add"))
        let plain = root.appendingPathComponent("plain"), encrypted = root.appendingPathComponent("encrypted")
        try command("/usr/bin/ssh-keygen", ["-q","-t","ed25519","-N","","-C","plain","-f",plain.path]); try command("/usr/bin/ssh-keygen", ["-q","-t","ed25519","-N","fixture-passphrase","-C","encrypted","-f",encrypted.path])
        let agent = try SSHAgentSession(runtime: runtime, temporaryRoot: root); defer { agent.close() }
        XCTAssertThrowsError(try agent.add(keys: [plain,encrypted])); let identities = try agent.publicIdentities(); XCTAssertTrue(identities.contains("plain")); XCTAssertFalse(identities.contains("encrypted"))
        let cancelled = OperationCancellation(); cancelled.cancel(); XCTAssertThrowsError(try agent.add(keys: [encrypted], cancellation: cancelled))
        XCTAssertEqual(try agent.publicIdentities(), identities)
    }
    func testCloseDuringLiveKeyLoadingReapsHelperGroup() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("slow-add"), marker = URL(fileURLWithPath: helper.path + ".started")
        let script = """
        #!/bin/sh
        /bin/sleep 30 &
        task_child=$!
        trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
        printf '%s %s\\n' "$$" "$task_child" > "$0.started.pending"
        /bin/mv "$0.started.pending" "$0.started"
        wait "$task_child"
        exec /usr/bin/ssh-add "$@"
        """
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let runtime = SSHAgentRuntime(agent: URL(fileURLWithPath: "/usr/bin/ssh-agent"), add: helper)
        let agent = try SSHAgentSession(runtime: runtime, temporaryRoot: root); defer { agent.close() }
        let load = Task.detached { Result { try agent.add(keys: [root.appendingPathComponent("not-loaded")]) } }
        for _ in 0..<500 { if FileManager.default.fileExists(atPath: marker.path) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let ids = try String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
        XCTAssertEqual(ids.count,2); XCTAssertTrue(ids.allSatisfy { kill($0,0)==0 })
        agent.close(); let result = await load.value
        if case .success = result { XCTFail("Closed key loader succeeded") }
        XCTAssertTrue(ids.allSatisfy { kill($0,0) != 0 }); XCTAssertFalse(FileManager.default.fileExists(atPath: agent.directory.path))
    }

}

extension SSHAgentSessionTests {
    func testSocketReadinessRefusesRegularFileAndReapsWorker() throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("not-a-socket")
        let script="""
        #!/bin/sh
        printf '%s\\n' "$$" > "$0.pid.pending"
        /bin/mv "$0.pid.pending" "$0.pid"
        : > "$3"
        exec /bin/sleep 30
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        XCTAssertThrowsError(try SSHAgentSession(runtime:.init(agent:helper,add:URL(fileURLWithPath:"/usr/bin/ssh-add")),temporaryRoot:root))
        let pid=try XCTUnwrap(Int32(String(contentsOf:URL(fileURLWithPath:helper.path+".pid")).trimmingCharacters(in:.whitespacesAndNewlines)))
        XCTAssertNotEqual(kill(pid,0),0)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix("tg-agent-")})
    }
    func testConcurrentCloseWaitsForSharedCredentialWorkerDrain() async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("close-add"),marker=URL(fileURLWithPath:helper.path+".started")
        let script="""
        #!/bin/sh
        /bin/sleep 30 &
        task_child=$!
        trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
        printf '%s %s\\n' "$$" "$task_child" > "$0.started.pending"
        /bin/mv "$0.started.pending" "$0.started"
        wait "$task_child"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let session=try SSHAgentSession(runtime:.init(agent:URL(fileURLWithPath:"/usr/bin/ssh-agent"),add:helper),temporaryRoot:root)
        defer{session.close()};XCTAssertTrue(session.isRunning)
        let add=Task.detached {Result {try session.add(keys:[root.appendingPathComponent("fixture-key")])}}
        for _ in 0..<500 {if FileManager.default.fileExists(atPath:marker.path){break};try await Task.sleep(nanoseconds:10_000_000)}
        let ids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        XCTAssertEqual(ids.count,2)
        let closes=(0..<8).map {_ in Task.detached {session.close();return !FileManager.default.fileExists(atPath:session.directory.path) && ids.allSatisfy{kill($0,0) != 0}}}
        for close in closes {let drained=await close.value;XCTAssertTrue(drained,"Close returned before shared worker cleanup")}
        if case .success = await add.value {XCTFail("Closed loader succeeded")}
        XCTAssertFalse(session.isRunning)
    }
    func testSuccessfulLoaderExitStopsItsRemainingOwnedChild() async throws {
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("early-exit-add"),marker=URL(fileURLWithPath:helper.path+".started")
        let script="""
        #!/bin/sh
        /bin/sleep 30 &
        printf '%s %s\\n' "$$" "$!" > "$0.started.pending"
        /bin/mv "$0.started.pending" "$0.started"
        exit 0
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let session=try SSHAgentSession(runtime:.init(agent:URL(fileURLWithPath:"/usr/bin/ssh-agent"),add:helper),temporaryRoot:root);defer{session.close()}
        try session.add(keys:[root.appendingPathComponent("fixture-key")])
        let ids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        XCTAssertEqual(ids.count,2);guard ids.count==2 else {return}
        defer {if getpgid(ids[1])==ids[0] {kill(ids[1],SIGKILL)}}
        for _ in 0..<500 {if kill(ids[1],0) != 0 {break};try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertNotEqual(kill(ids[1],0),0);XCTAssertTrue(session.isRunning)
    }
}
