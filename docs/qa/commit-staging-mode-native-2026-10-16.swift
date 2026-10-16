import AppKit
import Darwin
import TurtleGitCore

@main struct CommitStagingModeVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value{throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Commit mode timeout at \(line)")
    }
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func main() async {do{try await verify()}catch{fputs("Commit staging mode failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Staging Mode QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        for path in ["file","unrelated"] {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))};try await repo.stage(["file","unrelated"]);_ = try await repo.commit(message:"base")
        try Data("staged\n".utf8).write(to:root.appendingPathComponent("file"));try Data("unrelated staged\n".utf8).write(to:root.appendingPathComponent("unrelated"));try await repo.stage(["file","unrelated"])
        try Data("working\n".utf8).write(to:root.appendingPathComponent("file"));try Data("new\n".utf8).write(to:root.appendingPathComponent("new"))
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,initialTree=try await repo.run(["write-tree"]).stdout,unrelated=try await repo.run(["show",":unrelated"]).stdout
        let suite="TurtleGit.StagingMode."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(false,forKey:"EnableGravatar");defer{prefs.removePersistentDomain(forName:suite)}
        var owners:[CommitWindowController]=[];defer{owners.forEach{$0.close()}}
        func make(_ repository:GitRepository)->CommitWindowController {
            let value=CommitWindowController(repository:repository,access:nil,defaults:prefs);owners.append(value);value.window?.alphaValue=0;value.window?.orderFront(nil);value.model.reload();return value
        }
        func ready(_ model:CommitWindowModel) async throws {try await wait {!model.busy && !model.savingPreferences && !model.stagingHintVisible && model.changelistsLoaded}}
        func hint(_ owner:CommitWindowController,suppress:Bool) async throws {
            try await wait {owner.stagingHintAlert != nil && owner.model.stagingHintVisible}
            guard let alert=owner.stagingHintAlert else {throw Failure(description:"Actual staging hint absent")}
            alert.window.alphaValue=0
            try require(alert.buttons.map(\.title)==["OK"] && alert.suppressionButton?.title=="Do not show this message again" && alert.informativeText.contains("Mixed") && alert.informativeText.contains("Partial Staging"),"Source staging explanation/default controls missing")
            alert.suppressionButton?.state=suppress ? .on:.off;alert.buttons[0].performClick(nil)
            try await ready(owner.model)
        }
        let owner=make(repo),model=owner.model;try await ready(model)
        model.reload(paths:["file"]);try await ready(model)
        model.message="private draft";model.checked=["file"];model.selection=["file"]
        model.showViewPatch();try await wait {owner.partial?.model.busy==false && !model.savingPreferences}
        try require(owner.partial?.model.readOnly==true,"Actual checkbox-mode View Patch missing")
        let checked=model.checked,scope=model.scopePaths
        model.setStagingEnabled(true);try await wait {owner.stagingHintAlert != nil}
        try require(owner.partial==nil && model.inputsBlocked && !model.canCommit && model.message=="private draft" && model.checked==checked && model.scopePaths==scope,"Mode activation lost preview/draft/checks/scope or gates")
        model.check{_ in true};model.uncheckAll();model.setGroupChecked(model.visibleEntries,checked:false)
        let unchanged=try await repo.run(["write-tree"]).stdout;try require(unchanged==initialTree,"Mode/hint/check actions changed index")
        try await hint(owner,suppress:false)
        try require(model.visibleEntries.contains{$0.path=="unrelated"},"Staging mode hid an index path outside requested scope")
        let settings=try await repo.commitPreferences();try require(settings.staging && !settings.showPatch && !prefs.bool(forKey:"HintStagingMode"),"Mode/preview/hint persistence differs")
        try await wait {views(owner.window?.contentView).compactMap{$0 as? NSButton}.contains{$0.state == .mixed && $0.toolTip?.contains("mixed state")==true}}
        model.setStagingEnabled(false);try await ready(model);model.setStagingEnabled(true);try await hint(owner,suppress:true)
        try require(prefs.bool(forKey:"HintStagingMode"),"Suppression choice was not remembered")
        guard let mixed=model.entries.first(where:{$0.path=="file"}) else {throw Failure(description:"Mixed file disappeared")}
        model.setFileChecked(mixed,files:model.visibleEntries,highlighted:[mixed.id],checked:false);try await ready(model)
        let unstaged=try await repo.run(["show",":file"]).stdout;try require(unstaged==Data("base\n".utf8),"Whole-file unstage did not restore HEAD index")
        model.setFileChecked(model.entries.first{$0.path=="file"}!,files:model.visibleEntries,highlighted:["file"],checked:true);try await ready(model)
        let staged=try await repo.run(["show",":file"]).stdout,afterOther=try await repo.run(["show",":unrelated"]).stdout
        try require(staged==Data("working\n".utf8) && afterOther==unrelated,"Whole-file stage changed unrelated index")
        let stableTree=try await repo.run(["write-tree"]).stdout
        owner.close();try await wait {CommitWindowModel.activePreferenceOperations==0}
        let reopened=make(repo);try await ready(reopened.model);try require(reopened.model.stagingEnabled && reopened.stagingHintAlert==nil,"Reopen lost saved mode/suppression");reopened.close()
        // Hold actual config writes: queue ordering, Cancel drain and forced close.
        let helper=root.appendingPathComponent("mode-git"),mode=root.appendingPathComponent("mode-git.mode"),pause=root.appendingPathComponent("mode-git.pause"),marker=root.appendingPathComponent("mode-git.started"),quoted="'"+git.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        let script="""
        #!/bin/sh
        task_mode=$(/bin/cat "$0.mode" 2>/dev/null)
        if [ "$4" = config ] && [ "$5" = --local ] && [ "$6" = "$task_mode" ] && [ -f "$0.pause" ]; then
          /bin/rm "$0.pause"
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null' USR1
          printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp"
          /bin/mv "$0.started.tmp" "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:root,executable:helper)
        func gate(_ key:String) throws {try? FileManager.default.removeItem(at:marker);try Data(key.utf8).write(to:mode);try Data().write(to:pause)}
        func pids() throws -> [pid_t] {try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}}
        func stopped(_ values:[pid_t])->Bool {values.allSatisfy{kill($0,0) == -1 && errno==ESRCH}}
        let queued=make(wrapped);try await ready(queued.model);queued.model.message="queued draft";try require(queued.model.canCommit,"Fixture Commit was not ready before preference write");try gate("tgit.commitshowpatch");queued.model.savePatchPreference(true)
        try await wait {FileManager.default.fileExists(atPath:marker.path)};let queuedPIDs=try pids()
        try require(queued.model.inputsBlocked && !queued.model.canCommit && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Preference write lost input/Quit ownership")
        queued.model.savePatchPreference(false);queued.model.savePatchPreference(true);queued.model.savePatchPreference(false);_ = kill(queuedPIDs[0],SIGUSR1)
        try await ready(queued.model);let final=try await repo.commitPreferences();try require(!final.showPatch && final.staging && stopped(queuedPIDs),"Queued visibility did not keep final request")
        try gate("tgit.commitshowpatch");queued.model.savePatchPreference(true);try await wait {FileManager.default.fileExists(atPath:marker.path)};let cancelPIDs=try pids();var cancelled=false
        queued.model.cancel(closeWindow:false){cancelled=$0};try require(!cancelled,"Cancel did not wait for preference worker")
        try await wait {cancelled && CommitWindowModel.activePreferenceOperations==0 && stopped(cancelPIDs)}
        let afterCancel=try await repo.commitPreferences();try require(!afterCancel.showPatch,"Cancelled config write completed")
        let lock=root.appendingPathComponent(".git/config.lock");try Data().write(to:lock)
        queued.model.setStagingEnabled(false);try await ready(queued.model)
        try require(!queued.model.stagingEnabled && queued.model.error != nil,"Failed persistence discarded requested live mode/error")
        queued.model.error=nil;try FileManager.default.removeItem(at:lock);queued.model.setStagingEnabled(true);try await ready(queued.model)
        try require(queued.model.error==nil,"Preference retry failed")
        try gate("tgit.commitstagingsupport");queued.model.setStagingEnabled(false);try await wait {FileManager.default.fileExists(atPath:marker.path)};let closePIDs=try pids();queued.close()
        try await wait {CommitWindowModel.activePreferenceOperations==0 && stopped(closePIDs)}
        let afterClose=try await repo.commitPreferences();try require(!queued.model.messageFocusAvailable && afterClose.staging,"Retired preference write changed persisted mode")
        prefs.removeObject(forKey:"HintStagingMode");let retiredHint=make(repo);try await wait {retiredHint.stagingHintAlert != nil};retiredHint.stagingHintAlert?.suppressionButton?.state = .on;retiredHint.close()
        try await wait {CommitWindowModel.activePreferenceOperations==0};try require(!prefs.bool(forKey:"HintStagingMode"),"Retired hint saved a late suppression choice")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterTree=try await repo.run(["write-tree"]).stdout
        try require(afterHead==head && afterTree==stableTree && (try Data(contentsOf:root.appendingPathComponent("file")))==Data("working\n".utf8),"Mode/preference lifetime changed HEAD/index/working content")
        print("PASS: Commit mode/preview refresh, actual staging hint and suppression/reopen, mixed checkbox and whole-file stage/unstage, captured draft/check/scope, queued preference writes/retry, Cancel and closed-worker/hint fences, Quit/grant lifetime and helper cleanup; owned windows closed")
    }
}
