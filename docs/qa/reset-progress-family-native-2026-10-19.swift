import AppKit
import TurtleGitCore

struct ResetProgressFamilyVerification {
    @MainActor static func verify()async throws{
        typealias F=SwitchResetProgressFixture
        let suite="TurtleGit.ResetFamily."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(true,forKey:"ConfirmKillProcess");prefs.set(false,forKey:"ShowGitexeTimings");prefs.set(true,forKey:"StyleGitOutput")
        defer{prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let (repo,base,next)=try await F.repository("reset space"),state=try await repo.bisectState()
        let (slow,marker,release)=try F.wrapper(repo,command:"reset"),plan=try await repo.prepareReset(to:base,mode:.hard),model=ResetProgressWindowModel(repository:slow,plan:plan,preferences:prefs)
        model.outputClipboard=clipboard
        let parent=F.parent(),owner=ResetProgressWindowController(model:model)
        F.attach(owner.window,to:parent);defer{owner.close();parent.close()}
        var readReply:CheckedContinuation<BisectState,Error>?,readToken:OperationCancellation?,closed=0,changes=0,alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?
        defer{readReply?.resume(returning:state);readReply=nil}
        model.readBisect={token in readToken=token;return try await withCheckedThrowingContinuation{readReply=$0}}
        owner.onClosed={closed+=1};model.onChanged={_ in changes+=1};owner.presentCancellation={question,window,reply in alert=question;answer=reply;question.beginSheetModal(for:window,completionHandler:reply)}
        model.start();try F.require(model.hasPendingWork,"Reset start did not synchronously reserve work")
        try await F.wait("Held Reset progress did not arrive"){FileManager.default.fileExists(atPath:marker.path) && model.percentage==50}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try F.require(pids.count==2 && pids.allSatisfy{kill($0,0)==0},"Held Reset helper ownership missing")
        model.cancel();try await F.wait("Reset No question missing"){alert?.window.sheetParent===owner.window}
        try F.require(alert?.window.alphaValue==0 && alert?.window.appearance?.name==parent.appearance?.name,"Reset kill question lost captured appearance")
        answer?(.alertSecondButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Reset No did not detach"){!model.confirmingCancellation && owner.window?.attachedSheet==nil}
        try F.require(!model.cancelling && pids.allSatisfy{kill($0,0)==0},"Duplicate late Reset Yes killed rejected worker")
        model.cancel();try await F.wait("Reset late-Yes question missing"){alert?.window.sheetParent===owner.window}
        try Data().write(to:release);_ = kill(pids[1],SIGTERM)
        try await F.wait("Reset command did not finish before held bisect metadata"){readReply != nil && model.commandFinished && pids.allSatisfy{kill($0,0) != 0}}
        try F.require(model.commandSucceeded && model.success && model.busy && model.hasPendingWork && model.confirmingCancellation && changes==0 && !model.canCancel,"Reset exposed completion before held metadata or allowed killing completed command")
        let preamble=slow.executable.path+" --literal-pathspecs -C '"+repo.root.path+"' reset --hard "+base+" --\n"
        try F.require(model.output.hasPrefix(preamble),"Reset exact actual command preamble missing: \(model.output.debugDescription)")
        try await F.output(owner.window,text:model.output,range:model.completionRange,percentage:model.percentage,success:true,preferences:prefs,clipboard:clipboard)
        let capturedFooter=(model.output as NSString).substring(with:model.completionRange!)
        try F.require(!capturedFooter.contains(" ms @ "),"Reset ignored captured hidden timings")
        answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Reset late Yes question did not detach"){!model.confirmingCancellation && owner.window?.attachedSheet==nil}
        try F.require(readToken?.isCancelled==false && !model.cancelled && model.hasPendingWork,"Late Yes cancelled completed Reset metadata")
        try F.require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped actual held Reset metadata")
        model.perform(.clean);model.close();try F.require(closed==0,"Reset handed off while metadata read still owned")
        owner.close();try F.require(readToken?.isCancelled==true && model.hasPendingWork && closed==0,"Reset forced close dropped held metadata lifetime")
        readReply?.resume(returning:state);readReply=nil
        try await F.wait("Reset retired metadata did not drain/release"){!model.hasPendingWork && closed==1 && parent.attachedSheet==nil && ResetWindowController.activeChildReleases==0}
        try F.require(changes==0 && !model.active && model.postActions.isEmpty,"Retired Reset metadata published state/actions")
        try await verifyCancellation(repo:repo,target:next,preferences:prefs,clipboard:clipboard,slow:slow,marker:marker,release:release)
        try await verifyStalePlan(repo:repo,target:base,preferences:prefs,clipboard:clipboard)
        try await verifyRootRoutes(preferences:prefs)
        print("Reset exact preamble/styled receipt100 before held bisect read, native No/late Yes/actual cancel, forced-close/Quit drain, retry/preflight refusal and actual captured Root routes passed.")
    }
    @MainActor static func verifyCancellation(repo:GitRepository,target:String,preferences:UserDefaults,clipboard:NSPasteboard,slow:GitRepository,marker:URL,release:URL)async throws{
        typealias F=SwitchResetProgressFixture
        try FileManager.default.removeItem(at:release);try FileManager.default.removeItem(at:marker)
        let plan=try await repo.prepareReset(to:target,mode:.mixed),model=ResetProgressWindowModel(repository:slow,plan:plan,preferences:preferences)
        model.outputClipboard=clipboard
        let parent=F.parent(),owner=ResetProgressWindowController(model:model)
        F.attach(owner.window,to:parent);defer{owner.close();parent.close()}
        var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?,closed=0
        owner.onClosed={closed+=1};owner.presentCancellation={question,window,reply in alert=question;answer=reply;question.beginSheetModal(for:window,completionHandler:reply)}
        model.start();try await F.wait("Second held Reset did not start"){FileManager.default.fileExists(atPath:marker.path) && model.percentage==50}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        model.cancel();try await F.wait("Reset Yes question missing"){alert?.window.sheetParent===owner.window};answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Cancelled Reset worker did not drain"){!model.busy && !model.hasPendingWork && model.cancelled && pids.allSatisfy{kill($0,0) != 0}}
        try F.require(!model.success && model.postActions==[.retry] && owner.window?.attachedSheet==nil,"Reset cancellation lost retry or preceded actual question detach")
        try await F.output(owner.window,text:model.output,range:model.completionRange,percentage:model.percentage,success:false,preferences:preferences,clipboard:clipboard)
        let unchanged=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);try F.require(unchanged==plan.originalHead,"Cancelled Reset mutated HEAD")
        try Data().write(to:release);model.perform(.retry)
        try F.require(model.hasPendingWork && !model.commandFinished && model.completionRange==nil && model.percentage==nil && model.output.isEmpty,"Reset Retry did not synchronously retire old receipt")
        try await F.wait("Cancelled Reset retry did not succeed"){!model.busy && !model.hasPendingWork && model.success}
        model.close();try await F.wait("Reset result Close did not release"){closed==1 && parent.attachedSheet==nil && ResetWindowController.activeChildReleases==0}
    }
    @MainActor static func verifyStalePlan(repo:GitRepository,target:String,preferences:UserDefaults,clipboard:NSPasteboard)async throws{
        typealias F=SwitchResetProgressFixture
        let plan=try await repo.prepareReset(to:target,mode:.soft);_ = try await repo.run(["switch","-c","other"])
        let model=ResetProgressWindowModel(repository:repo,plan:plan,preferences:preferences)
        model.outputClipboard=clipboard
        let parent=F.parent(),owner=ResetProgressWindowController(model:model)
        F.attach(owner.window,to:parent);defer{owner.close();parent.close()}
        await model.run();try F.require(!model.success && model.postActions==[.retry] && !model.output.contains(repo.executable.path+" --literal-pathspecs"),"Stale-plan preflight fabricated an executed Reset command")
        _ = try await repo.run(["switch","main"]);model.perform(.retry)
        try await F.wait("Stale Reset retry did not recover original branch"){!model.busy && !model.hasPendingWork && model.success}
        let expected=repo.executable.path+" --literal-pathspecs -C '"+repo.root.path+"' reset --soft "+target+" --\n"
        try F.require(model.output.hasPrefix(expected),"Recovered Reset retry did not display actual command first")
    }
    @MainActor static func verifyRootRoutes(preferences:UserDefaults)async throws{
        typealias F=SwitchResetProgressFixture
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        defer{workspace.stopMonitoringForTermination()}
        for action in [ResetPostAction.submoduleUpdate,.clean] {
            let (repo,_,_)=try await F.repository("reset-root-"+action.rawValue)
            try Data("[submodule \"child\"]\npath = child\nurl = ../private-unused\n".utf8).write(to:repo.root.appendingPathComponent(".gitmodules"));try await repo.stage([".gitmodules"]);_ = try await repo.commit(message:"Submodule configuration")
            let revision=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),permission=RepositoryAccessLease(url:repo.root),owner=ResetWindowController(repository:repo,access:permission,revision:revision,preferences:preferences)
            owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua)
            defer{owner.close()}
            workspace.configureResetInteractions(owner,repository:repo,access:permission)
            owner.model.load();try await F.wait("Root Reset form did not load"){!owner.model.busy && !owner.model.chooser.busy}
            owner.model.mode = .hard;owner.model.confirmHard={_,reply in reply(true)};owner.model.reset()
            try await F.wait("Root Reset progress did not finish"){owner.progressController?.model.busy==false && owner.progressController?.model.hasPendingWork==false}
            let progress=owner.progressController!
            try F.require(progress.model.success && progress.model.postActions==[.submoduleUpdate,.clean],"Root Reset source actions differ")
            let before=Set(NSApp.windows.map{ObjectIdentifier($0)})
            progress.model.perform(action);progress.model.perform(action)
            var child:NSWindowController?
            try await F.wait("Actual Root Reset child missing"){child=NSApp.windows.filter{!before.contains(ObjectIdentifier($0))}.compactMap{$0.delegate as? NSWindowController}.first{action == .clean ? $0 is CleanWindowController:$0 is SubmoduleUpdateWindowController};return child != nil && owner.window?.attachedSheet==nil && progress.window?.sheetParent==nil}
            defer{child?.close()}
            try F.require(child!.window?.alphaValue==0 && child!.window?.appearance?.name==NSAppearance.Name.darkAqua,"Root Reset child lost captured appearance")
            if let value=child as? SubmoduleUpdateWindowController {
                try F.require(value.model.repositoryAccess===permission && value.model.presentationPreferences===preferences,"Reset Submodule Update lost captured grant/preferences")
                try await F.wait("Reset child submodule read did not drain"){!value.model.busy};value.close()
            }else if let value=child as? CleanWindowController {
                try F.require(value.model.presentationPreferences===preferences && GitReferenceName.equal(value.model.repository.root.path,repo.root.path),"Reset Clean lost captured repository/preferences")
                try await verifyCleanCache(workspace:workspace,repository:repo,revision:revision,permission:permission,origin:owner,existing:value,preferences:preferences)
                value.close()
            }
            try await F.wait("Reset root handoff release survived"){ResetWindowController.activeChildReleases==0}
        }
    }
    @MainActor static func verifyCleanCache(workspace:RepositoryModel,repository:GitRepository,revision:String,permission:RepositoryAccessLease,origin:ResetWindowController,existing:CleanWindowController,preferences:UserDefaults)async throws{
        typealias F=SwitchResetProgressFixture
        existing.model.options.directories=false
        let suite="TurtleGit.ResetCleanCache."+UUID().uuidString,other=UserDefaults(suiteName:suite)!
        other.set(0,forKey:"AutoCloseGitProgress")
        let owner=ResetWindowController(repository:repository,access:permission,revision:revision,preferences:other)
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua)
        defer{owner.close();other.removePersistentDomain(forName:suite)}
        workspace.configureResetInteractions(owner,repository:repository,access:permission)
        owner.model.load();try await F.wait("Second private Reset form did not load"){!owner.model.busy && !owner.model.chooser.busy}
        owner.model.mode = .hard;owner.model.confirmHard={_,reply in reply(true)};owner.model.reset()
        try await F.wait("Second private Reset progress did not drain"){owner.progressController?.model.busy==false && owner.progressController?.model.hasPendingWork==false}
        let progress=owner.progressController!,before=Set(NSApp.windows.map{ObjectIdentifier($0)})
        try F.require(existing.window?.isVisible==true && existing.model.presentationPreferences===preferences,"Existing private Cleanup window prerequisite missing")
        progress.model.perform(.clean)
        var replacement:CleanWindowController?
        try await F.wait("Reset Cleanup reused a window with different private preferences"){
            replacement=NSApp.windows.filter{!before.contains(ObjectIdentifier($0))}.compactMap{$0.delegate as? CleanWindowController}.first
            return replacement != nil && owner.window?.attachedSheet==nil && progress.window?.sheetParent==nil
        }
        defer{replacement?.close()}
        try F.require(replacement !== existing && replacement!.model.presentationPreferences===other && existing.model.presentationPreferences===preferences && existing.window?.isVisible==true && replacement!.window?.appearance?.name==NSAppearance.Name.darkAqua && replacement!.window?.alphaValue==0 && replacement!.model.options.directories && !existing.model.options.directories,"Cleanup cache changed the originating window or lost the new private preferences/presentation")
        replacement?.close()
        try await F.wait("Second private Cleanup did not close"){replacement?.window?.isVisible==false}
        let retainedWindows=Set(NSApp.windows.map{ObjectIdentifier($0)})
        origin.model.onPostAction?(.clean)
        try F.require(existing.window?.isVisible==true && !existing.model.retired && existing.model.presentationPreferences===preferences && !existing.model.options.directories && !NSApp.windows.contains{!retainedWindows.contains(ObjectIdentifier($0)) && $0.delegate is CleanWindowController},"Closing second private Cleanup removed/replaced or changed the retained first workflow")
    }

}
