import XCTest
@testable import TurtleGitCore

/// Core-only hosts have no installed repository-grant coordinator. Each case
/// installs its private callback and restores the neutral Core-host behavior.
final class GitReadPreparationTests:XCTestCase {
    private enum BarrierFailure:Error {case unexpectedPreparation,unexpectedAdditionalPreparation,missingEntry}
    private final class ReadCounter:@unchecked Sendable {
        private let lock=NSLock()
        private var count=0,finished=false
        func record()->Int {lock.lock();defer{lock.unlock()};count += 1;return count}
        var calls:Int {lock.lock();defer{lock.unlock()};return count}
        func finish(){lock.lock();finished=true;lock.unlock()}
        var completed:Bool {lock.lock();defer{lock.unlock()};return finished}
    }
    private final class HeldPreparation:@unchecked Sendable {
        let entered:XCTestExpectation
        private let condition=NSCondition()
        private var released=false,count=0
        let config:URL
        init(entered:XCTestExpectation,config:URL){self.entered=entered;self.config=config}
        var calls:Int {condition.lock();defer{condition.unlock()};return count}
        func open(){condition.lock();released=true;condition.broadcast();condition.unlock()}
        func prepare(_ cancellation:OperationCancellation?)throws {
            condition.lock();count += 1
            guard count==1 else {condition.unlock();throw BarrierFailure.unexpectedAdditionalPreparation}
            entered.fulfill()
            while !released {
                if cancellation?.isCancelled==true {condition.unlock();try cancellation?.check();return}
                _=condition.wait(until:Date().addingTimeInterval(0.01))
            }
            condition.unlock()
            try cancellation?.check()
            // Configuration becomes valid only after its authority is ready.
            // Launching the real config command before this callback returns
            // would therefore fail instead of producing the expected value.
            try Data("[turtle]\nreadiness = prepared\n".utf8).write(to:config,options:.atomic)
        }
    }
    private func verify(executable:URL)async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGit read preparation "+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root);GitRuntime.installReadPreparation{_ in}}
        let invalid=Data("[broken configuration\n".utf8),config=root.appendingPathComponent("global.config")
        try invalid.write(to:config)
        let environment=["GIT_CONFIG_GLOBAL":config.path,"GIT_CONFIG_NOSYSTEM":"1","GIT_CONFIG_COUNT":"0","HOME":root.path,"XDG_CONFIG_HOME":root.appendingPathComponent("xdg").path]
        let repository=GitRepository(root:root,executable:executable,libgit2Configuration:.init(enabled:false))
        GitRuntime.installReadPreparation{_ in}
        do {_=try await repository.run(["config","--global","--list"],environmentOverrides:environment);XCTFail("Malformed private global configuration was unexpectedly accepted")}
        catch {XCTAssertTrue(error is GitFailure,"Expected real Git to refuse the private malformed configuration: \(error)")}
        let counter=ReadCounter()
        GitRuntime.installReadPreparation{_ in _=counter.record();throw BarrierFailure.unexpectedPreparation}
        // Caller configuration and repository context are deliberately poisoned.
        // Metadata must isolate both after its env merge, without requiring or
        // creating any caller repository/worktree/index path.
        let unavailableRoot=root.appendingPathComponent("unavailable-caller-repository")
        let outsideCaller=root.appendingPathComponent("outside-caller-context")
        let probeRepository=GitRepository(root:unavailableRoot,executable:executable,libgit2Configuration:.init(enabled:false))
        var probeEnvironment=environment
        probeEnvironment["GIT_CONFIG_SYSTEM"]=config.path;probeEnvironment["GIT_CONFIG_NOSYSTEM"]="0"
        probeEnvironment["GIT_CONFIG_COUNT"]="not-a-number";probeEnvironment["GIT_CONFIG_PARAMETERS"]="'unterminated"
        for (key,leaf) in [("GIT_DIR","repository.git"),("GIT_WORK_TREE","worktree"),("GIT_COMMON_DIR","shared.git"),("GIT_INDEX_FILE","private-index")] {
            probeEnvironment[key]=outsideCaller.appendingPathComponent(leaf).path
        }
        probeEnvironment["GIT_CONFIG"]=config.path
        let version=try await probeRepository.executableVersion(environmentOverrides:probeEnvironment)
        XCTAssertEqual(version.exitCode,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:unavailableRoot.path),"Metadata probe must not create or depend on its caller's repository root")
        XCTAssertFalse(FileManager.default.fileExists(atPath:outsideCaller.path),"Metadata probe must not create caller repository/worktree/common-dir/index paths")
        XCTAssertTrue(version.stdout.starts(with:Data("git version ".utf8)),version.text)
        XCTAssertEqual(counter.calls,0,"Explicit executable metadata must not prepare repository/configuration grants")
        XCTAssertEqual(try Data(contentsOf:config),invalid,"A version probe must leave the invalid global config untouched")
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_=try await probeRepository.executableVersion(environmentOverrides:probeEnvironment,cancellation:cancelled);XCTFail("Pre-cancelled version probe unexpectedly ran")}
        catch {XCTAssertTrue(error is OperationCancellationFailure,"Version probe lost cancellation: \(error)")}
        XCTAssertEqual(counter.calls,0)

        struct Command {
            let name:String,arguments:[String],bytes:[Int:Data],executor:URL?
        }
        let protected=[
            Command(name:"generic plain version",arguments:["--version"],bytes:[:],executor:nil),
            Command(name:"ordinary config",arguments:["config","--global","--get","turtle.readiness"],bytes:[:],executor:nil),
            Command(name:"same raw version bytes",arguments:["--version"],bytes:[0:Data("--version".utf8)],executor:nil),
            Command(name:"raw replacement is a config command",arguments:["--version"],bytes:[0:Data("config".utf8)],executor:nil),
            Command(name:"prefixed version",arguments:["-c","turtle.readiness=inline","--version"],bytes:[:],executor:nil),
            Command(name:"version subcommand",arguments:["version"],bytes:[:],executor:nil),
            Command(name:"version with extra argument",arguments:["--version","--build-options"],bytes:[:],executor:nil),
            Command(name:"explicit alternate executor",arguments:["--version"],bytes:[:],executor:executable)
        ]
        for command in protected {
            let before=counter.calls
            do {
                _=try await repository.run(command.arguments,argumentBytes:command.bytes,environmentOverrides:environment,executorOverride:command.executor)
                XCTFail("\(command.name) bypassed the installed read-preparation boundary")
            } catch BarrierFailure.unexpectedPreparation {} catch {XCTFail("\(command.name) reached another boundary instead of preparation: \(error)")}
            XCTAssertEqual(counter.calls,before+1,command.name)
            XCTAssertEqual(try Data(contentsOf:config),invalid)
        }

        let entered=expectation(description:"Real Git config read reaches authority preparation")
        let gate=HeldPreparation(entered:entered,config:config),finished=ReadCounter(),token=OperationCancellation()
        GitRuntime.installReadPreparation{try gate.prepare($0)}
        let configTask=Task {
            defer{finished.finish()}
            return try await repository.run(["config","--global","--get","turtle.readiness"],environmentOverrides:environment,cancellation:token)
        }
        do {
            await fulfillment(of:[entered],timeout:5)
            guard gate.calls==1 else {throw BarrierFailure.missingEntry}
            // Another repository actor models an independent utility window.
            // It must complete while the real config command remains blocked.
            let independent=GitRepository(root:root.appendingPathComponent("still-unavailable-caller-repository"),executable:executable,libgit2Configuration:.init(enabled:false))
            let whileHeld=try await independent.executableVersion(environmentOverrides:probeEnvironment)
            XCTAssertTrue(whileHeld.stdout.starts(with:Data("git version ".utf8)))
            XCTAssertFalse(FileManager.default.fileExists(atPath:outsideCaller.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath:independent.root.path))
            XCTAssertEqual(gate.calls,1,"Explicit metadata probe reentered the held grant coordinator")
            XCTAssertFalse(finished.completed,"Real configuration read completed before authority preparation")
            XCTAssertEqual(try Data(contentsOf:config),invalid)
            gate.open()
            let prepared=try await configTask.value
            XCTAssertEqual(prepared.text.trimmingCharacters(in:.newlines),"prepared")
            XCTAssertTrue(finished.completed)
            XCTAssertEqual(gate.calls,1)
        } catch {
            token.cancel();gate.open();_=await configTask.result
            throw error
        }
    }
    func testSystemVersionProbeIsIndependentButConfigurationRequiresReadPreparation()async throws {
        try await verify(executable:URL(fileURLWithPath:"/usr/bin/git"))
    }
    func testBundledVersionProbeIsIndependentButConfigurationRequiresReadPreparation()async throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable=root.appendingPathComponent("build/git-runtime/Git/bin/git")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else {throw XCTSkip("Bundled Git runtime must be prepared for this engine-specific check")}
        try await verify(executable:executable)
    }
}
