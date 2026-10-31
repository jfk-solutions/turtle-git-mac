import XCTest
import Darwin
@testable import TurtleGitCore

final class GitCommandDiagnosticsTests:XCTestCase {
    private final class Recorder:@unchecked Sendable {
        private let lock=NSLock()
        private var storage=[GitCommandDiagnosticEvent]()
        func append(_ event:GitCommandDiagnosticEvent){lock.lock();storage.append(event);lock.unlock()}
        var events:[GitCommandDiagnosticEvent]{lock.lock();defer{lock.unlock()};return storage}
    }
    func testSanitizedCommandMetadataRetainsSafeArgumentsWithoutPayloads() {
        let samples:[([String],[String])]=[
            (["-c","http.extraHeader=Bearer CONFIG_SECRET","commit","-amCOMMIT_SECRET","--","safe path.txt"],["CONFIG_SECRET","COMMIT_SECRET"]),
            (["-cturtle.value=CONFIG_ATTACHED","commit","-m","MESSAGE_SECRET"],["CONFIG_ATTACHED","MESSAGE_SECRET"]),
            (["push","-oPUSH_SECRET","--push-option=PUSH_EQUALS","origin","main"],["PUSH_SECRET","PUSH_EQUALS"]),
            (["config","--local","credential.helper","!echo CONFIG_POSITIONAL"],["!echo CONFIG_POSITIONAL"]),
            (["fetch","https://URL_USER:URL_PASSWORD@example.invalid/repo?unknown=QUERY_SECRET#FRAGMENT_SECRET"],["URL_USER","URL_PASSWORD","QUERY_SECRET","FRAGMENT_SECRET"]),
            (["fetch","--password","FLAG_SECRET","--oauth2-bearer=OAUTH_SECRET","--header=HEADER_SECRET"],["FLAG_SECRET","OAUTH_SECRET","HEADER_SECRET"]),
            (["/command:commit","/logmsg:LEGACY_MESSAGE:still=private","/path:/Users/private/safe repo"],["LEGACY_MESSAGE","still=private"]),
            (["/COMMAND:commit","/LoGmSgFiLe:/private/MESSAGE_FILE_SECRET","/msg:STASH_MESSAGE_SECRET","/message:ALIAS_MESSAGE_SECRET"],["MESSAGE_FILE_SECRET","STASH_MESSAGE_SECRET","ALIAS_MESSAGE_SECRET"]),
            (["--command","commit","--logmsg","NATIVE_MESSAGE_SECRET","--msg=NATIVE_MSG_EQUALS","--log-message","NATIVE_ALIAS_SECRET"],["NATIVE_MESSAGE_SECRET","NATIVE_MSG_EQUALS","NATIVE_ALIAS_SECRET"]),
            (["/command:commit","-qmNATIVE_SHORT_SECRET","/url:https://LEGACY_USER:LEGACY_PASSWORD@example.invalid/repo?unknown=LEGACY_QUERY"],["NATIVE_SHORT_SECRET","LEGACY_USER","LEGACY_PASSWORD","LEGACY_QUERY"])
        ]
        for (arguments,secrets) in samples {
            let safe=GitCommandDiagnostics.sanitizedArguments(arguments).joined(separator:" ")
            for secret in secrets {XCTAssertFalse(safe.contains(secret),safe)}
        }
        XCTAssertEqual(GitCommandDiagnostics.sanitizedArguments(["diff","--stat","--","safe path.txt"]),["diff","--stat","--","safe path.txt"])
        XCTAssertEqual(GitCommandDiagnostics.sanitizedArguments(["/command:commit","/path:/Users/private/safe repo"]),["/command:commit","/path:/Users/private/safe repo"])
        XCTAssertEqual(GitCommandDiagnostics.sanitizedArguments(["--command=commit","--path","/Users/private/safe repo"]),["--command=commit","--path","/Users/private/safe repo"])
        XCTAssertTrue(GitCommandDiagnostics.sanitizedArguments(samples[4].0).joined().contains("example.invalid/repo"))
        XCTAssertFalse(GitCommandDiagnostics.sanitizedText("line\nforged\u{1b}[31m").contains("\n"))
        XCTAssertLessThanOrEqual(GitCommandDiagnostics.sanitizedText(String(repeating:"x",count:10000)).count,256)
        XCTAssertEqual(GitCommandDiagnostics.sanitizedArguments(Array(repeating:"path",count:100)).count,65)
    }
    private func verify(executable:URL)async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit diagnostics "+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{GitCommandDiagnostics.installSink(nil);try? FileManager.default.removeItem(at:root)}
        let repository=GitRepository(root:root,executable:executable,askpass:nil,libgit2Configuration:.init(enabled:false))
        let environment=["HOME":root.path,"XDG_CONFIG_HOME":root.appendingPathComponent("xdg").path,"GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_COUNT":"0"]
        _=try await repository.run(["init","--initial-branch=main"],environmentOverrides:environment)
        for (key,value) in [("user.name","Private QA"),("user.email","qa@example.invalid"),("commit.gpgSign","false")] {_=try await repository.run(["config",key,value],environmentOverrides:environment)}
        let recorder=Recorder();GitCommandDiagnostics.installSink{recorder.append($0)}
        let message="PRIVATE_COMMIT_MESSAGE_"+UUID().uuidString,config="PRIVATE_CONFIG_"+UUID().uuidString
        _=try await repository.run(["-c","turtle.private="+config,"commit","--allow-empty","-m",message],environmentOverrides:environment)
        var events=recorder.events
        XCTAssertEqual(events.count,2);XCTAssertEqual(events.first?.phase,.started);XCTAssertEqual(events.last?.phase,.finished)
        XCTAssertEqual(events.first?.id,events.last?.id);XCTAssertEqual(events.last?.exitCode,0);XCTAssertEqual(events.last?.cancelled,false)
        XCTAssertNotNil(events.last?.elapsed)
        XCTAssertFalse(events.map(\.rendered).joined().contains(message));XCTAssertFalse(events.map(\.rendered).joined().contains(config))
        // Tracing does not change real argv: Git stored the exact private message.
        GitCommandDiagnostics.installSink(nil)
        let stored=try await repository.run(["log","-1","--format=%B"],environmentOverrides:environment)
        XCTAssertEqual(stored.text.trimmingCharacters(in:.newlines),message)
        XCTAssertEqual(recorder.events.count,2,"Disabled tracing must not publish events")
        GitCommandDiagnostics.installSink{recorder.append($0)}
        let beforeFailure=recorder.events.count
        do {_=try await repository.run(["rev-parse","--verify","missing-private-diagnostic-ref"],environmentOverrides:environment);XCTFail("Missing revision succeeded")}
        catch is GitFailure {}
        events=Array(recorder.events.dropFirst(beforeFailure));XCTAssertEqual(events.count,2);XCTAssertEqual(events.last?.exitCode,128)
        XCTAssertFalse(events.map(\.rendered).joined().contains("fatal:"),"Raw stderr must not enter metadata")
        let beforeVersion=recorder.events.count
        let version=try await repository.executableVersion(environmentOverrides:environment)
        XCTAssertTrue(version.text.hasPrefix("git version "));XCTAssertEqual(recorder.events.count,beforeVersion+2)
        let preCancelled=OperationCancellation();preCancelled.cancel()
        let beforeCancelled=recorder.events.count
        do {_=try await repository.run(["status"],environmentOverrides:environment,cancellation:preCancelled);XCTFail("Pre-cancelled command ran")}
        catch is OperationCancellationFailure {}
        XCTAssertEqual(recorder.events.count,beforeCancelled,"No process launch attempt occurred")
        // Raw diagnostic captions never replace the actual byte argument, and
        // neither the raw bytes nor stdin/output are handed to the sink.
        GitCommandDiagnostics.installSink(nil)
        _=try await repository.run(["config","turtle.private",config],environmentOverrides:environment)
        GitCommandDiagnostics.installSink{recorder.append($0)}
        let beforeRaw=recorder.events.count
        let raw=try await repository.run(["config","--get","RAW_CAPTION_SECRET"],argumentBytes:[2:Data("turtle.private".utf8)],environmentOverrides:environment,input:Data("STDIN_SECRET".utf8))
        XCTAssertEqual(raw.text.trimmingCharacters(in:.newlines),config)
        let rawText=recorder.events.dropFirst(beforeRaw).map(\.rendered).joined()
        for secret in [config,"RAW_CAPTION_SECRET","STDIN_SECRET"] {XCTAssertFalse(rawText.contains(secret))}

