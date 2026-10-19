// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class FormatPatchCommandCompletionTests:XCTestCase {
    private final class Capture:@unchecked Sendable {
        private let lock=NSLock();private var order:[String]=[],bytes=Data()
        func event(_ name:String){lock.lock();order.append(name);lock.unlock()}
        func output(_ chunk:GitOutputChunk){lock.lock();order.append("output");bytes.append(chunk.data);lock.unlock()}
        var events:[String]{lock.lock();defer{lock.unlock()};return order}
        var text:String{lock.lock();defer{lock.unlock()};return String(decoding:bytes,as:UTF8.self)}
    }
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func fixture()async throws->(GitRepository,String) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("Format Patch ' receipt "+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let git=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"),repository=GitRepository(root:folder,executable:git)
        _ = try await repository.run(["init","-b","main"])
        for(key,value)in[("user.name","Patch Receipt QA"),("user.email","patch@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_ = try await repository.run(["config",key,value])}
        try Data("base\n".utf8).write(to:folder.appendingPathComponent("file"));try await repository.stage(["file"]);_ = try await repository.commit(message:"base")
        let base=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("mail patch\n".utf8).write(to:folder.appendingPathComponent("file"));try await repository.stage(["file"]);_ = try await repository.commit(message:"mail patch")
        return(repository,base)
    }
    func testActualArgvAndPreambleCaptureAllExportModesWithoutChangingOutput()async throws {
        let(repo,base)=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let helper=repo.root.appendingPathComponent(".git/receipt-git"),argv=repo.root.appendingPathComponent(".git/actual-argv"),started=repo.root.appendingPathComponent(".git/started")
        let script="""
        #!/bin/sh
        if [ "${4-}" = format-patch ]; then
          /usr/bin/printf '%s\\0' "$@" > \(quote(argv.path))
          : > \(quote(started.path))
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:repo.root,executable:helper),branch="refs/heads/topic-'雪"
        _ = try await repo.run(["update-ref",branch,base])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        try Data((String(decoding:head,as:UTF8.self).trimmingCharacters(in:.newlines)+"\tnot-for-merge\tignored\n"+base+"\t\taccepted\n").utf8).write(to:repo.root.appendingPathComponent(".git/FETCH_HEAD"))
        try Data("staged\n".utf8).write(to:repo.root.appendingPathComponent("file"));try await repo.stage(["file"])
        try Data("unstaged\n".utf8).write(to:repo.root.appendingPathComponent("file"))
        let index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        for (ordinal,selection,version) in [(0,FormatPatchSelection.since("FETCH_HEAD"),["--end-of-options",base]),(1,.number(1),["-1"]),(2,.range(from:branch,to:"HEAD"),["--end-of-options",branch+"..HEAD"])] {
            try? FileManager.default.removeItem(at:started)
            let destination=repo.root.appendingPathComponent("mail '\(ordinal) $(touch should-not-exist) 雪"),capture=Capture()
            let expected=["--literal-pathspecs","-C",repo.root.path,"format-patch","--no-prefix","-o",destination.standardizedFileURL.resolvingSymlinksInPath().path]+version+["--"]
            let result=try await wrapped.formatPatch(selection:selection,to:destination,noPrefix:true,onOutput:{capture.output($0)},onCommand:{invocation in
                XCTAssertFalse(FileManager.default.fileExists(atPath:started.path),"Receipt followed process start")
                XCTAssertEqual(invocation.executable,helper);XCTAssertEqual(invocation.directory,repo.root);XCTAssertEqual(invocation.arguments,expected)
                let preamble=String(decoding:invocation.preamble,as:UTF8.self)
                XCTAssertTrue(preamble.hasPrefix("'"));XCTAssertTrue(preamble.contains("'\\''"));XCTAssertTrue(preamble.contains("$(touch should-not-exist)"));XCTAssertTrue(preamble.hasSuffix(" --\n"))
                capture.event("command")
            },onCommandFinished:{completion in
                XCTAssertTrue(completion.success);XCTAssertFalse(completion.cancelled);XCTAssertEqual(completion.exitCode,0);XCTAssertGreaterThanOrEqual(completion.elapsed,0)
                XCTAssertTrue(FileManager.default.fileExists(atPath:started.path));XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath:destination.path).count),1)
                capture.event("finished")
            })
            let actual=try Data(contentsOf:argv).split(separator:0).map{String(decoding:$0,as:UTF8.self)}
            XCTAssertEqual(actual,expected);XCTAssertEqual(capture.events.first,"command");XCTAssertEqual(capture.events.last,"finished");XCTAssertEqual(capture.events.filter{$0=="finished"}.count,1)
            XCTAssertEqual(capture.text,result.text);XCTAssertTrue(result.text.contains(".patch"));XCTAssertFalse(FileManager.default.fileExists(atPath:repo.root.appendingPathComponent("should-not-exist").path))
            let file=try XCTUnwrap(FileManager.default.contentsOfDirectory(at:destination,includingPropertiesForKeys:nil).first)
            XCTAssertTrue(try String(contentsOf:file).contains("Subject: [PATCH] mail patch"))
        }
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head);XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),index);XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent("file")),Data("unstaged\n".utf8))
    }
    func testPreflightFailuresAndPrecancelDoNotPublishCommandOrCompletion()async throws {
        let(repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let capture=Capture(),output=repo.root.appendingPathComponent("not-created")
        for (selection,folder) in [(FormatPatchSelection.number(0),output),(.since("bad\0revision"),output),(.number(1),repo.root.appendingPathComponent(".git/exports")),(.number(1),URL(string:"https://example.invalid/patches")!)] {
            do {_ = try await repo.formatPatch(selection:selection,to:folder,onCommand:{_ in capture.event("command")},onCommandFinished:{_ in capture.event("finished")});XCTFail("Invalid form exported")}
            catch is FormatPatchFailure{}
        }
        try Data("abcd\tnot-for-merge\tignored\n".utf8).write(to:repo.root.appendingPathComponent(".git/FETCH_HEAD"))
        do {_ = try await repo.formatPatch(selection:.since("FETCH_HEAD"),to:output,onCommand:{_ in capture.event("command")},onCommandFinished:{_ in capture.event("finished")});XCTFail("Empty merge selection exported")}
        catch FormatPatchFailure.selection{}
        let token=OperationCancellation();token.cancel()
        do {_ = try await repo.formatPatch(selection:.number(1),to:output,cancellation:token,onCommand:{_ in capture.event("command")},onCommandFinished:{_ in capture.event("finished")});XCTFail("Precancelled export ran")}
        catch OperationCancellationFailure.cancelled{}
        XCTAssertTrue(capture.events.isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
    }
    func testFailureAndLiveCancellationRetainPartialOutputAndFinishAfterDrain()async throws {
        let(repo,_)=try await fixture();defer{try? FileManager.default.removeItem(at:repo.root)}
        let helper=repo.root.appendingPathComponent(".git/controlled-git"),hold=repo.root.appendingPathComponent(".git/hold"),ready=repo.root.appendingPathComponent(".git/processes")
        let script="""
        #!/bin/sh
        if [ "${4-}" = format-patch ]; then
          /bin/mkdir -p "$6"
          /usr/bin/printf 'partial source patch' > "$6/0001-partial.patch"
          /usr/bin/printf '%s\\n' "$6/0001-partial.patch"
          if [ -f \(quote(hold.path)) ]; then
            /bin/sleep 30 & child=$!
            trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
            /usr/bin/printf '%s %s\\n' "$$" "$child" > \(quote(ready.path+".pending"))
            /bin/mv \(quote(ready.path+".pending")) \(quote(ready.path))
            wait "$child"
          fi
          /usr/bin/printf 'fatal: controlled format-patch failure\\n' >&2; exit 17
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:repo.root,executable:helper),head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),file=try Data(contentsOf:repo.root.appendingPathComponent("file"))
        for cancel in [false,true] {
            if cancel {try Data().write(to:hold)}
            let capture=Capture(),token=OperationCancellation(),destination=repo.root.appendingPathComponent(cancel ? "cancelled":"failed")
            let task=Task {try await wrapped.formatPatch(selection:.number(1),to:destination,cancellation:token,onOutput:{capture.output($0)},onCommand:{_ in capture.event("command")},onCommandFinished:{completion in
                XCTAssertFalse(completion.success);XCTAssertEqual(completion.cancelled,cancel);if !cancel {XCTAssertEqual(completion.exitCode,17)}
                if cancel,let text=try? String(contentsOf:ready),let pid=text.split(whereSeparator:{$0.isWhitespace}).first.flatMap({Int32($0)}) {XCTAssertNotEqual(kill(pid,0),0,"Receipt preceded leader drain")}
                capture.event("finished")
            })}
            if cancel {
                for _ in 0..<1000 where !FileManager.default.fileExists(atPath:ready.path){try? await Task.sleep(nanoseconds:5_000_000)}
                XCTAssertTrue(FileManager.default.fileExists(atPath:ready.path));XCTAssertFalse(capture.events.contains("finished"));token.cancel()
            }
            do {_ = try await task.value;XCTFail("Controlled export succeeded")}
            catch let failure as GitCommandCancellationFailure {XCTAssertTrue(cancel);XCTAssertTrue(failure.result.text.contains("0001-partial.patch"))}
            catch let failure as GitFailure {XCTAssertFalse(cancel);XCTAssertEqual(failure.code,17);XCTAssertTrue(failure.message.contains("0001-partial.patch"))}
            XCTAssertEqual(capture.events.first,"command");XCTAssertEqual(capture.events.last,"finished");XCTAssertEqual(capture.events.filter{$0=="finished"}.count,1)
            XCTAssertTrue(capture.text.contains("0001-partial.patch"));XCTAssertEqual(try Data(contentsOf:destination.appendingPathComponent("0001-partial.patch")),Data("partial source patch".utf8))
            if cancel {
                let pids=try String(contentsOf:ready).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
                XCTAssertEqual(pids.count,2)
                for _ in 0..<500 where pids.contains(where:{kill($0,0)==0}) {try await Task.sleep(nanoseconds:10_000_000)}
                for pid in pids {XCTAssertNotEqual(kill(pid,0),0,"Owned cancellation helper survived")}
            }
        }
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head);XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),index);XCTAssertEqual(try Data(contentsOf:repo.root.appendingPathComponent("file")),file)
    }
}
