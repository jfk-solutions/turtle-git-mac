import AppKit
import TurtleGitCore

@MainActor enum StashExportProgressFixture {
    static func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:message,code:1)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:message,code:2)}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func repository(_ name:String)async throws->(GitRepository,String,String){
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name),git=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:git);_ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Progress family"),("user.email","progress@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);_ = try await repo.run(["branch","older",base])
        try Data("next\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"next")
        let next=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        return(repo,base,next)
    }
    static func parent()->NSWindow{
        let owner=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:750,height:450),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.appearance=NSAppearance(named:.darkAqua);return owner
    }
    static func attach(_ child:NSWindow?,to parent:NSWindow){if let child{child.alphaValue=parent.alphaValue;child.appearance=parent.appearance;parent.beginSheet(child,completionHandler:nil)}}
    static func output(_ window:NSWindow?,text:String,range:NSRange?,percentage:Int?,success:Bool,preferences:UserDefaults,clipboard:NSPasteboard)async throws{
        try await wait("Native styled progress output did not update"){window?.contentView?.layoutSubtreeIfNeeded();return views(window?.contentView).compactMap{$0 as? SubmoduleProgressTextView}.first?.string==text}
        let field=views(window?.contentView).compactMap{$0 as? SubmoduleProgressTextView}.first!
        try require(range != nil && percentage==100 && NSMaxRange(range!)<=field.textStorage!.length,"Command receipt lost terminal100 or footer range")
        let caption=(text as NSString).substring(with:range!)
        try require(success ? caption.contains("Success") : ["git did not exit cleanly","Operation failed","User cancelled"].contains(where:caption.contains),"Wrong command completion footer: \(caption)")
        let color=field.textStorage!.attribute(.foregroundColor,at:range!.location,effectiveRange:nil) as? NSColor
        for mode in [NSAppearance.Name.aqua,.darkAqua]{NSAppearance(named:mode)!.performAsCurrentDrawingAppearance{
            let expected=success ? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.textColor:SubmoduleProgressTextView.successColor:SubmoduleProgressTextView.color(error:true)
            precondition(color?.usingColorSpace(.sRGB)==expected.usingColorSpace(.sRGB),"Progress footer color differs in \(mode)")
        }}
        try require(!field.isEditable && field.isSelectable && field.preferences===preferences && field.clipboard===clipboard,"Progress lost native selection or private captured preferences/clipboard: editable=\(field.isEditable),selectable=\(field.isSelectable),samePreferences=\(field.preferences===preferences),sameClipboard=\(field.clipboard===clipboard)")
        let selected=NSRange(location:0,length:min(4,(text as NSString).length));field.setSelectedRange(selected);field.copyAllInformation(nil)
        try require(clipboard.string(forType:.string)==text && field.selectedRange()==selected,"Progress Copy All changed bytes/selection")
    }
    static func wrapper(_ repo:GitRepository,command:String) throws->(GitRepository,URL,URL){
        let file=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("held-"+command),marker=URL(fileURLWithPath:file.path+".started"),release=URL(fileURLWithPath:file.path+".release")
        let git=repo.executable.path.replacingOccurrences(of:"'",with:"'\\''")
        let script="""
        #!/bin/sh
        task_command() {
          if [ "${1-}" = --literal-pathspecs ] || [ "${1-}" = --no-literal-pathspecs ]; then shift; fi
          if [ "${1-}" = -C ]; then shift 2; fi
          while [ "${1-}" = -c ]; do shift 2; done
          test "${1-}" = '\(command)'
        }
        if task_command "$@" && [ ! -f "$0.release" ]; then
          printf 'Updating files:  50%% (1/2)\\r' >&2
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp"
          /bin/mv "$0.started.tmp" "$0.started"
          wait "$task_child"
        fi
        exec '\(git)' "$@"
        """
        try script.write(to:file,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:file.path)
        return(GitRepository(root:repo.root,executable:file),marker,release)
    }
}

