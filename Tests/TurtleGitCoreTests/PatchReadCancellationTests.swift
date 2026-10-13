import XCTest
import Darwin
@testable import TurtleGitCore

final class PatchReadCancellationTests: XCTestCase {
    func testOwnedReadCommandsCancelAndPreserveRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPatchRead-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root), path = "雪\tfile.txt"
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Patch QA"])
        _ = try await repo.run(["config", "user.email", "patch@example.invalid"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent(path))
        try await repo.stage([path]); _ = try await repo.run(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", "base"])
        try Data("base\n雪 without LF".utf8).write(to: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let working = try Data(contentsOf: root.appendingPathComponent(path))
        for (number, phase) in ["rev-parse", "diff", "diff", "diff"].enumerated() {
            let helper = root.appendingPathComponent("held-\(number)")
            let script = """
            #!/bin/sh
            for arg in "$@"; do
              if [ "$arg" = \(phase) ]; then
                /bin/sleep 30 &
                task_child=$!
                trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
                printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
                /bin/mv "$0.ready.tmp" "$0.ready"
                wait "$task_child"
              fi
            done
            exec /usr/bin/git "$@"
            """
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let slow = GitRepository(root: root, executable: helper), token = OperationCancellation()
            let task = Task {
                if number <= 1 { _ = try await slow.workingTreePatchData(paths: [path], cancellation: token) }
                else if number == 2 { _ = try await slow.patchData(paths: [path], staged: false, cancellation: token) }
                else { _ = try await slow.patch(paths: [path], staged: true, cancellation: token) }
            }
            let marker = URL(fileURLWithPath: helper.path + ".ready")
            var pids: [Int32] = []
            for _ in 0..<1000 {
                if let raw = try? String(contentsOf: marker) { pids = raw.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }; if pids.count == 2 { break } }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            token.cancel()
            do { try await task.value; XCTFail("Cancelled patch read completed") }
            catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {}
            XCTAssertEqual(pids.count, 2)
            for _ in 0..<500 { if pids.allSatisfy({ kill($0, 0) != 0 }) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            for pid in pids { XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH) }
        }
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(after, head); XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), working)
        let bytes = try await repo.patchData(paths: [path], staged: false)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("+雪 without LF"))
    }
}
