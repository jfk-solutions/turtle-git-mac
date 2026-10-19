import AppKit
import TurtleGitCore

@MainActor enum SwitchResetProgressFixture {
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

struct SwitchProgressFamilyVerification {
    @MainActor static func verify()async throws{
        typealias F=SwitchResetProgressFixture
        let suite="TurtleGit.SwitchFamily."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ShowGitexeTimings");prefs.set(true,forKey:"StyleGitOutput");prefs.set(true,forKey:"ConfirmKillProcess")
        defer{prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let (repo,_,_)=try await F.repository("switch space")
        let model=SwitchProgressWindowModel(repository:repo,access:nil,reference:"refs/heads/older",preferences:prefs)
        model.outputClipboard=clipboard
        let parent=F.parent(),owner=SwitchProgressWindowController(model:model)
        F.attach(owner.window,to:parent);defer{owner.close();parent.close()}
        var readReply:CheckedContinuation<[StatusEntry],Error>?,readToken:OperationCancellation?,closed=0,finished=0
        defer{readReply?.resume(returning:[]);readReply=nil}
        owner.onClosed={closed+=1};model.onFinished={_,_ in finished+=1};model.readStatus={token in readToken=token;return try await withCheckedThrowingContinuation{readReply=$0}}
        model.start();try F.require(model.hasPendingWork,"Switch start did not synchronously reserve work")
        try await F.wait("Switch command did not reach held post-checkout status"){readReply != nil && model.commandFinished}
        try F.require(model.commandSucceeded && model.busy && model.hasPendingWork && model.postActions.isEmpty && finished==0,"Switch exposed workflow completion before status drain")
        let preamble=repo.executable.path+" --literal-pathspecs -C '"+repo.root.path+"' -c core.precomposeunicode=false switch --no-guess -- older\n"
        try F.require(model.output.hasPrefix(preamble),"Switch did not show exact actually executed command first: \(model.output.debugDescription)")
        try await F.output(owner.window,text:model.output,range:model.completionRange,percentage:model.percentage,success:true,preferences:prefs,clipboard:clipboard)
        try F.require(!(model.output as NSString).substring(with:model.completionRange!).contains(" ms @ "),"Switch ignored captured hidden timings")
        try F.require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped held Switch status")
        model.perform(.commit);model.close();try F.require(closed==0,"Switch handed off while post-checkout status still owned")
        owner.close();try F.require(readToken?.isCancelled==true && model.hasPendingWork && closed==0,"Switch forced close dropped held read ownership")
        readReply?.resume(returning:[]);readReply=nil
        try await F.wait("Switch retired read did not release sheet"){!model.hasPendingWork && closed==1 && parent.attachedSheet==nil && SwitchWindowController.activeChildReleases==0}
        try F.require(finished==0 && !model.active,"Retired Switch status published completion")
        _ = try await repo.run(["switch","main"]);try Data("working conflict\n".utf8).write(to:repo.root.appendingPathComponent("file"))
        let retry=SwitchProgressWindowModel(repository:repo,access:nil,reference:"refs/heads/older",preferences:prefs)
        retry.outputClipboard=clipboard
        let retryParent=F.parent(),retryOwner=SwitchProgressWindowController(model:retry)
        F.attach(retryOwner.window,to:retryParent);defer{retryOwner.close();retryParent.close()}
        await retry.run();try F.require(!retry.success && retry.commandFinished && !retry.commandSucceeded && retry.postActions==[.stash,.retry,.switchWithMerge],"Dirty checkout failure lost Retry choices")
        try await F.output(retryOwner.window,text:retry.output,range:retry.completionRange,percentage:retry.percentage,success:false,preferences:prefs,clipboard:clipboard)
        try F.require(retry.output.hasPrefix(preamble),"Failed Switch omitted actual command preamble")
        _ = try await repo.run(["reset","--hard","HEAD"]);retry.perform(.retry)
        try F.require(retry.hasPendingWork && !retry.commandFinished && retry.completionRange==nil && retry.percentage==nil && retry.output.isEmpty,"Switch Retry did not synchronously clear prior receipt")
        try await F.wait("Switch retry did not succeed"){!retry.busy && !retry.hasPendingWork && retry.success}
        try F.require(retry.output.hasPrefix(preamble) && !retry.output.contains("Your local changes"),"Switch Retry retained previous command diagnostics")
        try await verifyCancellation(repo:repo,preferences:prefs,clipboard:clipboard)
        try await verifyResolveRoute(preferences:prefs)
        print("Switch command preamble/styled receipt before held metadata, private Copy/timing, real failure/retry, native cancellation and actual source Resolve-to-Commit route passed.")
    }
}

extension SwitchProgressFamilyVerification {
    @MainActor static func verifyCancellation(repo:GitRepository,preferences:UserDefaults,clipboard:NSPasteboard)async throws{
        typealias F=SwitchResetProgressFixture
        _ = try await repo.run(["switch","main"])
        let (slow,marker,release)=try F.wrapper(repo,command:"switch"),model=SwitchProgressWindowModel(repository:slow,access:nil,reference:"refs/heads/older",preferences:preferences)
        model.outputClipboard=clipboard
        let parent=F.parent(),owner=SwitchProgressWindowController(model:model)
        F.attach(owner.window,to:parent);defer{owner.close();parent.close()}
        var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?,closed=0,handoffs=0
        owner.onClosed={closed+=1};owner.presentCancellation={question,window,reply in alert=question;answer=reply;question.beginSheetModal(for:window,completionHandler:reply)}
        model.onPostAction={action,_ in precondition(action == .commit && parent.attachedSheet==nil && !model.hasPendingWork);handoffs+=1}
        model.start();try await F.wait("Held Switch progress did not arrive"){FileManager.default.fileExists(atPath:marker.path) && model.percentage==50}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try F.require(pids.count==2 && pids.allSatisfy{kill($0,0)==0},"Held Switch helper ownership missing")
        model.cancel();try await F.wait("Native Switch kill question missing"){alert?.window.sheetParent===owner.window}
        try F.require(alert?.window.alphaValue==0 && alert?.window.appearance?.name==parent.appearance?.name && model.confirmingCancellation,"Switch kill question lost captured appearance/state")
        answer?(.alertSecondButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Switch No did not detach actual question"){!model.confirmingCancellation && owner.window?.attachedSheet==nil}
        try F.require(!model.cancelling && pids.allSatisfy{kill($0,0)==0},"Late duplicate Yes killed rejected Switch worker")
        model.cancel();try await F.wait("Switch Yes question missing"){alert?.window.sheetParent===owner.window};answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Cancelled Switch worker did not drain"){!model.busy && !model.hasPendingWork && model.cancelled && pids.allSatisfy{kill($0,0) != 0}}
        try await F.output(owner.window,text:model.output,range:model.completionRange,percentage:model.percentage,success:false,preferences:preferences,clipboard:clipboard)
        try F.require(owner.window?.attachedSheet==nil,"Cancelled Switch completed before question detach")
        try Data().write(to:release);model.perform(.retry)
        try F.require(model.hasPendingWork && !model.commandFinished && model.completionRange==nil,"Cancelled Switch Retry was not freshly admitted")
        try await F.wait("Cancelled Switch retry did not succeed"){!model.busy && !model.hasPendingWork && model.success}
        model.perform(.commit);model.perform(.commit)
        try await F.wait("Switch actual-close handoff did not release"){closed==1 && handoffs==1 && parent.attachedSheet==nil && SwitchWindowController.activeChildReleases==0}
    }
    @MainActor static func verifyResolveRoute(preferences:UserDefaults)async throws{
        typealias F=SwitchResetProgressFixture
        let (repo,_,_)=try await F.repository("switch-root-resolve")
        try Data("local switch merge\n".utf8).write(to:repo.root.appendingPathComponent("file"))
        let grant=RepositoryAccessLease(url:repo.root),workspace=RepositoryModel(startMonitoring:false,initializePreferences:false),owner=SwitchWindowController(repository:repo,access:grant,revision:"refs/heads/older",preferences:preferences)
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua)
        defer{owner.close();workspace.stopMonitoringForTermination()}
        workspace.configureSwitchInteractions(owner,repository:repo,access:grant);owner.model.load(revision:"refs/heads/older")
        try await F.wait("Root Switch options did not load"){!owner.model.busy};owner.model.options.merge=true;owner.model.checkout()
        try await F.wait("Root Switch merge result did not drain"){owner.progressController?.model.busy==false && owner.progressController?.model.hasPendingWork==false}
        let progress=owner.progressController!
        try F.require(progress.model.commandSucceeded && !progress.model.success && progress.model.postActions.contains(.resolve),"Real switch --merge did not preserve successful command receipt with conflicted workflow")
        let before=Set(NSApp.windows.map{ObjectIdentifier($0)})
        progress.model.perform(.resolve);progress.model.perform(.resolve)
        var commit:CommitWindowController?
        try await F.wait("Source Switch Resolve did not open actual Commit"){commit=NSApp.windows.filter{!before.contains(ObjectIdentifier($0))}.compactMap{$0.delegate as? CommitWindowController}.first;return commit != nil && owner.window?.attachedSheet==nil && progress.window?.sheetParent==nil}
        defer{commit?.close()}
        try F.require(commit!.model.access===grant && commit!.presentationPreferences===preferences && commit!.model.colorPreferences===preferences && commit!.window?.alphaValue==0 && commit!.window?.appearance?.name==NSAppearance.Name.darkAqua,"Switch Resolve-to-Commit lost captured grant/preferences/appearance")
        try await F.wait("Switch Resolve Commit read did not drain"){!commit!.model.busy};commit?.close()
    }
}
