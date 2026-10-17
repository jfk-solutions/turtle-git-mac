// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import TurtleGitCore

private final class DiagnosticChunks:@unchecked Sendable {
    private let lock=NSLock();private var bytes=Data()
    func append(_ chunk:GitOutputChunk) {lock.lock();bytes.append(chunk.data);lock.unlock()}
    var data:Data {lock.lock();defer {lock.unlock()};return bytes}
}
extension GitRepository {
    fileprivate func diagnosticReplayRun(_ arguments:[String],environment:[String:String]=[:],output:@escaping @Sendable(GitOutputChunk)->Void) throws ->GitResult {
        let previous=replayOutput;replayOutput=output;defer {replayOutput=previous}
        return try run(arguments,environmentOverrides:environment)
    }
}
final class GitCommandDiagnosticTests:XCTestCase {
    func testGlobalOptionsDoNotBecomeOperationOrConfigurationPayload() {
        let options:[[String]]=[["-c","core.foo=fetch"],["-C","push"],["--git-dir","svn"],["--work-tree=clone"],["--namespace","commit"],["--config-env","core.foo=PUSH"],["--config-env=core.askpass=PRIVATE_ENV"],["--shallow-file","rebase"],["--attr-source","reset"],["--attr-source=refs/tags/one"],["--exec-path=/tmp/git"],["--no-advice","--no-lazy-fetch","--no-optional-locks"],["--literal-pathspecs","--no-literal-pathspecs","--glob-pathspecs","--noglob-pathspecs","--icase-pathspecs"],["-p","-P","--paginate","--no-pager","--bare","--no-replace-objects"]]
        for prefix in options {
            let identity=GitCommandIdentity(prefix+["status","--","fetch","-c","core.askpass=path"])
            XCTAssertEqual(identity.command,"status",prefix.joined(separator:" "));XCTAssertEqual(identity.arguments,["--","fetch","-c","core.askpass=path"])
            XCTAssertEqual(identity.overridesConfiguration("core.askpass"),prefix==["--config-env=core.askpass=PRIVATE_ENV"])
            XCTAssertFalse(GitAskpassRuntime.mayAuthenticate(prefix+["status","push"]))
        }
        for invalid in [["-c"],["-C"],["--namespace"],["--config-env"],["--unknown","private-value","fetch"],["-ctoken=private","push"],["--","push"]] {XCTAssertNil(GitCommandIdentity(invalid).command)}
        for (args,command) in [(["-c","x.y=z","--version"],"version"),(["-h","status"],"help"),(["--exec-path","status"],"--exec-path"),(["--list-cmds=main"],"--list-cmds")] {XCTAssertEqual(GitCommandIdentity(args).command,command)}
    }
    func testFailureSummaryNamesOperationWithoutOptionValuesAndRetainsRawResult() {
        let args=["-c","http.extraHeader=PRIVATE_TOKEN","-C","/private/path","stash","apply","stash@{2}"],stderr=Data("fatal: unavailable\n".utf8)
        let failure=GitFailure(arguments:args,code:128,message:"stdout\nfatal: unavailable\n",standardError:stderr)
        XCTAssertEqual(failure.summary,"git stash apply failed (128)");XCTAssertFalse(failure.summary.contains("PRIVATE_TOKEN"));XCTAssertFalse(failure.summary.contains("private/path"))
        XCTAssertEqual(failure.diagnosticText,"fatal: unavailable\n");XCTAssertTrue(failure.localizedDescription.contains("stdout\n"))
        let presented=failure.markingOutputDelivered();XCTAssertFalse(failure.outputWasDelivered);XCTAssertTrue(presented.outputWasDelivered)
        XCTAssertEqual(presented.arguments,args);XCTAssertEqual(presented.message,failure.message);XCTAssertEqual(presented.standardError,stderr);XCTAssertEqual(presented.code,128)
        XCTAssertEqual(GitFailure(arguments:["--unknown","PRIVATE_TOKEN"],code:129,message:"usage").summary,"Git command failed (129)")
        XCTAssertEqual(GitFailure(arguments:["bad\nname"],code:1,message:"bad command").summary,"Git command failed (1)")
        XCTAssertEqual(GitCommandIdentity(["-c","x.y=z","svn","clone","url"]).displayName,"svn clone")
    }
    func testAskpassDependsOnRealOperationAndOnlyGlobalOverrides() {
        let helper=URL(fileURLWithPath:"/tmp/owned-helper")
        for args in [["log","push"],["show","svn"],["config","fetch"],["diff","credential"],["-C","push","status"],["--namespace","fetch","log"]] {XCTAssertFalse(GitAskpassRuntime.mayAuthenticate(args))}
        for command in ["fetch","push","clone","pull","ls-remote","svn","lfs","submodule","credential"] {XCTAssertTrue(GitAskpassRuntime.mayAuthenticate(["-c","core.foo=status",command]))}
        for action in ["update","prune","show"] {XCTAssertTrue(GitAskpassRuntime.mayAuthenticate(["--no-pager","remote",action,"origin"]))}
        XCTAssertFalse(GitAskpassRuntime.mayAuthenticate(["remote","get-url","fetch"]))
        XCTAssertTrue(GitAskpassRuntime.mayAuthenticate(["remote","-v","update","origin"]))
        for prefix in [["-c","CORE.ASKPASS="],["--config-env","core.askpass=PRIVATE"],["--config-env=core.askpass=PRIVATE"]] {XCTAssertFalse(GitAskpassRuntime.shouldInstall(arguments:prefix+["fetch"],environment:[:],helper:helper))}
        XCTAssertTrue(GitAskpassRuntime.shouldInstall(arguments:["fetch","core.askpass=remote-name"],environment:[:],helper:helper))
    }
    func testRepositoryFailureCarriesStderrAndActualDeliveryMetadata() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root);_=try await repo.run(["init","-b","main"])
        let args=["-c","core.precomposeunicode=false","-C",root.path,"rev-parse","--verify","refs/heads/absent"]
        for live in [false,true] {
            let chunks=DiagnosticChunks()
            let callback:(@Sendable (GitOutputChunk)->Void)?
            if live { callback = { chunk in chunks.append(chunk) } } else { callback = nil }
            do {_=try await repo.run(args,onOutput:callback);XCTFail("Missing ref succeeded")}
            catch let failure as GitFailure {
                XCTAssertEqual(failure.identity.command,"rev-parse");XCTAssertEqual(failure.outputWasDelivered,live)
                XCTAssertFalse(failure.standardError?.isEmpty ?? true);XCTAssertTrue(failure.message.contains("fatal:"))
                if live {XCTAssertEqual(chunks.data,failure.standardError)}
            }
        }
        // A synchronous parser consumer is not a live UI-output callback.
        do {_=try await repo.run(args,consumeOutput:{_ in});XCTFail("Missing ref succeeded")}
        catch let failure as GitFailure {XCTAssertFalse(failure.outputWasDelivered)}
    }
    func testReplayOutputUsesOperationAfterGlobalOptions() async throws {
        let (root,repo,_)=try await GitPatchTests().fixture();defer {try? FileManager.default.removeItem(at:root)}
        let unrelated=DiagnosticChunks()
        _=try await repo.diagnosticReplayRun(["--namespace","commit","version"],output:{unrelated.append($0)})
        XCTAssertTrue(unrelated.data.isEmpty,"Namespace value became a replay operation")
        let actual=DiagnosticChunks()
        _=try await repo.diagnosticReplayRun(["--config-env","commit.gpgsign=TURTLEGIT_DIAGNOSTIC_SIGN","commit","--allow-empty","-m","replay diagnostic"],environment:["TURTLEGIT_DIAGNOSTIC_SIGN":"false"],output:{actual.append($0)})
        XCTAssertTrue(String(decoding:actual.data,as:UTF8.self).contains("replay diagnostic"),"Prefixed Commit lost the scoped replay output callback")
    }
    func testCancellationDeliveryAnnotationRetainsFullPartialResult() {
        let result=GitResult(exitCode:143,stdout:Data("partial\n".utf8),stderr:Data("phase\r".utf8))
        let failure=GitCommandCancellationFailure(result:result),presented=failure.markingOutputDelivered()
        XCTAssertFalse(failure.outputWasDelivered);XCTAssertTrue(presented.outputWasDelivered)
        XCTAssertEqual(presented.result.stdout,result.stdout);XCTAssertEqual(presented.result.stderr,result.stderr);XCTAssertEqual(presented.result.exitCode,143)
    }
}
