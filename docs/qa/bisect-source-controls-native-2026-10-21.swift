// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import ScreenCaptureKit
import TurtleGitCore

private extension NSWindow {
    @objc func turtleBisectOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-18000,y:-18000));turtleBisectOrder(place,relativeTo:number)
    }
}
@MainActor enum BisectSourceVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws{if !condition{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ predicate:()->Bool)async throws{for _ in 0..<3000{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Bisect source timeout at \(line)")}
    static func views(_ root:NSView?)->[NSView]{guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func capture(_ window:NSWindow?,_ name:String)async throws{
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_BISECT_SOURCE_CAPTURES"],let window else{return}
        guard #available(macOS 14.4,*)else{throw Failure(description:"Owned compositor capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance;defer{window.alphaValue=alpha;window.appearance=appearance}
        window.orderFront(nil);window.alphaValue=1
        for(theme,suffix)in[(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
            let content=try await SCShareableContent.currentProcess,owned=try unwrap(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned capture window missing")
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            let bytes=try unwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]),"Capture encoding failed")
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.BisectSource."+UUID().uuidString,prefs:UserDefaults
        var owners:[BisectWindowController]=[],pickers:[LogWindowController]=[],release:[()->Void]=[]
        var repository:GitRepository {GitRepository(root:root,executable:git)}
        var hashes:[String]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(false,forKey:"DownloadAnimation")}
        func seed()async throws {
            let repo=repository;_=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Bisect source QA"),("user.email","bisect@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for n in 0..<12 {
                try Data("\(n)\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"step \(n)")
                hashes.append(try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines))
            }
            for name in ["zeta","Alpha","alpha2","alpha10"]{_=try await repo.run(["branch",name,hashes[1]])}
            for name in ["z-tag","A-tag"]{_=try await repo.run(["tag",name,hashes[2]])}
        }
        func owner(_ repo:GitRepository?=nil)->BisectWindowController {
            let owner=BisectWindowController(repository:repo ?? repository,access:RepositoryAccessLease(url:root),good:hashes.first,bad:hashes.last,preferences:prefs)
            owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.window?.orderFront(nil);return owner
        }
        func cleanup()async {
            release.forEach{$0()};release=[];pickers.forEach{$0.close()};owners.forEach{$0.close()}
            for window in NSApp.windows{window.orderOut(nil);window.close()}
            for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
        func drained()->Bool {BisectWindowModel.activeOperations==0 && BisectWindowController.activeChildReleases==0 && owners.allSatisfy{!$0.hasPendingWork} && pickers.allSatisfy{$0.model.pendingHistoryLoads==0}}
    }
    static func heldRepository(_ c:Context,_ name:String,_ words:[String])throws->(GitRepository,URL) {
        let wrapper=c.root.appendingPathComponent(name+"-git"),marker=c.root.appendingPathComponent(name+"-pids")
        func q(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let pattern=words.joined(separator:" ")
        let script="""
        #!/bin/sh
        case " $* " in *' \(pattern) '*)
          /bin/sleep 30 &
          turtle_child=$!
          trap 'kill "$turtle_child" 2>/dev/null;wait "$turtle_child" 2>/dev/null;exit 143' TERM INT
          printf '%s %s\\n' "$$" "$turtle_child" > \(q(marker.path))
          wait "$turtle_child"
          ;;
        esac
        exec \(q(c.git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        return(GitRepository(root:c.root,executable:wrapper),marker)
    }
    static func assertReaped(_ marker:URL)throws {
        let pids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)}
        try require(pids.count==2,"Private worker PID receipt malformed")
        for pid in pids{try require(kill(pid,0) == -1 && errno==ESRCH,"Owned Bisect process remains live: \(pid)")}
    }
    static func ownership(_ c:Context)async throws {
        let (loadingRepo,loadingMarker)=try heldRepository(c,"loading",["--is-bare-repository"]),loading=c.owner(loadingRepo)
        var closed=false;loading.onClosed={closed=true}
        try await wait{FileManager.default.fileExists(atPath:loadingMarker.path)}
        try require(loading.hasPendingWork && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Live initial read escaped owner/Quit")
        loading.close();try require(!closed,"Owner released before initial subprocess was reaped")
        try await wait{closed && !loading.hasPendingWork};try assertReaped(loadingMarker)
        try require(loading.model.state==nil && loading.model.error==nil && loading.model.choices.isEmpty,"Late read published into retired Bisect form")
        let (held,marker)=try heldRepository(c,"classification",["bisect","good"]),owner=c.owner(held),model=owner.model
        try await wait{model.canStart};model.start();try await wait{FileManager.default.fileExists(atPath:marker.path)}
        try require(model.busy && owner.hasPendingWork,"Actual Start classification not owned")
        model.cancel();try await wait{!model.hasPendingWork};try assertReaped(marker)
        func cancellationDiagnostic()->String {"active=\(String(describing:model.state?.active)) head=\(model.state?.head ?? "nil") error=\(model.error ?? "nil") exit=\(String(describing:model.lastExitCode)) pending=\(model.hasPendingWork) busy=\(model.busy) retired=\(model.retired) quit=\(model.confirmingQuit) picker=\(model.hasPicker) confirmingCancellation=\(model.confirmingCancellation) sheet=\(String(describing:owner.window?.attachedSheet)) output=\(model.output)"}
        try require(model.state?.active==true,"Cancellation lost actual recoverable session: "+cancellationDiagnostic())
        let recovered=try await c.repository.bisectState();try require(recovered.active,"Actual Git session was not retained after cancellation: "+cancellationDiagnostic())
        if model.error != nil {
            do{try await wait{owner.window?.attachedSheet != nil || model.error==nil}}catch{throw Failure(description:"Cancellation acknowledgment did not mount: "+cancellationDiagnostic())}
            if let sheet=owner.window?.attachedSheet {
                let okay=try unwrap(views(sheet.contentView).compactMap{$0 as? NSButton}.first{$0.title=="OK"},"Cancellation native acknowledgment button missing: "+cancellationDiagnostic())
                okay.performClick(nil)
            }
            do{try await wait{owner.window?.attachedSheet==nil && model.error==nil}}catch{throw Failure(description:"Cancellation acknowledgment did not detach: "+cancellationDiagnostic())}
        }
        try require(model.canPerform(.reset),"Acknowledged cancellation did not enable actual Reset: "+cancellationDiagnostic())
        model.perform(.reset);try await wait{!model.hasPendingWork};try require(model.state?.active==false && model.state?.head==c.hashes.last,"Real reset did not restore original branch")
        // A real dirty-tree Start opens an owned decision; force-close and a
        // retained affirmative callback must not create a stash/session.
        try Data("private dirty bytes\n".utf8).write(to:c.root.appendingPathComponent("file"))
        let dirty=c.owner();try await wait{dirty.model.canStart}
        var answer:((NSApplication.ModalResponse)->Void)?,question:NSWindow?
        dirty.presentQuestion={_,alert,_,reply in question=alert.window;answer=reply}
        dirty.model.start();try await wait{answer != nil}
        try require(question?.alphaValue==0 && dirty.hasPendingWork,"Owned Stash decision became visible or unowned")
        dirty.close();answer?(.alertSecondButtonReturn);answer=nil;try await wait{!dirty.hasPendingWork}
        let state=try await c.repository.bisectState(),stash=try await c.repository.run(["stash","list"]).text
        try require(!state.active && stash.isEmpty && (try Data(contentsOf:c.root.appendingPathComponent("file")))==Data("private dirty bytes\n".utf8),"Late closed Stash response mutated repository")
        try await routingRetirement(c)
    }
    static func requireHidden(_ owner:NSWindowController,_ name:String)throws {
        let window=try unwrap(owner.window,name+" missing native window"),screens=NSScreen.screens.map(\.frame)
        let offscreen = !screens.contains{$0.intersects(window.frame)}
        try require(!window.isVisible || window.alphaValue==0 || offscreen,name+" escaped private presentation: alpha=\(window.alphaValue) visible=\(window.isVisible) frame=\(window.frame) screens=\(screens)")
    }
    static func routingRetirement(_ c:Context)async throws {
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:c.git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:c.root.appendingPathComponent("private-marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=c.prefs;workspace.notifyFinder={};workspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:c.root)}
        workspace.bisectWindowPresentation={owner in owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.window?.orderFront(nil)}
        defer{workspace.stopMonitoringForTermination()}
        let existing=Set(c.owners.map(ObjectIdentifier.init))
        func routed()->[BisectWindowController]{NSApp.windows.compactMap{$0.delegate as? BisectWindowController}.filter{!existing.contains(ObjectIdentifier($0))}}
        func invoke(){workspace.handleCommandLine(arguments:["--command=bisect","--start","--good",c.hashes[0],"--bad",c.hashes.last!],currentDirectory:c.root.path)}
        invoke();try await wait{!workspace.busy && routed().contains{$0.model.canStart}}
        let owner=try unwrap(routed().first{$0.model.canStart},"Routed Bisect form missing");c.owners.append(owner)
        try requireHidden(owner,"Routed Bisect")
        var pending:CheckedContinuation<Bool,Never>?,closed=false
        owner.model.confirmStash={await withCheckedContinuation{pending=$0}};owner.model.cancelPrompt={}
        c.release.append{pending?.resume(returning:false);pending=nil}
        let previous=owner.onClosed;owner.onClosed={previous();closed=true}
        owner.model.start();try await wait{pending != nil};owner.close()
        try require(!owner.canReuse && owner.hasPendingWork && !closed,"Cached Bisect owner did not retain held real Start review")
        let head=try await c.repository.run(["rev-parse","HEAD"]).stdout
        workspace.error=nil;invoke();try await wait{!workspace.busy && workspace.error != nil}
        try require(workspace.error=="Wait for the current bisect operation to finish." && !owner.canReuse && owner.window?.isVisible==false && routed().allSatisfy{$0 === owner},"Retired cached Bisect was reopened or replacement dispatched before drain")
        try require(try await c.repository.run(["rev-parse","HEAD"]).stdout==head,"Retired-cache request changed Git HEAD")
        pending?.resume(returning:false);pending=nil;try await wait{closed && !owner.hasPendingWork}
        try Data("11\n".utf8).write(to:c.root.appendingPathComponent("file"));workspace.error=nil;invoke()
        try await wait{!workspace.busy && routed().contains{$0 !== owner && $0.model.canStart}}
        let replacement=try unwrap(routed().first{$0 !== owner && $0.model.canStart},"Fresh Bisect owner not created after drain");c.owners.append(replacement)
        try require(replacement.canReuse && replacement.model.preferences === c.prefs && owner.model.retired,"Fresh cache owner lost private preferences or revived retired model")
        try requireHidden(replacement,"Fresh routed Bisect")
    }
    static func picker(_ c:Context)async throws {
        let owner=c.owner(),model=owner.model;try await wait{model.canStart}
        var child:LogWindowController?,answer:((LogEntry?)->Void)?
        let factory=owner.makePicker
        owner.makePicker={repo,access,revision,prefs,choose in
            answer=choose;let result=factory(repo,access,revision,prefs,choose);child=result;c.pickers.append(result);return result
        }
        owner.chooseRevision(good:true);try await wait{child != nil && child?.model.pendingHistoryLoads==0 && child?.model.revisions.isEmpty==false}
        let goodPicker=try unwrap(child,"Good picker absent")
        try require(goodPicker.model.colorPreferences === c.prefs && goodPicker.model.endRevision==c.hashes[0] && goodPicker.model.selected==[c.hashes[0]],"Default Good picker lost captured preferences or exact end/selected revision")
        let selected=try unwrap(goodPicker.model.revisions.first,"Actual Good history missing");goodPicker.model.finishSelection(selected)
        try await wait{!model.hasPicker && !owner.hasPendingWork && owner.window?.attachedSheet==nil}
        try require(model.good==selected.hash,"Actual accepted Log selection did not reach captured good field")
        child=nil;owner.chooseRevision(good:false);try await wait{child != nil && child?.model.pendingHistoryLoads==0 && child?.model.revisions.isEmpty==false}
        let badPicker=try unwrap(child,"Bad picker absent"),before=model.bad,retained=try unwrap(answer,"Bad picker callback absent")
        try require(badPicker.model.endRevision==before && badPicker.model.selected==[before] && badPicker.model.colorPreferences === c.prefs,"Bad picker was not scoped to captured endpoint/preferences")
        let stale=try unwrap(badPicker.model.revisions.first,"Actual Bad history missing")
        model.confirmingQuit=true;model.confirmingQuit=false;badPicker.close();try await wait{!model.hasPicker && owner.window?.attachedSheet==nil}
        retained(stale);try require(model.bad==before,"Late Log selection revived across Quit/child retirement")
        // A picker actual query is held by an owned subprocess, then closed with
        // its parent: owner release must wait for real Log work, not just flags.
        let (held,marker)=try heldRepository(c,"picker",["log"])
        let closing=c.owner();try await wait{closing.model.canStart};var loading:LogWindowController?,closed=false
        closing.makePicker={_,access,revision,prefs,choose in
            let result=LogWindowController(repository:held,access:access,onChoose:choose,labelDefaults:prefs,initialRevision:revision);loading=result;c.pickers.append(result);return result
        }
        closing.onClosed={closed=true};closing.chooseRevision(good:false)
        try await wait{FileManager.default.fileExists(atPath:marker.path)}
        try require((loading?.model.pendingHistoryLoads ?? 0) > 0 && closing.hasPendingWork,"Held actual picker query not owned")
        closing.close();try require(!closed,"Bisect owner released before picker query drained")
        try await wait{closed && !closing.hasPendingWork && loading?.model.pendingHistoryLoads==0};try assertReaped(marker)
    }
    static func controls(_ c:Context)async throws {
        let owner=c.owner(),model=owner.model;try await wait{model.canStart}
        try await wait{views(owner.window?.contentView).compactMap{$0 as? NSComboBox}.count==2}
        let combos=views(owner.window?.contentView).compactMap{$0 as? NSComboBox}
        for combo in combos {
            try require(combo.completes && combo.isEnabled && combo.usesSingleLineMode,"Bisect native revision input missing editable completion/single-line behavior")
            let choices=combo.objectValues.compactMap{$0 as? String}
            try require(choices==model.choices && choices.contains("A-tag") && choices.contains("z-tag") && choices.contains("Alpha") && choices.contains("zeta"),"Native revision list lost branch/tag choices")
            try require((choices.firstIndex(of:"Alpha") ?? 999)<(choices.firstIndex(of:"zeta") ?? -1) && (choices.firstIndex(of:"A-tag") ?? 999)<(choices.firstIndex(of:"z-tag") ?? -1),"Combined branch/tag native choices not source sorted")
        }
        let native=try unwrap(owner.window as? ReferenceFormNativeWindow,"Bisect native command window missing"),router=try unwrap((owner.window as? ReferenceFormNativeWindow)?.formCommands,"Bisect form key router missing"),menu=NSMenu()
        router.keyWindow={ [weak native] in native};router.applicationMenu={menu};router.install()
        try await wait{router.menu?.items.first{$0.identifier?.rawValue=="TurtleGit.ReferenceForm.bisectGood"}?.isEnabled==true}
        let focus=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command,.option],timestamp:0,windowNumber:native.windowNumber,context:nil,characters:"g",charactersIgnoringModifiers:"g",isARepeat:false,keyCode:5),"Bisect focus event missing")
        try require(native.performKeyEquivalent(with:focus),"Actual Bisect focus command not handled")
        try await wait{combos.first{$0.accessibilityLabel()=="Last known good"}?.currentEditor() === native.firstResponder}
        let good=try unwrap(combos.first{$0.accessibilityLabel()=="Last known good"},"Good combo missing"),old=model.good
        model.good=String(repeating:"long-revision-",count:18);try await wait{good.toolTip==model.good};native.contentView?.layoutSubtreeIfNeeded()
        if let content=native.contentView{try require(content.bounds.insetBy(dx:-1,dy:-1).contains(good.convert(good.bounds,to:content)),"Long revision escaped form width")}
        model.good=old;try await wait{good.stringValue==old};try await capture(owner.window,"bisect-source-options")
        let oldBinding=model.revision(\.good,context:model.formContext),context=model.formContext
        model.confirmingQuit=true;model.confirmingQuit=false;oldBinding.wrappedValue="late";model.start(context:context)
        try require(model.good==old && !model.busy,"Old revision/start context revived after Quit")
        model.start();try await wait{!model.hasPendingWork && model.state?.active==true}
        try require(model.lastExitCode==0,"Actual Bisect Start failed: "+model.output)
        func control()async throws->BisectNativeCompletionControl {
            try await wait{views(owner.window?.contentView).compactMap{$0 as? BisectNativeCompletionControl}.contains{$0.isEnabled}}
            return try unwrap(views(owner.window?.contentView).compactMap{$0 as? BisectNativeCompletionControl}.first{$0.isEnabled},"Native post-action split missing")
        }
        func actionMenu()async throws->NSMenu {
            let control=try await control(),menu=try unwrap(control.menu(forSegment:1),"Bisect split menu missing")
            menu.delegate?.menuWillOpen?(menu);try require(menu.items.allSatisfy{$0.isEnabled && $0.image != nil},"Source Bisect menu icons/enabled state missing");return menu
        }
        let first=try await actionMenu();try require(first.items.map(\.title)==["Bisect good","Bisect bad","Bisect skip","Bisect reset"],"Bisect post action source order differs")
        let snapshot=try await c.repository.bisectState();model.confirmingQuit=true;model.confirmingQuit=false;first.performActionForItem(at:2);await Task.yield()
        let unchanged=try await c.repository.bisectState();try require(unchanged.log==snapshot.log && !model.busy,"Retained native menu mutated after Quit")
        let skip=try await actionMenu(),beforeSkip=model.formContext;skip.performActionForItem(at:2);try await wait{model.formContext != beforeSkip && !model.hasPendingWork};try require(model.lastExitCode==0 && model.state?.log.contains("git bisect skip ")==true,"Native Skip did not execute actual Git")
        let main=try await control();try require(main.label(forSegment:0)=="Bisect good","Native post-operation default did not match source first action")
        let space=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:native.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49),"Native split Space missing")
        let beforeGood=model.formContext,goodLog=model.state?.log;main.keyDown(with:space);try await wait{model.formContext != beforeGood && !model.hasPendingWork};try require(model.state?.log != goodLog && model.state?.log.contains("git bisect good ")==true && model.lastExitCode==0,"Native primary keyboard action failed")
        let bad=try await actionMenu(),beforeBad=model.formContext,badLog=model.state?.log;bad.performActionForItem(at:1);try await wait{model.formContext != beforeBad && !model.hasPendingWork};try require(model.lastExitCode==0 && model.state?.log != badLog && model.state?.log.contains("git bisect bad ")==true,"Native Bad failed")
        try await capture(owner.window,"bisect-source-completion")
        let reset=try await actionMenu(),beforeReset=model.formContext;reset.performActionForItem(at:3);try await wait{model.formContext != beforeReset && !model.hasPendingWork}
        try require(model.lastExitCode==0 && model.state?.active==false && model.state?.head==c.hashes.last,"Native Reset lost original branch")
        // The actual source default switches to Submodule Update after a
        // successful operation when real repository metadata offers it.
        try Data().write(to:c.root.appendingPathComponent(".gitmodules"))
        let submodule=c.owner();try await wait{submodule.model.canStart};submodule.model.start();try await wait{!submodule.model.hasPendingWork && submodule.model.lastExitCode==0}
        var events:[String]=[];submodule.onClosed={events.append("closed")};submodule.model.onSubmoduleUpdate={events.append("update")}
        try await wait{submodule.model.canUpdateSubmodules}
        submodule.model.updateSubmodules(context:submodule.model.formContext);try await wait{events.count==2 && !submodule.hasPendingWork}
        try require(events==["closed","update"] && submodule.model.retired && submodule.window?.sheetParent==nil,"Submodule continuation did not defer until owner drain/detachment")
        _=try await c.repository.bisect(.reset)
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleBisectOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let context=Context(),which=CommandLine.arguments[3]
        do {
            try await context.seed()
            switch which{case "controls":try await controls(context);case "picker":try await picker(context);default:try await ownership(context)}
            await context.cleanup();try require(context.drained(),"Bisect owned work/native children did not drain");print("PASS: Bisect source "+which)
        }catch{await context.cleanup();fputs("Bisect source failed: \(error)\n",stderr);exit(1)}
    }
}
@main struct BisectSourceMain{static func main()async{await BisectSourceVerification.main()}}
