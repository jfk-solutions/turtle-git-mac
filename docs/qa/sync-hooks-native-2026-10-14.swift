import AppKit
import TurtleGitCore

@main struct SyncHooksVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ text:String) throws { if !value { throw Failure(description:text) } }
    @MainActor static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<2000 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) };throw Failure(description:"Sync hook timeout")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Sync hooks failed: \(error)\n",stderr);ClientHookProcessPool.shared.cancelAll();exit(1) }
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        let suite="TurtleGit.SyncHooks.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"AskSetTrackedBranch");prefs.set(false,forKey:"ConfirmKillProcess")
        defer { prefs.removePersistentDomain(forName:suite);ClientHookProcessPool.shared.cancelAll() }
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Sync Hooks QA"),("user.email","sync-hooks@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let remote=root.appendingPathComponent("remote.git");_ = try await repo.run(["init","--bare",remote.path]);_ = try await repo.run(["remote","add","origin",remote.path])
        _ = try await repo.run(["tag","test-tag"]);_ = try await repo.run(["notes","add","-m","sync-note"])
        let script=root.appendingPathComponent("hook.sh")
        try """
        phase="$1"
        root="$2"
        printf '%s\\n' "$phase" >> "$root/events"
        if [ -f "$root/slow-$phase" ]; then : > "$root/started-$phase"; /bin/sleep 30; fi
        if [ -f "$root/fail-$phase" ]; then printf '%s failed' "$phase" >&2; exit 9; fi
        """.write(to:script,atomically:true,encoding:.utf8)
        func hook(_ type:ClientHookType,_ phase:String)->ClientHook { ClientHook(type:type,path:root.path,command:"/bin/sh '"+script.path+"' "+phase+" '%root%'",show:false) }
        let globals=[hook(.prePush,"pre"),hook(.postPush,"post")]
        prefs.set(try ClientHookConfiguration.serialize(globals),forKey:"hooks")
        func events()->[String] { ((try? String(contentsOf:root.appendingPathComponent("events"))) ?? "").split(separator:"\n").map(String.init) }
        func make()->SynchronizationWindowModel {
            let value=SynchronizationWindowModel(repository:repo,access:nil,preferences:prefs);value.localBranch="main";value.remote="origin";value.remoteBranch="main";return value
        }
        let model=make();defer { model.invalidate() }
        for action in [SynchronizationTransportAction.push,.pushTags,.pushNotes] {
            let before=events().count;model.push(action,shift:false)
            try await wait { !model.busy && SynchronizationWindowModel.activePushWorkflows==0 && ClientHookProcessPool.shared.activeScripts==0 }
            try require(model.commandSucceeded && model.error==nil,"Direct Push mode failed: "+(model.error ?? "unknown"))
            try require(Array(events().dropFirst(before))==["pre","post"],"Direct mode skipped/duplicated hooks")
        }
        try Data().write(to:root.appendingPathComponent("fail-pre"))
        model.clientHooks.continueAfterFailure={ _ in false }
        let beforeAbort=events().count;model.push(.push,shift:false)
        try await wait { !model.busy && SynchronizationWindowModel.activePushWorkflows==0 && ClientHookProcessPool.shared.activeScripts==0 }
        try require(Array(events().dropFirst(beforeAbort))==["pre"] && !model.commandSucceeded && model.error?.contains("Pre-push hook failed")==true,"Abort ran transport/post hook")
        model.clientHooks.continueAfterFailure={ _ in true };let beforeContinue=events().count;model.push(.push,shift:false)
        try await wait { !model.busy && SynchronizationWindowModel.activePushWorkflows==0 && ClientHookProcessPool.shared.activeScripts==0 }
        try require(Array(events().dropFirst(beforeContinue))==["pre","post"] && model.commandSucceeded && model.commandOutput.contains("failure was continued"),"Continue lost post hook/output")
        try FileManager.default.removeItem(at:root.appendingPathComponent("fail-pre"))
        try Data("post failure revision\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"post failure")
        try Data().write(to:root.appendingPathComponent("fail-post"));model.push(.push,shift:false)
        try await wait { !model.busy && SynchronizationWindowModel.activePushWorkflows==0 && ClientHookProcessPool.shared.activeScripts==0 }
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,remoteHead=try await repo.run(["--git-dir",remote.path,"rev-parse","refs/heads/main"]).stdout
        try require(head==remoteHead && model.commandSucceeded && model.error?.contains("push succeeded, but") == true,"Post failure hid successful Push")
        try FileManager.default.removeItem(at:root.appendingPathComponent("fail-post"))
        // Git transport failure still owns its source post-action.
        let receive=remote.appendingPathComponent("hooks/pre-receive")
        try "#!/bin/sh\nexit 8\n".write(to:receive,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:receive.path)
        try Data("rejected revision\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"rejected")
        let beforeReject=events().count;model.push(.push,shift:false)
        try await wait { !model.busy && SynchronizationWindowModel.activePushWorkflows==0 && ClientHookProcessPool.shared.activeScripts==0 }
        try require(!model.commandSucceeded && Array(events().dropFirst(beforeReject))==["pre","post"],"Rejected Push skipped its post-action")
        try FileManager.default.removeItem(at:receive)
        // A forced owner exit cancels a waiting hook and cannot push or run Post.
        try Data().write(to:root.appendingPathComponent("slow-pre"));let closing=make();closing.push(.push,shift:false)
        try await wait { FileManager.default.fileExists(atPath:root.appendingPathComponent("started-pre").path) }
        try require(SynchronizationWindowModel.activePushWorkflows==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped active Push hook")
        let beforeClose=events().count;closing.invalidate()
        try await wait { SynchronizationWindowModel.activePushWorkflows==0 && ClientHookProcessPool.shared.activeScripts==0 }
        try require(events().count==beforeClose && closing.closed,"Retired Push continued hooks")
        try FileManager.default.removeItem(at:root.appendingPathComponent("slow-pre"))
        // Shift delegates hooks to the full Push child instead of running them twice.
        let shifted=make();var options=0;shifted.runPushOptions={ _ in options += 1 }
        let beforeShift=events().count;shifted.push(.push,shift:true)
        try await wait { !shifted.busy && SynchronizationWindowModel.activePushWorkflows==0 }
        try require(options==1 && events().count==beforeShift,"Shift duplicated full-dialog hooks");shifted.invalidate()
        print("Sync hooks: Push/tags/notes Pre/Post, Abort/Continue, successful Push with post failure, rejected Push post-action, closed hook/process/Quit lifetime and Shift delegation passed. Private hooks/repos/preferences; owned operations settled.")
    }
}
