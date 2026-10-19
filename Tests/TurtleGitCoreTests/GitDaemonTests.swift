import XCTest
import Darwin
@testable import TurtleGitCore

final class GitDaemonTests: XCTestCase {
    final class Output: @unchecked Sendable {
        private let lock = NSLock(); private var bytes = Data()
        func append(_ chunk: GitOutputChunk) { lock.lock(); defer { lock.unlock() }; bytes.append(chunk.data) }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
    }
    func port() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard got == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return (fd, UInt16(bigEndian: address.sin_port))
    }
    func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turtlegit-daemon-雪-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Daemon QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("served\n".utf8).write(to: root.appendingPathComponent("tracked")); try await repo.stage(["tracked"]); _ = try await repo.commit(message: "initial")
        return (root, repo)
    }
    func testConfigurationAndFinderParity() throws {
        var config = GitDaemonConfiguration()
        XCTAssertEqual(try config.arguments(root: URL(fileURLWithPath: "/repo 雪")), ["daemon", "--verbose", "--export-all", "--base-path=/repo 雪"])
        XCTAssertEqual(config.urls(addresses: ["::1", "127.0.0.1"]), ["git://[::1]/", "git://127.0.0.1/"])
        config.listenAddresses = ["127.0.0.1"]; config.port = 10001
        XCTAssertEqual(config.urls(), ["git://127.0.0.1:10001/"])
        XCTAssertTrue(try config.arguments(root: URL(fileURLWithPath: "/repo")).contains("--listen=127.0.0.1"))
        config.listenAddresses = ["--enable=receive-pack"]; XCTAssertThrowsError(try config.arguments(root: URL(fileURLWithPath: "/repo")))
        config.listenAddresses = []; config.port = 0; XCTAssertThrowsError(try config.arguments(root: URL(fileURLWithPath: "/repo")))
        XCTAssertFalse(RepositoryAction.daemon.requiresWorkingTree); XCTAssertEqual(RepositoryAction.daemon.icon, .daemon)
        XCTAssertTrue(FinderRepositoryMetadata(bare: true).allows(.daemon)); XCTAssertTrue(FinderMenuEntry.daemon.availableInFinder)
        XCTAssertTrue(FinderShellRules.allows(.daemon, flags: [.bare]))
        XCTAssertFalse(FinderShellRules.allows(.daemon, flags: [.inGit, .onlyOne, .added]))
        let request = FinderRequest(action: .daemon, paths: [URL(fileURLWithPath: "/repo 雪")])
        XCTAssertEqual(try XCTUnwrap(request.url.flatMap(FinderRequest.init(url:))).action, .daemon)
    }
    func testLoopbackCloneCancellationAndRepositoryPreservation() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).text
        let (fd, number) = try port(); close(fd)
        var config = GitDaemonConfiguration(); config.listenAddresses = ["127.0.0.1"]; config.port = number
        let output = Output(), token = OperationCancellation()
        let daemon = Task.detached { try GitDaemon.run(repository: repo, configuration: config, cancellation: token, onOutput: { output.append($0) }) }
        for _ in 0..<500 {
            if output.text.contains("Ready to rumble") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        var cloneError: Error?
        do {
            XCTAssertTrue(output.text.contains("Ready to rumble"), output.text)
            let clone = root.appendingPathComponent("clone")
            _ = try await repo.run(["clone", config.urls()[0], clone.path])
            XCTAssertEqual(try Data(contentsOf: clone.appendingPathComponent("tracked")), Data("served\n".utf8))
            let clonedHead = try await GitRepository(root: clone).run(["rev-parse", "HEAD"]).text
            XCTAssertEqual(clonedHead, head)
        } catch { cloneError = error }
        token.cancel(); _ = try await daemon.value
        if let cloneError { throw cloneError }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text
        XCTAssertEqual(afterHead, head)
        // The same port must be reusable immediately after owned cancellation.
        let secondToken = OperationCancellation(), secondOutput = Output()
        let again = Task.detached { try GitDaemon.run(repository: repo, configuration: config, cancellation: secondToken, onOutput: { secondOutput.append($0) }) }
        for _ in 0..<500 {
            if secondOutput.text.contains("Ready to rumble") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        secondToken.cancel(); _ = try await again.value
        XCTAssertTrue(secondOutput.text.contains("Ready to rumble"), secondOutput.text)
    }
    func testPortConflictAndPrecancelledStart() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (fd, number) = try port(); defer { close(fd) }
        var config = GitDaemonConfiguration(); config.listenAddresses = ["127.0.0.1"]; config.port = number
        let result = await Task.detached { Result { try GitDaemon.run(repository: repo, configuration: config, cancellation: OperationCancellation(), onOutput: { _ in }) } }.value
        if case .success = result { XCTFail("Occupied port must fail") }
        let token = OperationCancellation(); token.cancel()
        XCTAssertThrowsError(try GitDaemon.run(repository: repo, configuration: config, cancellation: token, onOutput: { _ in XCTFail("Precancelled command produced output") }))
    }
    func testWorkerCleanupAfterNaturalExitAndCancellation() async throws {
        let (root, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent(".git/daemon-wrapper")
        let pidFile = root.appendingPathComponent(".git/worker-pid")
        for naturalExit in [true, false] {
            // A helper remains in the owned group even if its leader exits.
            // Publish readiness only after the complete PID has been written.
            // File existence alone can observe shell redirection's empty file.
            let temporaryPID = root.appendingPathComponent(".git/worker-pid-" + UUID().uuidString)
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
            defer { try? FileManager.default.removeItem(at: temporaryPID); try? FileManager.default.removeItem(at: pidFile) }
            let script = "#!/bin/sh\n/bin/sleep 60 &\nworker=$!\nprintf '%s\\n' \"$worker\" > " + quote(temporaryPID.path) + " && /bin/mv " + quote(temporaryPID.path) + " " + quote(pidFile.path) + "\n" + (naturalExit ? "exit 7\n" : "wait\n")
            try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            let repo = GitRepository(root: root, executable: wrapper), token = OperationCancellation()
            let output = Output()
            let run = Task.detached { Result { try GitDaemon.run(repository: repo, cancellation: token, onOutput: output.append) } }
            var workerPID: Int32?, readinessError: Error?
            do {
                for _ in 0..<100 {
                    if let text = try? String(contentsOf: pidFile), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                        workerPID = pid; break
                    }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard workerPID != nil else {
                    throw NSError(domain: "GitDaemonTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "The owned daemon did not publish a complete worker PID.\n" + output.text])
                }
            } catch {
                readinessError = error
                token.cancel()
            }
            if !naturalExit { token.cancel() }
            // Even a readiness/Task cancellation failure must retire the actual
            // process group before this test releases its repository and files.
            let result = await run.value
            if let readinessError { throw readinessError }
            let pid = try XCTUnwrap(workerPID)
            if naturalExit, case .success = result { XCTFail("Nonzero natural exit must report failure") }
            // macOS may retain a killed orphan briefly until launchd reaps it.
            for _ in 0..<100 {
                if kill(pid, 0) != 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNotEqual(kill(pid, 0), 0, "Daemon worker survived its owner")
        }
    }
}
