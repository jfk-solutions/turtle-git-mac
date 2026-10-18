import AppKit
import ObjectiveC
import TurtleGitCore

extension PrimaryCommandsVerification {
    @MainActor static func verifyIntegration() async throws {
        // Scope all ordering interception to this private receiver process so root
        // command paths and framework-owned sheets stay invisible before ordering.
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitIntegrationOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer {method_exchangeImplementations(original,hidden)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        let suite="TurtleGit.IntegrationCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"ConfirmKillProcess")
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Integration command QA"),("user.email","integration@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("file.txt")
        try Data("base\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_ = try await repo.commit(message:"base")
        let baseline=try await repo.run(["rev-parse","HEAD"]).stdout
        _ = try await repo.run(["checkout","-b","topic"])
        try Data("topic\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_ = try await repo.commit(message:"topic")
        _ = try await repo.run(["checkout","main"])
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:root.appendingPathComponent("marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs;workspace.notifyFinder={}
        workspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root)}
        let host=NSWindow(contentRect:.init(x:0,y:0,width:700,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;workspace.workspaceWindow=host
        defer {workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()};host.close()}
        func windows<T>(_ type:T.Type)->[T] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? T}}
        func invoke(_ arguments:[String]) {workspace.handleCommandLine(arguments:arguments,currentDirectory:root.path)}
        func cleanup() async throws {
            workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()};host.close()
            try await wait {StashWindowModel.activePreparations == 0 && StashWindowController.activeChildReleases == 0 && StashRestoreWindowModel.activeOperations == 0 && LocalGitCommandProgress.activeOperations == 0 && SettingsSheetController.activeSheets == 0 && MergeWindowModel.activeReads == 0 && MergeProgressWindowModel.activeOperations == 0}
        }
        do {
        invoke(["--command=merge"])
        try await wait {!workspace.busy && windows(MergeWindowController.self).first?.model.busy==false}
        let merge=try requireOne(windows(MergeWindowController.self))
        try require(merge.model.presentationPreferences===prefs,"Merge lost command owner's preferences")
        merge.model.branchRevision="topic";merge.model.message="kept merge draft";merge.model.options.noCommit=true;merge.model.options.noFastForward=true
        invoke(["/command:merge"]);try await wait {!workspace.busy}
        try require(windows(MergeWindowController.self).count==1 && merge.model.message=="kept merge draft" && merge.model.branchRevision=="topic","Repeated Merge command replaced draft or opened a duplicate")
        let initialHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(initialHead==baseline && Data(contentsOf:file)==Data("base\n".utf8),"Merge command ran before acceptance")
        merge.model.onProgress={_ in};merge.model.merge()
        try await wait {merge.model.progress != nil && merge.model.progress?.busy==false}
        let mergeProgress=merge.model.progress!
        try require(mergeProgress.success && FileManager.default.fileExists(atPath:root.appendingPathComponent(".git/MERGE_HEAD").path),"Accepted No Commit merge did not retain pending merge state")
        mergeProgress.close();try await wait {!workspace.busy}
        invoke(["--command=merge","--abort"])
        try await wait {!workspace.busy && !windows(MergeAbortWindowController.self).isEmpty}
        let abort=try requireOne(windows(MergeAbortWindowController.self))
        try require(abort.model.presentationPreferences===prefs && Data(contentsOf:file)==Data("topic\n".utf8),"Abort launch lost preferences or ran before acceptance")
        invoke(["/command:merge","/abort"]);try await wait {!workspace.busy}
        try require(windows(MergeAbortWindowController.self).count==1,"Repeated Abort command duplicated the review")
        abort.model.onResize={_ in};abort.model.abort();try await wait {!abort.model.busy && abort.model.success && !workspace.busy}
        let abortedHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(abortedHead==baseline && Data(contentsOf:file)==Data("base\n".utf8) && !FileManager.default.fileExists(atPath:root.appendingPathComponent(".git/MERGE_HEAD").path),"Accepted Abort changed HEAD or failed to restore worktree")
        abort.close()
        try Data("shelved 🐢\n".utf8).write(to:file)
        let message="command message 🐢\n`literal` $(literal)"
        invoke(["--command=stashsave","--msg",message]);try await wait {!workspace.busy && !windows(StashWindowController.self).isEmpty}
        let save=try requireOne(windows(StashWindowController.self))
        try await wait {save.model.prepared && !save.model.preparing && !save.model.busy}
        try require(save.model.options.message==message && save.model.progress==nil,"Stash message preset lost or launched without acceptance")
        save.model.options.message="kept stash draft 🐢"
        invoke(["--command=stashsave","--msg=must not replace"]);try await wait {!workspace.busy}
        try require(windows(StashWindowController.self).count==1 && save.model.options.message=="kept stash draft 🐢","Repeated Stash command replaced draft")
        // A duplicate old response must not accept a later warning snapshot.
        var replies=[(Bool)->Void]();save.model.confirmUntracked={replies.append($0)};save.model.options.includeUntracked=true
        save.model.save();try require(replies.count==1,"Missing untracked warning")
        replies[0](false);save.model.save();try require(replies.count==2,"Missing second warning")
        replies[0](true);try require(save.model.confirmingUntracked && save.model.progress==nil,"Old warning response accepted a new request")
        replies[1](false);save.model.options.includeUntracked=false
        save.model.onProgress={_ in};save.model.save();try await wait {save.model.progress != nil && save.model.progress?.busy==false}
        let saved=save.model.progress!
        try require(saved.success && saved.result?.created==true && Data(contentsOf:file)==Data("base\n".utf8),"Accepted Stash Save failed to create actual stash")
        let stash=try await repo.run(["rev-parse","refs/stash"]).stdout
        let subject=try await repo.run(["log","-1","--format=%s","refs/stash"]).text
        try require(subject.contains("kept stash draft 🐢"),"Edited Stash message did not reach Git")
        saved.close();try await wait {!workspace.busy}
        var resultReplies=[(Bool,Bool)->Void](),restoreCalls=0
        workspace.stashRestoreWindowFactory={repository,access,pop,reference,show in
            restoreCalls += 1
            let owner=StashRestoreWindowController(repository:repository,access:access,pop:pop,reference:reference,showChanges:show,preferences:prefs)
            owner.model.onPresent={prompt,reply in resultReplies.append(reply)}
            return owner
        }
        invoke(["--command=stashapply"])
        try await wait {!workspace.busy && windows(StashRestoreWindowController.self).first?.model.result != nil && !resultReplies.isEmpty}
        let applied=try requireOne(windows(StashRestoreWindowController.self))
        let afterApply=try await repo.run(["rev-parse","refs/stash"]).stdout
        try require(!applied.pop && applied.model.success && applied.model.preferences===prefs && applied.model.prompt?.kind == .question && afterApply==stash && Data(contentsOf:file)==Data("shelved 🐢\n".utf8),"Stash Apply lost source result question, worktree bytes or retained stash")
        resultReplies.removeFirst()(false,false);try await wait {windows(StashRestoreWindowController.self).isEmpty}
        invoke(["--command=stashlist"]);try await wait {!workspace.busy && windows(ReferenceLogWindowController.self).first?.model.busy==false}
        let list=try requireOne(windows(ReferenceLogWindowController.self));try require(list.model.reference=="refs/stash","Stash List did not open stash RefLog");list.close()
        _ = try await repo.run(["reset","--hard","HEAD"])
        invoke(["--command=stashpop"])
        try await wait {!workspace.busy && windows(StashRestoreWindowController.self).first?.model.result != nil && !resultReplies.isEmpty}
        let popped=try requireOne(windows(StashRestoreWindowController.self))
        let missing=try await repo.run(["rev-parse","--verify","refs/stash"],successfulExitCodes:0...128)
        try require(popped.pop && popped.model.success && missing.exitCode != 0 && Data(contentsOf:file)==Data("shelved 🐢\n".utf8),"Stash Pop failed to restore and remove stash")
        resultReplies.removeFirst()(false,false);try await wait {windows(StashRestoreWindowController.self).isEmpty}
        // A real pending receiver with injected cancellable backend exposes launch/acceptance races.
        invoke(["--command=stashsave"]);try await wait {!workspace.busy && !windows(StashWindowController.self).isEmpty}
        let pendingSave=try requireOne(windows(StashWindowController.self))
        try await wait {pendingSave.model.prepared && !pendingSave.model.preparing && !pendingSave.model.busy}
        workspace.stashRestoreWindowFactory={repository,access,pop,reference,show in
            restoreCalls += 1
            let owner=StashRestoreWindowController(repository:repository,access:access,pop:pop,reference:reference,showChanges:show,preferences:prefs)
            owner.model.restore={_,_,token in while !token.isCancelled {try await Task.sleep(nanoseconds:10_000_000)};throw OperationCancellationFailure.cancelled}
            return owner
        }
        invoke(["--command=stashapply"]);try await wait {!workspace.busy && windows(StashRestoreWindowController.self).first?.model.busy==true}
        let running=try requireOne(windows(StashRestoreWindowController.self)),beforeCalls=restoreCalls
        invoke(["--command=stashpop"]);try await wait {!workspace.busy}
        try require(restoreCalls==beforeCalls && windows(StashRestoreWindowController.self).count==1 && workspace.error?.contains("current stash operation")==true,"Concurrent stash launch started a second mutation")
        pendingSave.model.save();try await wait {!pendingSave.model.preparing};try require(!pendingSave.model.busy && pendingSave.model.progress==nil && pendingSave.model.error != nil,"Existing Save draft bypassed active stash operation")
        pendingSave.close();running.model.cancel();try await wait {!running.model.busy && StashRestoreWindowModel.activeOperations==0}
        try require(running.model.cancelled,"Injected owned receiver failed to cancel")
        running.close()
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==baseline,"Merge/Stash command family changed HEAD unexpectedly")
        try await cleanup()
        print("PASS: integration command family: preserved Merge/Abort and Stash drafts; private preferences; accepted real No Commit merge and Abort; Stash Save message/warning generations; actual Apply/Pop/List and result questions; pending duplicate/mutation refusal and cancellation; HEAD preserved and owned windows closed")
        } catch {let original=error;do {try await cleanup()} catch {throw Failure(description:"\(original); cleanup: \(error)")};throw original}
    }
}

private extension NSWindow {
    @objc func turtleGitIntegrationOrder(_ place:NSWindow.OrderingMode,relativeTo otherWindowNumber:Int) {
        alphaValue=0
        turtleGitIntegrationOrder(place,relativeTo:otherWindowNumber)
    }
}
