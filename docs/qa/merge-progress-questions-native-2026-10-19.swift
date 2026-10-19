import AppKit
import TurtleGitCore

struct MergeProgressQuestionsVerification {
    @MainActor static func verify()async throws{
        typealias F=MergeProgressFamilyFixture
        let suite="TurtleGit.MergeQuestions."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(true,forKey:"ConfirmKillProcess")
        defer{prefs.removePersistentDomain(forName:suite)}
        let repo=try await F.repository("held-worker"),root=URL(fileURLWithPath:CommandLine.arguments[1]),helper=root.appendingPathComponent("held-merge-git"),marker=root.appendingPathComponent("merge-worker-pids")
        let actual=repo.executable.path.replacingOccurrences(of:"'",with:"'\\''")
        let script="""
        #!/bin/sh
        task_merge=false
        case "$1" in
          --literal-pathspecs|--no-literal-pathspecs)
            if [ "$2" = -C ] && [ "$4" = merge ]; then task_merge=true; fi ;;
        esac
        if [ "$task_merge" = true ]; then
          printf 'Receiving objects:  50%% (1/2)\\r' >&2
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > '\(marker.path).tmp'
          /bin/mv '\(marker.path).tmp' '\(marker.path)'
          wait "$task_child"
        fi
        exec '\(actual)' "$@"
        """
        try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let heldRepo=GitRepository(root:repo.root,executable:helper),model=MergeProgressWindowModel(repository:heldRepo,access:nil,options:F.options(),target:.branch,showStashPop:false,preferences:prefs),host=F.owner(model)
        defer{host.1.close();host.0.close()}
        var question:NSAlert?,reply:((NSApplication.ModalResponse)->Void)?,readReply:CheckedContinuation<[StatusEntry],Error>?,readToken:OperationCancellation?,closed=0,changes=0
        defer{readReply?.resume(returning:[]);readReply=nil}
        host.1.onClosed={closed+=1};model.onChanged={_ in changes+=1}
        model.readStatus={token in readToken=token;return try await withCheckedThrowingContinuation{readReply=$0}}
        host.1.presentQuestion={kind,alert,window,answer in
            if case .cancellation=kind{}else{preconditionFailure("Unexpected worker question")}
            question=alert;reply=answer;alert.beginSheetModal(for:window,completionHandler:answer)
        }
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        model.start();try F.require(model.hasPendingWork && MergeProgressWindowModel.activeOperations>0,"start did not synchronously register worker ownership")
        try await F.wait("Held Merge worker/progress did not arrive"){FileManager.default.fileExists(atPath:marker.path) && model.percentage==50}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try F.require(pids.count==2 && pids.allSatisfy{kill($0,0)==0},"Held merge helper processes were not alive")
        model.cancel();try await F.wait("Kill-process question did not attach"){question?.window.sheetParent===host.1.window}
        try F.require(model.confirmingCancellation && model.busy && !model.cancelling && question?.window.alphaValue==0 && question?.window.appearance?.name==host.0.appearance?.name,"Kill question lost blocking state/captured appearance")
        reply?(.alertSecondButtonReturn);reply?(.alertFirstButtonReturn)
        try await F.wait("No-kill response did not detach"){!model.confirmingCancellation && host.1.window?.attachedSheet==nil}
        try F.require(model.busy && !model.cancelling && pids.allSatisfy{kill($0,0)==0},"Duplicate late Yes killed rejected worker")
        question=nil;model.cancel();try await F.wait("Second kill question missing"){question?.window.sheetParent===host.1.window}
        reply?(.alertFirstButtonReturn);reply?(.alertFirstButtonReturn)
        try await F.wait("Cancelled Merge did not reach held recovery read"){readReply != nil && model.commandFinished && model.cancelled && pids.allSatisfy{kill($0,0) != 0}}
        try await F.footer(model,host.1,success:false)
        try F.require(model.busy && model.hasPendingWork && model.percentage==100 && model.postActions.isEmpty && host.1.window?.attachedSheet==nil,"Cancelled command lost retained100/footer or exposed recovery actions before read drain")
        try F.require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped held recovery read")
        model.perform(.stash);try F.require(changes==0,"Held recovery read dispatched a post-action")
        host.1.close()
        try F.require(readToken?.isCancelled==true && model.hasPendingWork && closed==0 && MergeWindowController.activeChildReleases>0,"Forced close dropped undrained recovery ownership")
        readReply?.resume(returning:[]);readReply=nil
        try await F.wait("Retired recovery read did not release actual sheet"){!model.hasPendingWork && closed==1 && MergeWindowController.activeChildReleases==0 && host.0.attachedSheet==nil}
        try F.require(changes==0 && !model.active && model.postActions.isEmpty,"Retired recovery read published state/actions")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try F.require(after==head,"Cancelled held worker changed HEAD")
        // A real conflicting merge paints its footer before its informational
        // hint; only actual sheet detach permits recovery actions to appear.
        let conflictRepo=try await F.repository("conflict-questions",conflict:true),conflict=MergeProgressWindowModel(repository:conflictRepo,access:nil,options:F.options(),target:.branch,showStashPop:false,preferences:prefs),conflictHost=F.owner(conflict)
        defer{conflictHost.1.close();conflictHost.0.close()}
        question=nil;reply=nil
        conflictHost.1.presentQuestion={kind,alert,window,answer in
            if case .conflictHint=kind{}else{preconditionFailure("Unexpected conflict question")}
            question=alert;reply=answer;alert.beginSheetModal(for:window,completionHandler:answer)
        }
        let conflicted=Task{await conflict.run()}
        try await F.wait("Real conflict hint did not attach"){question?.window.sheetParent===conflictHost.1.window && conflict.confirmingConflictHint}
        try await F.footer(conflict,conflictHost.1,success:false)
        try F.require(conflict.busy && conflict.postActions.isEmpty && question?.showsSuppressionButton==true,"Conflict hint did not block recovery or lost suppression")
        question?.suppressionButton?.state = .on;reply?(.alertFirstButtonReturn);reply?(.alertFirstButtonReturn)
        await conflicted.value
        try F.require(!conflict.busy && !conflict.hasPendingWork && conflictHost.1.window?.attachedSheet==nil && conflict.postActions==[.resolve,.commit,.stash] && prefs.bool(forKey:MergeProgressWindowModel.conflictHintPreference),"Conflict hint did not detach before recovery/persist captured suppression")
        conflictHost.1.close();try await F.wait("Conflict host did not detach"){conflictHost.0.attachedSheet==nil && MergeWindowController.activeChildReleases==0}
        _ = try await conflictRepo.abortMerge()
        prefs.removeObject(forKey:MergeProgressWindowModel.conflictHintPreference)
        let retired=MergeProgressWindowModel(repository:conflictRepo,access:nil,options:F.options(),target:.branch,showStashPop:false,preferences:prefs),retiredHost=F.owner(retired)
        defer{retiredHost.1.close();retiredHost.0.close()};question=nil;reply=nil;var retiredClosed=0
        retiredHost.1.onClosed={retiredClosed+=1};retiredHost.1.presentQuestion={_,alert,window,answer in question=alert;reply=answer;alert.beginSheetModal(for:window,completionHandler:answer)}
        let retiredWork=Task{await retired.run()};try await F.wait("Retired conflict question missing"){question?.window.sheetParent===retiredHost.1.window}
        question?.suppressionButton?.state = .on;let late=reply;retiredHost.1.close();late?(.alertFirstButtonReturn)
        await retiredWork.value;try await F.wait("Retired conflict sheet/work did not drain"){!retired.hasPendingWork && retiredClosed==1 && retiredHost.0.attachedSheet==nil && MergeWindowController.activeChildReleases==0}
        try F.require(!prefs.bool(forKey:MergeProgressWindowModel.conflictHintPreference) && retired.postActions.isEmpty,"Late retired hint stored suppression or recovery actions")
        try await verifyRootRoutes(preferences:prefs)
        print("Merge actual kill No/Yes, streamed progress, cancelled footer before held recovery, process/Quit drain, conflict suppression and retired duplicate replies passed.")
    }
    @MainActor static func verifyRootRoutes(preferences:UserDefaults)async throws{
        typealias F=MergeProgressFamilyFixture
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        defer{workspace.stopMonitoringForTermination()}
        preferences.set(true,forKey:MergeProgressWindowModel.conflictHintPreference)
        for route in ["commit","resolve","abort","stash","push"] {
            let conflicted=["resolve","abort","stash"].contains(route)
            let repo=try await F.repository("route-"+route,conflict:conflicted),permission=RepositoryAccessLease(url:repo.root)
            let parent=MergeWindowController(repository:repo,access:permission,preferences:preferences)
            defer{parent.close()}
            parent.window?.alphaValue=0;parent.window?.appearance=NSAppearance(named:.darkAqua)
            workspace.configureMergeInteractions(parent,repository:repo,access:permission)
            parent.model.load(revision:"refs/heads/feature")
            try await F.wait("Actual Merge form did not prepare for "+route){!parent.model.busy && parent.model.prepared}
            parent.model.options.noFastForward=true;parent.model.options.noCommit=route=="commit"
            parent.model.merge()
            try await F.wait("Actual Merge progress missing for "+route){parent.progressController != nil}
            let progress=parent.progressController!
            try await F.wait("Actual Merge result did not drain for "+route){!progress.model.busy && !progress.model.hasPendingWork}
            try F.require(progress.window?.sheetParent===parent.window && progress.window?.alphaValue==0 && progress.window?.appearance?.name==parent.window?.appearance?.name,"Actual Merge progress did not inherit source presentation")
            let before=Set(NSApp.windows.map{ObjectIdentifier($0)})
            if route=="abort"{progress.model.cancelResult()}
            else{progress.model.perform(route=="commit" ? .commit:route=="resolve" ? .resolve:route=="stash" ? .stash:.push)}
            func child()->NSWindowController?{
                NSApp.windows.filter{!before.contains(ObjectIdentifier($0))}.compactMap{$0.delegate as? NSWindowController}.first{value in
                    switch route {
                    case "commit":return value is CommitWindowController
                    case "resolve":return value is ResolveWindowController
                    case "abort":return value is MergeAbortWindowController
                    case "stash":return value is StashWindowController
                    default:return value is PushWindowController
                    }
                }
            }
            do{
                try await F.wait("Actual post-Merge child route missing: "+route){child() != nil && parent.window?.attachedSheet==nil && progress.window?.sheetParent==nil}
                let destination=child()!
                try F.require(!progress.model.hasPendingWork && destination.window?.alphaValue==0 && destination.window?.appearance?.name==NSAppearance.Name.darkAqua,"Post-Merge "+route+" preceded drain or lost captured appearance")
                if let value=destination as? CommitWindowController {
                    try F.require(value.presentationPreferences===preferences && value.model.colorPreferences===preferences && value.model.access===permission,"Actual Commit route lost preferences/grant")
                    try await F.wait("Commit route read did not settle"){!value.model.busy};value.close()
                }else if let value=destination as? ResolveWindowController {
                    try F.require(value.model.preferences===preferences && value.model.repositoryAccess===permission,"Actual Resolve route lost preferences/grant")
                    try await F.wait("Resolve route read did not settle"){!value.model.busy};value.close()
                }else if let value=destination as? MergeAbortWindowController {
                    try F.require(value.model.presentationPreferences===preferences && value.model.repositoryAccess===permission,"Actual Abort route lost preferences/grant");value.close()
                }else if let value=destination as? StashWindowController {
                    try F.require(value.model.preferences===preferences && value.model.repositoryAccess===permission && value.model.followUp.mergeRevision=="refs/heads/feature","Actual Stash route lost preferences/grant/retry target")
                    try await F.wait("Stash route read did not settle"){!value.model.busy && !value.model.preparing};value.close()
                }else if let value=destination as? PushWindowController {
                    try F.require(value.model.presentationPreferences===preferences && value.model.repositoryAccess===permission,"Actual Push route lost preferences/grant")
                    try await F.wait("Push route read did not settle"){!value.model.busy};value.close()
                }
                try await F.wait("Post-Merge child release survived "+route){MergeWindowController.activeChildReleases==0}
                parent.close()
            }catch{child()?.close();progress.close();parent.close();throw error}
        }
    }

}
