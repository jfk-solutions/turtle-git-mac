// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class ClientHooksTests: XCTestCase {
    func testSourceFormatSelectionAndApprovalIdentity() throws {
        let root = URL(fileURLWithPath:"/work/repo")
        let global = ClientHook(type:.preCommit,path:"/work",command:"/bin/echo global")
        let local = ClientHook(type:.preCommit,path:root.path,command:"/bin/echo local",enabled:false,local:true)
        let wildcard = ClientHook(type:.preCommit,path:"*",command:"/bin/echo fallback")
        let text = try ClientHookConfiguration.serialize([global,wildcard])
        XCTAssertEqual(ClientHookConfiguration.parse(text),ClientHookConfiguration.sorted([global,wildcard]))
        XCTAssertEqual(ClientHookConfiguration.selected(type:.preCommit,workingTree:root,hooks:[global,local,wildcard]),local)
        let exact = ClientHook(type:.preCommit,path:root.path,command:"/bin/echo exact")
        XCTAssertEqual(ClientHookConfiguration.selected(type:.preCommit,workingTree:root,hooks:[local,exact,wildcard]),exact)
        var disabled = exact; disabled.enabled = false
        XCTAssertEqual(ClientHookConfiguration.selected(type:.preCommit,workingTree:root,hooks:[disabled,wildcard]),wildcard)
        XCTAssertEqual(ClientHookConfiguration.selected(type:.preCommit,workingTree:URL(fileURLWithPath:"/workshop"),hooks:[global,wildcard]),wildcard)
        XCTAssertEqual(ClientHookConfiguration.parse(text + "pre_commit_hook\n/incomplete\n"),ClientHookConfiguration.parse(text))
        XCTAssertEqual(ClientHookConfiguration.parse(text + text),ClientHookConfiguration.parse(text))
        XCTAssertEqual(ClientHookConfiguration.parse("pre_commit_hook\n?\n/bin/echo local\nfalse\nhide\n",local:true,root:root.path).first?.path,root.path)
        var changed = local; changed.command += " changed"
        XCTAssertNotEqual(changed.approvalIdentity,local.approvalIdentity)
        XCTAssertThrowsError(try ClientHookConfiguration.validate([exact,exact]))
    }
    func testLiteralMacCommandArgumentsAndAllPayloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitHookQA-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let root = directory.appendingPathComponent("repo with 'quotes' 雪")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        XCTAssertEqual(try ClientHookCommand.arguments("/bin/echo '%root%' \"two words\" '' literal\\ space",root:root.path),["/bin/echo",root.path,"two words","","literal space"])
        XCTAssertThrowsError(try ClientHookCommand.arguments("/bin/echo 'unfinished",root:root.path))
        for type in ClientHookType.allCases {
            let hook = ClientHook(type:type,path:root.path,command:"/bin/echo")
            var invocation:ClientHookInvocation? = try ClientHookInvocation(hook:hook,workingTree:root,paths:["one","雪"],message:"original",amend:true,error:"push failed",upstream:"origin/main",rebasedBranch:"feature",temporaryRoot:directory)
            let storage = invocation!.directory
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:storage.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
            switch type {
            case .startCommit,.preCommit:
                XCTAssertEqual(invocation!.arguments.count,3)
                XCTAssertEqual(try String(contentsOfFile:invocation!.arguments[0],encoding:.utf8),"one\n雪\n")
                try Data("\u{feff}changed 雪".utf8).write(to:invocation!.messageFile!)
                XCTAssertEqual(try invocation!.readMessage(exitCode:0),"changed 雪")
                XCTAssertEqual(try invocation!.readMessage(exitCode:1),"original")
            case .postCommit: XCTAssertEqual(invocation!.arguments,[root.path,"true"])
            case .prePush,.postPush:
                XCTAssertEqual(invocation!.arguments.last,root.path)
                XCTAssertEqual(try String(contentsOfFile:invocation!.arguments[0],encoding:.utf8),"push failed")
            case .preRebase:
                XCTAssertEqual(Array(invocation!.arguments.prefix(2)),["origin/main","feature"])
                XCTAssertEqual(invocation!.arguments.last,root.path)
            }
            invocation = nil
            XCTAssertFalse(FileManager.default.fileExists(atPath:storage.path))
        }
    }
    func testProjectConfigRoundTripPreservesOtherKeysAndCancellation() async throws {
        let (root,_,repo) = try GeneralSetupBatchTests().fixture("")
        defer { try? FileManager.default.removeItem(at:root) }
        _ = try await repo.run(["init","-b","main"])
        try Data("[other]\nvalue = retained\n".utf8).write(to:root.appendingPathComponent(".tgitconfig"))
        let hooks = ClientHookType.allCases.map { ClientHook(type:$0,path:root.path,command:"/bin/echo " + $0.rawValue,wait:false,show:false,local:true) }
        try await repo.saveProjectClientHooks(hooks)
        let read = try await repo.projectClientHooks()
        XCTAssertEqual(read,hooks)
        _ = try await repo.run(["config","--file",root.appendingPathComponent(".tgitconfig").path,"hook.precommit.wait","2"])
        let numeric = try await repo.projectClientHooks()
        XCTAssertEqual(numeric.first { $0.type == .preCommit }?.wait,true)
        let cancelled = OperationCancellation(); cancelled.cancel()
        do { try await repo.saveProjectClientHooks([],cancellation:cancelled); XCTFail("Cancelled write accepted") } catch OperationCancellationFailure.cancelled {}
        try await repo.saveProjectClientHooks([])
        let empty = try await repo.projectClientHooks(), other = try await repo.run(["config","--file",root.appendingPathComponent(".tgitconfig").path,"--get","other.value"])
        XCTAssertTrue(empty.isEmpty); XCTAssertEqual(other.text,"retained\n")
    }
    func testOwnedExecutionUsesWorkingDirectoryAndReadsMutatedMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitHookExecutionQA-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let root = directory.appendingPathComponent("repo with spaces")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let script = directory.appendingPathComponent("hook.sh")
        try Data("[ \"$1\" = \"$4\" ] || exit 7\npwd\nprintf 'changed message' > \"$3\"\nprintf 'hook warning' >&2\n".utf8).write(to:script)
        let hook = ClientHook(type:.preCommit,path:root.path,command:"/bin/sh '" + script.path + "' '%root%'")
        let invocation = try ClientHookInvocation(hook:hook,workingTree:root,message:"original",temporaryRoot:directory)
        let tokenForSuccess = OperationCancellation()
        var execution:ClientHookExecution? = try await ClientHookExecution.start(invocation:invocation,cancellation:tokenForSuccess)
        let result = try await execution!.completion.value
        execution = nil
        XCTAssertFalse(tokenForSuccess.isCancelled,"Completed disposal cancelled the caller token")
        XCTAssertEqual(result.exitCode,0); XCTAssertEqual(result.message,"changed message")
        XCTAssertEqual(URL(fileURLWithPath:result.output.trimmingCharacters(in:.newlines)).resolvingSymlinksInPath().path,root.resolvingSymlinksInPath().path); XCTAssertEqual(result.error,"hook warning")
        let token = OperationCancellation(); token.cancel()
        do { _ = try await ClientHookExecution.start(invocation:invocation,cancellation:token); XCTFail("Pre-cancelled hook launched") } catch OperationCancellationFailure.cancelled {}
    }
    func testRunningCancellationReapsItsOwnedLeader() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitHookCancelQA-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let script = directory.appendingPathComponent("wait.sh")
        try Data("printf '%s' \"$$\" > \"$1/pid\"\nsleep 30 &\nwait\n".utf8).write(to:script)
        let hook = ClientHook(type:.postCommit,path:directory.path,command:"/bin/sh '" + script.path + "'",show:false)
        let invocation = try ClientHookInvocation(hook:hook,workingTree:directory,temporaryRoot:directory)
        let execution = try await ClientHookExecution.start(invocation:invocation)
        let marker = directory.appendingPathComponent("pid")
        var capturedPID:Int32?
        for _ in 0..<500 {
            capturedPID = (try? String(contentsOf:marker,encoding:.utf8)).flatMap(Int32.init)
            if capturedPID != nil { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let pid = try XCTUnwrap(capturedPID)
        execution.cancel()
        do { _ = try await execution.completion.value; XCTFail("Cancelled script succeeded") } catch OperationCancellationFailure.cancelled {}
        XCTAssertEqual(Darwin.kill(pid,0),-1); XCTAssertEqual(errno,ESRCH)
    }

}
