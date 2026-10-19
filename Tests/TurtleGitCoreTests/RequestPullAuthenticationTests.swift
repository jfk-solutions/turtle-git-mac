// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class RequestPullAuthenticationTests:XCTestCase {
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    func testRequestPullEligibilityUsesActualCommandAndPreservesCallerPolicies()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("RequestAuthPolicy-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("askpass"),ssh=root.appendingPathComponent("TurtleGitOpenSSHAskpass")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        try FileManager.default.createSymbolicLink(at:ssh,withDestinationURL:helper)
        for arguments in [["request-pull","--","base","ssh://fixture.invalid/repo","main"],["-C",root.path,"-c","credential.helper=","request-pull","--","base","url","main"]] {
            XCTAssertTrue(GitAskpassRuntime.mayAuthenticate(arguments));XCTAssertTrue(GitAskpassRuntime.shouldInstall(arguments:arguments,environment:[:],helper:helper))
            XCTAssertEqual(GitAskpassRuntime.sshEnvironment(arguments:arguments,environment:[:],helper:helper),["SSH_ASKPASS":ssh.path,"SSH_ASKPASS_REQUIRE":"force"])
        }
        for arguments in [["status","--","request-pull"],["show","--","request-pull"],["-c","alias.probe=!git request-pull origin","status"],["--exec-path=request-pull"],["-C","request-pull","status"]] {
            XCTAssertFalse(GitAskpassRuntime.mayAuthenticate(arguments));XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments:arguments,environment:[:],helper:helper));XCTAssertTrue(GitAskpassRuntime.sshEnvironment(arguments:arguments,environment:[:],helper:helper).isEmpty)
        }
        for policy in [["GIT_ASKPASS":"caller"],["GIT_ASKPASS":""],["TURTLEGIT_DISABLE_ASKPASS":"1"]] {XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments:["request-pull"],environment:policy,helper:helper))}
        XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments:["-c","core.askPass=caller","request-pull"],environment:[:],helper:helper))
        XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments:["request-pull"],environment:[:],helper:nil))
        for policy in [["SSH_ASKPASS":"caller"],["SSH_ASKPASS":""],["SSH_ASKPASS_REQUIRE":"never"],["TURTLEGIT_DISABLE_ASKPASS":"1"]] {XCTAssertTrue(GitAskpassRuntime.sshEnvironment(arguments:["request-pull"],environment:policy,helper:helper).isEmpty)}
    }
    func testActualNestedRequestPullTransportInheritsPrivateAskpassAndCancellation()async throws {
        let host=ProcessInfo.processInfo.environment
        if host["GIT_ASKPASS"] != nil || host["SSH_ASKPASS"] != nil || host["GIT_SSH_COMMAND"] != nil || host["TURTLEGIT_DISABLE_ASKPASS"] == "1" || host["SSH_ASKPASS_REQUIRE"]?.lowercased()=="never" {throw XCTSkip("Explicit caller authentication policy takes precedence.")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Request Pull ' auth "+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:root)}
        let git=URL(fileURLWithPath:host["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"),source=root.appendingPathComponent("source"),bare=root.appendingPathComponent("published.git")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:false)
        let repo=GitRepository(root:source,executable:git,askpass:nil)
        _ = try await repo.run(["init","-b","main"])
        for(key,value)in[("user.name","Private Auth QA"),("user.email","auth@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("credential.helper","")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:source.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("private request change\n".utf8).write(to:source.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"request change")
        _ = try await repo.run(["clone","--bare",source.path,bare.path])
        let helper=root.appendingPathComponent("private askpass ' helper"),alias=root.appendingPathComponent("TurtleGitOpenSSHAskpass"),transport=root.appendingPathComponent("private ssh"),wrapper=root.appendingPathComponent("git-wrapper")
        let prompts=root.appendingPathComponent("prompts"),hold=root.appendingPathComponent("hold"),ready=root.appendingPathComponent("held-processes"),credential=root.appendingPathComponent("synthetic-response")
        let helperScript="""
        #!/bin/sh
        umask 077
        /usr/bin/printf '%s\\n' "$1" >> \(quote(prompts.path))
        if [ -f \(quote(hold.path)) ]; then
          /bin/sleep 30 & child=$!
          trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
          /usr/bin/printf '%s %s\\n' "$$" "$child" > \(quote(ready.path+".pending"))
          /bin/mv \(quote(ready.path+".pending")) \(quote(ready.path))
          wait "$child"
        fi
        case "$1" in Username*) /usr/bin/printf '%s\\n' 'fixture-user';; Password*) /usr/bin/printf '%s\\n' 'fixture-password';; *) exit 72;; esac
        """
        // This executable substitutes for SSH entirely. No socket, server,
        // key, DNS lookup or external credential store participates.
        let transportScript="""
        #!/bin/sh
        umask 077
        for arg in "$@"; do if [ "$arg" = -G ]; then exit 0; fi; done
        test "${GIT_TERMINAL_PROMPT:-}" = 0 || exit 73
        test "${GIT_ASKPASS:-}" = \(quote(helper.path)) || exit 74
        test "${SSH_ASKPASS:-}" = \(quote(alias.path)) || exit 75
        /usr/bin/printf 'protocol=https\\nhost=fixture.invalid\\n\\n' | \(quote(git.path)) -c credential.helper= credential fill > \(quote(credential.path)) || exit 76
        /usr/bin/grep -q '^username=fixture-user$' \(quote(credential.path)) || exit 77
        /usr/bin/grep -q '^password=fixture-password$' \(quote(credential.path)) || exit 78
        exec \(quote(git.path)) upload-pack \(quote(bare.path))
        """
        let runtime=GitRuntime.environment(executable:git).sorted{$0.key<$1.key}.map{"export "+$0.key+"="+quote($0.value)}.joined(separator:"\n")
        let wrapperScript="""
        #!/bin/sh
        \(runtime)
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
        # Isolate the synthetic transport from the user's selected SSH client.
        # Git/OpenSSH askpass variables still come from the actual Core runner.
        export GIT_SSH_COMMAND=\(quote(quote(transport.path))) GIT_SSH_VARIANT=ssh
        unset GIT_SSH
        exec \(quote(git.path)) "$@"
        """
        for(file,text)in[(helper,helperScript),(transport,transportScript),(wrapper,wrapperScript)] {try Data(text.utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)}
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:helper)
        _ = try await repo.run(["config","core.sshCommand",quote(transport.path)])
        let wrapped=GitRepository(root:source,executable:wrapper,askpass:helper),head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:source.appendingPathComponent(".git/index")),working=try Data(contentsOf:source.appendingPathComponent("file")),config=try Data(contentsOf:source.appendingPathComponent(".git/config"))
        var options=RequestPullOptions();options.start=base;options.repositoryURL="ssh://fixture.invalid/private-repository";options.end="main"
        let text=String(decoding:try await wrapped.requestPull(options),as:UTF8.self)
        XCTAssertTrue(text.contains("request change"));XCTAssertTrue(text.contains(options.repositoryURL))
        let requested=try String(contentsOf:prompts);XCTAssertTrue(requested.contains("Username"));XCTAssertTrue(requested.contains("Password"));XCTAssertFalse(text.contains("fixture-password"))
        try Data().write(to:hold);let token=OperationCancellation(),submitted=options
        let task=Task {try await wrapped.requestPull(submitted,cancellation:token)}
        var pids:[Int32]=[]
        for _ in 0..<1000 {pids=((try? String(contentsOf:ready)) ?? "").split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)};if pids.count==2{break};try? await Task.sleep(nanoseconds:5_000_000)}
        XCTAssertEqual(pids.count,2,"Nested askpass was not reached");XCTAssertTrue(pids.allSatisfy{kill($0,0)==0})
        token.cancel();let cancelled=await task.result
        if case .success=cancelled {XCTFail("Cancelled nested authentication succeeded")}
        for _ in 0..<500 where pids.contains(where:{kill($0,0)==0}) {try? await Task.sleep(nanoseconds:10_000_000)}
        for pid in pids {XCTAssertNotEqual(kill(pid,0),0,"Owned askpass/helper child survived cancellation")}
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;XCTAssertEqual(after,head);XCTAssertEqual(try Data(contentsOf:source.appendingPathComponent(".git/index")),index);XCTAssertEqual(try Data(contentsOf:source.appendingPathComponent("file")),working);XCTAssertEqual(try Data(contentsOf:source.appendingPathComponent(".git/config")),config)
    }
}
