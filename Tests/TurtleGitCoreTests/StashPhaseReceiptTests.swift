// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class StashPhaseReceiptTests:XCTestCase {
    private final class Receipts:@unchecked Sendable {
        private let lock=NSLock()
        private var stored=[StashSaveCommandCompletion]()
        func append(_ value:StashSaveCommandCompletion) {lock.lock();stored.append(value);lock.unlock()}
        var values:[StashSaveCommandCompletion] {lock.lock();defer{lock.unlock()};return stored}
    }
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func fixture()async throws->(GitRepository,GitRepository,URL,URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Stash phase ' 雪 "+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let git=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map{URL(fileURLWithPath:$0)} ?? URL(fileURLWithPath:"/usr/bin/git")
        let repo=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
        _ = try await repo.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Phase QA"),("user.email","phase@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {
            _ = try await repo.run(["config",key,value])
        }
        try Data("base\n".utf8).write(to:repo.root.appendingPathComponent("file"))
        try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let mode=repo.root.appendingPathComponent(".git/phase-mode"),submitted=repo.root.appendingPathComponent(".git/submitted"),helper=repo.root.appendingPathComponent(".git/phase-git")
        let runtime=GitRuntime.environment(executable:git).sorted{$0.key<$1.key}.map{"export "+$0.key+"="+quote($0.value)}.joined(separator:"\n")
        let body="""
        #!/bin/sh
        \(runtime)
        task_command() {
          while [ "$#" -gt 0 ]; do
            case "$1" in
              -c|-C|--git-dir|--work-tree) shift; [ "$#" -gt 0 ] && shift ;;
              --literal-pathspecs|--no-literal-pathspecs|--no-optional-locks|--no-pager) shift ;;
              *) printf '%s' "$1"; return ;;
            esac
          done
        }
        task_cmd=$(task_command "$@")
        task_mode=$(/bin/cat \(quote(mode.path)) 2>/dev/null)
        if [ "$task_cmd" = rev-parse ]; then
          case "$task_mode" in
            pre-error) printf 'CONTROLLED reference read\\n' >&2; exit 17 ;;
            pre-malformed) printf 'not-an-object-id\\n'; exit 0 ;;
            pre-noisy-missing) printf 'unexpected output\\n'; exit 1 ;;
            post-error) if [ -f \(quote(submitted.path)) ]; then printf 'CONTROLLED post-save read\\n' >&2; exit 19; fi ;;
          esac
        fi
        if [ "$task_cmd" = stash ]; then
          printf 'submitted\\n' >> \(quote(submitted.path))
          if [ "$task_mode" = restore-error ]; then printf 'CONTROLLED restore failure\\n' >&2; exit 17; fi
          if [ "$task_mode" = restore-hold ]; then
            /bin/sleep 30 & task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf 'owned restore holding\\n' >&2
            printf '%s %s\\n' "$$" "$task_child" > \(quote(repo.root.appendingPathComponent(".git/hold-ready.pending").path))
            /bin/mv \(quote(repo.root.appendingPathComponent(".git/hold-ready.pending").path)) \(quote(repo.root.appendingPathComponent(".git/hold-ready").path))
            wait "$task_child"
          fi
        fi
        if [ "$task_cmd" = ls-files ] && [ "$task_mode" = conflict ]; then
          test -f \(quote(repo.root.appendingPathComponent(".git/receipt-seen").path)) || exit 81
        fi
        exec \(quote(git.path)) "$@"
        """
        try Data(body.utf8).write(to:helper)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        return (repo,GitRepository(root:repo.root,executable:helper,libgit2Configuration:.init(enabled:false)),mode,submitted)
    }
    private func set(_ value:String,_ url:URL)throws {try Data(value.utf8).write(to:url)}

    func testReferenceFailuresBeforeSaveCannotLaunchOrMutate()async throws {
        let (repo,wrapped,mode,submitted)=try await fixture()
        defer {try? FileManager.default.removeItem(at:repo.root)}
        try set("changed\n",repo.root.appendingPathComponent("file"))
        let index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        let refs=try await repo.run(["show-ref"]).stdout
        for value in ["pre-error","pre-malformed","pre-noisy-missing"] {
            try set(value,mode);let receipts=Receipts()
            do {_ = try await wrapped.saveStash(.init(),onCommandFinished:receipts.append);XCTFail("Reference read failure became an absent stash")}
            catch let failure as GitFailure {
                XCTAssertEqual(failure.arguments.first,"rev-parse")
                XCTAssertEqual(failure.code,value=="pre-error" ? 17:1)
            }
            XCTAssertTrue(receipts.values.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath:submitted.path))
            XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),index)
            XCTAssertEqual(try String(contentsOf:repo.root.appendingPathComponent("file")),"changed\n")
            let after=try await repo.run(["show-ref"]).stdout;XCTAssertEqual(after,refs)
        }
    }

    func testSavedCommandReceiptSurvivesFailedReferenceInspectionWithoutRetry()async throws {
        let (repo,wrapped,mode,submitted)=try await fixture()
        defer {try? FileManager.default.removeItem(at:repo.root)}
        try set("changed\n",repo.root.appendingPathComponent("file"));try set("post-error",mode)
        let receipts=Receipts(),head=try await repo.run(["rev-parse","HEAD"]).stdout
        do {_ = try await wrapped.saveStash(.init(),onCommandFinished:receipts.append);XCTFail("Post-save inspection failure was hidden")}
        catch let failure as StashSaveReferenceReadFailure {
            XCTAssertEqual(failure.command.exitCode,0);XCTAssertNil(failure.previous)
            XCTAssertFalse(failure.command.text.isEmpty)
            XCTAssertTrue(failure.details.contains("CONTROLLED post-save read"))
        }
        XCTAssertEqual(receipts.values.count,1);let completed=try XCTUnwrap(receipts.values.first)
        XCTAssertTrue(completed.success);XCTAssertFalse(completed.cancelled);XCTAssertEqual(completed.exitCode,0)
        XCTAssertEqual(try String(contentsOf:submitted),"submitted\n")
        XCTAssertEqual(try String(contentsOf:repo.root.appendingPathComponent("file")),"base\n")
        let saved=try await repo.run(["rev-parse","refs/stash"]).text.trimmingCharacters(in:.newlines)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head)
        try set("pass",mode)
        let unchanged=try await wrapped.saveStash(.init())
        XCTAssertFalse(unchanged.created);XCTAssertEqual(unchanged.previous,saved);XCTAssertEqual(unchanged.current,saved)
    }

    func testBisectStashPreservesSuccessfulSaveWhenReferenceInspectionFails()async throws {
        let (repo,wrapped,mode,submitted)=try await fixture()
        defer {try? FileManager.default.removeItem(at:repo.root)}
        try set("changed\n",repo.root.appendingPathComponent("file"));try set("post-error",mode)
        do {_ = try await wrapped.stashBeforeBisectWorkflow();XCTFail("Bisect ignored failed stash inspection")}
        catch let failure as BisectMutationFailure {
            XCTAssertTrue(failure.underlying is StashSaveReferenceReadFailure)
            XCTAssertEqual(failure.mutation.commands.count,1)
            let command=try XCTUnwrap(failure.mutation.commands.first)
            XCTAssertEqual(command.arguments,["stash","push"]);XCTAssertEqual(command.exitCode,0)
            XCTAssertFalse(command.output.isEmpty);XCTAssertTrue(failure.mutation.success)
        }
        XCTAssertEqual(try String(contentsOf:submitted),"submitted\n")
        XCTAssertEqual(try String(contentsOf:repo.root.appendingPathComponent("file")),"base\n")
        let state=try await repo.bisectState();XCTAssertFalse(state.active)
        _ = try await repo.run(["rev-parse","--verify","refs/stash"])
    }

    func testRestoreReceiptsExcludeValidationAndDistinguishActualFailure()async throws {
        let (repo,wrapped,mode,_)=try await fixture()
        defer {try? FileManager.default.removeItem(at:repo.root)}
        try set("changed\n",repo.root.appendingPathComponent("file"));_ = try await repo.saveStash(.init())
        let index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        let refs=try await repo.run(["show-ref"]).stdout
        let absent=Receipts()
        do {_ = try await wrapped.restoreStash(pop:false,reference:"stash@{9999}",onCommandFinished:absent.append);XCTFail("Missing selected stash accepted")}catch is GitFailure {}
        let token=OperationCancellation();token.cancel()
        do {_ = try await wrapped.restoreStash(pop:true,cancellation:token,onCommandFinished:absent.append);XCTFail("Pre-cancelled Pop accepted")}catch OperationCancellationFailure.cancelled {}
        XCTAssertTrue(absent.values.isEmpty)
        try set("restore-error",mode)
        let failed=Receipts()
        do {_ = try await wrapped.restoreStash(pop:false,onCommandFinished:failed.append);XCTFail("Actual failure ignored")}
        catch let failure as GitFailure {XCTAssertEqual(failure.code,17)}
        XCTAssertEqual(failed.values.count,1);let failureReceipt=try XCTUnwrap(failed.values.first)
        XCTAssertEqual(failureReceipt.exitCode,17);XCTAssertFalse(failureReceipt.success);XCTAssertFalse(failureReceipt.cancelled)
        XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),index)
        let after=try await repo.run(["show-ref"]).stdout;XCTAssertEqual(after,refs)
        try set("pass",mode);let accepted=Receipts()
        let result=try await wrapped.restoreStash(pop:false,reference:"stash@{0}",onCommandFinished:accepted.append)
        XCTAssertFalse(result.conflicted);XCTAssertEqual(accepted.values.count,1)
        let successReceipt=try XCTUnwrap(accepted.values.first)
        XCTAssertTrue(successReceipt.success);XCTAssertEqual(successReceipt.exitCode,0)
        XCTAssertEqual(try String(contentsOf:repo.root.appendingPathComponent("file")),"changed\n")
    }

    func testConflictReceiptPrecedesCapturedBackendInspectionAndRetainsStash()async throws {
        let (repo,wrapped,mode,_)=try await fixture()
        defer {try? FileManager.default.removeItem(at:repo.root)}
        try set("stashed\n",repo.root.appendingPathComponent("file"));let saved=try await repo.saveStash(.init())
        try set("other\n",repo.root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"other")
        try set("conflict",mode);let receipts=Receipts(),seen=repo.root.appendingPathComponent(".git/receipt-seen")
        let result=try await wrapped.restoreStash(pop:true,backend:.init(enabled:false),onCommandFinished:{value in
            receipts.append(value);try? Data().write(to:seen)
        })
        XCTAssertTrue(result.conflicted);XCTAssertEqual(receipts.values.count,1)
        let conflictReceipt=try XCTUnwrap(receipts.values.first)
        XCTAssertEqual(conflictReceipt.exitCode,1);XCTAssertFalse(conflictReceipt.success)
        let stash=try await repo.run(["rev-parse","refs/stash"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(stash,saved.current)
        let stages=try await repo.run(["ls-files","-u","-z"]).stdout;XCTAssertFalse(stages.isEmpty)
    }

    func testRunningRestoreCancellationReceiptsOwnGroupAndDrain()async throws {
        let (repo,wrapped,mode,_)=try await fixture()
        defer {try? FileManager.default.removeItem(at:repo.root)}
        try set("stashed\n",repo.root.appendingPathComponent("file"));_ = try await repo.saveStash(.init())
        let before=try await repo.run(["show-ref"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        let ready=repo.root.appendingPathComponent(".git/hold-ready")
        try set("restore-hold",mode)
        for pop in [false,true] {
            try? FileManager.default.removeItem(at:ready)
            let token=OperationCancellation(),receipts=Receipts()
            let work=Task {try await wrapped.restoreStash(pop:pop,cancellation:token,onCommandFinished:receipts.append)}
            defer {token.cancel()}
            var owned=[Int32]()
            for _ in 0..<1000 {
                owned=((try? String(contentsOf:ready)) ?? "").split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
                if owned.count==2 {break}
                try await Task.sleep(nanoseconds:5_000_000)
            }
            XCTAssertEqual(owned.count,2)
            if owned.count==2 {
                XCTAssertEqual(getpgid(owned[0]),owned[0]);XCTAssertEqual(getpgid(owned[1]),owned[0])
                XCTAssertEqual(kill(owned[0],0),0);XCTAssertEqual(kill(owned[1],0),0)
            }
            XCTAssertTrue(receipts.values.isEmpty)
            token.cancel()
            do {_ = try await work.value;XCTFail("Running restore succeeded after cancellation")}
            catch let failure as GitCommandCancellationFailure {
                XCTAssertTrue([Int32(130),143,137].contains(failure.result.exitCode))
                XCTAssertTrue(failure.result.text.contains("owned restore holding"))
                XCTAssertEqual(receipts.values.first?.exitCode,failure.result.exitCode)
            }
            XCTAssertEqual(receipts.values.count,1);XCTAssertTrue(receipts.values.first?.cancelled==true)
            XCTAssertFalse(receipts.values.first?.success==true)
            for pid in owned {XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)}
            XCTAssertEqual(try String(contentsOf:repo.root.appendingPathComponent("file")),"base\n")
            XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),index)
            let after=try await repo.run(["show-ref"]).stdout;XCTAssertEqual(after,before)
        }
    }
}
