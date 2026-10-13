import XCTest
import Darwin
@testable import TurtleGitCore

final class WorkingPatchCancellationTests: XCTestCase {
    func testReviewSubsetComparisonApplyAndSaveCancellationReapOwnedCommands() async throws {
        let (root, repository, bytes) = try await WorkingTreePatchReviewTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try await repository.reviewWorkingTreePatch(bytes)
        let id = try XCTUnwrap(review.files.first { $0.path == "--new 雪" }?.id)
        let comparison = try await repository.compareWorkingTreePatchFile(review, fileID: id)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let working = try Data(contentsOf: root.appendingPathComponent("--old 雪"))
        for (number, phase) in ["--stat", "--numstat", "--numstat", "--check", "hash-object"].enumerated() {
            let wrapper = root.appendingPathComponent("held-command-\(number)")
            let script = """
            #!/bin/sh
            for arg in "$@"; do
              if [ "$arg" = '\(phase)' ]; then
                /bin/sleep 30 & child=$!
                printf '%s %s\\n' "$$" "$child" > "$0.ready"
                wait "$child"
                break
              fi
            done
            exec /usr/bin/git "$@"
            """
            try Data(script.utf8).write(to: wrapper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            let slow = GitRepository(root: root, executable: wrapper), token = OperationCancellation()
            let work = Task {
                switch number {
                case 0: _ = try await slow.reviewWorkingTreePatch(bytes, cancellation: token)
                case 1: _ = try await slow.reviewWorkingTreePatchFiles(review, fileIDs: [id], cancellation: token)
                case 2: _ = try await slow.compareWorkingTreePatchFile(review, fileID: id, cancellation: token)
                case 3: _ = try await slow.applyWorkingTreePatch(review, cancellation: token)
                default: _ = try await slow.saveWorkingTreePatchFile(comparison, text: "edited\n", cancellation: token)
                }
            }
            var pids: [Int32] = []
            for _ in 0..<1000 {
                if let text = try? String(contentsOf: URL(fileURLWithPath: wrapper.path + ".ready")) {
                    pids = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                    if pids.count == 2 { break }
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            token.cancel()
            do { try await work.value; XCTFail("Canceled operation completed") }
            catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {}
            XCTAssertEqual(pids.count, 2)
            for _ in 0..<500 {
                if pids.allSatisfy({ kill($0, 0) != 0 }) { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            for pid in pids { XCTAssertEqual(kill(pid, 0), -1) }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("--old 雪")), working)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("--new 雪").path))
        }
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        XCTAssertEqual(afterHead, head)
    }
}
