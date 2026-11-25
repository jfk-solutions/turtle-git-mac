import AppKit
import TurtleGitCore
@main struct RebaseReplayProgressVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String)throws{if !condition{throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws{for _ in 0..<2500{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Replay progress timeout line \(line)")}
    @MainActor static func main()async{do{try await verify()}catch{fputs("Replay progress failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws{
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"]);for (key,value) in [("user.name","Replay QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("rebase.autostash","false")]{_ = try await repo.run(["config",key,value])}
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
        try require(model.dockProgress?.kind == .paused,"Edit pause lost yellow Dock state")
        var questions=0;model.confirmReplayCancellation={questions += 1;return questions>1};model.execute("continue")
        try await wait{FileManager.default.fileExists(atPath:marker.path) && model.output.contains("Unicode 雪")}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["ls-files","--stage","-z"]).stdout
        try require(model.replaying && model.output.contains("Replay: 35%") && !model.output.contains("Replay: 10%") && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Replay stream/ownership missing")
        try require(model.dockProgress?.kind == .running,"Live replay lost running Dock state")
        model.cancelReplay();try await wait{questions==1 && !model.confirmingReplayCancellation};try require(model.busy,"No killed the replay")
        model.cancelReplay();try await wait{!model.busy && RebaseWindowModel.activeReplayOperations==0}
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
        try require(model.active && !model.completedSuccessfully && head==afterHead && index==afterIndex && model.status.contains("stopped"),"Interrupted replay lost actual recovery state")
        try require(model.dockProgress?.kind == .failed,"Cancelled replay lost retained failure Dock state")
        controller.close();try require(model.dockProgress == nil,"Retired replay kept Dock state");try FileManager.default.removeItem(at:marker);setenv("TG_REPLAY_GATE","--abort",1);prefs.set(false,forKey:"ConfirmKillProcess")
        let late=RebaseWindowController(repository:wrapped,access:nil,preferences:prefs);late.model.load();try await wait{!late.model.busy && late.model.active};var changed=0;late.model.onChanged={changed += 1};late.model.execute("abort")
        try await wait{FileManager.default.fileExists(atPath:marker.path)};late.close();try require(RebaseWindowModel.activeReplayOperations>0,"Forced close lost replay process lifetime")
        try await wait{RebaseWindowModel.activeReplayOperations==0};try require(late.model.retired && changed==0,"Retired replay published a callback")
        _ = try await repo.abortRebase();let ended=try await repo.rebaseState();try require(!ended.active,"Fresh Core recovery after scoped cancellation failed")
        // Declining pre-replay Stash preserves the message draft and leaves Start
        // available; it must not turn a command that never ran into Done.
        try Data("dirty".utf8).write(to:root.appendingPathComponent("base"))
        let decline=RebaseWindowController(repository:repo,access:nil,preferences:prefs);defer{decline.close()};decline.model.load(upstream:"upstream");try await wait{!decline.model.busy && decline.model.canStart}
        @MainActor func repositoryReceipt()async throws ->[Data] {
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let state=try await repo.rebaseState()
            let head=try await repo.run(["rev-parse","HEAD"]).stdout
            let index=try await repo.run(["ls-files","--stage","-z"]).stdout
            let stash=try await repo.run(["rev-parse","--verify","--quiet","refs/stash"],successfulExitCodes:0...1)
            return [head,index,try encoder.encode(state),Data(String(stash.exitCode).utf8)+stash.stdout,try Data(contentsOf:root.appendingPathComponent("base"))]
        }
        @MainActor func declinedReady(_ owner:RebaseWindowController,_ phase:String)async throws {
            do {try await wait{!owner.model.busy && !owner.model.replaying && owner.model.pendingBatchWorkers==0 && RebaseWindowModel.activeReplayOperations==0}}
            catch {
                fputs("Declined pre-replay phase=\(phase) busy=\(owner.model.busy) replaying=\(owner.model.replaying) workers=\(owner.model.pendingBatchWorkers) active=\(owner.model.active) canStart=\(owner.model.canStart) finished=\(owner.model.finished) stash=\(owner.model.hasReplayStash) editor=\(owner.model.replayMessageEditorID) draft=\(String(reflecting:owner.model.amendMessage)) pendingConfirmation=\(owner.model.pendingConfirmation != nil) question=\(owner.model.hasReplayQuestion) sheet=\(owner.window?.attachedSheet != nil) error=\(owner.model.error ?? "none") output=\(String(owner.model.output.suffix(1024)))\n",stderr)
                throw error
            }
        }
        let beforeDecline=try await repositoryReceipt(),declinedDraft="unsaved draft 雪"
        let declineEditor=decline.model.replayMessageEditorID
        var stashQuestions=0
        decline.model.amendMessage=declinedDraft
        decline.model.chooseStashBeforeReplay={stashQuestions += 1;return false}
        decline.model.execute("start");try await declinedReady(decline,"stash")
        let afterDecline=try await repositoryReceipt()
        let declinedState="questions=\(stashQuestions),draft=\(String(reflecting:decline.model.amendMessage)),canStart=\(decline.model.canStart),stash=\(decline.model.hasReplayStash),finished=\(decline.model.finished),active=\(decline.model.active),editorSame=\(decline.model.replayMessageEditorID==declineEditor),error=\(decline.model.error ?? "none")"
        try require(stashQuestions==1,"Dirty tracked state did not reach exactly one actual pre-replay Stash question: "+declinedState)
        try require(decline.model.amendMessage==declinedDraft && decline.model.canStart && !decline.model.hasReplayStash,"Declined pre-replay question lost draft/retry state: "+declinedState)
        try require(decline.model.replayMessageEditorID==declineEditor && !decline.model.active && !decline.model.finished && !decline.model.completedSuccessfully,"Declined pre-start question replaced editor or invented completed replay: "+declinedState)
        try require(beforeDecline==afterDecline,"Declined Stash changed actual HEAD/index/session/stash/dirty worktree bytes")
        decline.close()
        // The adjacent author/committer repair question also precedes Start.
        // A clean tracked tree reaches it without creating a stash first.
        try Data("base".utf8).write(to:root.appendingPathComponent("base"))
        let identityDecline=RebaseWindowController(repository:repo,access:nil,preferences:prefs);defer{identityDecline.close()}
        identityDecline.model.load(upstream:"upstream");try await wait{!identityDecline.model.busy && identityDecline.model.canStart}
        let beforeIdentityDecline=try await repositoryReceipt(),identityDraft="identity question draft 雪",identityEditor=identityDecline.model.replayMessageEditorID
        var identityQuestions=0,unexpectedStashQuestions=0
        identityDecline.model.amendMessage=identityDraft
        identityDecline.model.chooseStashBeforeReplay={unexpectedStashQuestions += 1;return false}
        identityDecline.model.readReplayIdentity={_ in .init(authorName:"",authorEmail:"",committerName:"",committerEmail:"")}
        identityDecline.model.repairReplayIdentity={identityQuestions += 1;return false}
        identityDecline.model.execute("start");try await declinedReady(identityDecline,"identity")
        let afterIdentityDecline=try await repositoryReceipt()
        try require(identityQuestions==1 && unexpectedStashQuestions==0,"Clean pre-start identity question was not reached exactly once")
        try require(identityDecline.model.amendMessage==identityDraft && identityDecline.model.replayMessageEditorID==identityEditor && identityDecline.model.canStart && !identityDecline.model.hasReplayStash && !identityDecline.model.active && !identityDecline.model.finished && !identityDecline.model.completedSuccessfully,"Declined identity repair lost accepted draft/editor/retry state: "+String(reflecting:identityDecline.model.amendMessage))
        try require(beforeIdentityDecline==afterIdentityDecline,"Declined identity repair changed HEAD/index/session/stash/working bytes")
        identityDecline.close()
        print("Replay progress: real Continue CR/split-UTF8 stream, No/Yes cancellation, active Quit accounting, actual paused session/HEAD/index recovery, forced-close Abort cancellation and callback fencing; Core scope clears for subsequent Abort. Owned controllers closed.")
    }
}
