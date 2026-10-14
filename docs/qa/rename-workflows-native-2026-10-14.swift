import AppKit
import TurtleGitCore
@main struct RenameWorkflowsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String)throws{if !condition{throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool)async throws{for _ in 0..<2000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Rename workflow timeout")}
    @MainActor static func main()async{do{try await verify()}catch{fputs("Rename workflows failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"]);for (key,value) in [("user.name","Rename QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        let path="file 雪\n.txt";try Data("base".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"base")
        try Data("staged".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);try Data("working".utf8).write(to:root.appendingPathComponent(path))
        let suite="TurtleGit.RenameWorkflow."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"ConfirmKillProcess");defer{prefs.removePersistentDomain(forName:suite)};ProgressActionLog.install(store:ActionLogStore(storageURL:root.appendingPathComponent("actions.log")),preferences:prefs)
        let owner=RenameWindowController(repository:repo,access:nil,source:path,preferences:prefs);defer{owner.close()}
        owner.model.name=path;owner.model.rename();try await wait{!owner.model.busy};try require(owner.model.error != nil && !owner.model.progress,"Invalid name did not remain in input")
        let folder=root.appendingPathComponent("folder",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);owner.model.chooseDestination(folder.appendingPathComponent("renamed.txt"));try await wait{!owner.model.busy};try require(owner.model.name=="folder/renamed.txt","Browse lost relative path")
        var callbacks:[(String,String)]=[],refreshed=0;owner.model.onRenamed={old,new,_ in callbacks.append((old,new))};owner.model.onChanged={refreshed += 1};owner.model.rename();try await wait{RenameWindowModel.activeOperations==0}
        let staged=try await repo.run(["show",":folder/renamed.txt"]).text;try require(owner.model.retired && refreshed==1 && callbacks.first?.0==path && callbacks.first?.1=="folder/renamed.txt" && staged=="staged" && String(contentsOf:folder.appendingPathComponent("renamed.txt"))=="working","Rename lost captured callback/index/worktree or close ownership")
        let helper=root.appendingPathComponent("gated-mv"),marker=root.appendingPathComponent(".git/mv-ready")
        let script = #"""
        #!/bin/sh
        if [ "$4" = mv ];then
          printf 'Rename: 10%%\rRename: 35%%\r\n'
          : > "$3/.git/mv-ready"
          while :;do /bin/sleep 0.05;done
        fi
        exec "$TG_RENAME_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_RENAME_GIT",git.path,1);defer{unsetenv("TG_RENAME_GIT")}
        let wrapped=GitRepository(root:root,executable:helper),slow=RenameWindowController(repository:wrapped,access:nil,source:"folder/renamed.txt",preferences:prefs);defer{slow.close()};slow.model.name="again.txt";slow.model.rename();try await wait{FileManager.default.fileExists(atPath:marker.path) && slow.model.output.contains("Rename: 35%")}
        try require(!slow.model.output.contains("Rename: 10%") && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Live rename stream/Quit lost")
        slow.model.cancel();try await wait{!slow.model.busy};try require(slow.model.cancelled && FileManager.default.fileExists(atPath:folder.appendingPathComponent("renamed.txt").path),"Cancellation moved gated file")
        slow.model.back();try require(!slow.model.progress && slow.model.name=="again.txt","Back lost entered name");slow.close()
        let late=RenameWindowController(repository:repo,access:nil,source:"folder/renamed.txt",preferences:prefs);var release:((String)->Void)?;late.model.resolveDestination={_,_ in await withCheckedContinuation{c in release={c.resume(returning:$0)}}};late.model.chooseDestination(folder.appendingPathComponent("late.txt"));try await wait{release != nil};late.close();try require(RenameWindowModel.activeOperations>0,"Retired browse read lost lifetime")
        release?("late.txt");try await wait{RenameWindowModel.activeOperations==0};try require(late.model.name=="renamed.txt","Retired destination reply changed input")
        print("Rename workflows: input error retention, same-worktree browse paths, actual staged/working preservation and successful close/callback, real mv stream/cancellation/Back, retained read/Quit lifetime and late destination suppression. Owned windows closed.")
    }
}
