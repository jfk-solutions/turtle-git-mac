import AppKit
import TurtleGitCore
@main struct RebaseReplayProgressVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String)throws{if !condition{throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws{for _ in 0..<2500{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Replay progress timeout line \(line)")}
    @MainActor static func main()async{do{try await verify()}catch{fputs("Replay progress failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"]);for (key,value) in [("user.name","Replay QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        try Data("base".utf8).write(to:root.appendingPathComponent("base"));try await repo.stage(["base"]);_ = try await repo.commit(message:"base");let base=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["checkout","-b","upstream"]);try Data("up".utf8).write(to:root.appendingPathComponent("up"));try await repo.stage(["up"]);_ = try await repo.commit(message:"up")
        _ = try await repo.run(["checkout","-b","topic",base.hash]);try Data("first".utf8).write(to:root.appendingPathComponent("first"));try await repo.stage(["first"]);_ = try await repo.commit(message:"first")
        try Data("second".utf8).write(to:root.appendingPathComponent("second"));try await repo.stage(["second"]);_ = try await repo.commit(message:"second")
        var options=RebaseOptions();options.branch="topic";options.upstream="upstream";var plan=try await repo.rebasePlan(options);plan.entries[0].action = .edit
        let editor=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac");_ = try await repo.startRebase(plan,editorExecutable:editor)
        let helper=root.appendingPathComponent("gated-replay"),marker=root.appendingPathComponent(".git/replay-ready")
        let script = #"""
        #!/bin/sh
        replay=0;mode=
        for argument in "$@";do [ "$argument" = rebase ] && replay=1;case "$argument" in --continue|--abort) mode="$argument";;esac;done
        if [ "$replay" = 1 ] && [ "$mode" = "$TG_REPLAY_GATE" ];then
          printf 'Replay: 10%%\rReplay: 35%%\r\nUnicode ';printf '\351\233';/bin/sleep 0.05;printf '\252\n'
          : > "$3/.git/replay-ready"
          while :;do /bin/sleep 0.05;done
        fi
        exec "$TG_REPLAY_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_REPLAY_GIT",git.path,1);setenv("TG_REPLAY_GATE","--continue",1);defer{unsetenv("TG_REPLAY_GIT");unsetenv("TG_REPLAY_GATE")}
        let wrapped=GitRepository(root:root,executable:helper),suite="TurtleGit.ReplayProgress."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;prefs.set(true,forKey:"ConfirmKillProcess");prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");defer{prefs.removePersistentDomain(forName:suite)}
        let controller=RebaseWindowController(repository:wrapped,access:nil,preferences:prefs),model=controller.model;defer{controller.close()};model.load();try await wait{!model.busy && model.state?.isEditPause==true}
        var questions=0;model.confirmReplayCancellation={questions += 1;return questions>1};model.execute("continue")
        try await wait{FileManager.default.fileExists(atPath:marker.path) && model.output.contains("Unicode 雪")}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["ls-files","--stage","-z"]).stdout
        try require(model.replaying && model.output.contains("Replay: 35%") && !model.output.contains("Replay: 10%") && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Replay stream/ownership missing")
        model.cancelReplay();try await wait{questions==1 && !model.confirmingReplayCancellation};try require(model.busy,"No killed the replay")
        model.cancelReplay();try await wait{!model.busy && RebaseWindowModel.activeReplayOperations==0}
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
        try require(model.active && !model.completedSuccessfully && head==afterHead && index==afterIndex && model.status.contains("stopped"),"Interrupted replay lost actual recovery state")
        controller.close();try FileManager.default.removeItem(at:marker);setenv("TG_REPLAY_GATE","--abort",1);prefs.set(false,forKey:"ConfirmKillProcess")
        let late=RebaseWindowController(repository:wrapped,access:nil,preferences:prefs);late.model.load();try await wait{!late.model.busy && late.model.active};var changed=0;late.model.onChanged={changed += 1};late.model.execute("abort")
        try await wait{FileManager.default.fileExists(atPath:marker.path)};late.close();try require(RebaseWindowModel.activeReplayOperations>0,"Forced close lost replay process lifetime")
        try await wait{RebaseWindowModel.activeReplayOperations==0};try require(late.model.retired && changed==0,"Retired replay published a callback")
        _ = try await repo.abortRebase();let ended=try await repo.rebaseState();try require(!ended.active,"Fresh Core recovery after scoped cancellation failed")
        // Declining pre-replay Stash preserves the message draft and leaves Start
        // available; it must not turn a command that never ran into Done.
        try Data("dirty".utf8).write(to:root.appendingPathComponent("base"))
        let decline=RebaseWindowController(repository:repo,access:nil,preferences:prefs);defer{decline.close()};decline.model.load(upstream:"upstream");try await wait{!decline.model.busy && decline.model.canStart}
        decline.model.amendMessage="unsaved draft 雪";decline.model.chooseStashBeforeReplay={false};decline.model.execute("start");try await wait{!decline.model.busy && RebaseWindowModel.activeReplayOperations==0}
        try require(decline.model.amendMessage=="unsaved draft 雪" && decline.model.canStart && !decline.model.hasReplayStash,"Declined pre-replay question lost draft/retry state");decline.close()
        print("Replay progress: real Continue CR/split-UTF8 stream, No/Yes cancellation, active Quit accounting, actual paused session/HEAD/index recovery, forced-close Abort cancellation and callback fencing; Core scope clears for subsequent Abort. Owned controllers closed.")
    }
}
