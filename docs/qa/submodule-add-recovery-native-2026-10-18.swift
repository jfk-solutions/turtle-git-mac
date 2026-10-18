// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore
import Darwin

// Inject the private file-selection grant used by the native Browse path;
// the coordinator still has to acquire and retain the selected key permission.
private final class AddRecoveryIdentityBookmarks:RepositoryBookmarkProvider {
    var starts=0,stops=0
    func create(for url:URL) throws -> Data {Data(url.path.utf8)}
    func resolve(_ data:Data) throws -> ResolvedBookmark {ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {starts += 1;return true}
    func stopAccessing(_ url:URL) {stops += 1}
}
private actor AddRecoveryCredentials:SSHAuthenticationStore {
    func read(identity:String)->String? {nil}
    func save(identity:String,name:String,passphrase:String) {}
    func entries()->[SSHAuthenticationEntry] {[]}
    func remove(identity:String) {}
}
@MainActor enum SubmoduleAddRecoveryVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String? {message}}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(message:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2400 {if ready() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Submodule Add recovery did not settle at \(line)")
    }
    static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let sourceRoot=root.appendingPathComponent("source"),checkout=root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at:sourceRoot,withIntermediateDirectories:true)
        let source=GitRepository(root:sourceRoot,executable:git)
        _ = try await source.run(["init","-b","main"])
        for (key,value) in [("user.name","Add recovery QA"),("user.email","add@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await source.run(["config",key,value])}
        try Data("base\n".utf8).write(to:sourceRoot.appendingPathComponent("file"));try await source.stage(["file"]);_ = try await source.commit(message:"base")
        _ = try await source.run(["clone",sourceRoot.path,checkout.path])
        let plain=GitRepository(root:checkout,executable:git),wrapper=root.appendingPathComponent("git-add-recovery"),key=root.appendingPathComponent("key")
        let generator=Process();generator.executableURL=URL(fileURLWithPath:"/usr/bin/ssh-keygen");generator.arguments=["-q","-t","ed25519","-N","","-C","private-add-recovery","-f",key.path]
        try generator.run();generator.waitUntilExit();try require(generator.terminationStatus == 0,"Private key generation failed")
        let quote="'"+git.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        let script="""
        #!/bin/sh
        task_add=
        task_key=
        for task_arg do
          case "$task_arg" in add) task_add=1;; remote.origin.turtlegitsshkeyfile) task_key=1;; esac
        done
        if [ -n "$task_add" ]; then printf '%s\\n' add >> "$0.adds"; fi
        if [ -n "$task_key" ]; then
          printf '%s\\n' key >> "$0.keys"
          if [ -f "$0.fail" ]; then printf '%s\\n' 'injected key setup failure' >&2; exit 73; fi
          if [ -f "$0.pause" ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.started"
            wait "$task_child"
          fi
        fi
        exec \(quote) -c protocol.file.allow=always "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let repo=GitRepository(root:checkout,executable:wrapper),fail=URL(fileURLWithPath:wrapper.path+".fail"),pause=URL(fileURLWithPath:wrapper.path+".pause"),marker=URL(fileURLWithPath:wrapper.path+".started")
        let agentRoot=URL(fileURLWithPath:"/tmp/tg-add-"+String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at:agentRoot,withIntermediateDirectories:true)
        let suite="TurtleGit.SubmoduleAddRecovery.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");defer {prefs.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:agentRoot)}
        let identityBookmarks=AddRecoveryIdentityBookmarks()
        let identities=SSHIdentityAccessStore(storageURL:root.appendingPathComponent("private-key-grants.json"),provider:identityBookmarks)
        try identities.remember(key,requireSecurityScope:true)
        try require(try identities.grants().count == 1,"Private Browse key grant was not recorded")
        var controllers:[SubmoduleAddProgressWindowController]=[],coordinators:[SSHTransportCoordinator]=[],factories=0,pids:[Int32]=[]
        func model(_ path:String)->SubmoduleAddProgressWindowModel {
            var options=SubmoduleAddOptions();options.source=sourceRoot.path;options.path=path;options.sshKey=key
            let model=SubmoduleAddProgressWindowModel(repository:repo,access:nil,sourceAccess:nil,keyAccess:nil,options:options,preferences:prefs,identities:identities,makeSSHCoordinator:{repository in
                factories += 1
                let value=SSHTransportCoordinator(repository:repository,identities:identities,temporaryRoot:agentRoot,credentials:AddRecoveryCredentials(),runtime:{SSHAgentRuntime(agent:URL(fileURLWithPath:"/usr/bin/ssh-agent"),add:URL(fileURLWithPath:"/usr/bin/ssh-add"))})
                coordinators.append(value);return value
            })
            let controller=SubmoduleAddProgressWindowController(model:model);controller.window?.alphaValue=0;controller.window?.orderFront(nil);controllers.append(controller);return model
        }
        func drained()->Bool {SubmoduleAddProgressWindowModel.activeOperations == 0 && SSHTransportCoordinator.activeOperations == 0}
        func cleanup() async throws {
            controllers.forEach {$0.close()};coordinators.forEach {$0.close()}
            try await wait {drained() && pids.allSatisfy {kill($0,0) != 0} && controllers.allSatisfy {$0.window?.isVisible != true && $0.window?.attachedSheet == nil}}
            try require((try? FileManager.default.contentsOfDirectory(atPath:agentRoot.path).isEmpty) == true,"Private agent directory survived cleanup")
            try require(identityBookmarks.starts == identityBookmarks.stops,"Private SSH key permission survived cleanup")
        }
        do {
            try Data().write(to:fail)
            let value=model("modules/recover ' 雪")
            var outcomes:[SubmoduleAddOutcome]=[],added=0
            value.onAttemptCompleted={outcomes.append($0)};value.onAdded={_ in added += 1};value.start()
            try await wait {!value.busy && drained()}
            // Keep the full parity assertion, but report each independent fact
            // so a failed phase, native footer or transport setup is identifiable.
            let attemptDiagnostics=outcomes.enumerated().map { index,outcome in
                "attempt[\(index)] phase=\(outcome.phase.rawValue) attempted=\(outcome.attempted) added=\(outcome.added) configured=\(outcome.configured) cancelled=\(outcome.cancelled) success=\(outcome.success) output=\(String(reflecting:outcome.output)) receipt=\(String(describing:outcome.receipt))"
            }.joined(separator:"\n")
            let partialDiagnostics="\(attemptDiagnostics)\nlastOutcome phase=\(value.lastOutcome.phase.rawValue) attempted=\(value.lastOutcome.attempted) added=\(value.lastOutcome.added) configured=\(value.lastOutcome.configured) success=\(value.lastOutcome.success) receipt=\(String(describing:value.lastOutcome.receipt))\ncurrentWork=\(String(reflecting:value.currentWork)) percentage=\(String(describing:value.percentage)) completionRange=\(String(describing:value.completionRange)) canRetry=\(value.canRetry) error=\(String(describing:value.error)) nativeOutput=\(String(reflecting:value.output)) factories=\(factories) addedCallbacks=\(added)"
            try require(outcomes.count == 1 && outcomes[0].attempted && outcomes[0].added && outcomes[0].output.contains("injected key setup failure") && !outcomes[0].configured && !outcomes[0].success && value.lastOutcome.receipt != nil && value.canRetry && value.currentWork.contains("73") && value.percentage == 100 && value.completionRange != nil && added == 0 && value.output.contains("submodule was added"),"Partial Add was not distinguished/notified from key configuration failure; \(partialDiagnostics)")
            let index=try Data(contentsOf:checkout.appendingPathComponent(".git/index")),head=try await plain.run(["rev-parse","HEAD"]).stdout
            let factoryCount=factories
            value.confirmingQuit=true;value.retry();try require(!value.busy && outcomes.count == 1,"Deferred Quit accepted key recovery");value.confirmingQuit=false
            try FileManager.default.removeItem(at:fail);value.retry();value.retry()
            try await wait {!value.busy && drained()}
            let keyValue=try await plain.run(["-C",checkout.appendingPathComponent("modules/recover ' 雪").path,"config","--local","--get","remote.origin.turtlegitsshkeyfile"]).text
            try require(value.success && outcomes.count == 2 && outcomes[1].success && added == 1 && factories == factoryCount && keyValue == key.path+"\n","Key-only recovery lost outcome/options or reopened SSH transport")
            let adds=try String(contentsOf:URL(fileURLWithPath:wrapper.path+".adds")),keys=try String(contentsOf:URL(fileURLWithPath:wrapper.path+".keys"))
            let afterHead=try await plain.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:checkout.appendingPathComponent(".git/index"))
            try require(adds == "add\n" && keys == "key\nkey\n" && index == afterIndex && head == afterHead,"Recovery repeated Add or changed HEAD/index")
            value.retry();try require(outcomes.count == 2,"Successful recovery allowed another retry")
            controllers.first?.close()

            // Close while key configuration ignores UI retirement until the
            // owned process actually unwinds. Partial mutation notification survives.
            try Data().write(to:pause)
            let retiring=model("modules/retiring")
            var retiredOutcomes:[SubmoduleAddOutcome]=[],lateSuccess=0
            retiring.onAttemptCompleted={retiredOutcomes.append($0)};retiring.onAdded={_ in lateSuccess += 1};retiring.start()
            try await wait {FileManager.default.fileExists(atPath:marker.path)}
            pids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap {Int32($0)}
            try require(pids.count == 2 && pids.allSatisfy {kill($0,0) == 0},"Owned key-write worker/sleep missing")
            controllers.last?.close()
            try require(SubmoduleAddProgressWindowModel.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced close released actual Add work/Quit too early")
            try await wait {drained() && pids.allSatisfy {kill($0,0) != 0}}
            try require(retiredOutcomes.count == 1 && retiredOutcomes[0].attempted && retiredOutcomes[0].added && retiredOutcomes[0].cancelled && !retiredOutcomes[0].success && lateSuccess == 0,"Retired partial Add lost notification or published success")
            try await cleanup()
            print("PASS: local Submodule Add/key failure phase, immutable child recovery without Add/SSH repeat, once-only typed partial/success callbacks, private agent cleanup, Quit and forced key-write cancellation with actual process drain; HEAD/index preserved during recovery")
        } catch {let original=error;do {try await cleanup()} catch {throw Failure(message:"\(original); cleanup: \(error)")};throw original}
    }
}