        // Hold a real Git pre-commit child. The terminal event must follow the
        // owned process runner's cancellation/drain, not the cancel request.
        let hook=root.appendingPathComponent(".git/hooks/pre-commit"),marker=root.appendingPathComponent("held-pids")
        let script="""
        #!/bin/sh
        /bin/sleep 30 & child=$!
        printf '%s %s\\n' "$$" "$child" > '\(marker.path)'
        wait "$child"
        """
        try Data(script.utf8).write(to:hook)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        let token=OperationCancellation(),beforeHeld=recorder.events.count
        let work=Task{try await repository.run(["commit","--allow-empty","-m","CANCEL_MESSAGE_SECRET"],environmentOverrides:environment,cancellation:token)}
        var pids=[Int32]()
        for _ in 0..<1000 {
            if let text=try? String(contentsOf:marker,encoding:.utf8) {pids=text.split(whereSeparator: \.isWhitespace).compactMap{Int32($0)};if pids.count==2 {break}}
            try? await Task.sleep(nanoseconds:5_000_000)
        }
        let heldEvents=Array(recorder.events.dropFirst(beforeHeld))
        token.cancel()
        do {_=try await work.value;XCTFail("Cancelled Git commit succeeded")}
        catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {}
        XCTAssertEqual(pids.count,2,"Actual hook and child must reach held execution")
        XCTAssertEqual(heldEvents.count,1);XCTAssertEqual(heldEvents.first?.phase,.started)
        events=Array(recorder.events.dropFirst(beforeHeld));XCTAssertEqual(events.count,2)
        XCTAssertEqual(events.first?.id,events.last?.id);XCTAssertEqual(events.last?.phase,.finished);XCTAssertEqual(events.last?.cancelled,true)
        XCTAssertNotNil(events.last?.exitCode)
        for _ in 0..<500 {if pids.allSatisfy({kill($0,0) != 0}) {break};try? await Task.sleep(nanoseconds:10_000_000)}
        for pid in pids {XCTAssertEqual(kill(pid,0),-1,"Terminal diagnostics must follow owned child drain")}
        XCTAssertFalse(events.map(\.rendered).joined().contains("CANCEL_MESSAGE_SECRET"))
    }
    func testSystemGitLifecycleRedactionDisabledAndCancellation()async throws {try await verify(executable:URL(fileURLWithPath:"/usr/bin/git"))}
    func testBundledGitLifecycleRedactionDisabledAndCancellation()async throws {
        let executable=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/git-runtime/Git/bin/git")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else{throw XCTSkip("Bundled Git runtime not present")}
        try await verify(executable:executable)
    }
}