struct StashProgressFamilyVerification {
    @MainActor static func verify()async throws {
        typealias F=StashExportProgressFixture
        let suite="TurtleGit.StashFamily."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ShowGitexeTimings");prefs.set(true,forKey:"StyleGitOutput");prefs.set(true,forKey:"ConfirmKillProcess")
        defer{prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let(repo,_,_)=try await F.repository("stash space")
        try Data("saved work\n".utf8).write(to:repo.root.appendingPathComponent("file"))
        let model=StashSaveProgressWindowModel(repository:repo,access:nil,options:StashSaveOptions(),followUp:StashSaveFollowUp(),preferences:prefs)
        model.outputClipboard=clipboard
        let parent=F.parent(),owner=StashSaveProgressWindowController(model:model)
        F.attach(owner.window,to:parent);defer{owner.close();parent.close()}
        var pending:CheckedContinuation<StashSaveResult,Error>?,closed=0,finished=0,heldToken:OperationCancellation?
        defer{pending?.resume(throwing:OperationCancellationFailure.cancelled);pending=nil}
        model.saveOperation={options,token,output,receipt in
            heldToken=token
            let result=try await repo.saveStash(options,cancellation:token,onOutput:output,onCommand:{output(GitOutputChunk(stream:.stdout,data:$0.preamble))},onCommandFinished:receipt)
            return try await withCheckedThrowingContinuation{pending=$0;_ = result}
        }
        owner.onClosed={closed+=1};model.onFinished={_,_ in finished+=1}
        model.start();try F.require(model.hasPendingWork,"Stash start did not synchronously reserve actual work")
        try await F.wait("Stash command receipt/held metadata missing"){pending != nil && model.commandFinished}
        try F.require(model.commandSucceeded && !model.success && model.busy && model.hasPendingWork && model.postActions.isEmpty && finished==0,"Stash receipt exposed workflow completion before metadata")
        let expected=repo.executable.path+" --no-literal-pathspecs -C '"+repo.root.path+"' stash push\n"
        try F.require(model.output.hasPrefix(expected),"Stash did not show exact executed command first: \(model.output.debugDescription)")
        try await F.output(owner.window,text:model.output,range:model.completionRange,percentage:model.percentage,success:true,preferences:prefs,clipboard:clipboard)
        try F.require(!(model.output as NSString).substring(with:model.completionRange!).contains(" ms @ "),"Stash ignored captured hidden timings")
        try F.require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped held Stash metadata")
        owner.close();try F.require(heldToken?.isCancelled==true && model.hasPendingWork && closed==0,"Forced Stash close released before held metadata")
        pending?.resume(throwing:OperationCancellationFailure.cancelled);pending=nil
        try await F.wait("Stash retired metadata did not drain/detach"){!model.hasPendingWork && closed==1 && parent.attachedSheet==nil && StashWindowController.activeChildReleases==0}
        try F.require(finished==0 && !model.active,"Retired Stash published completion")
        try await verifyCancellation(repo:repo,preferences:prefs,clipboard:clipboard)
        try await verifyRootRoutes(preferences:prefs)
        try await verifyRestoreStatusCache(preferences:prefs)
        print("Stash exact preamble/styled receipt/private Copy, synchronous ownership/held metadata/Quit/retirement, real native No/Yes and captured Root followups passed.")
    }
    @MainActor static func verifyCancellation(repo:GitRepository,preferences:UserDefaults,clipboard:NSPasteboard)async throws {
        typealias F=StashExportProgressFixture
        try Data("cancel preserved\n".utf8).write(to:repo.root.appendingPathComponent("file"))
        let(slow,marker,_)=try F.wrapper(repo,command:"stash")
        let model=StashSaveProgressWindowModel(repository:slow,access:nil,options:StashSaveOptions(),followUp:StashSaveFollowUp(),preferences:preferences)
        model.outputClipboard=clipboard
        let parent=F.parent(),owner=StashSaveProgressWindowController(model:model)
        F.attach(owner.window,to:parent);defer{owner.close();parent.close()}
        var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?,closed=0
        owner.onClosed={closed+=1};owner.presentCancellation={question,window,reply in alert=question;answer=reply;question.beginSheetModal(for:window,completionHandler:reply)}
        model.start();try await F.wait("Held Stash worker/progress missing"){FileManager.default.fileExists(atPath:marker.path) && model.percentage==50}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try F.require(pids.count==2 && pids.allSatisfy{kill($0,0)==0},"Stash helper ownership missing")
        model.cancel();try await F.wait("Stash kill question missing"){alert?.window.sheetParent===owner.window}
        try F.require(alert?.window.alphaValue==0 && alert?.window.appearance?.name==parent.appearance?.name,"Stash cancellation lost captured appearance")
        answer?(.alertSecondButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Stash No did not actually detach"){!model.confirmingCancellation && owner.window?.attachedSheet==nil}
        try F.require(!model.cancelling && pids.allSatisfy{kill($0,0)==0},"Late duplicate Yes killed rejected Stash worker")
        model.cancel();try await F.wait("Stash second question missing"){alert?.window.sheetParent===owner.window};answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Stash cancelled worker did not drain"){!model.hasPendingWork && !model.busy && model.cancelled && pids.allSatisfy{kill($0,0) != 0}}
        try F.require(!model.commandSucceeded && !model.success && model.postActions.isEmpty && owner.window?.attachedSheet==nil,"Cancelled Stash exposed postactions before question drain")
        try await F.output(owner.window,text:model.output,range:model.completionRange,percentage:model.percentage,success:false,preferences:preferences,clipboard:clipboard)
        try F.require(try Data(contentsOf:repo.root.appendingPathComponent("file"))==Data("cancel preserved\n".utf8),"Cancelled stash changed working bytes")
        model.close();model.close();try await F.wait("Cancelled Stash close did not release once"){closed==1 && parent.attachedSheet==nil}
    }
    @MainActor static func verifyRootRoutes(preferences:UserDefaults)async throws {
        typealias F=StashExportProgressFixture
        let(repo,_,_)=try await F.repository("stash-root-routes"),grant=RepositoryAccessLease(url:repo.root),workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        defer{workspace.stopMonitoringForTermination()}
        for action in [StashSavePostAction.pull,.merge] {
            try Data("route \(action)\n".utf8).write(to:repo.root.appendingPathComponent("file"))
            let owner=StashWindowController(repository:repo,access:grant,preferences:preferences)
            owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua)
            defer{owner.close()}
            workspace.configureStashInteractions(owner,repository:repo,access:grant)
            owner.model.followUp.showPull=true;owner.model.followUp.mergeRevision="refs/heads/older"
            owner.model.prepare();try await F.wait("Root Stash preparation did not drain"){owner.model.prepared && !owner.model.preparing}
            owner.model.save();try await F.wait("Root Stash progress did not finish"){owner.progressController?.model.success==true && owner.progressController?.model.hasPendingWork==false}
            let progress=owner.progressController!,before=Set(NSApp.windows.map{ObjectIdentifier($0)})
            try F.require(progress.model.postActions.contains(action),"Stash followup missing captured action")
            progress.model.perform(action);progress.model.perform(action)
            try await F.wait("Root Stash followup did not release actual progress/options"){owner.progressController==nil && owner.window?.attachedSheet==nil && progress.window?.sheetParent==nil}
            let children=NSApp.windows.filter{!before.contains(ObjectIdentifier($0))}
            if action == .merge {
                let child=try children.compactMap{$0.delegate as? MergeWindowController}.first.unwrap("Stash Merge did not open actual controller")
                defer{child.close()}
                try F.require(child.model.repositoryAccess===grant && child.model.presentationPreferences===preferences && child.window?.appearance?.name==NSAppearance.Name.darkAqua && child.window?.alphaValue==0,"Stash Merge lost captured grant/preferences/appearance")
                try await F.wait("Stash Merge child metadata did not drain"){!child.model.busy}
            } else {
                let child=try children.compactMap{$0.delegate as? FetchWindowController}.first.unwrap("Stash Pull did not open actual controller")
                defer{child.close()}
                try F.require(child.model.repositoryAccess===grant && child.model.presentationPreferences===preferences && child.window?.appearance?.name==NSAppearance.Name.darkAqua && child.window?.alphaValue==0,"Stash Pull lost captured grant/preferences/appearance")
                try await F.wait("Stash Pull child metadata did not drain"){!child.model.busy}
            }
            try F.require(children.filter{$0.delegate is MergeWindowController || $0.delegate is FetchWindowController}.count==1,"Stash duplicate postaction opened multiple children")
        }
    }
    @MainActor static func verifyRestoreStatusCache(preferences:UserDefaults)async throws {
        typealias F=StashExportProgressFixture
        let suite="TurtleGit.StashRestorePrivateB."+UUID().uuidString,other=UserDefaults(suiteName:suite)!
        other.set(0,forKey:"AutoCloseGitProgress");other.set(false,forKey:"ConfirmKillProcess")
        defer{other.removePersistentDomain(forName:suite)}
        let(repo,_,_)=try await F.repository("stash-status-cache"),grant=RepositoryAccessLease(url:repo.root),workspace=RepositoryModel(startMonitoring:false,initializePreferences:false)
        var first:StatusWindowController?,second:StatusWindowController?
        defer{first?.close();second?.close();workspace.stopMonitoringForTermination()}
        for iteration in 0..<3 {
            let prefs=iteration==1 ? other:preferences
            _ = try await repo.run(["reset","--hard","HEAD"])
            try Data("restore cache \(iteration)\n".utf8).write(to:repo.root.appendingPathComponent("file"))
            let owner=StashWindowController(repository:repo,access:grant,preferences:prefs)
            owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:iteration==1 ? .aqua:.darkAqua)
            defer{owner.close()}
            workspace.configureStashInteractions(owner,repository:repo,access:grant);owner.model.prepare()
            try await F.wait("Stash cache preparation did not settle"){owner.model.prepared && !owner.model.preparing}
            owner.model.save();try await F.wait("Stash cache Save did not settle"){owner.progressController?.model.success==true && owner.progressController?.model.hasPendingWork==false}
            let progress=owner.progressController!,before=Set(NSApp.windows.map{ObjectIdentifier($0)})
            progress.model.perform(.apply);progress.model.perform(.apply)
            var restore:StashRestoreWindowController?
            try await F.wait("Stash Apply did not open actual Restore result"){restore=NSApp.windows.filter{!before.contains(ObjectIdentifier($0))}.compactMap{$0.delegate as? StashRestoreWindowController}.first;return restore?.model.prompt != nil && restore?.model.busy==false && StashRestoreWindowModel.activeOperations==0 && restore?.window?.attachedSheet != nil}
            defer{restore?.close()}
            try F.require(restore?.model.preferences===prefs && restore?.window?.appearance?.name==owner.window?.appearance?.name,"Stash Restore lost captured preferences/appearance")
            let sheet=restore!.window!.attachedSheet!,yes=F.views(sheet.contentView).compactMap{$0 as? NSButton}.first{$0.title=="Yes"}
            try F.require(yes != nil,"Actual Stash Restore changes question has no Yes control");yes?.performClick(nil)
            var status:StatusWindowController?
            try await F.wait("Restore changes did not open captured Working Tree after detach"){status=NSApp.windows.compactMap{$0.delegate as? StatusWindowController}.first{$0.model.colorPreferences===prefs && !$0.model.retired};return status != nil && restore?.window?.attachedSheet==nil && restore?.window?.sheetParent==nil}
            try F.require(status!.model.colorPreferences===prefs && status!.window?.appearance?.name==owner.window?.appearance?.name && status!.window?.alphaValue==0,"Restore->Status lost private preference/appearance snapshot")
            try await F.wait("Working Tree refresh did not drain"){!status!.model.busy}
            if iteration==0 {first=status;first!.model.filter.showUnversioned=false}
            else if iteration==1 {
                second=status;try F.require(second !== first && first?.model.retired==false && first?.model.filter.showUnversioned==false,"Private B Working Tree reused or changed private A draft")
                second?.close();try await F.wait("Private B Working Tree did not retire"){second?.model.retired==true}
            } else {try F.require(status===first && first?.model.filter.showUnversioned==false,"Closing private B evicted reusable private A Working Tree")}
        }
    }

}
private extension Optional {
    func unwrap(_ message:String)throws->Wrapped {guard let self else{throw NSError(domain:message,code:1)};return self}
}
