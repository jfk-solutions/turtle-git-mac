import AppKit
import TurtleGitCore

@main struct HistoryWorkflowsVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws { for _ in 0..<2000 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) };throw Failure(description:"History workflow timeout at line \(line)") }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("History workflow failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","History QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        for name in ["root","a","b","c"] { try Data((name+"\n").utf8).write(to:root.appendingPathComponent(name));try await repo.stage([name]);_ = try await repo.commit(message:"add "+name) }
        let entries=try await repo.history(),head=entries[0].hash,tree=try await repo.run(["rev-parse","HEAD^{tree}"]).stdout
        let suite="TurtleGit.HistoryWorkflows."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(16,forKey:"GitOutputLimitinKiB");prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(false,forKey:"EnableGravatar")
        defer { prefs.removePersistentDomain(forName:suite) }
        let helper=root.appendingPathComponent("stream-git"),marker=root.appendingPathComponent("ready"),release=root.appendingPathComponent("release"),counter=root.appendingPathComponent("counter")
        let script = #"""
        #!/bin/sh
        if [ "$4" = "$TG_HISTORY_MATCH" ] && { [ -z "$TG_HISTORY_MODE" ] || [ "$5" = "$TG_HISTORY_MODE" ]; }; then
          count=0;[ ! -e "$3/counter" ] || count=$(cat "$3/counter");count=$((count+1));printf '%s' "$count" > "$3/counter"
          printf 'Work: 10%%\rWork: 55%%\r\nUnicode '
          printf '\351\233'; /bin/sleep 0.06;printf '\252\n'
          if [ "$count" = "$TG_HISTORY_OCCURRENCE" ]; then
            if [ "$TG_HISTORY_BIG" = 1 ];then row=0;while [ "$row" -lt 32 ];do printf '%1024s\n' X;row=$((row+1));done;fi
            : > "$3/ready"
            while [ ! -e "$3/release" ];do /bin/sleep 0.05;done
          fi
        fi
        exec "$TG_HISTORY_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        setenv("TG_HISTORY_GIT",git.path,1)
        defer { for key in ["TG_HISTORY_GIT","TG_HISTORY_MATCH","TG_HISTORY_MODE","TG_HISTORY_OCCURRENCE","TG_HISTORY_BIG"] { unsetenv(key) } }
        let wrapped=GitRepository(root:root,executable:helper)
        @MainActor func gate(_ command:String,mode:String="",occurrence:Int=1,big:Bool=false) { for file in [marker,release,counter] { try? FileManager.default.removeItem(at:file) };setenv("TG_HISTORY_MATCH",command,1);setenv("TG_HISTORY_MODE",mode,1);setenv("TG_HISTORY_OCCURRENCE",String(occurrence),1);setenv("TG_HISTORY_BIG",big ? "1":"0",1) }
        @MainActor func live(_ text:String,_ busy:Bool) throws { try require(busy && text.contains("Unicode 雪") && text.contains("Work: 55%") && !text.contains("Work: 10%"),"Live history output damaged");try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"History worker lacks Quit ownership") }
        // Preserve the first successful MERGE_MSG while cancellation stops a later revision.
        gate("revert",occurrence:2)
        let revertController=HistoryRevertWindowController(repository:wrapped,access:nil,entries:Array(entries.prefix(2)),mainline:nil,preferences:prefs),revert=revertController.model
        defer { revertController.close() }
        revert.ask={title,_,_,_ in title == "Revert the selected commit(s)?"};var raw="";revert.onChanged={raw=$0};revert.start()
        try await wait { FileManager.default.fileExists(atPath:marker.path) && revert.output.contains("Unicode 雪") };try live(revert.output,revert.busy)
        let message=try String(contentsOf:root.appendingPathComponent(".git/MERGE_MSG"),encoding:.utf8);try require(message.contains(entries[0].hash),"First Revert message was lost before next command")
        revertController.window?.contentView?.layoutSubtreeIfNeeded();try await wait { descendants(revertController.window!.contentView!).contains {$0 is SubmoduleProgressTextView} }
        let text=descendants(revertController.window!.contentView!).compactMap {$0 as? SubmoduleProgressTextView}.first!;try await wait { text.string == revert.output }
        let clipboard=NSPasteboard.withUniqueName();defer { clipboard.releaseGlobally() };text.clipboard=clipboard;text.copyAllInformation(nil);try require(clipboard.string(forType:.string) == revert.output && text.outputMenu().items.last?.image != nil,"History copy icons/control missing")
        revert.cancel();try await wait { !revert.busy && HistoryRevertWindowModel.activeOperations == 0 }
        try require(revert.cancelled && revert.completed == 2 && raw.contains("Work: 10%") && !FileManager.default.fileExists(atPath:root.appendingPathComponent("c").path) && FileManager.default.fileExists(atPath:root.appendingPathComponent("b").path),"Cancellation lost original callback/partial Revert state")
        let retained=try String(contentsOf:root.appendingPathComponent(".git/MERGE_MSG"),encoding:.utf8);try require(retained.contains(entries[0].hash),"Cancellation discarded successful Revert message");revertController.close();_ = try await repo.run(["reset","--hard","HEAD"])
        // Skip a root failure, process the next revision, and dispatch Commit only once after close.
        gate("disabled");let skip=HistoryRevertWindowModel(repository:repo,access:nil,entries:[entries.last!,entries[0]],mainline:nil,preferences:prefs)
        var questions:[String]=[],events:[String]=[]
        skip.ask={title,_,_,_ in questions.append(title);return true};skip.close={events.append("close")};skip.onCommit={events.append("commit")};skip.start();try await wait {!skip.busy && HistoryRevertWindowModel.activeOperations == 0}
        try require(skip.success && skip.completed == 2 && questions.count == 3 && events == ["close","commit"],"Skip/Commit handoff was not ordered/once-only")
        _ = try await repo.run(["reset","--hard","HEAD"])
        // Successful Combine uses actual native Commit presets and real amendment/replay.
        let combine=HistoryCombineWindowModel(repository:repo,access:nil,entries:Array(entries[1...2]),firstOffset:1,expectedHead:head,preferences:prefs)
        var combinedRaw="",presets=false
        combine.presentCommit={plan in
            let child=CommitWindowController(repository:repo,access:nil,defaults:prefs);defer {child.close()};child.model.loadHistoryCombine(plan,date:.first)
            try? await wait {!child.model.busy}
            presets=child.model.amend && child.model.setAuthorDate && child.model.message == plan.message && child.model.historyCombine?.originalHead == head
            do {_ = try await repo.run(["commit","--amend","-m",plan.message]);return true} catch {return false}
        }
        combine.onChanged={combinedRaw=$0};combine.start();try await wait {!combine.busy && HistoryCombineWindowModel.activeOperations == 0}
        let finalTree=try await repo.run(["rev-parse","HEAD^{tree}"]).stdout,rows=try await repo.history()
        try require(combine.success && presets && finalTree == tree && rows.count == entries.count-1 && !combinedRaw.isEmpty,"Combine Commit/replay lost final tree or presets")
        _ = try await repo.run(["reset","--hard",head])
        // Retired Combine waits for the injected Commit child, then holds rollback ownership.
        gate("reset",mode:"--hard",big:true)
        let retired=HistoryCombineWindowModel(repository:wrapped,access:nil,entries:Array(entries[1...2]),firstOffset:1,expectedHead:head,preferences:prefs)
        var commitReply:((Bool)->Void)?,callbacks=0
        // Replace with a single explicit continuation; no app or public Git operation is launched by a response.
        retired.presentCommit={_ in await withCheckedContinuation { continuation in commitReply={continuation.resume(returning:$0)} } }
        retired.onChanged={_ in callbacks += 1};gate("disabled");retired.start();try await wait {retired.presentingCommit && commitReply != nil};let frozen=retired.output;retired.invalidate()
        try require(HistoryCombineWindowModel.activeOperations > 0,"Retirement dropped pending Commit ownership")
        gate("reset",mode:"--hard",big:true);commitReply?(false)
        try await wait {FileManager.default.fileExists(atPath:marker.path)};try require(HistoryCombineWindowModel.activeOperations > 0 && retired.recovering,"Rollback not owned")
        retired.cancel();try Data().write(to:release);try await wait {HistoryCombineWindowModel.activeOperations == 0 && LocalGitCommandProgress.activeOperations == 0}
        let restoredHead=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),restoredTree=try await repo.run(["write-tree"]).stdout
        try require(callbacks == 0 && retired.output == frozen && restoredHead == head && restoredTree == tree,"Forced Combine retirement failed rollback or published late callback")
        // Both owner types register and cancel a live ancestry read, keeping Quit blocked until drain.
        for ownerType in ["log","sync"] {
            gate("rev-parse",mode:"--verify")
            let token=OperationCancellation(),log=LogWindowModel(repository:wrapped,access:nil,labelDefaults:prefs),sync=SynchronizationWindowModel(repository:wrapped,access:nil,preferences:prefs)
            let task=Task { () -> Bool in do { if ownerType == "log" {try await log.validateCombineSelection(Array(entries.prefix(2)),offset:0,head:head,token:token)} else {try await sync.validateCombineSelection(Array(entries.prefix(2)),offset:0,head:head,token:token)};return true } catch {return false} }
            try await wait {FileManager.default.fileExists(atPath:marker.path)};try require(HistoryCombineSelectionReader.activeReads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Combine menu read lacks global ownership")
            if ownerType == "log" {log.invalidate()} else {sync.invalidate()};let accepted=await task.value;try require(!accepted && HistoryCombineSelectionReader.activeReads == 0,"Closed history owner accepted late ancestry")
        }
        print("History workflows: Revert live/copy/original results, preserved partial MERGE_MSG, cancellation, Skip and ordered Commit handoff; real Combine amendment/replay/presets and forced pending-child rollback; Log/Sync ancestry ownership and Quit passed. Private fixtures/preferences/clipboard; owned windows closed.")
    }
}
