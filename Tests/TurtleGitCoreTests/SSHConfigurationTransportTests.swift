import XCTest
@testable import TurtleGitCore

final class SSHConfigurationTransportTests:XCTestCase {
    struct Fixture {
        let files:SSHConfigurationAccessTests.Fixture
        let executable:URL,marker:URL,release:URL,arguments:URL
        let repository:GitRepository
        init()throws {
            files=try .init();executable=files.root.appendingPathComponent("private-git")
            marker=files.root.appendingPathComponent("started");release=files.root.appendingPathComponent("release");arguments=files.root.appendingPathComponent("argv")
            let script="""
            #!/bin/sh
            for arg in "$@"; do
              case "$arg" in
                fetch|push|pull|clone)
                  printf '%s\\0' "$@" > "$SSH_SCOPE_ARGUMENTS"
                  : > "$SSH_SCOPE_STARTED"
                  while [ ! -f "$SSH_SCOPE_RELEASE" ]; do /bin/sleep 0.01; done
                  exit 0;;
              esac
            done
            exec /usr/bin/git "$@"
            """
            try Data(script.utf8).write(to:executable);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
            repository=GitRepository(root:files.root,executable:executable,askpass:nil,libgit2Configuration:.init(enabled:false),sshConfigurationAccess:files.store)
        }
        var environment:[String:String] {["GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_COUNT":"0","SSH_SCOPE_STARTED":marker.path,"SSH_SCOPE_RELEASE":release.path,"SSH_SCOPE_ARGUMENTS":arguments.path]}
        func cleanup(){files.cleanup()}
    }
    func initialize(_ f:Fixture)async throws {_ = try await f.repository.run(["init","-b","main"],environmentOverrides:f.environment)}
    func waitFor(_ url:URL)async throws {
        for _ in 0..<1000 {if FileManager.default.fileExists(atPath:url.path){return};try await Task.sleep(nanoseconds:5_000_000)}
        XCTFail("Owned transport did not reach its private marker");throw SSHConfigurationAccessFailure.changed
    }
    func testEndpointAndLocalMetadataClassification()async throws {
        for endpoint in ["https://example.invalid/repo","http://example.invalid/repo","git://example.invalid/repo","file:///tmp/repo","/tmp/a:b","./a:b","folder/a:b","relative"] {XCTAssertFalse(SSHConfigurationTransport.needsAccess(endpoint:endpoint))}
        for endpoint in ["ssh://alias/repo","git+ssh://alias/repo","user@alias:repo","[::1]:repo","ext::custom-client", "unknown://host/repo"] {XCTAssertTrue(SSHConfigurationTransport.needsAccess(endpoint:endpoint))}
        let f=try Fixture();defer{f.cleanup()};try await initialize(f)
        try f.files.store.remember(f.files.file,requireSecurityScope:true);f.files.bookmarks.failResolve=true
        let before=f.files.bookmarks.counts
        for args in [["status","--porcelain"],["submodule","status"],["submodule","summary"],["submodule","init"],["submodule","sync"],["credential","fill"],["remote","show","-n","origin"],["ls-remote","--get-url","https://example.invalid/repo"],["lfs","status"]] {
            let needed=try await f.repository.sshConfigurationNeeded(args,environment:f.environment,cancellation:nil)
            XCTAssertFalse(needed,"Metadata family unexpectedly requested SSH permissions")
        }
        _ = try await f.repository.run(["status","--porcelain"],environmentOverrides:f.environment)
        XCTAssertEqual(f.files.bookmarks.counts.resolves,before.resolves)
    }
    func testGitResolvedURLRewritesAndCapturedOverrides()async throws {
        let f=try Fixture();defer{f.cleanup()};try await initialize(f)
        func configure(_ key:String,_ value:String)async throws {_ = try await f.repository.run(["config",key,value],environmentOverrides:f.environment)}
        try await configure("remote.origin.url","https://example.invalid/repo")
        try await configure("remote.origin.pushurl","user@alias:push/repo")
        try await configure("url.ssh://alias/.insteadOf","https://rewritten.invalid/")
        try await configure("url.ssh://alias/.pushInsteadOf","https://push-rewritten.invalid/")
        try await configure("url.https://long-target.invalid/KeepCase/.pushInsteadOf","https://push-rewritten.invalid/public/")
        try await configure("remotes.https-only","origin")
        let config=f.files.root.appendingPathComponent(".git/config")
        let tieRules="\n[url \"https://TieTarget.invalid/KeepCase/\"]\n pushInsteadOf = unused-prefix:\n[url \"ssh://tie-alias/\"]\n pushInsteadOf = tie-input:\n[url \"https://TieTarget.invalid/KeepCase/\"]\n pushInsteadOf = tie-input:\n"
        let writer=try FileHandle(forWritingTo:config);try writer.seekToEnd();try writer.write(contentsOf:Data(tieRules.utf8));try writer.close()
        let cases:[([String],Bool)]=[
            (["fetch","--","origin"],false),(["push","--","origin"],true),
            (["fetch","--multiple","https-only"],false),(["remote","update","https-only"],false),
            (["clone","--","https://rewritten.invalid/repo","new"],true),
            (["push","--","https://push-rewritten.invalid/repo"],true),
            (["push","--","https://push-rewritten.invalid/public/repo"],false),
            (["push","--","tie-input:repo"],false),
            (["-c","url.ssh://empty-alias/.pushInsteadOf=","push","--","https://empty-rewrite.invalid/repo"],true),
            (["push","--","https://other.invalid/repo"],false),
            (["push","--repo","user@alias:target","HEAD"],true),
            (["push","--repo=ssh://alias/target","HEAD"],true),
            (["push","--repo=https://other.invalid/target","HEAD"],false),
            (["-c","remote.origin.url=ssh://alias/repo","fetch","--","origin"],true),
            (["-c","remote.ssh.url=ssh://alias/repo","fetch","--deepen","3","ssh"],true),
            (["-c","remote.ssh.url=ssh://alias/repo","lfs","fetch","ssh"],true),
            (["--turtlegit-transfer-notifications","--turtlegit-source-fetch","fetch","--","origin"],false),
            (["request-pull","HEAD","user@alias:repo","main"],true),
            (["submodule","add","--","https://other.invalid/repo","child"],false)]
        for (args,expected) in cases {let actual=try await f.repository.sshConfigurationNeeded(args,environment:f.environment,cancellation:nil);XCTAssertEqual(actual,expected,"SSH authority classification for authored argv \(String(reflecting:args))")}
        let fromEnvironment=try await f.repository.sshConfigurationNeeded(["--config-env=url.ssh://env-alias/.pushInsteadOf=SSH_SCOPE_REWRITE","push","--","https://env-rewrite.invalid/repo"],environment:f.environment.merging(["SSH_SCOPE_REWRITE":"https://env-rewrite.invalid/"]){_,new in new},cancellation:nil)
        XCTAssertTrue(fromEnvironment,"Anonymous push ignored captured --config-env rewrite")
        let opaque=try await f.repository.sshConfigurationNeeded(["fetch","--","display-only"],argumentBytes:[2:Data("ssh://alias/雪".utf8)],environment:f.environment,cancellation:nil)
        XCTAssertTrue(opaque)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.marker.path),"Classification spawned a transport")
    }
    func testKnownHTTPSAndLocalBypassInvalidSelectedPermissionButSSHRefuses()async throws {
        let f=try Fixture();defer{f.cleanup()};try await initialize(f)
        try f.files.store.remember(f.files.file,requireSecurityScope:true);f.files.bookmarks.failResolve=true
        try Data().write(to:f.release)
        let before=f.files.bookmarks.counts
        for endpoint in ["https://example.invalid/repo",f.files.root.appendingPathComponent("local-source").path] {
            _ = try await f.repository.run(["fetch","--",endpoint],environmentOverrides:f.environment)
        }
        XCTAssertEqual(f.files.bookmarks.counts.resolves,before.resolves)
        try FileManager.default.removeItem(at:f.marker)
        do {_ = try await f.repository.run(["fetch","--","user@alias:repo"],environmentOverrides:f.environment);XCTFail("SSH silently bypassed an unavailable selected permission")}
        catch {XCTAssertTrue(error is SSHConfigurationAccessFailure)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.marker.path),"Refused permission still spawned transport")
        let previous=GitRuntime.sshConfigurationAccess
        GitRuntime.installSSHConfigurationAccess(f.files.store)
        let captured=GitRepository(root:f.files.root,executable:f.executable,askpass:nil)
        let plain=GitRepository(root:f.files.root,executable:f.executable,askpass:nil,sshConfigurationAccess:nil)
        GitRuntime.installSSHConfigurationAccess(previous)
        XCTAssertTrue(captured.sshConfigurationAccess === f.files.store,"Repository lost the host's captured authority store")
        _ = try await plain.run(["fetch","--","user@alias:repo"],environmentOverrides:f.environment)
        XCTAssertTrue(plain.sshConfigurationAccess==nil)
    }
    func testScopesSurviveForgetAndCancellationUntilOwnedChildDrains()async throws {
        let f=try Fixture();defer{f.cleanup()};try await initialize(f)
        try f.files.store.remember(f.files.file,requireSecurityScope:true)
        let grants=try f.files.store.grants(),before=f.files.bookmarks.counts,token=OperationCancellation()
        let task=Task {try await f.repository.run(["--turtlegit-transfer-notifications","fetch","--","user@alias:repo"],environmentOverrides:f.environment,cancellation:token,executorOverride:f.executable)}
        do {
            try await waitFor(f.marker)
            XCTAssertEqual(f.files.bookmarks.counts.starts,before.starts+1)
            XCTAssertEqual(f.files.bookmarks.counts.stops,before.stops)
            try f.files.store.forget(grants)
            XCTAssertEqual(f.files.bookmarks.counts.stops,before.stops,"Forget revoked a running child's held scope")
            token.cancel()
            do {_ = try await task.value;XCTFail("Cancelled owned transport succeeded")}
            catch {XCTAssertTrue(token.isCancelled)}
            XCTAssertEqual(f.files.bookmarks.counts.starts,f.files.bookmarks.counts.stops)
            let raw=try Data(contentsOf:f.arguments).split(separator:0).map{String(decoding:$0,as:UTF8.self)}
            XCTAssertEqual(Array(raw.suffix(4)),["--turtlegit-transfer-notifications","fetch","--","user@alias:repo"])
            let resolved=f.files.bookmarks.counts.resolves
            try Data().write(to:f.release)
            _ = try await f.repository.run(["fetch","--","user@alias:repo"],environmentOverrides:f.environment)
            XCTAssertEqual(f.files.bookmarks.counts.resolves,resolved,"A new operation restored a forgotten grant")
        }catch {token.cancel();try? Data().write(to:f.release);_ = try? await task.value;throw error}
    }
    func testRecursiveHTTPSParentsCannotBypassSelectedSSHAuthority()async throws {
        let f=try Fixture();defer{f.cleanup()};try await initialize(f)
        try f.files.store.remember(f.files.file,requireSecurityScope:true);f.files.bookmarks.failResolve=true
        try Data().write(to:f.release)
        let https="https://example.invalid/parent"
        _ = try await f.repository.run(["clone","--",https,"destination"],environmentOverrides:f.environment)
        try FileManager.default.removeItem(at:f.marker)
        for options in [["--recursive"],["--recurse-submodules"],["--recurse-submodules=selected-path"]] {
            do {_ = try await f.repository.run(["clone"]+options+["--",https,"destination"],environmentOverrides:f.environment);XCTFail("Recursive HTTPS parent bypassed its possible SSH children")}
            catch {XCTAssertTrue(error is SSHConfigurationAccessFailure)}
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.marker.path))
        }
        _ = try await f.repository.run(["clone","--recursive","--no-recurse-submodules","--",https,"destination"],environmentOverrides:f.environment)
        try FileManager.default.removeItem(at:f.marker)
        let modules="[submodule \"child\"]\n path = child\n url = ssh://alias/child\n"
        try Data(modules.utf8).write(to:f.files.root.appendingPathComponent(".gitmodules"))
        let classify:[([String],Bool)]=[
            (["fetch","--",https],true),(["pull","--",https],true),
            (["fetch","--recurse-submodules=no","--",https],false),
            (["pull","--no-recurse-submodules","--",https],false),
            (["-c","fetch.recurseSubmodules=false","fetch","--",https],false),
            (["-c","push.recurseSubmodules=on-demand","push","--",https],true),
            (["-c","submodule.recurse=true","push","--",https],true),
            (["push","--recurse-submodules=no","--",https],false),
            (["remote","update"],true),(["lfs","migrate","info"],true)]
        for (args,expected) in classify {let value=try await f.repository.sshConfigurationNeeded(args,environment:f.environment,cancellation:nil);XCTAssertEqual(value,expected,"Recursive SSH authority classification for authored argv \(String(reflecting:args))")}
        do {_ = try await f.repository.run(["fetch","--",https],environmentOverrides:f.environment);XCTFail("Default on-demand fetch bypassed existing SSH submodule authority")}
        catch {XCTAssertTrue(error is SSHConfigurationAccessFailure)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.marker.path))
        _ = try await f.repository.run(["fetch","--no-recurse-submodules","--",https],environmentOverrides:f.environment)
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.marker.path))
    }
    func testSSHSigningAndExplicitVerificationKeepTransportPolicySeparate()async throws {
        let f=try Fixture();defer{f.cleanup()};try await initialize(f)
        let ssh=["-c","gpg.format=ssh"],signed=ssh+["-c","commit.gpgsign=true"]
        let cases:[([String],Bool)]=[
            (signed+["commit","-m","private fixture"],true),
            (signed+["commit","--no-gpg-sign","-m","private fixture"],false),
            (signed+["commit","--dry-run"],false),(signed+["commit","-m","--no-gpg-sign"],true),
            (ssh+["commit","-s","-S","-m","fixture"],true),
            (["-c","gpg.format=openpgp","-c","commit.gpgsign=true","commit","-S"],false),
            (ssh+["tag","-u","authored-key","fixture"],true),
            (ssh+["-c","tag.gpgsign=true","tag","--list"],false),
            (ssh+["rebase","--continue"],true),(signed+["merge","--no-commit","other"],false),
            (["verify-commit","HEAD"],true),(["verify-tag","fixture"],true),
            (["show","--show-signature","HEAD"],true),(["show","--","--show-signature"],false)]
        for (args,expected) in cases {let needed=try await f.repository.sshConfigurationNeeded(args,environment:f.environment,cancellation:nil);XCTAssertEqual(needed,expected,"Signing SSH authority classification for authored argv \(String(reflecting:args))")}
        XCTAssertFalse(GitAskpassRuntime.mayAuthenticate(signed+["commit","-S"]))
    }
}
