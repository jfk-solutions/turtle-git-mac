import AppKit
import TurtleGitCore
@main struct RemovalProgressVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String)throws{if !condition{throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool)async throws{for _ in 0..<2000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Removal timeout")}
    @MainActor static func main()async{do{try await verify()}catch{fputs("Removal progress failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"]);for (key,value) in [("user.name","Remove QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        let paths=["first 雪\n.txt","second","third","fourth","last"];for path in paths{try Data(path.utf8).write(to:root.appendingPathComponent(path))};try await repo.stage(paths);_ = try await repo.commit(message:"base")
        let suite="TurtleGit.Removal."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"ConfirmKillProcess");defer{prefs.removePersistentDomain(forName:suite)};ProgressActionLog.install(store:ActionLogStore(storageURL:root.appendingPathComponent("private-actions.log")),preferences:prefs)
        let normal=RemoveWindowController(repository:repo,access:nil,request:try RemovalRequest(paths:[paths[0]],keepLocal:false),preferences:prefs);defer{normal.close()};normal.model.confirm={true};normal.start();try await wait{!normal.model.busy};try require(normal.model.removed==1 && !FileManager.default.fileExists(atPath:root.appendingPathComponent(paths[0]).path),"Normal removal did not execute");normal.close()
        let ordered=RemoveWindowController(repository:repo,access:nil,request:try RemovalRequest(paths:[paths[1],paths[2],paths[3]],keepLocal:true),preferences:prefs);defer{ordered.close()};var failures:[String]=[]
        ordered.model.confirm={try! Data("external change".utf8).write(to:root.appendingPathComponent(paths[2]),options:.atomic);return true};ordered.model.ignoreError={path,_ in failures.append(path);return true};var callbacks=0;ordered.onChanged={_ in callbacks += 1};ordered.start();try await wait{!ordered.model.busy}
        let tracked=try await repo.trackedPaths();try require(ordered.model.removed==2 && ordered.model.ignored==1 && failures==[paths[2]] && callbacks==1 && tracked.contains(paths[2]) && !tracked.contains(paths[1]) && !tracked.contains(paths[3]),"Stale confirmation/ordered Ignore lost exact effects")
        try require(paths[1...3].allSatisfy{FileManager.default.fileExists(atPath:root.appendingPathComponent($0).path)},"Keep local removed disk files");ordered.close()
        let helper=root.appendingPathComponent("stream-rm"),marker=root.appendingPathComponent(".git/rm-ready")
        let script = #"""
        #!/bin/sh
        if [ "$4" = rm ];then
          printf 'Remove: 10%%\rRemove: 35%%\r\n'
          : > "$3/.git/rm-ready"
          while :;do /bin/sleep 0.05;done
        fi
        exec "$TG_REMOVE_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_REMOVE_GIT",git.path,1);defer{unsetenv("TG_REMOVE_GIT")}
        let wrapped=GitRepository(root:root,executable:helper),slow=RemoveWindowController(repository:wrapped,access:nil,request:try RemovalRequest(paths:[paths[4]],keepLocal:false),preferences:prefs);defer{slow.close()};slow.model.confirm={true};let index=try await repo.run(["ls-files","--stage","-z"]).stdout;slow.start()
        try await wait{FileManager.default.fileExists(atPath:marker.path) && slow.model.output.contains("Remove: 35%")};try require(!slow.model.output.contains("Remove: 10%") && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Stream/owned Quit missing")
        slow.model.cancel();try await wait{!slow.model.busy && RemoveWindowModel.activeOperations==0};let after=try await repo.run(["ls-files","--stage","-z"]).stdout;try require(slow.model.cancelled && after==index && FileManager.default.fileExists(atPath:root.appendingPathComponent(paths[4]).path),"Cancelled removal mutated gated target");slow.close()
        // Retired confirmation reply cannot begin mutation, and remains counted.
        let late=RemoveWindowController(repository:repo,access:nil,request:try RemovalRequest(paths:[paths[4]],keepLocal:true),preferences:prefs);var release:((Bool)->Void)?,published=0;late.onChanged={_ in published += 1};late.model.confirm={await withCheckedContinuation{c in release={c.resume(returning:$0)}}};late.start();try await wait{release != nil};late.close();try require(RemoveWindowModel.activeOperations>0,"Forced closure dropped pending owned reply")
        release?(true);try await wait{RemoveWindowModel.activeOperations==0};let final=try await repo.trackedPaths();try require(published==0 && final.contains(paths[4]),"Retired confirmation removed/published")
        print("Removal family: actual normal/keep-local Git effects, captured stale-file refusal and ordered Ignore, one parent refresh, real streamed rm cancellation and unchanged gated index, retained pending confirmation/Quit lifetime and late-reply retirement. Owned windows closed.")
    }
}
