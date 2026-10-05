import XCTest
import Darwin
@testable import TurtleGitCore

final class GitProcessCancellationTests: XCTestCase {
    func testPreCancelledExportDoesNotCreateOutputOrChangeRepository() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let folder = root.appendingPathComponent("export")
        let token = OperationCancellation(); token.cancel()
        do { _ = try await repo.formatPatch(selection: .number(1), to: folder, cancellation: token); XCTFail("Cancelled export ran") } catch is OperationCancellationFailure {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    }

    func testRunningExportCancellationStopsLeaderAndChildAndKeepsPartialOutput() async throws {
        let (root, repo, path) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        let ready = root.appendingPathComponent("processes")
        let helper = root.appendingPathComponent("slow-git")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        if [ "$4" = format-patch ]; then
          /bin/mkdir -p "$6"
          /usr/bin/printf 'partial patch bytes' > "$6/0001-partial.patch"
          /usr/bin/printf '%s\\n' "$6/0001-partial.patch"
          /usr/bin/printf 'export helper started\\n' >&2
          /bin/sleep 30 &
          child=$!
          /usr/bin/printf '%s\\n%s\\n' "$$" "$child" > \(quote(ready.path))
          wait "$child"
        else
          exec /usr/bin/git "$@"
        fi
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let slow = GitRepository(root: root, executable: helper)
        let folder = root.appendingPathComponent("export")
        let token = OperationCancellation()
        let task = Task { try await slow.formatPatch(selection: .number(1), to: folder, cancellation: token) }
        defer { token.cancel() }
        let deadline = Date().addingTimeInterval(5)
        var pids: [Int32] = []
        while Date() < deadline {
            pids = ((try? String(contentsOf: ready, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
            if pids.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard pids.count == 2 else {
            token.cancel(); _ = await task.result
            XCTFail("Helper did not report a live leader and child"); return
        }
        XCTAssertEqual(getpgid(pids[0]), pids[0]); XCTAssertEqual(getpgid(pids[1]), pids[0])
        let started = Date(); token.cancel()
        do { _ = try await task.value; XCTFail("Cancelled export reported success") }
        catch let failure as GitCommandCancellationFailure {
            XCTAssertTrue(failure.result.text.contains("0001-partial.patch"))
            XCTAssertTrue(failure.result.text.contains("export helper started"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let stopped = Date().addingTimeInterval(5)
        while Date() < stopped && pids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        for pid in pids { XCTAssertEqual(kill(pid, 0), -1, "Owned process still exists: \(pid)"); XCTAssertEqual(errno, ESRCH) }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("0001-partial.patch")), Data("partial patch bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text
        XCTAssertEqual(afterHead, head)
    }

    func testCancellableRunnerRetainsSuccessfulOutputAndOrdinaryFailure() async throws {
        let (root, repo, _) = try await GitPatchTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = OperationCancellation()
        let output = root.appendingPathComponent("patches")
        let result = try await repo.formatPatch(selection: .number(1), to: output, cancellation: token)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 1)
        XCTAssertTrue(result.text.contains(".patch"))
        do { _ = try await repo.run(["show", "--end-of-options", "missing-revision"], cancellation: token); XCTFail("Git failure accepted") }
        catch let failure as GitFailure { XCTAssertNotEqual(failure.code, 0); XCTAssertTrue(failure.message.contains("missing-revision")) }
        XCTAssertFalse(token.isCancelled)
    }
}
