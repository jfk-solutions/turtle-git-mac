import XCTest
import Darwin
@testable import TurtleGitCore

final class GitProcessExitTests: XCTestCase {
    private func fixture() throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit-exit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("git-helper")
        let script = """
        #!/bin/sh
        case "$4" in
          arguments)
            /usr/bin/printf '%s\\0' "$1" "$2" "$3" "$5" "$TURTLEGIT_EXIT_VALUE" "$GIT_TERMINAL_PROMPT" "$GIT_PAGER" "$LC_ALL"
            /usr/bin/printf 'error bytes\\n' >&2
            exit "$6" ;;
          signal) kill -TERM "$$" ;;
          quick) /usr/bin/printf '%s\\n' "$$" > "$5"; /usr/bin/printf 'completed\\n' ;;
          large) /usr/bin/head -c 2097152 /dev/zero; /usr/bin/head -c 1048576 /dev/zero >&2 ;;
          *) exit 99 ;;
        esac
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return (root, GitRepository(root: root, executable: helper))
    }
    func testOrdinaryExitPreservesArgumentsEnvironmentAndAcceptedStatus() async throws {
        let (root, repo) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let argument = "literal 雪\n' $() *"
        let result = try await repo.run(["arguments", argument, "7"], environmentOverrides: ["TURTLEGIT_EXIT_VALUE": "value 雪\n"], successfulExitCodes: 0...7)
        XCTAssertEqual(result.exitCode, 7)
        let fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(fields, ["--literal-pathspecs", "-C", root.path, argument, "value 雪\n", "0", "cat", "C"])
        XCTAssertEqual(result.stderr, Data("error bytes\n".utf8))
        do { _ = try await repo.run(["arguments", "value", "7"]); XCTFail("Unaccepted status succeeded") }
        catch let failure as GitFailure { XCTAssertEqual(failure.code, 7); XCTAssertTrue(failure.message.contains("error bytes")) }
        let alternate = try await repo.run(["arguments", "value", "0"], literalPathspecs: false)
        XCTAssertTrue(alternate.stdout.starts(with: Data("--no-literal-pathspecs\0".utf8)))
    }
    func testOrdinarySignalPreservesFoundationTerminationStatus() async throws {
        let (root, repo) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await repo.run(["signal"]); XCTFail("Signalled command succeeded") }
        catch let failure as GitFailure { XCTAssertEqual(failure.code, SIGTERM) }
    }
    func testOrdinaryLargeStreamsDrainWithoutPipes() async throws {
        let (root, repo) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try await repo.run(["large"])
        XCTAssertEqual(result.stdout.count, 2097152); XCTAssertEqual(result.stderr.count, 1048576)
    }
    func testConcurrentFastExitsCompleteAndReapOnlyOwnedChildren() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let (root, repo) = try self.fixture(); defer { try? FileManager.default.removeItem(at: root) }
                    let marker = root.appendingPathComponent("pid")
                    for _ in 0..<20 {
                        let result = try await repo.run(["quick", marker.path])
                        XCTAssertEqual(result.stdout, Data("completed\n".utf8))
                        let pid = Int32(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines))!
                        var status: Int32 = 0
                        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
                        XCTAssertEqual(errno, ECHILD, "The ordinary runner must reap its own child")
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
