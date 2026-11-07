// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class TransportPhaseReceiptTests:XCTestCase {
    private final class Events:@unchecked Sendable {
        private let lock=NSLock()
        private var pushes=[PushTransportCompletion](),clones=[CloneCommandCompletion]()
        func push(_ value:PushTransportCompletion){lock.lock();pushes.append(value);lock.unlock()}
        func clone(_ value:CloneCommandCompletion){lock.lock();clones.append(value);lock.unlock()}
        var pushValues:[PushTransportCompletion]{lock.lock();defer{lock.unlock()};return pushes}
        var cloneValues:[CloneCommandCompletion]{lock.lock();defer{lock.unlock()};return clones}
    }
    private struct Fixture {
        let root:URL,source:GitRepository,wrapped:GitRepository,remote:GitRepository,mode:URL,ready:URL,submitted:URL
        var destination:URL {root.appendingPathComponent("clone ' 雪")}
        var push:PushOptions {var value=PushOptions();value.remote="origin";value.source="main";return value}
        var clone:CloneOptions {var value=CloneOptions();value.source=source.root.path;return value}
    }
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func set(_ text:String,_ path:URL)throws{try Data(text.utf8).write(to:path)}
    private func fixture()async throws->Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Transport phase ' 雪 "+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var complete=false;defer{if !complete{try? FileManager.default.removeItem(at:root)}}
        let executable=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git")
        let source=GitRepository(root:root.appendingPathComponent("source"),executable:executable,libgit2Configuration:.init(enabled:false))
        try FileManager.default.createDirectory(at:source.root,withIntermediateDirectories:true)
        _ = try await source.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Transport QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await source.run(["config",key,value])}
        try set("original\n",source.root.appendingPathComponent("file"));try await source.stage(["file"]);_ = try await source.commit(message:"base")
        let remote=GitRepository(root:root.appendingPathComponent("remote.git"),executable:executable)
        _ = try await source.run(["init","--bare","--template=",remote.root.path])
        _ = try await source.run(["remote","add","origin",remote.root.path])
        let mode=root.appendingPathComponent("mode"),ready=root.appendingPathComponent("ready"),submitted=root.appendingPathComponent("submitted"),helper=root.appendingPathComponent("phase-git")
        let environment=GitRuntime.environment(executable:executable).sorted{$0.key<$1.key}.map{"export "+$0.key+"="+quote($0.value)}.joined(separator:"\n")
        let script="""
        #!/bin/sh
        \(environment)
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
        task_identity=no
        for task_arg in "$@"; do [ "$task_arg" = --is-bare-repository ] && task_identity=yes; done
        if [ "$task_cmd" = push ] || [ "$task_cmd" = clone ]; then
          printf '%s\\n' "$task_cmd" >> \(quote(submitted.path))
        fi
        if [ "$task_cmd" = push ] && [ "$task_mode" = push-reject ]; then printf 'CONTROLLED push rejection\\n' >&2; exit 17; fi
        if [ "$task_cmd" = rev-list ] && [ "$task_mode" = counter-reject ]; then printf 'CONTROLLED counter failure\\n' >&2; exit 19; fi
        if [ "$task_cmd" = push ] && [ "$task_mode" = push-completed-hold ]; then
          \(quote(executable.path)) "$@" || exit "$?"
        fi
        if { [ "$task_cmd" = push ] && { [ "$task_mode" = push-hold ] || [ "$task_mode" = push-completed-hold ]; }; } || { [ "$task_identity" = yes ] && [ "$task_mode" = inspect-hold ]; }; then
          /bin/sleep 30 & task_child=$!
          task_exit=143; [ "$task_mode" = push-completed-hold ] && task_exit=0
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit "$task_exit"' TERM INT
          printf 'owned transport phase holding\\n' >&2
          printf '%s %s\\n' "$$" "$task_child" > \(quote(ready.path+".pending"))
          /bin/mv \(quote(ready.path+".pending")) \(quote(ready.path))
          wait "$task_child"
        fi
        exec \(quote(executable.path)) "$@"
        """
        try set(script,helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        complete=true
        return .init(root:root,source:source,wrapped:GitRepository(root:source.root,executable:helper,libgit2Configuration:.init(enabled:false)),remote:remote,mode:mode,ready:ready,submitted:submitted)
    }
    private func held(_ ready:URL)async throws->[Int32] {
        for _ in 0..<1000 {
            let ids=((try? String(contentsOf:ready)) ?? "").split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
            if ids.count==2 {XCTAssertEqual(getpgid(ids[0]),ids[0]);XCTAssertEqual(getpgid(ids[1]),ids[0]);return ids}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        throw NSError(domain:"TransportPhaseReceiptTests",code:1,userInfo:[NSLocalizedDescriptionKey:"Owned transport phase did not reach its gate"])
    }
    private func absent(_ pids:[Int32]) {for pid in pids {XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)}}

    func testPushPreflightHasNoReceiptAndCompletedPublicationSurvivesLateCancellation()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let events=Events();var options=f.push;options.destination="../invalid"
        do {_ = try await f.wrapped.push(options,onTransportFinished:{events.push($0)});XCTFail("Invalid destination accepted")}catch PushValidationFailure.destination {}
        options=f.push
        do {_ = try await f.wrapped.push(options,prepareTransport:{_,token in token.cancel();return nil},onTransportFinished:{events.push($0)});XCTFail("Cancelled preparation submitted push")}catch{}
        XCTAssertTrue(events.pushValues.isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:f.submitted.path))
        let token=OperationCancellation()
        let output=try await f.wrapped.push(options,cancellation:token,onTransportFinished:{value in events.push(value);token.cancel()})
        let receipt=try XCTUnwrap(events.pushValues.first);XCTAssertEqual(events.pushValues.count,1)
        XCTAssertTrue(receipt.success);XCTAssertFalse(receipt.cancelled);XCTAssertNil(receipt.failure);XCTAssertEqual(receipt.completed,["origin"]);XCTAssertEqual(receipt.output,output)
        let expected=try await f.source.run(["rev-parse","HEAD"]).stdout,actual=try await f.remote.run(["rev-parse","refs/heads/main"]).stdout
        XCTAssertEqual(actual,expected);XCTAssertEqual(try String(contentsOf:f.submitted),"push\n")
    }

    func testPushFailureAndCounterFailureRetainRealReceiptsAndRemoteState()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let events=Events();try set("push-reject",f.mode)
        do {_ = try await f.wrapped.push(f.push,onOutput:{_ in},onTransportFinished:{events.push($0)});XCTFail("Rejected push succeeded")}
        catch let failure as PushExecutionFailure {XCTAssertEqual(failure.commandFailure?.code,17);XCTAssertTrue(failure.commandFailure?.outputWasDelivered==true);XCTAssertFalse(failure.cancelled)}
        let rejected=try XCTUnwrap(events.pushValues.first);XCTAssertFalse(rejected.success);XCTAssertTrue(rejected.completed.isEmpty)
        let refs=try await f.remote.run(["show-ref"],successfulExitCodes:0...1);XCTAssertEqual(refs.exitCode,1)
        try set("counter-reject",f.mode);var options=f.push;options.showBranchRevisionNumber=true
        do {_ = try await f.wrapped.push(options,onTransportFinished:{events.push($0)});XCTFail("Failed source counter hidden")}
        catch let failure as PushExecutionFailure {XCTAssertEqual(failure.commandFailure?.code,19);XCTAssertEqual(failure.completed,["origin"])}
        XCTAssertEqual(events.pushValues.count,2);let counted=try XCTUnwrap(events.pushValues.last)
        XCTAssertFalse(counted.success);XCTAssertFalse(counted.cancelled);XCTAssertEqual(counted.completed,["origin"])
        let expected=try await f.source.run(["rev-parse","HEAD"]).stdout,actual=try await f.remote.run(["rev-parse","refs/heads/main"]).stdout
        XCTAssertEqual(actual,expected)
    }

    func testPushPartialRemoteReceiptSurvivesLaterPreparationFailure()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        _ = try await f.source.run(["remote","rename","origin","a-good"])
        _ = try await f.source.run(["remote","add","z-later",f.root.appendingPathComponent("unopened.git").path])
        var options=f.push;options.allRemotes=true;let events=Events()
        do {
            _ = try await f.wrapped.push(options,prepareTransport:{remotes,_ in
                if remotes==["z-later"] {throw NSError(domain:"TransportPhaseReceiptTests",code:41,userInfo:[NSLocalizedDescriptionKey:"CONTROLLED later preparation failure"])}
                return nil
            },onTransportFinished:{events.push($0)})
            XCTFail("Later preparation failure hidden")
        } catch let failure as PushExecutionFailure {
            XCTAssertEqual(failure.completed,["a-good"]);XCTAssertEqual(failure.failedRemote,"z-later");XCTAssertFalse(failure.cancelled)
        }
        XCTAssertEqual(events.pushValues.count,1);let receipt=try XCTUnwrap(events.pushValues.first)
        XCTAssertFalse(receipt.success);XCTAssertFalse(receipt.cancelled);XCTAssertEqual(receipt.completed,["a-good"])
        let expected=try await f.source.run(["rev-parse","HEAD"]).stdout,actual=try await f.remote.run(["rev-parse","refs/heads/main"]).stdout
        XCTAssertEqual(actual,expected);XCTAssertEqual(try String(contentsOf:f.submitted),"push\n")
    }

    func testPushRunningCancellationKeepsActualOutputAndDrainsOwnedGroup()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try set("push-hold",f.mode);let events=Events(),token=OperationCancellation();defer{token.cancel()}
        let work=Task {try await f.wrapped.push(f.push,cancellation:token,onTransportFinished:{events.push($0)})}
        let pids:[Int32]
        do {pids=try await held(f.ready)}catch{token.cancel();_ = try? await work.value;throw error}
        XCTAssertTrue(events.pushValues.isEmpty);token.cancel()
        do {_ = try await work.value;XCTFail("Running push ignored cancellation")}
        catch let failure as PushExecutionFailure {
            XCTAssertTrue(failure.cancelled);let command=try XCTUnwrap(failure.commandCancellation)
            XCTAssertTrue([Int32(130),143,137].contains(command.result.exitCode));XCTAssertTrue(command.result.text.contains("owned transport phase holding"))
        }
        absent(pids);XCTAssertEqual(events.pushValues.count,1);let receipt=try XCTUnwrap(events.pushValues.first)
        XCTAssertFalse(receipt.success);XCTAssertTrue(receipt.cancelled);XCTAssertTrue(receipt.output.contains("owned transport phase holding"))
        let refs=try await f.remote.run(["show-ref"],successfulExitCodes:0...1);XCTAssertEqual(refs.exitCode,1)
    }

    func testPushExitZeroAfterCancellationRetainsAlreadyPublishedRemote()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try set("push-completed-hold",f.mode);let events=Events(),token=OperationCancellation();defer{token.cancel()}
        let work=Task {try await f.wrapped.push(f.push,cancellation:token,onTransportFinished:{events.push($0)})}
        let pids:[Int32]
        do {pids=try await held(f.ready)}catch{token.cancel();_ = try? await work.value;throw error}
        let expected=try await f.source.run(["rev-parse","HEAD"]).stdout,actual=try await f.remote.run(["rev-parse","refs/heads/main"]).stdout
        XCTAssertEqual(actual,expected);XCTAssertTrue(events.pushValues.isEmpty)
        token.cancel();_ = try await work.value;absent(pids)
        XCTAssertEqual(events.pushValues.count,1);let receipt=try XCTUnwrap(events.pushValues.first)
        XCTAssertTrue(receipt.success);XCTAssertFalse(receipt.cancelled);XCTAssertEqual(receipt.completed,["origin"])
        XCTAssertEqual(try String(contentsOf:f.submitted),"push\n")
    }

    func testCloneSuccessfulReceiptDoesNotBecomeCancelledWhenOwnerCancelsBeforeVerification()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let token=OperationCancellation(),events=Events()
        let outcome=try await f.wrapped.cloneOutcome(f.clone,to:f.destination,cancellation:token,onCommandFinished:{value in events.clone(value);token.cancel()})
        let receipt=try XCTUnwrap(events.cloneValues.first);XCTAssertEqual(events.cloneValues.count,1)
        XCTAssertTrue(receipt.success);XCTAssertFalse(receipt.cancelled);XCTAssertEqual(receipt.exitCode,0)
        XCTAssertTrue(outcome.cancelledAfterCreation);XCTAssertFalse(outcome.verified);XCTAssertNotNil(outcome.verificationError)
        let recovered=try await f.wrapped.inspectCloneOutcome(outcome,at:f.destination)
        XCTAssertTrue(recovered.verified);XCTAssertEqual(recovered.output,outcome.output)
        XCTAssertEqual(try String(contentsOf:f.submitted),"clone\n")
        XCTAssertEqual(try String(contentsOf:f.destination.appendingPathComponent("file")),"original\n")
    }

    func testCloneInitialVerificationCancellationRetainsCreatedRepositoryWithoutRetryingClone()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        try set("inspect-hold",f.mode);let events=Events(),token=OperationCancellation();defer{token.cancel()}
        let work=Task {try await f.wrapped.cloneOutcome(f.clone,to:f.destination,cancellation:token,onCommandFinished:{events.clone($0)})}
        let pids:[Int32]
        do {pids=try await held(f.ready)}catch{token.cancel();_ = try? await work.value;throw error}
        XCTAssertEqual(events.cloneValues.count,1);XCTAssertTrue(events.cloneValues.first?.success==true);token.cancel()
        let outcome=try await work.value;absent(pids)
        XCTAssertTrue(outcome.cancelledAfterCreation);XCTAssertFalse(outcome.verified);XCTAssertNotNil(outcome.verificationError)
        try set("pass",f.mode)
        let recovered=try await f.wrapped.inspectCloneOutcome(outcome,at:f.destination)
        XCTAssertTrue(recovered.verified);XCTAssertEqual(events.cloneValues.count,1);XCTAssertEqual(try String(contentsOf:f.submitted),"clone\n")
    }

    func testCloneRecoveryInspectionAndConfigurationCancellationOwnTheirVerification()async throws {
        let f=try await fixture();defer{try? FileManager.default.removeItem(at:f.root)}
        let accepted=try await f.wrapped.cloneOutcome(f.clone,to:f.destination)
        XCTAssertTrue(accepted.verified)
        var options=f.clone;options.sshKey=f.root.appendingPathComponent("owned-key");options.loadSSHKeyWithAgent=true
        let configuration=options
        let destination=GitRepository(root:f.destination,executable:f.source.executable)
        let originalConfig=try Data(contentsOf:f.destination.appendingPathComponent(".git/config"))
        for configure in [false,true] {
            try? FileManager.default.removeItem(at:f.ready);try set("inspect-hold",f.mode)
            let token=OperationCancellation();defer{token.cancel()}
            let work=Task {
                if configure {_ = try await f.wrapped.configureClonedRepository(configuration,at:f.destination,expected:accepted,cancellation:token)}
                else {_ = try await f.wrapped.inspectCloneOutcome(accepted,at:f.destination,cancellation:token)}
            }
            let pids:[Int32]
            do {pids=try await held(f.ready)}catch{token.cancel();_ = try? await work.value;throw error}
            token.cancel()
            do {try await work.value;XCTFail("Recovery verification ignored cancellation")}
            catch let failure as GitCommandCancellationFailure {XCTAssertTrue([Int32(130),143,137].contains(failure.result.exitCode))}
            absent(pids)
            XCTAssertEqual(try Data(contentsOf:f.destination.appendingPathComponent(".git/config")),originalConfig)
        }
        let key=try await destination.run(["config","--local","--get","remote.origin.turtlegitsshkeyfile"],successfulExitCodes:0...1)
        XCTAssertEqual(key.exitCode,1)
        XCTAssertTrue(accepted.verified);XCTAssertEqual(try String(contentsOf:f.submitted),"clone\n")
        XCTAssertEqual(try String(contentsOf:f.destination.appendingPathComponent("file")),"original\n")
    }
}
