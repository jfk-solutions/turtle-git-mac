// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class SynchronizationCommandCompletionTests:XCTestCase {
    private final class Receipts:@unchecked Sendable {
        private let lock=NSLock()
        private var values:[SynchronizationCommandCompletion]=[]
        func append(_ value:SynchronizationCommandCompletion){lock.lock();defer{lock.unlock()};values.append(value)}
        var all:[SynchronizationCommandCompletion]{lock.lock();defer{lock.unlock()};return values}
    }
    private struct Fixture {
        let folder:URL,root:URL,git:URL,control:URL,seen:URL,done:URL,metadata:URL,ready:URL
        let real:GitRepository,wrapped:GitRepository
    }
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    private func fixture()async throws->Fixture {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("SynchronizationReceipt-"+UUID().uuidString),root=folder.appendingPathComponent("client"),server=folder.appendingPathComponent("server.git")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let git=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map{URL(fileURLWithPath:$0)} ?? URL(fileURLWithPath:"/usr/bin/git"),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Receipt QA"),("user.email","receipt@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        _ = try await repo.run(["clone","--bare","--",root.path,server.path]);_ = try await repo.run(["remote","add","origin",server.path]);_ = try await repo.run(["fetch","origin"])
        _ = try await repo.run(["config","branch.main.remote","origin"]);_ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
        // This fixture observes the CLI receipt/inspection ordering through an
        // executable wrapper. Selected helper inspection has separate coverage.
        let wrapper=folder.appendingPathComponent("receipt-git"),environment=GitRuntime.environment(executable:git).sorted{$0.key<$1.key}.map{"export "+$0.key+"="+quote($0.value)}.joined(separator:"\n")
        let script="""
        #!/bin/sh
        \(environment)
        inspect_command() {
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --literal-pathspecs|--no-literal-pathspecs) shift ;;
              -C) selected_root="$2"; shift 2 ;;
              -c) shift 2 ;;
              *) selected_command="$1"; break ;;
            esac
          done
        }
        inspect_command "$@"
        mode=$(cat "$selected_root/.git/receipt-mode" 2>/dev/null)
        case "$selected_command" in
        fetch|stash|submodule)
          if [ "$mode" = "hold-$selected_command" ]; then
            : > "$selected_root/.git/receipt-ready"
            while :; do /bin/sleep 0.02; done
          fi
          if [ "$mode" = "fail-$selected_command" ]; then
            : > "$selected_root/.git/receipt-done"; printf 'controlled command failure\\n' >&2; exit 17
          fi
          \(quote(git.path)) "$@"
          result=$?
          : > "$selected_root/.git/receipt-done"
          exit "$result"
          ;;
        rev-parse|status|ls-files)
          if [ -f "$selected_root/.git/receipt-done" ]; then
            if [ ! -f "$selected_root/.git/receipt-seen" ]; then printf 'metadata preceded receipt\\n' >&2; exit 81; fi
            : > "$selected_root/.git/receipt-metadata"
            if [ "$mode" = fail-metadata ]; then printf 'controlled post-command metadata failure\\n' >&2; exit 82; fi
            /bin/sleep 0.2
          fi
          ;;
        esac
        exec \(quote(git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        return Fixture(folder:folder,root:root,git:git,control:root.appendingPathComponent(".git/receipt-mode"),seen:root.appendingPathComponent(".git/receipt-seen"),done:root.appendingPathComponent(".git/receipt-done"),metadata:root.appendingPathComponent(".git/receipt-metadata"),ready:root.appendingPathComponent(".git/receipt-ready"),real:repo,wrapped:GitRepository(root:root,executable:wrapper,libgit2Configuration:.init(enabled:false)))
    }
    private func arm(_ fixture:Fixture,_ mode:String="")throws {
        for path in [fixture.seen,fixture.done,fixture.metadata,fixture.ready] {try? FileManager.default.removeItem(at:path)}
        try Data(mode.utf8).write(to:fixture.control)
    }
    private func callback(_ fixture:Fixture,_ receipts:Receipts)->@Sendable(SynchronizationCommandCompletion)->Void {
        {completion in try? Data().write(to:fixture.seen);receipts.append(completion)}
    }
    private func options(_ action:SynchronizationTransportAction)->SynchronizationTransportOptions {
        var value=SynchronizationTransportOptions(action:action);value.localBranch="main";value.remote="origin";value.remoteBranch="main";return value
    }
    func testTransportReceiptPrecedesSuccessfulAndFailedFollowUpMetadata()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.folder)}
        for fails in [false,true] {
            try arm(f,fails ? "fail-metadata":"")
            let plan=try await f.wrapped.synchronizationTransportPlan(options(.fetchAndRebase)),receipts=Receipts()
            do {
                _ = try await f.wrapped.synchronize(plan,onCommandFinished:callback(f,receipts))
                XCTAssertFalse(fails,"Expected the independent post-command metadata failure")
            }catch is SynchronizationTransportFollowUpFailure {XCTAssertTrue(fails)}
            XCTAssertTrue(FileManager.default.fileExists(atPath:f.metadata.path),"Follow-up metadata did not execute after the receipt")
            let result=try XCTUnwrap(receipts.all.first)
            XCTAssertEqual(receipts.all.count,1);XCTAssertTrue(result.success);XCTAssertFalse(result.cancelled);XCTAssertEqual(result.exitCode,0)
            XCTAssertGreaterThanOrEqual(result.elapsed,0)
            if !fails {XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(result.finished),0.15,"Receipt includes subsequent metadata delay")}
        }
    }
    func testStashAndSubmoduleReceiptsRetainActualCommandOutcomeBeforeInspection()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.folder)}
        try arm(f)
        let stash=Receipts(),missing=try await f.wrapped.synchronizationStash(.pop,onCommandFinished:callback(f,stash))
        XCTAssertNotEqual(missing.command.exitCode,0);XCTAssertNil(missing.conflictCheckError)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.metadata.path),"Failed stash was not inspected after its receipt")
        XCTAssertEqual(stash.all.count,1);XCTAssertFalse(try XCTUnwrap(stash.all.first).success);XCTAssertFalse(try XCTUnwrap(stash.all.first).cancelled)
        XCTAssertEqual(stash.all.first?.exitCode,missing.command.exitCode)
        try arm(f)
        let successful=Receipts();_ = try await f.wrapped.synchronizeSubmodules(.sync,onCommandFinished:callback(f,successful))
        XCTAssertEqual(successful.all.count,1);XCTAssertTrue(try XCTUnwrap(successful.all.first).success);XCTAssertEqual(successful.all.first?.exitCode,0)
        try arm(f,"fail-submodule")
        let failed=Receipts()
        do {_ = try await f.wrapped.synchronizeSubmodules(.sync,onCommandFinished:callback(f,failed));XCTFail("Controlled failure was accepted")}catch is GitFailure {}
        XCTAssertEqual(failed.all.count,1);XCTAssertFalse(try XCTUnwrap(failed.all.first).success);XCTAssertEqual(failed.all.first?.exitCode,17)
    }
    func testCancellationEmitsOnceOnlyAfterStartedCommandAndPreflightEmitsNothing()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.folder)}
        for family in ["fetch","stash","submodule"] {
            try arm(f,"hold-"+family)
            let token=OperationCancellation(),receipts=Receipts()
            let plan=family=="fetch" ? try await f.wrapped.synchronizationTransportPlan(options(.fetch)):nil
            let task=Task {
                if let plan {_ = try await f.wrapped.synchronize(plan,cancellation:token,onCommandFinished:callback(f,receipts))}
                else if family=="stash" {_ = try await f.wrapped.synchronizationStash(.save,cancellation:token,onCommandFinished:callback(f,receipts))}
                else {_ = try await f.wrapped.synchronizeSubmodules(.sync,cancellation:token,onCommandFinished:callback(f,receipts))}
            }
            do {
                for _ in 0..<1000 where !FileManager.default.fileExists(atPath:f.ready.path) {try await Task.sleep(nanoseconds:5_000_000)}
                XCTAssertTrue(FileManager.default.fileExists(atPath:f.ready.path));XCTAssertTrue(receipts.all.isEmpty)
                token.cancel()
                do {try await task.value;XCTFail("Cancelled command succeeded")}catch {}
            } catch {token.cancel();_ = await task.result;throw error}
            XCTAssertEqual(receipts.all.count,1)
            let receipt=try XCTUnwrap(receipts.all.first);XCTAssertTrue(receipt.cancelled);XCTAssertFalse(receipt.success)
            try arm(f)
            let before=Receipts(),cancelled=OperationCancellation();cancelled.cancel()
            do {
                if let plan {_ = try await f.wrapped.synchronize(plan,cancellation:cancelled,onCommandFinished:callback(f,before))}
                else if family=="stash" {_ = try await f.wrapped.synchronizationStash(.save,cancellation:cancelled,onCommandFinished:callback(f,before))}
                else {_ = try await f.wrapped.synchronizeSubmodules(.sync,cancellation:cancelled,onCommandFinished:callback(f,before))}
                XCTFail("Pre-cancelled preflight ran")
            }catch {}
            XCTAssertTrue(before.all.isEmpty,"Validation must not invent a requested-command receipt")
        }
    }
}
