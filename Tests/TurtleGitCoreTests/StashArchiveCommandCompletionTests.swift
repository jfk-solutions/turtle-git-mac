// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

final class StashArchiveCommandCompletionTests:XCTestCase {
    private final class ArchivePaths:@unchecked Sendable {
        private let lock=NSLock();private var paths:[URL]=[]
        func record(_ command:GitCommandInvocation) {lock.lock();defer{lock.unlock()};if let value=command.arguments.first(where:{$0.hasPrefix("--output=")}) {paths.append(URL(fileURLWithPath:String(value.dropFirst("--output=".count))))}}
        var values:[URL] {lock.lock();defer{lock.unlock()};return paths}
    }
    private final class Events:@unchecked Sendable {
        let lock=NSLock();private var events:[String]=[]
        func add(_ value:String){lock.lock();events.append(value);lock.unlock()}
        var values:[String]{lock.lock();defer{lock.unlock()};return events}
    }
    private func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func fixture()async throws->GitRepository {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Stash Archive ' receipt "+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let git=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"].map{URL(fileURLWithPath:$0)} ?? URL(fileURLWithPath:"/usr/bin/git"),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Receipt QA"),("user.email","receipt@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        return repo
    }
    func testStashReceiptPrecedesReferenceReadAndExactExecutedCommand()async throws {
        let repo=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let done=repo.root.appendingPathComponent(".git/push-done"),seen=repo.root.appendingPathComponent(".git/receipt-seen"),metadata=repo.root.appendingPathComponent(".git/metadata-seen"),helper=repo.root.appendingPathComponent(".git/receipt-git")
        let environment=GitRuntime.environment(executable:repo.executable).sorted{$0.key<$1.key}.map{"export "+$0.key+"="+quote($0.value)}.joined(separator:"\n")
        let script="""
        #!/bin/sh
        \(environment)
        if [ "${4-}" = stash ]; then
          \(quote(repo.executable.path)) "$@"; task_result=$?
          : > \(quote(done.path)); exit "$task_result"
        fi
        if [ "${4-}" = rev-parse ] && [ -f \(quote(done.path)) ]; then
          test -f \(quote(seen.path)) || exit 81
          : > \(quote(metadata.path)); /bin/sleep 0.15
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        try Data("changed\n".utf8).write(to:repo.root.appendingPathComponent("file"))
        let wrapped=GitRepository(root:repo.root,executable:helper),events=Events();var options=StashSaveOptions();options.message="snapshot ' 雪";options.includeUntracked=true
        let result=try await wrapped.saveStash(options,onCommand:{invocation in
            events.add(String(decoding:invocation.preamble,as:UTF8.self))
            XCTAssertEqual(invocation.arguments,["--no-literal-pathspecs","-C",repo.root.path,"stash","push","--include-untracked","-m","snapshot ' 雪"])
        },onCommandFinished:{receipt in
            XCTAssertTrue(receipt.success);XCTAssertFalse(receipt.cancelled);XCTAssertEqual(receipt.exitCode,0);XCTAssertGreaterThanOrEqual(receipt.elapsed,0)
            XCTAssertTrue(FileManager.default.fileExists(atPath:done.path));try? Data().write(to:seen);events.add("receipt")
        })
        XCTAssertTrue(result.created);XCTAssertTrue(FileManager.default.fileExists(atPath:metadata.path));XCTAssertEqual(events.values.count,2)
        XCTAssertEqual(events.values.first,quote(helper.path)+" --no-literal-pathspecs -C "+quote(repo.root.path)+" stash push --include-untracked -m 'snapshot '\\'' 雪'\n")
        XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent("file")),Data("base\n".utf8))
    }
    func testArchiveReceiptPrecedesAtomicFinalizationAndCancellationPreservesDestination()async throws {
        let repo=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let destination=repo.root.appendingPathComponent("export.zip"),original=Data("existing ZIP".utf8)
        for cancel in [false,true] {
            try original.write(to:destination);let events=Events(),token=OperationCancellation(),paths=ArchivePaths()
            do {
                _ = try await repo.archiveRevision(to:destination,cancellation:token,onCommand:{invocation in
                    paths.record(invocation)
                    let arguments=invocation.arguments
                    XCTAssertEqual(Array(arguments.prefix(4)),["--literal-pathspecs","-C",repo.root.path,"archive"])
                    XCTAssertTrue(arguments[4].hasPrefix("--output="));XCTAssertEqual(Array(arguments[5...6]),["--verbose","--end-of-options"])
                    XCTAssertEqual(URL(fileURLWithPath:String(arguments[4].dropFirst("--output=".count))).lastPathComponent,destination.lastPathComponent)
                    events.add("command")
                },onCommandFinished:{receipt in
                    XCTAssertTrue(receipt.success);XCTAssertFalse(receipt.cancelled);XCTAssertEqual(receipt.exitCode,0);events.add("receipt")
                },beforeFinalization:{
                    XCTAssertEqual(events.values,["command","receipt"]);XCTAssertEqual(try Data(contentsOf:destination),original);events.add("finalize")
                    if cancel{token.cancel()}
                })
                XCTAssertFalse(cancel);XCTAssertEqual(Array(try Data(contentsOf:destination).prefix(2)),[0x50,0x4b])
            }catch{XCTAssertTrue(cancel);XCTAssertEqual(try Data(contentsOf:destination),original)}
            XCTAssertEqual(events.values,["command","receipt","finalize"])
            XCTAssertEqual(paths.values.count,1)
            for file in paths.values {XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));XCTAssertFalse(FileManager.default.fileExists(atPath:file.deletingLastPathComponent().path))}
        }
    }
    func testValidationDoesNotEmitRequestedCommandOrReceipt()async throws {
        let repo=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let events=Events();var invalid=StashSaveOptions();invalid.message="bad\0message"
        do{_ = try await repo.saveStash(invalid,onCommand:{_ in events.add("command")},onCommandFinished:{_ in events.add("receipt")});XCTFail("Invalid stash accepted")}catch is StashFailure{}
        do{_ = try await repo.archiveRevision("bad\0revision",to:repo.root.appendingPathComponent("bad.zip"),onCommand:{_ in events.add("command")},onCommandFinished:{_ in events.add("receipt")});XCTFail("Invalid archive accepted")}catch is RevisionArchiveFailure{}
        let token=OperationCancellation();token.cancel()
        do{_ = try await repo.saveStash(StashSaveOptions(),cancellation:token,onCommandFinished:{_ in events.add("receipt")});XCTFail("Precancelled stash accepted")}catch{}
        do{_ = try await repo.archiveRevision(to:repo.root.appendingPathComponent("bad.zip"),cancellation:token,onCommandFinished:{_ in events.add("receipt")});XCTFail("Precancelled archive accepted")}catch{}
        XCTAssertTrue(events.values.isEmpty)
    }
    func testActualCommandFailuresAndCancellationEmitOneReceipt()async throws {
        let repo=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let helper=repo.root.appendingPathComponent("failure-git"),control=repo.root.appendingPathComponent(".git/hold-command"),ready=repo.root.appendingPathComponent(".git/command-ready")
        let script="""
        #!/bin/sh
        case "${4-}" in stash|archive)
          if [ -f \(quote(control.path)) ]; then
            : > \(quote(ready.path))
            while :; do /bin/sleep 0.02; done
          fi
          printf 'fatal: controlled command failure\\n' >&2; exit 17;;
        esac
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:repo.root,executable:helper)
        for family in ["stash","archive"] {
            for cancel in [false,true] {
                try? FileManager.default.removeItem(at:ready)
                if cancel{try Data().write(to:control)}else{try? FileManager.default.removeItem(at:control)}
                let events=Events(),token=OperationCancellation(),paths=ArchivePaths()
                let task=Task {
                    if family=="stash" {_ = try await wrapped.saveStash(StashSaveOptions(),cancellation:token,onCommandFinished:{receipt in
                        XCTAssertFalse(receipt.success);XCTAssertEqual(receipt.cancelled,cancel);if !cancel{XCTAssertEqual(receipt.exitCode,17)};events.add("receipt")
                    })}
                    else {_ = try await wrapped.archiveRevision(to:repo.root.appendingPathComponent("failed.zip"),cancellation:token,onCommand:{paths.record($0)},onCommandFinished:{receipt in
                        XCTAssertFalse(receipt.success);XCTAssertEqual(receipt.cancelled,cancel);if !cancel{XCTAssertEqual(receipt.exitCode,17)};events.add("receipt")
                    })}
                }
                if cancel {
                    for _ in 0..<1000 where !FileManager.default.fileExists(atPath:ready.path){try await Task.sleep(nanoseconds:5_000_000)}
                    XCTAssertTrue(FileManager.default.fileExists(atPath:ready.path));XCTAssertTrue(events.values.isEmpty);token.cancel()
                }
                do{try await task.value;XCTFail("Controlled failed/cancelled command succeeded")}catch{}
                XCTAssertEqual(events.values,["receipt"])
                if family=="archive" {
                    XCTAssertEqual(paths.values.count,1)
                    for file in paths.values {XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));XCTAssertFalse(FileManager.default.fileExists(atPath:file.deletingLastPathComponent().path))}
                }
            }
        }
    }

}
