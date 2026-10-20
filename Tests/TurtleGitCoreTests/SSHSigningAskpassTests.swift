// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import Darwin
@testable import TurtleGitCore

final class SSHSigningAskpassTests:XCTestCase {
    private func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    private func directory()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit SSH signing ' "+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);return root
    }
    private func executable(_ text:String,at url:URL)throws {
        try Data(text.utf8).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)
    }
    func testSigningClassificationKeepsCredentialPolicySeparateAndPreservesOverrides()throws {
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("TurtleGitGitAskpass"),alias=root.appendingPathComponent("TurtleGitOpenSSHAskpass")
        try executable("#!/bin/sh\nexit 1\n",at:helper);try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:helper)
        for command in ["commit","commit-tree","tag","merge","rebase","cherry-pick","revert","am"] {
            for args in [[command],["-C",root.path,"-c","gpg.format=ssh",command],["--config-env=gpg.format=FORMAT",command]] {
                XCTAssertTrue(GitAskpassRuntime.mayRequestSSHSignature(args))
                XCTAssertFalse(GitAskpassRuntime.mayAuthenticate(args),"Local signing became a credential/TLS operation")
                XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments:args,environment:[:],helper:helper),"Signing replaced a Git credential helper")
                let environment=GitAskpassRuntime.sshEnvironment(arguments:args,environment:[:],helper:helper)
                XCTAssertEqual(environment["SSH_ASKPASS"],alias.path);XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"],"force");XCTAssertEqual(environment["DISPLAY"],"TurtleGit-signing")
            }
        }
        for args in [["show","--","commit"],["status","--","tag"],["-C","commit","status"],["-c","alias.sign=!git commit -S","log"],["--exec-path=rebase"],["--config-env"]] {
            XCTAssertFalse(GitAskpassRuntime.mayRequestSSHSignature(args));XCTAssertTrue(GitAskpassRuntime.sshEnvironment(arguments:args,environment:[:],helper:helper).isEmpty)
        }
        for environment in [["SSH_ASKPASS":"private-agent-helper"],["SSH_ASKPASS":""],["SSH_ASKPASS_REQUIRE":"never"],["SSH_ASKPASS_REQUIRE":"NEVER"],["TURTLEGIT_DISABLE_ASKPASS":"1"]] {
            XCTAssertTrue(GitAskpassRuntime.sshEnvironment(arguments:["commit","-S"],environment:environment,helper:helper).isEmpty)
        }
        let preferred=GitAskpassRuntime.sshEnvironment(arguments:["tag","-s"],environment:["SSH_ASKPASS_REQUIRE":"prefer","DISPLAY":"caller-display","GIT_ASKPASS":"caller-git"],helper:helper)
        XCTAssertEqual(preferred,["SSH_ASKPASS":alias.path]);XCTAssertNil(preferred["GIT_ASKPASS"])
        for args in [["-c","core.askPass=caller","commit","-S"],["--config-env=core.askPass=CALLER_HELPER","rebase","--continue"],["--config-env","core.askPass=CALLER_HELPER","tag","-s"]] {
            XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments:args,environment:[:],helper:helper))
            XCTAssertEqual(GitAskpassRuntime.sshEnvironment(arguments:args,environment:[:],helper:helper)["SSH_ASKPASS"],alias.path,"Git's helper override incorrectly disabled the independent OpenSSH signing channel")
        }
        XCTAssertTrue(GitAskpassRuntime.sshEnvironment(arguments:["commit"],environment:[:],helper:nil).isEmpty)
    }
    func testRealEncryptedSSHCommitTagRebaseWrongRetryAndCancellationDrain()async throws {
        let host=ProcessInfo.processInfo.environment
        if host["SSH_ASKPASS"] != nil || host["TURTLEGIT_DISABLE_ASKPASS"] == "1" || host["SSH_ASKPASS_REQUIRE"]?.lowercased()=="never" {throw XCTSkip("Explicit host OpenSSH askpass policy takes precedence.")}
        let root=try directory();defer{try? FileManager.default.removeItem(at:root)}
        let git=URL(fileURLWithPath:host["TURTLEGIT_GROUP_TEST_GIT"] ?? "/usr/bin/git"),key=root.appendingPathComponent("encrypted signing key"),phrase="private signing fixture ' 雪"
        let generation=Process();generation.executableURL=URL(fileURLWithPath:"/usr/bin/ssh-keygen");generation.arguments=["-q","-t","ed25519","-a","1","-N",phrase,"-C","signing@example.invalid","-f",key.path];generation.standardInput=FileHandle.nullDevice;generation.standardOutput=FileHandle.nullDevice;generation.standardError=FileHandle.nullDevice
        try generation.run();generation.waitUntilExit();XCTAssertEqual(generation.terminationStatus,0)
        let helper=root.appendingPathComponent("TurtleGitGitAskpass"),alias=root.appendingPathComponent("TurtleGitOpenSSHAskpass"),explicit=root.appendingPathComponent("private-agent-askpass")
        let response=root.appendingPathComponent("synthetic-response"),prompts=root.appendingPathComponent("prompts"),hold=root.appendingPathComponent("hold"),ready=root.appendingPathComponent("held-processes")
        let script="""
        #!/bin/sh
        umask 077
        /usr/bin/printf '%s|%s\\n' "${0##*/}" "$1" >> \(quote(prompts.path))
        if [ -f \(quote(hold.path)) ]; then
          /bin/sleep 30 & child=$!
          trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
          /usr/bin/printf '%s %s\\n' "$$" "$child" > \(quote(ready.path+".pending"))
          /bin/mv \(quote(ready.path+".pending")) \(quote(ready.path))
          wait "$child"
        fi
        /bin/cat \(quote(response.path))
        """
        try executable(script,at:helper);try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:helper);try FileManager.default.createSymbolicLink(at:explicit,withDestinationURL:helper)
        let repo=GitRepository(root:root,executable:git,askpass:helper)
        let isolated=["GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_SYSTEM":"/dev/null","SSH_AUTH_SOCK":"/dev/null"]
        _=try await repo.run(["init","-b","main"],environmentOverrides:isolated)
        for (name,value) in [("user.name","Private Signing QA"),("user.email","signing@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("gpg.format","ssh"),("gpg.ssh.program","/usr/bin/ssh-keygen"),("user.signingkey",key.path)] {_=try await repo.run(["config",name,value],environmentOverrides:isolated)}
        let file=root.appendingPathComponent("file");try Data("base\n".utf8).write(to:file)
        _=try await repo.run(["add","--","file"],environmentOverrides:isolated);_=try await repo.run(["commit","-m","base"],environmentOverrides:isolated)
        let initial=try await repo.run(["rev-parse","HEAD"],environmentOverrides:isolated).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let allowed=root.appendingPathComponent("allowed-signers"),publicKey=try String(contentsOf:URL(fileURLWithPath:key.path+".pub"))
        try Data(("signing@example.invalid "+publicKey).utf8).write(to:allowed)
        for (name,value) in [("gpg.ssh.allowedSignersFile",allowed.path),("commit.gpgsign","true"),("tag.gpgsign","true")] {_=try await repo.run(["config",name,value],environmentOverrides:isolated)}
        try Data("wrong synthetic response\n".utf8).write(to:response);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:response.path)
        do {_=try await repo.run(["commit","--allow-empty","-m","signed retry"],environmentOverrides:isolated);XCTFail("Incorrect signing passphrase committed")}
        catch let failure as GitFailure {XCTAssertFalse(failure.localizedDescription.contains("wrong synthetic response"));XCTAssertFalse(failure.localizedDescription.contains(phrase))}
        let afterWrongPassphrase=try await repo.run(["rev-parse","HEAD"],environmentOverrides:isolated).stdout
        XCTAssertEqual(afterWrongPassphrase,initial)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),index)
        try Data((phrase+"\n").utf8).write(to:response)
        _=try await repo.run(["commit","--allow-empty","-m","signed retry"],environmentOverrides:isolated)
        _=try await repo.run(["verify-commit","HEAD"],environmentOverrides:isolated)
        _=try await repo.run(["tag","-s","-m","signed tag","signed-fixture"],environmentOverrides:isolated)
        _=try await repo.run(["verify-tag","signed-fixture"],environmentOverrides:isolated)
        _=try await repo.run(["rebase","--force-rebase","--empty=keep","--gpg-sign","--root"],environmentOverrides:isolated)
        _=try await repo.run(["verify-commit","HEAD"],environmentOverrides:isolated)
        var custom=isolated;custom["SSH_ASKPASS"]=explicit.path;custom["SSH_ASKPASS_REQUIRE"]="force";custom["DISPLAY"]="private-agent";custom["GIT_ASKPASS"]="unchanged-git-helper"
        _=try await repo.run(["-c","core.askPass=unchanged-configured-helper","commit","--allow-empty","-m","explicit signing helper"],environmentOverrides:custom)
        _=try await repo.run(["verify-commit","HEAD"],environmentOverrides:isolated)
        let requests=try String(contentsOf:prompts);XCTAssertTrue(requests.contains("TurtleGitOpenSSHAskpass|"));XCTAssertTrue(requests.contains("private-agent-askpass|"));XCTAssertFalse(requests.contains(phrase))
        let head=try await repo.run(["rev-parse","HEAD"],environmentOverrides:isolated).stdout,configuration=try Data(contentsOf:root.appendingPathComponent(".git/config")),beforeCancellation=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try Data().write(to:hold);let cancellation=OperationCancellation()
        let pending=Task {try await repo.run(["tag","-s","-m","cancelled signing","cancelled-fixture"],environmentOverrides:isolated,cancellation:cancellation)}
        defer{cancellation.cancel()}
        var pids:[Int32]=[]
        for _ in 0..<1000 {pids=((try? String(contentsOf:ready)) ?? "").split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)};if pids.count==2{break};try await Task.sleep(nanoseconds:5_000_000)}
        XCTAssertEqual(pids.count,2,"Signing did not reach its owned askpass helper");XCTAssertTrue(pids.allSatisfy{kill($0,0)==0})
        cancellation.cancel();if case .success=await pending.result {XCTFail("Cancelled signer created a tag")}
        for _ in 0..<500 where pids.contains(where:{kill($0,0)==0}) {try await Task.sleep(nanoseconds:10_000_000)}
        for pid in pids {XCTAssertNotEqual(kill(pid,0),0,"Owned signing prompt child survived command drain")}
        let cancelledTag=try await repo.run(["show-ref","--verify","--quiet","refs/tags/cancelled-fixture"],environmentOverrides:isolated,successfulExitCodes:0...1).exitCode
        let afterCancellation=try await repo.run(["rev-parse","HEAD"],environmentOverrides:isolated).stdout
        XCTAssertEqual(cancelledTag,1);XCTAssertEqual(afterCancellation,head)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/index")),beforeCancellation);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".git/config")),configuration);XCTAssertEqual(try Data(contentsOf:file),Data("base\n".utf8))
        try FileManager.default.removeItem(at:hold)
        _=try await repo.run(["tag","-s","-m","retried signing","cancelled-fixture"],environmentOverrides:isolated)
        _=try await repo.run(["verify-tag","cancelled-fixture"],environmentOverrides:isolated)
    }
}
