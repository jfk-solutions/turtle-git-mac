import AppKit
import TurtleGitCore

@main struct PullCleanupVerification {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool,_ message:String) throws { if !value { throw Failure(message:message) } }
    @MainActor static func wait(_ predicate:()->Bool) async throws { for _ in 0..<2000 { if predicate() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(message:"Timeout") }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Pull cleanup failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.PullCleanup.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        prefs.set(0,forKey:"AutoCloseGitProgress"); prefs.set(false,forKey:"ConfirmKillProcess")
        let stages=["initial","config","remote","validation","pull","inspection","success","reset","answeredNo","answeredYes"]
        let remoteRoot=root.appendingPathComponent("producer");try FileManager.default.createDirectory(at:remoteRoot,withIntermediateDirectories:true)
        let producer=GitRepository(root:remoteRoot,executable:git)
        _ = try await producer.run(["init","-b","main"])
        for (key,value) in [("user.name","Pull QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await producer.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:remoteRoot.appendingPathComponent("file"));try await producer.stage(["file"]);_ = try await producer.commit(message:"base")
        let base=try await producer.run(["rev-parse","HEAD"]).stdout
        for stage in stages { _ = try await producer.run(["clone",remoteRoot.path,root.appendingPathComponent(stage).path]) }
        _ = try await producer.run(["commit","--allow-empty","-m","next"])
        for stage in stages {
            let client=root.appendingPathComponent(stage), actual=GitRepository(root:client,executable:git)
            let helper=root.appendingPathComponent("slow-"+stage),marker=URL(fileURLWithPath:helper.path+".started"),pause=URL(fileURLWithPath:helper.path+".pause")
            let command=["initial":"rev-parse","validation":"check-ref-format","inspection":"status","success":"rev-parse","reset":"config","answeredNo":"pull","answeredYes":"pull"][stage] ?? stage
            let quoted="'"+git.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
            let script="""
            #!/bin/sh
            if [ "${4-}" = pull ]; then
              if [ '\(stage)' = inspection ] || [ '\(stage)' = reset ]; then exit 1; fi
              if [ '\(stage)' = success ]; then
                \(quoted) "$@"
                task_result=$?
                touch "$0.done"
                exit "$task_result"
              fi
            fi
            if [ "${4-}" = '\(command)' ] && [ -f "$0.pause" ]; then
              if [ '\(stage)' != success ] || [ -f "$0.done" ]; then
                printf 'owned Pull work\\n'
                /bin/sleep 30 &
                task_child=$!
                trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
                printf '%s %s\\n' "$$" "$task_child" > "$0.started"
                wait "$task_child"
              fi
            fi
            exec \(quoted) "$@"
            """
            try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
            let normalAnswer=stage.hasPrefix("answered")
            prefs.set(normalAnswer ? 2 : 0,forKey:"AutoCloseGitProgress")
            let wrapped=GitRepository(root:client,executable:helper)
            let owner=FetchWindowController(repository:wrapped,access:nil,isPull:true,preferences:prefs);var ids:[Int32]=[]
            defer { owner.close();for pid in ids where kill(pid,0)==0 { _ = kill(pid,SIGTERM) } }
            owner.presentPullProgress={parent,_ in parent.makeFirstResponder(nil);return true}
            owner.model.load(remote:"origin");try await wait { !owner.model.busy };owner.model.options.branch="main"
            if stage != "reset" { try Data().write(to:pause) };owner.model.fetch()
            try await wait { owner.progressController != nil };let model=owner.progressController!.model
            var completions=0,dispatches=0,lateAnswer:((Bool)->Void)?
            let completed=model.onCompleted;model.onCompleted={ completed();completions += 1 };model.onPostAction={ _,_ in dispatches += 1 }
            if stage=="reset" { try await wait { !model.busy };try Data().write(to:pause);model.perform(.reset) }
            try await wait { FileManager.default.fileExists(atPath:marker.path) }
            ids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap { Int32($0) }
            try require(ids.count==2 && ids.allSatisfy{kill($0,0)==0},"Owned process not live")
            if stage=="pull" || normalAnswer { prefs.set(true,forKey:"ConfirmKillProcess");model.confirmCancellation={lateAnswer=$0};model.cancel();try require(model.confirmingCancellation,"Missing Cancel confirmation") }
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Pull escaped Quit guard")
            if normalAnswer {
                // Release only the owned sleep helper; the wrapper continues real Pull.
                try require(kill(ids[1],SIGTERM)==0,"Unable to release completion fixture")
                try await wait { !model.busy }
                try require(model.success && !model.cancelled && model.confirmingCancellation && owner.progressController != nil && !owner.model.closed,"Finished Pull escaped pending answer")
                model.perform(.diff)
                try require(dispatches==0 && !owner.progressController!.windowShouldClose(owner.progressController!.window!),"Pending answer allowed action/close")
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Finished pending answer escaped Quit")
                lateAnswer?(stage=="answeredYes")
                try await wait { owner.model.closed && owner.progressController==nil }
                lateAnswer?(true)
                try require(model.success && !model.cancelled && completions==1 && dispatches==0,"Late answer changed successful completion")
                try await wait { ids.allSatisfy{kill($0,0) != 0} }
                let after=try await actual.run(["rev-parse","HEAD"]).stdout
                try require(after != base,"Normal completion lost Pull result")
                prefs.set(false,forKey:"ConfirmKillProcess");print("PASS Pull finished with held Cancel answer: "+stage);continue
            }
            owner.close();let frozen=(model.output,model.rawOutput,model.oldHead,model.newHead,model.postActions,completions)
            lateAnswer?(true);model.perform(.pull);model.perform(.mergeUnrelated);model.start()
            try await wait { ids.allSatisfy{kill($0,0) != 0} };try await Task.sleep(nanoseconds:100_000_000)
            try require(owner.model.closed && owner.progressController==nil && !model.busy && !model.confirmingCancellation && !model.confirmingConflictHint && !model.dispatchingAction,"Closed Pull retained work")
            try require(frozen.0==model.output && frozen.1==model.rawOutput && frozen.2==model.oldHead && frozen.3==model.newHead && frozen.4==model.postActions && frozen.5==completions && dispatches==0,"Late result changed closed Pull")
            let after=try await actual.run(["rev-parse","HEAD"]).stdout
            try require(stage=="success" ? after != base : after==base,"Pull completion/cancellation HEAD effect differs")
            prefs.set(false,forKey:"ConfirmKillProcess");print("PASS forced Pull cleanup: "+stage)
        }
    }
}
