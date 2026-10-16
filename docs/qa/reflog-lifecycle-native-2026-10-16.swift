import AppKit
import Darwin
import TurtleGitCore

@main struct RefLogLifecycleVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"RefLog lifecycle timeout at \(line)")
    }
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func main() async {do {try await verify()}catch {fputs("RefLog lifecycle failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","RefLog Lifecycle QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("file")
        for value in ["first","second","third"] {try Data((value+"\n").utf8).write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:value+" unique")}
        _ = try await repo.run(["branch","topic"])
        try Data("stash\n".utf8).write(to:file);_ = try await repo.run(["stash","push","-m","lifecycle"])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),headLog=root.appendingPathComponent(".git/logs/HEAD"),logBytes=try Data(contentsOf:headLog),stash=try await repo.referenceLog("refs/stash")
        let helper=root.appendingPathComponent("lifecycle-git"),mode=root.appendingPathComponent("lifecycle-git.mode"),pause=root.appendingPathComponent("lifecycle-git.pause"),marker=root.appendingPathComponent("lifecycle-git.started")
        let quoted="'"+git.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        let script="""
        #!/bin/sh
        task_mode=$(/bin/cat "$0.mode" 2>/dev/null)
        if [ "$task_mode" = fail-load ] && [ "$4" = for-each-ref ]; then
          printf 'owned refresh failure\\n' >&2
          exit 1
        fi
        if [ "$task_mode" = fail-delete ] && [ "$4" = reflog ]; then
          printf 'owned deletion failure\\n' >&2
          exit 1
        fi
        if [ "$task_mode" = "$4" ] && [ -f "$0.pause" ]; then
          /bin/rm "$0.pause"
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp"
          /bin/mv "$0.started.tmp" "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let wrapped=GitRepository(root:root,executable:helper),suite="TurtleGit.RefLogLifecycle."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");defer{prefs.removePersistentDomain(forName:suite)}
        var owners:[ReferenceLogWindowController]=[]
        defer {owners.forEach{$0.close()}}
        func owner(_ reference:String = "HEAD") -> ReferenceLogWindowController {
            let result=ReferenceLogWindowController(repository:wrapped,access:nil,reference:reference,preferences:prefs);owners.append(result)
            result.window?.alphaValue=0;result.window?.orderFront(nil);return result
        }
        func gate(_ command:String) throws {try? FileManager.default.removeItem(at:marker);try Data(command.utf8).write(to:mode);try Data().write(to:pause)}
        func pids() throws -> [pid_t] {try String(contentsOf:marker).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}}
        func stopped(_ ids:[pid_t])->Bool {ids.allSatisfy{kill($0,0) == -1 && errno==ESRCH}}
        func owned() throws {try require(ReferenceLogWindowModel.activeOwnedOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Owned RefLog operation lost Quit protection")}
        func answer(_ controller:ReferenceLogWindowController,_ title:String,default expected:String) async throws {
            try await wait {guard let sheet=controller.window?.attachedSheet else{return false};sheet.alphaValue=0;return sheet.defaultButtonCell != nil && views(sheet.contentView).compactMap{$0 as? NSButton}.contains{$0.title==title}}
            let sheet=controller.window!.attachedSheet!,button=views(sheet.contentView).compactMap{$0 as? NSButton}.first{$0.title==title}!
            try require(sheet.defaultButtonCell?.title==expected,"RefLog native question default differs")
            button.performClick(nil)
        }
        // Superseding a blocked initial refresh must terminate its owned process.
        try gate("for-each-ref");let refreshed=owner(),model=refreshed.model
        try await wait {FileManager.default.fileExists(atPath:marker.path)};let refreshPIDs=try pids();try owned()
        try require(model.canRefresh && model.canClose && !model.commandSurfaceAvailable,"Refresh/close surfaces unavailable during read")
        try require((refreshed.window as? ReferenceLogNativeWindow)?.functionKey(96)==true,"F5 did not supersede load")
        try await wait {!model.busy && model.entries.count>=3 && ReferenceLogWindowModel.activeOwnedOperations==0 && stopped(refreshPIDs)}
        model.selectReference("refs/heads/topic");try await wait {!model.busy && model.reference=="refs/heads/topic"}
        _ = try await repo.run(["branch","-D","topic"]);model.reload()
        try await wait {!model.busy && model.reference=="HEAD"}
        try require(!model.names.contains("refs/heads/topic") && views(refreshed.window?.contentView).compactMap{$0 as? NSPopUpButton}.contains{$0.titleOfSelectedItem=="HEAD"},"Vanished ref did not fall back in actual picker")
        try Data("fail-load".utf8).write(to:mode);model.reload()
        try await wait {!model.busy && model.error?.contains("owned refresh failure")==true}
        try require(model.entries.isEmpty && model.selection.isEmpty,"Failed refresh exposed stale reference rows")
        try await answer(refreshed,"OK",default:"OK");try Data("disabled".utf8).write(to:mode);model.reload()
        try await wait {!model.busy && model.entries.count>=3}
        refreshed.close();try await wait {ReferenceLogWindowModel.activeOwnedOperations==0}
        // Parent metadata belongs to a model even without visible table rows.
        let parent=ReferenceLogWindowModel(repository:wrapped,access:nil,reference:"HEAD",preferences:prefs);defer{parent.invalidate()}
        parent.reload();try await wait {!parent.busy};try gate("rev-list");parent.requestDiffParents(parent.entries[0])
        try await wait {FileManager.default.fileExists(atPath:marker.path)};let parentPIDs=try pids();try owned();parent.invalidate()
        try await wait {ReferenceLogWindowModel.activeOwnedOperations==0 && stopped(parentPIDs)}
        try require(parent.diffParents.isEmpty && parent.error==nil,"Retired parent read published metadata/error")
        // Normal close cancels a live unified read, without viewer/error handoff.
        let diff=owner();try await wait {!diff.model.busy && diff.model.diffParents[diff.model.entries.first?.hash ?? ""] != nil}
        var viewers=0;diff.model.onUnifiedDiff={_,_ in viewers += 1};try gate("diff-tree");diff.model.inspect([diff.model.entries[0].id])
        try await wait {FileManager.default.fileExists(atPath:marker.path)};let diffPIDs=try pids();try owned();diff.window?.performClose(nil)
        try await wait {diff.model.isInvalidated && ReferenceLogWindowModel.activeOwnedOperations==0 && stopped(diffPIDs)}
        try require(viewers==0 && diff.model.error==nil,"Closed diff read handed off a viewer/error")
        // Real native Delete/Abort and Clear stash defaults, with Abort preservation.
        let questions=owner();try await wait {!questions.model.busy};questions.model.delete([questions.model.entries[0].id])
        try await answer(questions,"Abort",default:"Delete");try await wait {!questions.model.confirmingDelete && ReferenceLogWindowModel.activeOwnedOperations==0}
        questions.model.selectReference("refs/stash");try await wait {!questions.model.busy};questions.model.delete([],clear:true)
        try await answer(questions,"Abort",default:"Abort");try await wait {!questions.model.confirmingDelete && ReferenceLogWindowModel.activeOwnedOperations==0}
        let afterAbort=try await repo.referenceLog("refs/stash");try require(afterAbort==stash,"Abort changed stash stack")
        questions.model.delete([],clear:true);try await wait {questions.window?.attachedSheet != nil};try owned();questions.close()
        try await wait {ReferenceLogWindowModel.activeOwnedOperations==0};try require(!questions.model.confirmingDelete,"Closed confirmation remained pending")
        // Mutation is exclusive; forced close cancels before the actual Git command.
        let deletion=owner();try await wait {!deletion.model.busy};var callbacks=0;deletion.model.onChanged={_ in callbacks += 1}
        try gate("reflog");deletion.model.delete([deletion.model.entries[0].id]);try await answer(deletion,"Delete",default:"Delete")
        try await wait {FileManager.default.fileExists(atPath:marker.path)};let deletePIDs=try pids();try owned()
        let frozen=deletion.model.entries;deletion.model.reload();deletion.model.delete([frozen[0].id]);deletion.window?.performClose(nil)
        try require(deletion.model.mutating && !deletion.model.canClose && !deletion.model.isInvalidated,"Live deletion lost exclusivity")
        deletion.close();try await wait {ReferenceLogWindowModel.activeOwnedOperations==0 && stopped(deletePIDs)}
        try require(callbacks==0 && deletion.model.entries==frozen,"Retired deletion published late callbacks")
        // A forced close also settles the per-file failure sheet's continuation.
        let failure=owner();try await wait {!failure.model.busy};try Data("fail-delete".utf8).write(to:mode)
        failure.model.delete([failure.model.entries[0].id]);try await answer(failure,"Delete",default:"Delete")
        try await wait {failure.window?.attachedSheet?.defaultButtonCell?.title=="OK"};try owned();failure.close()
        try await wait {ReferenceLogWindowModel.activeOwnedOperations==0 && ReferenceLogWindowModel.activeRevisionReads==0}
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(afterHead==head && (try Data(contentsOf:headLog))==logBytes && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:file))==Data("third\n".utf8),"Read/Abort/cancelled deletion changed repository")
        print("PASS: RefLog missing-ref HEAD fallback, superseded F5 load, parent/diff cancellation, actual Delete/Abort and Clear defaults, pending/failure-sheet retirement, exclusive cancelled deletion, Quit lifetime, helper reaping and unchanged HEAD/log/index/working bytes; owned windows closed")
    }
}
