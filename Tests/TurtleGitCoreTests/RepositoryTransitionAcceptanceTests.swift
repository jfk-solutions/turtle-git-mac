import XCTest
@testable import TurtleGitCore

/// The output callback waits for this exact executor to become a zombie (or
/// already disappear after its owner reaped it), then cancels. It never reaps or
/// signals the child: GitRepository retains authoritative exit-status ownership.
private final class TransitionExitGate:@unchecked Sendable {
    let cancellation=OperationCancellation()
    private let pidFile:URL,marker:String,lock=NSLock()
    private var bytes=Data(),handled=false,observedExit=false,diagnostic:String?
    init(pidFile:URL,marker:String){self.pidFile=pidFile;self.marker=marker}
    var exitedBeforeCancellation:Bool {lock.lock();defer{lock.unlock()};return observedExit}
    var failure:String? {lock.lock();defer{lock.unlock()};return diagnostic}
    func observe(_ chunk:GitOutputChunk) {
        guard case .stdout=chunk.stream else{return}
        lock.lock();bytes.append(chunk.data)
        guard !handled,String(decoding:bytes,as:UTF8.self).contains(marker) else{lock.unlock();return}
        handled=true;lock.unlock()
        do {
            let pidText=try String(contentsOf:pidFile).trimmingCharacters(in:.whitespacesAndNewlines)
            guard let pid=Int32(pidText),pid>0 else{throw NSError(domain:"TransitionExitGate",code:1)}
            for _ in 0..<300 {
                let task=Process(),pipe=Pipe();task.executableURL=URL(fileURLWithPath:"/bin/ps")
                task.arguments=["-o","stat=","-p",String(pid)];task.standardOutput=pipe;task.standardError=FileHandle.nullDevice
                try task.run();let state=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines);task.waitUntilExit()
                if state.hasPrefix("Z") || task.terminationStatus==1 && state.isEmpty {
                    lock.lock();observedExit=true;lock.unlock();cancellation.cancel();return
                }
                Thread.sleep(forTimeInterval:0.01)
            }
            throw NSError(domain:"TransitionExitGate",code:2,userInfo:[NSLocalizedDescriptionKey:"Owned executor did not exit before cancellation"])
        }catch {lock.lock();diagnostic=error.localizedDescription;lock.unlock()}
    }
}

