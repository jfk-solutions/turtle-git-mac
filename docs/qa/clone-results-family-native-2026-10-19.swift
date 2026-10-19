import AppKit
import TurtleGitCore

@MainActor enum CreationResultsFixture {
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

struct CloneResultsFamilyVerification {
    @MainActor static func verify()async throws {
        typealias F=CreationResultsFixture
        let suite="TurtleGit.CloneResults."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ShowGitexeTimings");prefs.set(true,forKey:"StyleGitOutput");prefs.set(true,forKey:"ConfirmKillProcess")
        defer{prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let(repo,_,_)=try await F.repository("clone source space"),base=URL(fileURLWithPath:CommandLine.arguments[1]),grant=RepositoryAccessLease(url:base)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:repo.root.appendingPathComponent("file"))
        try await verifyPanels(root:base,git:repo.executable,preferences:prefs)
        let owner=CloneWindowController(directory:base,access:grant,preferences:prefs,executable:repo.executable)
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);defer{owner.close()}
        owner.model.source=repo.root.path;owner.model.directory=base.appendingPathComponent("held inspect clone").path
        let binding=owner.model.field(\.directory,context:owner.model.formContext),destination=owner.model.directory
        var progress:CloneProgressWindowController?,pending:CheckedContinuation<GitRepository,Never>?,candidate:GitRepository?,token:OperationCancellation?,closed=0,adoptions=0
        defer{if let candidate{pending?.resume(returning:candidate)};pending=nil}
        let present=owner.model.onProgress
        owner.model.onProgress={model in
            model.outputClipboard=clipboard
            model.inspectRepository={repo,_,request in candidate=repo;token=request;return await withCheckedContinuation{pending=$0}}
            present?(model);progress=owner.progressController
        }
        owner.onClosed={closed+=1};owner.model.onCloned={_,_,_,_,_ in adoptions+=1}
        owner.model.clone();try F.require(owner.model.hasPendingWork,"Clone submission did not synchronously reserve preflight")
        binding.wrappedValue=base.appendingPathComponent("stale destination").path
        try F.require(owner.model.directory==destination,"Old options binding changed accepted Clone destination")
        try await F.wait("Clone did not reach actual held inspection"){pending != nil && progress?.model.commandFinished==true}
        let model=progress!.model
        try F.require(model.commandSucceeded && model.commandCompleted && !model.success && model.busy && model.hasPendingWork && adoptions==0,"Clone receipt exposed completed workflow before actual discovery")
        try await F.output(progress!.window,text:model.output,range:model.completionRange,percentage:model.percentage,success:true,preferences:prefs,clipboard:clipboard)
        try F.require(model.output.contains(" clone ") && model.output.contains(repo.root.path) && !(model.output as NSString).substring(with:model.completionRange!).contains(" ms @ "),"Clone preamble/private timing preference missing")
        try F.require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped held Clone inspection")
        model.perform(.log);try F.require(adoptions==0,"Clone handed off while inspection owned")
        owner.close();try F.require(closed==0 && model.hasPendingWork && token?.isCancelled==true,"Options forced close released actual Clone inspection early")
        pending?.resume(returning:candidate!);pending=nil
        try await F.wait("Retired Clone options/progress did not drain/detach"){closed==1 && !model.hasPendingWork && progress?.presentationClosed==true && owner.window?.attachedSheet==nil && CloneWindowController.activeChildReleases==0}
        try F.require(adoptions==0 && !model.success && !model.active,"Retired discovery adopted a clone")
        try await verifyCancellation(repo:repo,base:base,grant:grant,preferences:prefs,clipboard:clipboard)
        try await verifyRootLog(repo:repo,base:base,grant:grant,preferences:prefs,clipboard:clipboard)
        let after=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),afterWorking=try Data(contentsOf:repo.root.appendingPathComponent("file"))
        try F.require(after==head && afterIndex==index && afterWorking==working,"Clone workflows changed source HEAD/index/working bytes")
        print("Clone native panel/context snapshots, exact styled command receipt/private Copy before held discovery, synchronous/forced-close/Quit lifetime, actual No/Yes cancellation and Root Log after options detach passed.")
    }
    @MainActor static func verifyPanels(root:URL,git:URL,preferences:UserDefaults)async throws {
        typealias F=CreationResultsFixture
        let owner=CloneWindowController(directory:root,access:RepositoryAccessLease(url:root),preferences:preferences,executable:git)
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);defer{owner.close()}
        var panel:NSOpenPanel?,answer:((NSApplication.ModalResponse)->Void)?,closed=0
        owner.onClosed={closed+=1};owner.model.presentOpenPanel={value,window,reply in panel=value;answer=reply;window.beginSheet(value,completionHandler:reply)};owner.model.selectedPanelURL={_ in root}
        let stale=owner.model.field(\.source,context:owner.model.formContext)
        owner.model.browseSource();try F.require(owner.model.hasPendingWork,"Clone browser did not synchronously reserve ownership")
        try await F.wait("Clone source panel not actually attached"){panel?.sheetParent===owner.window}
        try F.require(panel?.alphaValue==0 && panel?.appearance?.name==owner.window?.appearance?.name && !owner.windowShouldClose(owner.window!),"Clone chooser lost appearance/close ownership")
        stale.wrappedValue="late source";answer?(.OK);answer?(.cancel)
        try await F.wait("Clone source panel did not detach before applying"){owner.model.openPanel==nil && !owner.model.hasPendingWork && owner.window?.attachedSheet==nil}
        try F.require(owner.model.source==root.path,"Accepted source browse changed before native detach or stale field won")
        let oldDirectory=owner.model.directory
        owner.model.browseDirectory();try await F.wait("Clone destination panel missing"){owner.model.openPanel != nil && panel?.sheetParent===owner.window}
        owner.model.confirmingQuit=true;owner.model.confirmingQuit=false;answer?(.OK)
        try await F.wait("Clone stale Quit panel did not drain"){!owner.model.hasPendingWork && owner.window?.attachedSheet==nil}
        try F.require(owner.model.directory==oldDirectory,"Pre-Quit panel answer changed destination after Quit roundtrip")
        owner.model.browseSource();try await F.wait("Clone retire panel missing"){owner.model.openPanel != nil && panel?.sheetParent===owner.window}
        let oldSource=owner.model.source;owner.close();answer?(.OK);answer?(.OK)
        try await F.wait("Retired Clone chooser did not release exactly once"){closed==1 && owner.model.openPanel==nil && !owner.model.hasPendingWork && owner.window?.attachedSheet==nil}
        try F.require(owner.model.source==oldSource,"Retired picker published late source")
    }
    @MainActor static func verifyCancellation(repo:GitRepository,base:URL,grant:RepositoryAccessLease,preferences:UserDefaults,clipboard:NSPasteboard)async throws {
        typealias F=CreationResultsFixture
        let(slow,marker,_)=try F.wrapper(repo,command:"clone")
        var options=CloneOptions();options.source=repo.root.path
        let model=CloneProgressWindowModel(options:options,destination:base.appendingPathComponent("cancel clone"),executable:slow.executable,destinationAccess:grant,sourceAccess:grant,keyAccess:nil,preferences:preferences)
        model.outputClipboard=clipboard
        let parent=F.parent(),owner=CloneProgressWindowController(model:model)
        F.attach(owner.window,to:parent);defer{owner.close();parent.close()}
        var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?,closed=0,handoffs=0
        owner.onClosed={closed+=1};model.onPostAction={_,_ in handoffs+=1};owner.presentCancellation={value,window,reply in alert=value;answer=reply;value.beginSheetModal(for:window,completionHandler:reply)}
        model.start();try F.require(model.hasPendingWork,"Clone start did not synchronously reserve command")
        try await F.wait("Held Clone worker/progress missing"){FileManager.default.fileExists(atPath:marker.path) && model.percentage==50}
        let pids=try String(contentsOf:marker,encoding:.utf8).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try F.require(pids.count==2 && pids.allSatisfy{kill($0,0)==0},"Clone helper ownership missing")
        model.cancel();try await F.wait("Clone actual kill question missing"){alert?.window.sheetParent===owner.window}
        try F.require(alert?.window.alphaValue==0 && alert?.window.appearance?.name==parent.appearance?.name,"Clone question lost captured presentation")
        answer?(.alertSecondButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Clone No did not actually detach"){!model.confirmingCancellation && owner.window?.attachedSheet==nil}
        try F.require(!model.cancelling && pids.allSatisfy{kill($0,0)==0},"Late duplicate Yes killed rejected Clone worker")
        model.cancel();try await F.wait("Clone second question missing"){alert?.window.sheetParent===owner.window};answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn)
        try await F.wait("Clone cancellation did not drain worker"){!model.hasPendingWork && !model.busy && model.cancelled && pids.allSatisfy{kill($0,0) != 0}}
        try await F.output(owner.window,text:model.output,range:model.completionRange,percentage:model.percentage,success:false,preferences:preferences,clipboard:clipboard)
        try F.require(!model.commandSucceeded && model.postActions==[.retry] && owner.window?.attachedSheet==nil && handoffs==0,"Cancelled Clone exposed success/handoff before question detach")
        model.close();model.close();try await F.wait("Cancelled Clone did not close once"){closed==1 && parent.attachedSheet==nil}
    }
    @MainActor static func verifyRootLog(repo:GitRepository,base:URL,grant:RepositoryAccessLease,preferences:UserDefaults,clipboard:NSPasteboard)async throws {
        typealias F=CreationResultsFixture
        let store=try RepositoryAccessStore(storageURL:base.appendingPathComponent("clone-private-access.json")),workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotWriter:{_ in false},savedAccessStore:store)
        let owner=CloneWindowController(directory:base,access:grant,preferences:preferences,executable:repo.executable)
        owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua)
        defer{owner.close();workspace.closeRepository();workspace.stopMonitoringForTermination()}
        workspace.configureCloneInteractions(owner)
        owner.model.source=repo.root.path;owner.model.directory=base.appendingPathComponent("root log clone").path
        let present=owner.model.onProgress
        owner.model.onProgress={model in model.outputClipboard=clipboard;present?(model)}
        owner.model.clone();try await F.wait("Root Clone result did not finish"){owner.progressController?.model.success==true && owner.progressController?.model.hasPendingWork==false}
        let progress=owner.progressController!,before=Set(NSApp.windows.map{ObjectIdentifier($0)})
        progress.model.perform(.log);progress.model.perform(.log)
        var log:LogWindowController?
        try await F.wait("Clone Log did not wait for options/progress actual detach"){log=NSApp.windows.filter{!before.contains(ObjectIdentifier($0))}.compactMap{$0.delegate as? LogWindowController}.first;return log != nil && owner.progressController==nil && owner.window?.attachedSheet==nil && progress.window?.sheetParent==nil}
        defer{log?.close()}
        try F.require(log!.model.colorPreferences===preferences && log!.model.repositoryAccess===grant && log!.window?.alphaValue==0 && log!.window?.appearance?.name==NSAppearance.Name.darkAqua,"Clone Root Log lost captured scope/preferences/presentation")
        try await F.wait("Clone Root Log reads did not drain"){!log!.model.busy}
        try F.require(NSApp.windows.filter{!before.contains(ObjectIdentifier($0)) && $0.delegate is LogWindowController}.count==1,"Clone duplicate postaction opened multiple Logs")
    }
}
