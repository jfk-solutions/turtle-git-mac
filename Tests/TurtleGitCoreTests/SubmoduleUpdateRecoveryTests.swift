// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class SubmoduleUpdateRecoveryTests: XCTestCase {
    func testUTF8ArgumentBudgetKeepsOrderedExactPathsAndRejectsOversizedSingleArgument() throws {
        let fixed = ["git", "-C", "/fixture", "submodule", "update", "--recursive", "--"], pointer = MemoryLayout<UnsafeRawPointer?>.size
        let paths = ["folder/雪 ' \nfirst", "folder/e\u{301}", "folder/é", "-option-like"]
        let base = fixed.reduce(pointer) { $0 + $1.utf8.count + 1 + pointer }, limit = base + paths.map { $0.utf8.count + 1 + pointer }.max()!
        let batches = try SubmoduleUpdateBatchPlan.paths(paths, fixedArguments: fixed, byteLimit: limit)
        XCTAssertEqual(batches.flatMap { $0 }, paths); XCTAssertEqual(batches.count, paths.count)
        XCTAssertThrowsError(try SubmoduleUpdateBatchPlan.paths(paths, fixedArguments: fixed, byteLimit: base + 1))
        XCTAssertTrue(try SubmoduleUpdateBatchPlan.paths([], fixedArguments: fixed, byteLimit: limit).isEmpty)
    }
    func fixture() async throws -> SubmoduleSyncTests.Fixture {
        let f = try await SubmoduleSyncTests().fixture()
        let script = """
        #!/bin/sh
        task_operation=no
        for task_argument in "$@"; do
          [ "$task_argument" = update ] && task_operation=update
          [ "$task_argument" = sync ] && task_operation=sync
        done
        if [ "$task_operation" != no ]; then
          printf '%s\\n' "$task_operation" >> "$0.calls"
          printf '%s\\n' 'live recovery output 雪'
          if [ -f "$0.fail-first" ] && [ ! -f "$0.failed" ]; then touch "$0.failed"; printf '%s\\n' 'first command changed some files then failed' >&2; exit 7; fi
          if [ -f "$0.pause-second" ] && [ "$(/usr/bin/wc -l < "$0.calls" | /usr/bin/tr -d ' ')" = 2 ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            # Publish the PID pair atomically. Existence of the final marker
            # must mean both IDs are readable, not merely that redirection opened it.
            printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp"
            /bin/mv "$0.started.tmp" "$0.started"
            wait "$task_child"
          fi
          exit 0
        fi
        exec '\(f.git.path.replacingOccurrences(of: "'", with: "'\\''"))' "$@"
        """
        do { try script.write(to: f.wrapper, atomically: false, encoding: .utf8); return f }
        catch { try? FileManager.default.removeItem(at: f.root); throw error }
    }
    func limit(_ f: SubmoduleSyncTests.Fixture) -> Int {
        let fixed = [f.wrapper.path, "--literal-pathspecs", "-C", f.repo.root.path, "-c", "core.precomposeunicode=false"] + SubmoduleUpdateOptions().arguments(paths: [])
        let pointer=MemoryLayout<UnsafeRawPointer?>.size
        return fixed.reduce(pointer) { $0 + $1.utf8.count + 1 + pointer } + [f.first,f.second].map { $0.utf8.count + 1 + pointer }.max()!
    }
    func testBatchedUpdateAndSyncContinueOrdinaryFailureWithConservativePartialReceipts() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        let head=try await f.repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index"))
        try Data().write(to: URL(fileURLWithPath:f.wrapper.path+".fail-first"))
        let update=try await f.repo.updateSubmodulesWorkflow(paths:[f.second,f.first],options:.init(),argumentByteLimit:limit(f))
        XCTAssertEqual(update.entries.map(\.paths),[[f.second],[f.first]]);XCTAssertEqual(update.entries.map(\.exitCode),[7,0])
        XCTAssertEqual(update.attemptedPaths,[f.second,f.first]);XCTAssertEqual(update.successfulPaths,[f.first]);XCTAssertFalse(update.success);XCTAssertFalse(update.cancelled)
        XCTAssertFalse(update.attemptedPaths.contains("uninitialized"));XCTAssertTrue(update.output.contains("changed some files"))
        try FileManager.default.removeItem(atPath:f.wrapper.path+".failed")
        let sync=try await f.repo.syncSubmodulesWorkflow(scope:[f.second,f.first])
        XCTAssertEqual(sync.entries.map { $0.command.scope },[f.second,f.first]);XCTAssertEqual(sync.entries.map(\.exitCode),[7,0]);XCTAssertFalse(sync.success)
        XCTAssertEqual(try Data(contentsOf:f.repo.root.appendingPathComponent(".git/index")),index)
        let after=try await f.repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head)
    }
    func testCancelledSecondBatchRetainsFirstReceiptAndStopsLaterCommands() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at:f.root) }
        for syncing in [false,true] {
            for suffix in [".calls",".started"] {try? FileManager.default.removeItem(atPath:f.wrapper.path+suffix)}
            try Data().write(to:URL(fileURLWithPath:f.wrapper.path+".pause-second"))
            let token=OperationCancellation(),marker=URL(fileURLWithPath:f.wrapper.path+".started"),budget=limit(f)
            let work=Task {
                if syncing {_ = try await f.repo.syncSubmodulesWorkflow(scope:[f.first,f.second,"uninitialized"],cancellation:token)}
                else {_ = try await f.repo.updateSubmodulesWorkflow(paths:[f.first,f.second,"uninitialized"],options:.init(),cancellation:token,argumentByteLimit:budget)}
            }
            for _ in 0..<500 {if FileManager.default.fileExists(atPath:marker.path){break};try await Task.sleep(nanoseconds:10_000_000)}
            guard FileManager.default.fileExists(atPath:marker.path) else {token.cancel();_ = try? await work.value;XCTFail("Second command did not start");return}
            let pids=try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap {Int32($0)};token.cancel()
            do {_ = try await work.value;XCTFail("Cancelled sequence succeeded")}
            catch let failure as SubmoduleUpdateExecutionFailure {
                XCTAssertFalse(syncing);XCTAssertTrue(failure.result.cancelled);XCTAssertEqual(failure.result.successfulPaths,[f.first]);XCTAssertEqual(failure.result.attemptedPaths,[f.first,f.second])
            } catch let failure as SubmoduleSyncExecutionFailure {
                XCTAssertTrue(syncing);XCTAssertTrue(failure.result.cancelled);XCTAssertEqual(failure.result.entries.map {$0.command.scope},[f.first,f.second]);XCTAssertEqual(failure.result.entries.first?.exitCode,0)
            }
            XCTAssertEqual(pids.count,2);XCTAssertTrue(pids.allSatisfy {kill($0,0) != 0})
            XCTAssertEqual(try String(contentsOf:URL(fileURLWithPath:f.wrapper.path+".calls")).split(separator:"\n").count,2)
        }
    }
}