final class RepositoryTransitionAcceptanceTests:XCTestCase {
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private struct Fixture {
        let root:URL,ordinary:GitRepository,runner:GitRepository,old:String,new:String,log:URL,gate:TransitionExitGate,marker:String
    }
    private func fixture(command:String,exit:Int=0)async throws->Fixture {
        let (root,repo,_)=try await GitPatchTests().fixture()
        do {
            let old=try await repo.run(["rev-parse","HEAD"]).stdout
            _ = try await repo.run(["commit","--allow-empty","-m","second transition commit"])
            let new=try await repo.run(["rev-parse","HEAD"]).stdout
            let oldHash=String(decoding:old,as:UTF8.self).trimmingCharacters(in:.newlines)
            _ = try await repo.run(["branch","transition-target",oldHash])
            let executable=root.appendingPathComponent("transition-git"),pid=root.appendingPathComponent("transition-pid"),log=root.appendingPathComponent("mutation-count")
            let marker="TurtleGit-owned-transition-exit-"+UUID().uuidString
            // The public checkout workflow deliberately runs `git switch`;
            // keep semantic mutation-count labels while intercepting real argv.
            let verb=command=="checkout" ? "switch":command
            let script="#!/bin/sh\nfor argument in \"$@\"; do\n if [ \"$argument\" = "+quote(verb)+" ]; then\n  printf '%s\\n' \"$$\" > "+quote(pid.path)+"\n  printf '%s\\n' "+quote(command)+" >> "+quote(log.path)+"\n  "+quote(repo.executable.path)+" \"$@\"\n  result=$?\n  if [ \"$result\" != 0 ]; then exit \"$result\"; fi\n  printf '%s\\n' "+quote(marker)+"\n  exit "+String(exit)+"\n fi\ndone\nexec "+quote(repo.executable.path)+" \"$@\"\n"
            try Data(script.utf8).write(to:executable);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
            return .init(root:root,ordinary:repo,runner:GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false)),old:oldHash,new:String(decoding:new,as:UTF8.self).trimmingCharacters(in:.newlines),log:log,gate:.init(pidFile:pid,marker:marker),marker:marker)
        }catch {try? FileManager.default.removeItem(at:root);throw error}
    }
    private func assertGate(_ value:Fixture,file:StaticString=#filePath,line:UInt=#line)throws {
        XCTAssertNil(value.gate.failure,file:file,line:line)
        XCTAssertTrue(value.gate.exitedBeforeCancellation,"The private callback must cancel only after actual executor exit",file:file,line:line)
        XCTAssertTrue(value.gate.cancellation.isCancelled,file:file,line:line)
    }

    func testCheckoutAcceptsExactExitZeroCancellationAndSwitchesOnlyOnce()async throws {
        let f=try await fixture(command:"checkout");defer{try? FileManager.default.removeItem(at:f.root)}
        var options=CheckoutOptions();options.revision="refs/heads/transition-target"
        let receipt=try await f.runner.checkoutAccepted(options,cancellation:f.gate.cancellation,onOutput:f.gate.observe)
        try assertGate(f);XCTAssertTrue(receipt.cancelledAfterCommand);XCTAssertTrue(receipt.output.contains(f.marker))
        let head=try await f.ordinary.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let branch=try await f.ordinary.run(["symbolic-ref","HEAD"]).text.trimmingCharacters(in:.newlines)
        let main=try await f.ordinary.run(["rev-parse","refs/heads/main"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(head,f.old);XCTAssertEqual(main,f.new);XCTAssertEqual(branch,"refs/heads/transition-target")
        XCTAssertEqual(try String(contentsOf:f.log),"checkout\n")
    }

    func testResetAcceptsExactExitZeroCancellationAndMovesCapturedBranchOnlyOnce()async throws {
        let f=try await fixture(command:"reset");defer{try? FileManager.default.removeItem(at:f.root)}
        let plan=try await f.runner.prepareReset(to:f.old,mode:.soft)
        let index=try Data(contentsOf:f.root.appendingPathComponent(".git/index"))
        let receipt=try await f.runner.resetAccepted(plan,cancellation:f.gate.cancellation,onOutput:f.gate.observe,backend:.init(enabled:false))
        try assertGate(f);XCTAssertTrue(receipt.cancelledAfterCommand);XCTAssertTrue(receipt.output.contains(f.marker))
        let head=try await f.ordinary.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let branch=try await f.ordinary.run(["symbolic-ref","HEAD"]).text.trimmingCharacters(in:.newlines)
        XCTAssertEqual(head,f.old);XCTAssertEqual(branch,"refs/heads/main")
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent(".git/index")),index)
        XCTAssertEqual(try String(contentsOf:f.log),"reset\n")
    }

    func testPrecommandCancellationRunsNeitherCheckoutNorReset()async throws {
        for command in ["checkout","reset"] {
            let f=try await fixture(command:command);defer{try? FileManager.default.removeItem(at:f.root)}
            let plan=try await f.runner.prepareReset(to:f.old,mode:.soft)
            var options=CheckoutOptions();options.revision="refs/heads/transition-target"
            f.gate.cancellation.cancel()
            do {
                if command=="checkout" {_ = try await f.runner.checkoutAccepted(options,cancellation:f.gate.cancellation)}
                else {_ = try await f.runner.resetAccepted(plan,cancellation:f.gate.cancellation,backend:.init(enabled:false))}
                XCTFail("Precommand cancellation executed a mutation")
            }catch OperationCancellationFailure.cancelled {}
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.log.path))
            let actual=try await f.ordinary.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            XCTAssertEqual(actual,f.new)
        }
    }

    func testNonzeroExitCannotBeAdoptedMerelyBecauseHeadChanged()async throws {
        for command in ["checkout","reset"] {
            let f=try await fixture(command:command,exit:7);defer{try? FileManager.default.removeItem(at:f.root)}
            let plan=try await f.runner.prepareReset(to:f.old,mode:.soft)
            var options=CheckoutOptions();options.revision="refs/heads/transition-target"
            do {
                if command=="checkout" {_ = try await f.runner.checkoutAccepted(options,cancellation:f.gate.cancellation,onOutput:f.gate.observe)}
                else {_ = try await f.runner.resetAccepted(plan,cancellation:f.gate.cancellation,onOutput:f.gate.observe,backend:.init(enabled:false))}
                XCTFail("A nonzero command must not produce an accepted receipt")
            }catch let failure as GitCommandCancellationFailure {XCTAssertEqual(failure.result.exitCode,7)}
            try assertGate(f)
            let actual=try await f.ordinary.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            XCTAssertEqual(actual,f.old,"State exists, but deliberately does not override the real failed exit")
            XCTAssertEqual(try String(contentsOf:f.log),command+"\n")
        }
    }
}
