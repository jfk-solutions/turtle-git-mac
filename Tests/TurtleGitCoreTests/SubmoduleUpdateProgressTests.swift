// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class SubmoduleUpdateProgressTests: XCTestCase {
    private func fixture() async throws -> SubmoduleSyncTests.Fixture {
        let f = try await SubmoduleSyncTests().fixture()
        do {
            let script = """
            #!/bin/sh
            updating=no
            for argument in "$@"; do [ "$argument" = update ] && updating=yes; done
            if [ "$updating" = yes ]; then
              printf '%s\\n' called >> "$0.calls"
              printf '%s\\n' 'live update fixture 雪'
              if [ -f "$0.pause" ]; then
                /bin/sleep 30 &
                task_child=$!
                trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
                printf '%s %s\\n' "$$" "$task_child" > "$0.started"
                wait "$task_child"
              fi
              if [ -f "$0.fail" ]; then printf '%s\\n' 'fixture update failure' >&2; exit 7; fi
            fi
            exec '\(f.git.path.replacingOccurrences(of: "'", with: "'\\''"))' "$@"
            """
            try script.write(to: f.wrapper, atomically: false, encoding: .utf8)
            return f
        } catch { try? FileManager.default.removeItem(at:f.root); throw error }
    }
    func testStreamingSelectedUpdateAndOrdinaryFailurePreserveParent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let head = try await f.repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index"))
        var options = SubmoduleUpdateOptions(); options.noFetch = true
        let output = GitCliOutputParser()
        let result = try await f.repo.updateSubmodules(paths:[f.first],options:options,onOutput:{ output.appendChunk($0.data) })
        let streamed = output.processPending().data + output.finish().data
        XCTAssertTrue(result.contains("live update fixture 雪")); XCTAssertTrue(String(decoding:streamed,as:UTF8.self).contains("live update fixture 雪"))
        try Data().write(to:URL(fileURLWithPath:f.wrapper.path+".fail"))
        do { _ = try await f.repo.updateSubmodules(paths:[f.second],options:options); XCTFail("Failed Update succeeded") }
        catch let error as GitFailure { XCTAssertEqual(error.code,7); XCTAssertTrue(error.message.contains("fixture update failure")) }
        let after = try await f.repo.run(["rev-parse","HEAD"]).stdout; XCTAssertEqual(after,head)
        XCTAssertEqual(try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index")),index)
    }
    func testCancellationBeforeValidationDoesNotLaunchGit() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let token = OperationCancellation(); token.cancel()
        do { _ = try await f.repo.updateSubmodules(paths:[f.first],options:SubmoduleUpdateOptions(),cancellation:token); XCTFail("Pre-canceled Update succeeded") } catch is OperationCancellationFailure {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.wrapper.path+".calls"))
    }
    func testLiveCancellationReapsOwnedUpdateAndChild() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let index = try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index")), token = OperationCancellation(), parser = GitCliOutputParser()
        try Data().write(to:URL(fileURLWithPath:f.wrapper.path+".pause"))
        let work = Task { try await f.repo.updateSubmodules(paths:[f.first,f.second],options:SubmoduleUpdateOptions(),cancellation:token,onOutput:{ parser.appendChunk($0.data) }) }
        let marker = URL(fileURLWithPath:f.wrapper.path+".started")
        for _ in 0..<500 { if FileManager.default.fileExists(atPath:marker.path) { break }; try await Task.sleep(nanoseconds:10_000_000) }
        guard FileManager.default.fileExists(atPath:marker.path) else { token.cancel(); _ = try? await work.value; throw SubmoduleUpdateFailure.selection }
        let pids = try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap { Int32($0) }; token.cancel()
        do { _ = try await work.value; XCTFail("Live canceled Update succeeded") } catch { XCTAssertTrue(error is GitCommandCancellationFailure || error is OperationCancellationFailure) }
        let streamed = parser.processPending().data + parser.finish().data
        XCTAssertTrue(String(decoding:streamed,as:UTF8.self).contains("live update fixture 雪"))
        XCTAssertEqual(pids.count,2); XCTAssertTrue(pids.allSatisfy { kill($0,0) != 0 })
        XCTAssertEqual(try String(contentsOf:URL(fileURLWithPath:f.wrapper.path+".calls")),"called\n")
        XCTAssertEqual(try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index")),index)
    }
}
