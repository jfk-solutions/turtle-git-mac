// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class CloneCommandCompletionTests:XCTestCase {
    private final class Events:@unchecked Sendable {
        private let lock=NSLock();private var storage:[String]=[]
        func add(_ value:String){lock.lock();storage.append(value);lock.unlock()}
        var values:[String]{lock.lock();defer{lock.unlock()};return storage}
    }
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func fixture()async throws->GitRepository {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Clone ' receipt "+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let repo=GitRepository(root:root,executable:executable)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Receipt QA"),("user.email","receipt@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("original\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        return repo
    }
    func testExactInvocationAndReceiptPrecedeSSHConfigurationWarning()async throws {
        let f=try await SSHTransportPreparationTests().fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let seen=f.root.appendingPathComponent("receipt-seen"),configured=f.root.appendingPathComponent("config-seen")
        let original=try String(contentsOf:f.wrapper)
        let guardScript="""
        for argument in "$@"; do
          case "$argument" in remote.custom.turtlegitsshkeyfile)
            test -f \(quote(seen.path)) || exit 81
            : > \(quote(configured.path))
            printf '%s\\n' 'fixture denied SSH setting' >&2; exit 67;;
          esac
        done
        """
        try original.replacingOccurrences(of:"#!/bin/sh\n",with:"#!/bin/sh\n"+guardScript+"\n").write(to:f.wrapper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:f.wrapper.path)
        let destination=f.root.appendingPathComponent("cloned ' 雪"),events=Events(),before=try await f.source.run(["rev-parse","HEAD"]).stdout
        var options=CloneOptions();options.source=f.source.root.path;options.origin="custom";options.sshKey=f.key;options.loadSSHKeyWithAgent=true
        let expected=["--no-literal-pathspecs","-C",f.repo.root.path,"clone","--progress","-v","--origin","custom","--",f.source.root.path,destination.path]
        let preamble=([f.wrapper.path]+expected).map { value in
            let safe="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.@:=+%,"
            return !value.isEmpty && value.utf8.allSatisfy{safe.utf8.contains($0)} ? value:quote(value)
        }.joined(separator:" ")+"\n"
        let result=try await f.repo.cloneOutcome(options,to:destination,onOutput:{chunk in events.add("output:"+String(decoding:chunk.data,as:UTF8.self))},prepareTransport:{_,token in try f.agent(token)},onCommand:{invocation in
            XCTAssertEqual(invocation.executable,f.wrapper);XCTAssertEqual(invocation.directory,f.repo.root);XCTAssertEqual(invocation.arguments,expected)
            XCTAssertEqual(String(decoding:invocation.preamble,as:UTF8.self),preamble)
            events.add("command")
        },onCommandFinished:{receipt in
            XCTAssertTrue(receipt.success);XCTAssertFalse(receipt.cancelled);XCTAssertEqual(receipt.exitCode,0);XCTAssertGreaterThanOrEqual(receipt.elapsed,0)
            XCTAssertFalse(FileManager.default.fileExists(atPath:configured.path));try? Data().write(to:seen);events.add("receipt")
        })
        XCTAssertEqual(events.values.first,"command");XCTAssertEqual(events.values.filter{$0=="receipt"},["receipt"])
        XCTAssertFalse(events.values.contains{$0.hasPrefix("output:") && $0.contains("fixture denied")})
        XCTAssertTrue(FileManager.default.fileExists(atPath:configured.path));XCTAssertEqual(result.warnings.count,1);XCTAssertTrue(result.warnings[0].contains("fixture denied SSH setting"))
        let cloned=GitRepository(root:destination,executable:f.realGit),head=try await cloned.run(["rev-parse","HEAD"]).stdout,after=try await f.source.run(["rev-parse","HEAD"]).stdout
        XCTAssertEqual(head,before);XCTAssertEqual(after,before);XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("file")),Data("base\n".utf8))
    }
    func testPreflightAndTransportCancellationEmitNoRequestedCommandOrReceipt()async throws {
        let repo=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let events=Events(),destination=repo.root.appendingPathComponent("unused")
        var options=CloneOptions();options.source=""
        do{_ = try await repo.clone(options,to:destination,onCommand:{_ in events.add("command")},onCommandFinished:{_ in events.add("receipt")});XCTFail("Invalid source accepted")}catch is CloneFailure{}
        options.source=repo.root.path;let cancelled=OperationCancellation();cancelled.cancel()
        do{_ = try await repo.clone(options,to:destination,cancellation:cancelled,onCommand:{_ in events.add("command")},onCommandFinished:{_ in events.add("receipt")});XCTFail("Precancelled clone ran")}catch{}
        do{_ = try await repo.clone(options,to:destination,prepareTransport:{_,token in token.cancel();return nil},onCommand:{_ in events.add("command")},onCommandFinished:{_ in events.add("receipt")});XCTFail("Transport cancellation cloned")}catch{}
        XCTAssertTrue(events.values.isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
    }
    func testActualFailureAndCancellationEmitOneReceiptAfterDrain()async throws {
        let repo=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let helper=repo.root.appendingPathComponent("controlled-git"),hold=repo.root.appendingPathComponent("hold"),ready=repo.root.appendingPathComponent("ready")
        let script="""
        #!/bin/sh
        if [ "${4-}" = clone ]; then
          if [ -f \(quote(hold.path)) ]; then
            printf '%s\\n' "$$" > \(quote(ready.path))
            while :; do /bin/sleep 0.02; done
          fi
          printf 'fatal: controlled clone failure\\n' >&2; exit 17
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:repo.root,executable:helper),before=try await repo.run(["rev-parse","HEAD"]).stdout
        var options=CloneOptions();options.source=repo.root.path;let submitted=options
        for cancel in [false,true] {
            if cancel{try Data().write(to:hold)}
            let events=Events(),token=OperationCancellation(),destination=repo.root.appendingPathComponent(cancel ? "cancelled":"failed")
            let task=Task {try await wrapped.clone(submitted,to:destination,cancellation:token,onCommand:{_ in events.add("command")},onCommandFinished:{receipt in
                XCTAssertFalse(receipt.success);XCTAssertEqual(receipt.cancelled,cancel);if !cancel{XCTAssertEqual(receipt.exitCode,17)}
                if cancel,let pid=try? String(contentsOf:ready),let value=Int32(pid.trimmingCharacters(in:.whitespacesAndNewlines)){XCTAssertNotEqual(kill(value,0),0,"Receipt preceded process drain")}
                events.add("receipt")
            })}
            if cancel {
                for _ in 0..<1000 where !FileManager.default.fileExists(atPath:ready.path){try await Task.sleep(nanoseconds:5_000_000)}
                XCTAssertTrue(FileManager.default.fileExists(atPath:ready.path));XCTAssertEqual(events.values,["command"]);token.cancel()
            }
            do{_ = try await task.value;XCTFail("Controlled clone succeeded")}catch{}
            XCTAssertEqual(events.values,["command","receipt"]);XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        }
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,before);XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent("file")),Data("original\n".utf8))
    }
}
