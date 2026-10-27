import XCTest
import Darwin
@testable import TurtleGitCore

final class RawGitArgumentTests: XCTestCase {
    private func fixture() throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-byte-argv-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let helper = root.appendingPathComponent("private argument receiver")
        let script = """
        #!/bin/sh
        /usr/bin/printf '%s\\0' "$@"
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return (root, GitRepository(root: root, executable: helper, askpass: nil))
    }
    func testExactByteArgumentsRetainBoundariesAndOrdinaryUnicode() async throws {
        let (root, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = Data([0xFF, 0xFE]) + Data(" /literal\n'\" $() * [x] ".utf8)
        let unicode = "Cafe\u{301} 雪"
        let result = try await repository.run(["probe", "escaped caption", unicode, ""], argumentBytes: [1: raw])
        let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false).map { Data($0) }
        XCTAssertEqual(fields, [Data("--literal-pathspecs".utf8), Data("-C".utf8), Data(root.path.utf8), Data("probe".utf8), raw, Data(unicode.utf8), Data(), Data()])
        XCTAssertEqual(result.exitCode, 0)
    }
    func testByteArgumentsUseTheSameStreamingSpoolAndNoOutputRetention() async throws {
        let (root, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = Data([0x80, 0xFF, 0x0A, 0x09])
        var captured = Data()
        let result = try await repository.run(["probe", "display"], argumentBytes: [1: raw], literalPathspecs: false,
            cancellation: OperationCancellation(), retainStandardOutput: false,
            consumeOutput: { chunk in if case .stdout = chunk.stream { captured.append(chunk.data) } })
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(captured.split(separator: 0, omittingEmptySubsequences: false).map { Data($0) },
            [Data("--no-literal-pathspecs".utf8), Data("-C".utf8), Data(root.path.utf8), Data("probe".utf8), raw, Data()])
    }
    func testInvalidByteOverridesRefuseBeforeSpawn() async throws {
        let (root, repository) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for overrides in [[-1: Data([0xFF])], [2: Data([0xFF])], [0: Data([0xFF, 0, 0xFE])]] {
            do {
                _ = try await repository.run(["probe", "display"], argumentBytes: overrides)
                XCTFail("Invalid argument bytes were admitted")
            } catch let error as NSError {
                XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
                XCTAssertEqual(error.code, Int(EINVAL))
            }
        }
        do {
            _ = try await repository.run(["unreplaced\0argument"])
            XCTFail("Ordinary NUL argument was admitted")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(EINVAL))
        }
    }
    func testCancellationAfterRawDeliveryReapsTheOwnedProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-byte-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("stdout"), err = root.appendingPathComponent("stderr"), pidFile = root.appendingPathComponent("pid")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let output = try FileHandle(forWritingTo: out), error = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? error.close() }
        let token = OperationCancellation(), raw = Data([0xFF, 0xFE]) + Data("' $()\n".utf8)
        let deadline = Date().addingTimeInterval(5)
        let status = try CancellableGitProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' \"$$\" > \"$2\"; printf '%s' \"$1\"; exec /bin/sleep 30", "owned-receiver", "display", pidFile.path],
            argumentBytes: [3: raw], environment: ProcessInfo.processInfo.environment,
            output: output.fileDescriptor, error: error.fileDescriptor, cancellation: token, pollOutput: {
                if ((try? Data(contentsOf: out)) == raw && FileManager.default.fileExists(atPath: pidFile.path)) || Date() > deadline { token.cancel() }
            })
        XCTAssertTrue(token.isCancelled)
        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(try Data(contentsOf: out), raw)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        var childStatus: Int32 = 0
        XCTAssertEqual(waitpid(pid, &childStatus, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }
}
