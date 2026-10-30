// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct SourceFormControlsVerification {
    struct Failure:Error,LocalizedError,CustomStringConvertible {let description:String;var errorDescription:String?{description}}
    @MainActor static var owners:[NSWindowController]=[],releaseFiles:[URL]=[]
    static func require(_ value:Bool,_ message:String)throws {if !value{throw Failure(description:message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    @MainActor static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1600 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Source form timeout at \(line)")
    }
    @MainActor static func own(_ controller:NSWindowController){owners.append(controller);if let w=controller.window{w.alphaValue=0;w.setFrameOrigin(NSPoint(x:-24000,y:-24000));w.orderFront(nil)}}
    @MainActor static func key(_ window:NSWindow,_ text:String,_ code:UInt16,_ flags:NSEvent.ModifierFlags = [.command,.option])throws->NSEvent {
        try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code),"Native key event")
    }
    @MainActor static func capture(_ window:NSWindow,_ name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_SOURCE_FORM_CAPTURES"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned compositor capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance
        defer{window.alphaValue=alpha;window.appearance=appearance}
        window.alphaValue=1;window.orderFront(nil)
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
            let content=try await SCShareableContent.currentProcess
            let owned=try unwrap(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned capture missing")
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            let bytes=try unwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]),"Capture encoding")
            let filename=name+"-"+suffix+".png";try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent(filename))
            print("Owned capture: "+filename+" "+String(image.width)+"x"+String(image.height))
        }
    }
    static func fixture(_ root:URL,_ git:URL)async throws->GitRepository {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (k,v) in [("user.name","Source Form QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",k,v])}
        try Data("source form base\n".utf8).write(to:root.appendingPathComponent("base.txt"));try await repo.stage(["base.txt"]);_ = try await repo.commit(message:"source form base")
        _ = try await repo.run(["branch","topic"]);_ = try await repo.run(["tag","v1"])
        return repo
    }
    @MainActor static func transport(_ repo:GitRepository,_ prefs:UserDefaults)async throws {
        let server=repo.root.deletingLastPathComponent().appendingPathComponent("private transport server.git")
        _ = try await repo.run(["clone","--bare","--template=","--",repo.root.path,server.path])
        _ = try await repo.run(["remote","add","origin",server.path]);_ = try await repo.run(["fetch","origin"])
        _ = try await repo.run(["branch","--set-upstream-to=origin/main","main"])
        let long="feature/"+String(repeating:"long-source-caption-",count:8)+"雪"
        _ = try await repo.run(["branch",long])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["write-tree"]).stdout
        let push=PushWindowController(repository:repo,access:nil,preferences:prefs);own(push)
        push.model.load(source:long)
        try await wait(push.window){push.model.canEditForm && !push.model.preparing}
        let model=push.model,window=try unwrap(push.window as? PushNativeWindow,"Native Push owner missing")
        model.options.destination="refs/heads/private-review-draft";model.options.forceWithLease=true
        let captured=model.formContext,stale=model.option(\.destination,context:captured),source=model.options.source,destination=model.options.destination
        _ = try await repo.run(["remote","add","added-by-private-fixture",server.path])
        // Prohibited receivers cannot become physical key windows. Inject only
        // this owner query; actual event owner, modal/sheet and read guards remain.
        window.keyOwnerQuery={ [weak window] candidate in candidate === window }
        window.makeFirstResponder(nil)
        try require(window.performKeyEquivalent(with:key(window,"",96,[])),"Push F5 did not route to its actual owner")
        try require(model.busy && !model.canRefresh,"Push F5 did not acquire a real refresh")
        stale.wrappedValue="unowned stale value"
        try await wait(window){!model.busy && model.canEditForm}
        try require(model.remotes.contains("added-by-private-fixture"),"Push F5 only repainted cached remote list")
        try require(model.options.source==source && model.options.destination==destination && model.options.forceWithLease,"Push F5 replaced captured operation draft")
        stale.wrappedValue="late stale value";try require(model.options.destination==destination,"Old Push form binding changed refreshed draft")
        try await capture(window,"push-source-controls")
        model.confirmingQuit=true
        let blocked=model.formContext,binding=model.option(\.destination,context:blocked)
        binding.wrappedValue="quit-owned value";model.refreshFromSourceCommand()
        try require(!model.busy && !model.canRefresh && model.options.destination==destination,"Push Quit fence admitted form edit/refresh")
        model.confirmingQuit=false
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:200,height:90),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        window.beginSheet(sheet,completionHandler:nil)
        _ = window.performKeyEquivalent(with:try key(window,"",96,[]))
        try require(!model.busy,"Push F5 refreshed behind an owned sheet")
        window.endSheet(sheet,returnCode:.cancel);sheet.close();try await wait{sheet.sheetParent==nil}
        window.close();try await wait{!push.serviceWorkPending}
        // Four source sticky menus share an owner, yet retain separate choices.
        let prefix="TurtleGit.Sync."+repo.root.path
        prefs.set(2,forKey:prefix+".pullAction");prefs.set(2,forKey:prefix+".pushAction")
        let heldRead=repo.root.deletingLastPathComponent().appendingPathComponent("hold-sync-read"),counter=repo.root.deletingLastPathComponent().appendingPathComponent("sync-read-count"),wrapper=repo.root.deletingLastPathComponent().appendingPathComponent("sync-counting-git")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let wrapperText="""
        #!/bin/sh
        for argument do
          if [ "$argument" = branch.main.remote ]; then
            /usr/bin/printf 'read\\n' >> \(quote(counter.path))
            while [ -f \(quote(heldRead.path)) ]; do /bin/sleep 0.02; done
          fi
        done
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(wrapperText.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        func readCount()->Int {((try? String(contentsOf:counter,encoding:.utf8)) ?? "").split(separator:"\n").count}
        let counted=GitRepository(root:repo.root,executable:wrapper)
        let sync=SynchronizationWindowController(repository:counted,access:nil,preferences:prefs);own(sync)
        let sm=sync.model;sm.sshSettings.enabled=false
        try await wait(sync.window){!sm.busy && sm.outgoing != nil && views(sync.window?.contentView).compactMap{$0 as? SynchronizationNativeActionControl}.count==4}
        let branchCombo=try unwrap(views(sync.window?.contentView).compactMap{$0 as? NSComboBox}.first{$0.accessibilityLabel()=="Remote Branch"},"Actual Sync Remote Branch editor missing")
        try await wait(sync.window){branchCombo.isEnabled && (branchCombo.delegate as? FetchHistoryCombo.Coordinator)?.live==true && (branchCombo.delegate as? FetchHistoryCombo.Coordinator)?.updating==false}
        branchCombo.selectText(nil)
        let editor=try unwrap(branchCombo.currentEditor() as? NSTextView,"Sync native field editor did not take focus")
        let readsBeforeTyping=readCount()
        try Data().write(to:heldRead);releaseFiles.append(heldRead)
        // Unmatched intermediate names exercise real consecutive edits without
        // NSComboBox intentionally completing a prefix back to existing main.
        for value in ["private-x","private-xy","main"] {
            let beforeContext=sm.formContext
            editor.insertText(value,replacementRange:NSRange(location:0,length:editor.string.utf16.count))
            // AppKit may enqueue the field editor's control notification. Keep
            // the actual editor and allow bounded delivery before inspecting it.
            for _ in 0..<40 {if sm.remoteBranch==value {break};try await Task.sleep(nanoseconds:5_000_000)}
            let coordinator=branchCombo.delegate as? FetchHistoryCombo.Coordinator
            let callbackState=["expected="+value,"model="+sm.remoteBranch,"editor="+editor.string,"combo="+branchCombo.stringValue,
                "enabled="+String(branchCombo.isEnabled),"accepts="+String(coordinator?.accepts(branchCombo) ?? false),
                "updating="+String(coordinator?.updating ?? true),"canEdit="+String(sm.canEditText),
                "before="+String(describing:beforeContext),"current="+String(describing:sm.formContext)].joined(separator:" | ")
            try require(sm.remoteBranch==value,"Continuous native Sync callback dropped text:"+callbackState)
            try require(branchCombo.currentEditor() === editor,"Sync replaced same-field native editor during typing")
        }
        try require(!sm.busy && sm.waitingForInput && readCount()==readsBeforeTyping,"Sync launched a read for each typed character")
        try await Task.sleep(nanoseconds:450_000_000)
        try require(readCount()==readsBeforeTyping,"Sync read before the source 1000ms idle debounce")
        try await wait(sync.window){sm.busy && readCount()==readsBeforeTyping+1}
        try require(branchCombo.isEnabled && branchCombo.currentEditor() === editor,"Deferred Sync read disabled/replaced the active field editor")
        try FileManager.default.removeItem(at:heldRead)
        try await wait(sync.window){!sm.busy && !sm.hasPendingInlineWork && readCount()==readsBeforeTyping+1 && sm.outgoing != nil}
        try require(branchCombo.currentEditor() === editor && editor.string=="main","Deferred Sync projection replaced focused text editor")
        let oldBranchReceipt=sm.formString(\.remoteBranch,context:sm.formContext),beforeOtherField=sm.remoteBranch
        let remoteDraft=sm.formString(\.remote,context:sm.formContext)
        remoteDraft.wrappedValue="added-by-private-fixture"
        oldBranchReceipt.wrappedValue="unowned branch callback"
        try require(sm.remoteBranch==beforeOtherField,"Other-field edit failed to retire earlier typing receipt")
        let beforeQuitRead=readCount();sm.confirmingQuit=true
        oldBranchReceipt.wrappedValue="Quit callback"
        try await wait{!sm.hasPendingInlineWork}
        try await Task.sleep(nanoseconds:1_050_000_000)
        try require(readCount()==beforeQuitRead && sm.remoteBranch==beforeOtherField,"Quit failed to cancel deferred Sync read/typing receipt")
        sm.confirmingQuit=false
        oldBranchReceipt.wrappedValue="late after Quit"
        try require(sm.remoteBranch==beforeOtherField,"Quit reused old Sync typing receipt")
        sm.formString(\.remote,context:sm.formContext).wrappedValue="origin"
        try await wait(sync.window){!sm.busy && !sm.hasPendingInlineWork && sm.outgoing != nil && sm.remote=="origin"}
        sync.window?.makeFirstResponder(nil)
        let scopeDraft=sm.formString(\.remoteBranch,context:sm.formContext)
        scopeDraft.wrappedValue="ma"
        sm.formString(\.localBranch,context:sm.formContext,tracking:true).wrappedValue="topic"
        try require(sm.busy && !sm.waitingForInput,"Local scope change did not retire pending typing timer")
        scopeDraft.wrappedValue="stale after local scope"
        try await wait(sync.window){!sm.busy && !sm.hasPendingInlineWork && sm.outgoing != nil}
        try require(sm.localBranch=="topic" && sm.remoteBranch != "stale after local scope","Old field receipt replaced new local scope")
        sm.formString(\.localBranch,context:sm.formContext,tracking:true).wrappedValue="main"
        try await wait(sync.window){!sm.busy && !sm.hasPendingInlineWork && sm.outgoing != nil && sm.remoteBranch=="main"}
        let controls=views(sync.window?.contentView).compactMap{$0 as? SynchronizationNativeActionControl}
        let expected:[String:[String]]=[
            "pull":["Pull","Fetch","Fetch & Rebase","Fetch All","Remote Update","Cleanup stale remote branches","Compare Tags"],
            "push":["Push","Push tags","Push notes"],
            "submodule":["Submodule Update","Submodule Init","Submodule Sync"],
            "stash":["Stash changes","Stash pop","Stash apply"]]
        for group in ["pull","push","submodule","stash"] {
            let control=try unwrap(controls.first{$0.identifier?.rawValue=="TurtleGit.Sync.Action."+group},"Native Sync split missing: "+group)
            try require(control.segmentCount==2 && control.isEnabled,"Sync split disabled or separated: "+group)
            let menu=try unwrap(control.menu(forSegment:1),"Sync menu missing: "+group)
            try require(menu.items.map(\.title)==expected[group],"Source Sync menu order: "+group+" actual="+menu.items.map(\.title).joined(separator:"|"))
            try require(menu.items.allSatisfy{$0.image != nil} && menu.items.filter{$0.state == .on}.count==1,"Sync icons/current check: "+group)
            menu.delegate?.menuWillOpen?(menu)
            sm.force.toggle()
            if let item=menu.items.first,let action=item.action {_ = NSApp.sendAction(action,to:item.target,from:item)}
            try require(!sm.busy,"Stale Sync menu executed command: "+group)
            try await wait(sync.window){control.isEnabled}
        }
        let pull=try unwrap(controls.first{$0.identifier?.rawValue=="TurtleGit.Sync.Action.pull"},"Pull split missing")
        let pushControl=try unwrap(controls.first{$0.identifier?.rawValue=="TurtleGit.Sync.Action.push"},"Push split missing")
        try require(pull.label(forSegment:0)=="Fetch & Rebase" && pushControl.label(forSegment:0)=="Push notes","Sync remembered choices not projected into primary captions")
        try await capture(sync.window!,"sync-source-controls")
        let formDraft=sm.formString(\.remoteBranch,context:sm.formContext),oldBranch=sm.remoteBranch
        sm.confirmingQuit=true
        formDraft.wrappedValue="stale while Quit owns form"
        try require(sm.remoteBranch==oldBranch,"Sync captured field binding bypassed Quit owner")
        try await wait(sync.window){controls.allSatisfy{!$0.isEnabled}}
        for control in controls {
            control.keyDown(with:try key(sync.window!," ",49,[]))
        }
        try require(!sm.busy,"Disabled Sync keyboard control started operation")
        sm.confirmingQuit=false;try await wait(sync.window){controls.allSatisfy{$0.isEnabled}}
        formDraft.wrappedValue="late stale after Quit"
        try require(sm.remoteBranch==oldBranch,"Sync reused a retired form context")
        // Deliberate private local Fetch proves a fresh one-use menu action and
        // its sticky primary caption without remote network or user repositories.
        let interruptedDraft=sm.formString(\.remoteBranch,context:sm.formContext)
        interruptedDraft.wrappedValue="main"
        try require(sm.waitingForInput,"Pending transport typing timer not acquired")
        let menu=try unwrap(pull.menu(forSegment:1),"Fresh Fetch menu missing")
        menu.delegate?.menuWillOpen?(menu)
        let fetch=menu.items[1]
        if let action=fetch.action {_ = NSApp.sendAction(action,to:fetch.target,from:fetch)}
        try require(sm.busy && sm.pullAction == .fetch && !sm.waitingForInput,"Fresh Sync Fetch did not retire typing timer")
        interruptedDraft.wrappedValue="unowned during transport"
        try require(sm.remoteBranch=="main","Transport admitted old typing receipt")
        if let action=menu.items[0].action {_ = NSApp.sendAction(action,to:menu.items[0].target,from:menu.items[0])}
        try require(sm.pullAction == .fetch,"Consumed Sync menu retargeted active transport")
        try await wait(sync.window){!sm.busy && !sm.hasPendingInlineWork}
        try require(sm.commandSucceeded && pull.label(forSegment:0)=="Fetch" && prefs.integer(forKey:prefix+".pullAction")==1,"Private Fetch failed or sticky choice was not retained")
        interruptedDraft.wrappedValue="late after transport"
        try require(sm.remoteBranch=="main" && !sm.waitingForInput,"Transport completion reused an old typing receipt")
        pull.keyDown(with:try key(sync.window!," ",49,[]))
        try require(sm.busy && sm.pullAction == .fetch,"Native momentary Space did not repeat remembered Sync action")
        try await wait(sync.window){!sm.busy && !sm.hasPendingInlineWork}
        try require(sm.commandSucceeded,"Repeated private Fetch keyboard action failed")
        let beforeClosingRead=readCount()
        sm.formString(\.remoteBranch,context:sm.formContext).wrappedValue="topic"
        sync.window?.close()
        try await wait{!sm.hasPendingInlineWork}
        try await Task.sleep(nanoseconds:1_050_000_000)
        try require(readCount()==beforeClosingRead,"Closed Sync owner launched deferred typing read")
        pull.keyDown(with:try key(sync.window!," ",49,[]))
        try require(!sm.busy && pull.lifetime.retired,"Closed Sync control accepted keyboard action")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout
        try require(afterHead==head && afterIndex==index,"Source control exercises changed HEAD/index")
    }
    @MainActor static func referenceControls(_ owner:NSWindowController,name:String,commandID:String,sourceKey:String,expectedIDs:[String],read:@escaping()->Bool,publish:()->Void,setQuit:(Bool)->Void,requiresEditor:Bool=false,longCaption:String?=nil)async throws {
        let window=try unwrap(owner.window as? ReferenceFormNativeWindow,"Missing native reference form owner: "+name)
        try await wait(window){window.formCommands != nil}
        let router=try unwrap(window.formCommands,"Missing owned form commands: "+name),privateMenu=NSMenu(title:"Private receiver form menu")
        router.applicationMenu={privateMenu};router.keyWindow={ [weak window] in window };router.install()
        try await wait(window){router.menu?.items.contains{$0.identifier?.rawValue=="TurtleGit.ReferenceForm."+commandID && $0.isEnabled}==true}
        let menu=try unwrap(router.menu,"Missing form menu: "+name)
        try require(menu.items.compactMap{$0.identifier?.rawValue}==expectedIDs.map{"TurtleGit.ReferenceForm."+$0},"Source form command order: "+name)
        try require(!menu.items.isEmpty && menu.items.allSatisfy{$0.image != nil && $0.keyEquivalentModifierMask == [.command,.option]},"Form menu icons/native aliases: "+name)
        let item=try unwrap(menu.items.first{$0.identifier?.rawValue=="TurtleGit.ReferenceForm."+commandID},"Missing source command: "+name)
        try require(item.keyEquivalent==sourceKey,"Source command key mismatch: "+name)
        window.makeFirstResponder(nil)
        // Ending a native field edit publishes its committed value. Acquire the
        // replacement router receipt after SwiftUI processes that publication.
        try await Task.sleep(nanoseconds:20_000_000)
        try await wait(window){router.menu?.items.contains{$0.identifier?.rawValue==item.identifier?.rawValue && $0.isEnabled}==true}
        let initial=read()
        try require(window.performKeyEquivalent(with:key(window,sourceKey,0)),"Actual native mnemonic was not handled: "+name)
        try require(read() != initial,"Actual native mnemonic did not change its source option: "+name)
        try await wait(window){router.menu?.items.contains{$0.identifier?.rawValue==item.identifier?.rawValue && $0.isEnabled}==true}
        if requiresEditor {
            let field=try unwrap(views(window.contentView).compactMap{$0 as? NSTextField}.first{$0.isEnabled && $0.isEditable},"Editable native source field missing: "+name)
            field.selectText(nil)
            try await Task.sleep(nanoseconds:20_000_000)
            try await wait(window){router.menu?.items.contains{$0.identifier?.rawValue==item.identifier?.rawValue && $0.isEnabled}==true}
            try require((window.firstResponder as? NSTextView)?.isEditable==true,"Source text field did not take native editing focus: "+name)
            let value=read()
            try require(!router.performKeyEquivalent(try key(window,sourceKey,0,.option)) && read()==value,"Option mnemonic stole an editable text gesture: "+name)
            try require(window.performKeyEquivalent(with:key(window,sourceKey,0)),"Command-Option alias unavailable while editing: "+name)
            try require(read() != value,"Text-safe native alias did not execute: "+name)
            window.makeFirstResponder(nil)
            try await wait(window){router.menu?.items.contains{$0.identifier?.rawValue==item.identifier?.rawValue && $0.isEnabled}==true}
        }
        let retained=try unwrap(router.menu?.items.first{$0.identifier?.rawValue==item.identifier?.rawValue},"Current source command missing")
        publish();let published=read()
        if let action=retained.action{_ = NSApp.sendAction(action,to:retained.target,from:retained)}
        try require(read()==published,"Retained stale menu changed a new form publication: "+name)
        setQuit(true)
        let blocked=read();_ = router.performKeyEquivalent(try key(window,sourceKey,0))
        try require(read()==blocked,"Quit-owned form accepted source keyboard action: "+name)
        setQuit(false)
        try await wait(window){router.menu?.items.contains{$0.identifier?.rawValue==item.identifier?.rawValue && $0.isEnabled}==true}
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:180,height:80),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        window.beginSheet(sheet,completionHandler:nil);let beforeSheet=read();_ = router.performKeyEquivalent(try key(window,sourceKey,0))
        try require(read()==beforeSheet,"Owned sheet admitted background form key: "+name)
        window.endSheet(sheet,returnCode:.cancel);sheet.close();try await wait{sheet.sheetParent==nil}
        if let longCaption {
            let caption=try unwrap(views(window.contentView).compactMap{$0 as? NSTextField}.first{$0.toolTip?.contains(longCaption)==true && $0.isSelectable && !$0.isEditable},"Long native reference caption missing: "+name)
            try require(caption.lineBreakMode == .byTruncatingMiddle && caption.stringValue.contains(longCaption),"Long source caption was destructively abbreviated/wrapped: "+name)
            let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
            caption.selectText(nil)
            let editor=try unwrap(caption.currentEditor() as? NSTextView,"Read-only reference did not permit native selection: "+name)
            editor.setSelectedRange(NSRange(location:0,length:editor.string.utf16.count));board.declareTypes([.string],owner:nil)
            try require(editor.writeSelection(to:board,types:editor.writablePasteboardTypes) && board.string(forType:.string)?.contains(longCaption)==true,"Reference native Copy lost full caption: "+name)
            window.makeFirstResponder(nil)
            let host=try unwrap(window.contentView,"Caption host missing")
            window.setContentSize(.init(width:max(650,window.contentMinSize.width),height:max(550,window.contentMinSize.height)))
            host.layoutSubtreeIfNeeded()
            try require(host.bounds.insetBy(dx:-1,dy:-1).contains(caption.convert(caption.bounds,to:host)),"Long reference caption extends outside minimum native form: "+name)
        }
        // Assert the requested minimum remains the actual width: containment
        // alone would incorrectly pass if intrinsic reference text grew the host.
        // NSHostingController can replace live AppKit minimum properties after
        // appearing; exercise each controller's declared source size instead.
        let declaredMinimum:NSSize
        switch name {
        case "branch","tag": declaredMinimum = .init(width:650,height:530)
        case "switch": declaredMinimum = .init(width:600,height:390)
        case "merge": declaredMinimum = .init(width:660,height:570)
        case "reset": declaredMinimum = .init(width:690,height:405)
        default: throw Failure(description:"Unknown source form: "+name)
        }
        let requestedWidth=declaredMinimum.width,requestedHeight=declaredMinimum.height
        let declaredFrame=window.frameRect(forContentRect:.init(origin:.zero,size:declaredMinimum)).size
        func hasNativeFloor()->Bool {
            window.contentMinSize.width+0.5>=declaredMinimum.width && window.contentMinSize.height+0.5>=declaredMinimum.height && window.minSize.width+0.5>=declaredFrame.width && window.minSize.height+0.5>=declaredFrame.height
        }
        try require(hasNativeFloor(),"Native minimum floor lost after model/sheet updates: "+name)
        // Model the hosting controller recomputing limits. Both native setters
        // must preserve the declared floor through the next actual render turn.
        window.contentMinSize = .zero;window.minSize = .zero
        try await Task.sleep(nanoseconds:20_000_000)
        try require(hasNativeFloor(),"Hosting limit reset removed native source floor: "+name)
        window.setContentSize(.init(width:requestedWidth,height:requestedHeight))
        try await Task.sleep(nanoseconds:30_000_000)
        let minimumHost=try unwrap(window.contentView,"Minimum form host missing")
        minimumHost.layoutSubtreeIfNeeded()
        try require(abs(minimumHost.bounds.width-requestedWidth)<=1,"Long reference enlarged minimum form: "+name+" width="+String(describing:minimumHost.bounds.width))
        let nativeViews=views(minimumHost)
        let branchPopup=try unwrap(nativeViews.compactMap{$0 as? NSPopUpButton}.first{$0.accessibilityLabel()?.lowercased().contains("branch revision")==true},"Native branch popup missing: "+name)
        let branchRadio=try unwrap(nativeViews.compactMap{$0 as? NSButton}.first{$0.title=="Branch"},"Native Branch radio missing: "+name)
        let popupRect=branchPopup.convert(branchPopup.bounds,to:minimumHost),radioRect=branchRadio.convert(branchRadio.bounds,to:minimumHost)
        let contentBounds=minimumHost.bounds.insetBy(dx:-1,dy:-1)
        if longCaption != nil {
            let caption=try unwrap(nativeViews.compactMap{$0 as? NSTextField}.first{$0.identifier?.rawValue=="Current branch"},"Native current-branch caption missing at minimum size: "+name)
            try require(contentBounds.contains(caption.convert(caption.bounds,to:minimumHost)),"Minimum source form clips current-branch caption: "+name)
        }
        // SwiftUI virtual footer nodes are absent in hidden receivers; inspect
        // native buttons when exposed and require deliberate captures for the
        // remaining footer visual acceptance, rather than inventing AX nodes.
        for button in nativeViews.compactMap({$0 as? NSButton}) where ["OK","Cancel","Help"].contains(button.title) {
            try require(contentBounds.contains(button.convert(button.bounds,to:minimumHost)),"Minimum source form clips native footer: "+name+" "+button.title)
        }
        if !(contentBounds.contains(popupRect) && contentBounds.contains(radioRect) && popupRect.width>=100 && radioRect.width>=50 && radioRect.maxX<=popupRect.minX+1) {
            print("Reference layout diagnostic \(name): host=\(minimumHost.bounds) popup=\(popupRect) radio=\(radioRect) requested=\(requestedWidth)x\(requestedHeight)")
            try await capture(window,name+"-source-controls-failure")
        }
        try require(contentBounds.contains(popupRect) && contentBounds.contains(radioRect) && popupRect.width>=100 && radioRect.width>=50 && radioRect.maxX<=popupRect.minX+1,"Long reference hid/overlapped Branch radio or popup: "+name)
        // The source row reserves a trailing browse button. Its SwiftUI virtual
        // accessibility node is unavailable in hidden receivers, so check the
        // actual native popup leaves the source button's complete trailing slot.
        try require(popupRect.maxX<=minimumHost.bounds.maxX-25,"Long reference consumed trailing browse slot: "+name)
        for button in nativeViews.compactMap({$0 as? NSButton}) where button.title=="…" || button.accessibilityLabel()=="Browse references" {
            try require(contentBounds.contains(button.convert(button.bounds,to:minimumHost)),"Native browse control escaped source form: "+name)
        }
        try require(branchPopup.menu?.items.contains{item in
            let expected="feature/"+String(repeating:"source-reference-caption-",count:7)+"雪-menu-target"
            return item.title==expected && item.toolTip=="refs/heads/"+expected
        }==true,"Long reference menu lost full source title/tooltip: "+name)
        try await capture(window,name+"-source-controls")
        let retired=try unwrap(router.menu?.items.first{$0.identifier?.rawValue==item.identifier?.rawValue},"Source command missing before close")
        window.close();let final=read()
        if let action=retired.action{_ = NSApp.sendAction(action,to:retired.target,from:retired)}
        _ = router.performKeyEquivalent(try key(window,sourceKey,0))
        try require(read()==final && window.formCommands==nil,"Retired native form command resurrected owner: "+name)
    }
    @MainActor static func references(_ repo:GitRepository,_ prefs:UserDefaults)async throws {
        let long="feature/"+String(repeating:"source-reference-caption-",count:7)+"雪"
        _ = try await repo.run(["switch","-c",long])
        // Merge correctly omits the current branch; supply a separate long
        // source candidate so every form must preserve its full menu spelling.
        _ = try await repo.run(["branch",long+"-menu-target"])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,refs=try await repo.run(["show-ref"]).stdout,index=try await repo.run(["write-tree"]).stdout
        for isTag in [false,true] {
            let owner=BranchTagWindowController(repository:repo,access:nil,isTag:isTag,preferences:prefs);own(owner)
            let model=owner.model;model.load(revision:nil,name:isTag ? "private-tag-draft":"private-branch-draft")
            try await wait(owner.window){model.canEditForm}
            try require(model.currentBranch==long,"Reference form model did not resolve the full current branch")
            // The initial HEAD(detached) radio already has this identifier.
            // Model read completion precedes SwiftUI's native update; await the
            // resolved caption, then retain the full title/tooltip/mode check.
            do {
                try await wait(owner.window){views(owner.window?.contentView).compactMap{$0 as? NSButton}.contains{$0.identifier?.rawValue=="ReferenceForm.HEAD" && $0.title=="HEAD ("+long+")"}}
            } catch {
                let current=views(owner.window?.contentView).compactMap{$0 as? NSButton}.filter{$0.identifier?.rawValue=="ReferenceForm.HEAD"}
                fputs("HEAD caption readiness: tag=\(isTag) model=\(model.currentBranch) native=\(current.map{($0.title,$0.toolTip ?? "nil",String(describing:$0.cell?.lineBreakMode))})\n",stderr)
                throw error
            }
            let headCaption=try unwrap(views(owner.window?.contentView).compactMap{$0 as? NSButton}.first{$0.identifier?.rawValue=="ReferenceForm.HEAD"},"Native HEAD radio missing")
            try require(headCaption.title.contains(long) && headCaption.toolTip==headCaption.title && headCaption.cell?.lineBreakMode == .byTruncatingMiddle,"Long HEAD radio lost full source name/tooltip")
            let ids=["name","head","branch","tag","commit","browseReferences","chooseCommit","track","force"]+(isTag ? ["sign","push"]:["switch"])+["message"]
            try await referenceControls(owner,name:isTag ? "tag":"branch",commandID:"force",sourceKey:"f",expectedIDs:ids,read:{model.options.force},publish:{model.options.force.toggle()},setQuit:{model.confirmingQuit=$0},requiresEditor:true)
        }
        let checkout=SwitchWindowController(repository:repo,access:nil,preferences:prefs);own(checkout)
        checkout.model.load();try await wait(checkout.window){checkout.model.canEditForm}
        let switchModel=checkout.model
        try await wait(checkout.window){views(checkout.window?.contentView).compactMap{$0 as? NSPopUpButton}.contains{$0.toolTip?.contains(long)==true}}
        try await referenceControls(checkout,name:"switch",commandID:"newBranch",sourceKey:"n",expectedIDs:["branch","tag","commit","browseReferences","chooseCommit","newBranch","force","merge","track","override"],read:{switchModel.options.createBranch},publish:{switchModel.options.createBranch.toggle()},setQuit:{switchModel.confirmingQuit=$0},requiresEditor:true)
        let merge=MergeWindowController(repository:repo,access:nil,preferences:prefs);own(merge)
        merge.model.load(revision:"topic");try await wait(merge.window){merge.model.canEditForm}
        let mm=merge.model
        try await referenceControls(merge,name:"merge",commandID:"squash",sourceKey:"s",expectedIDs:["branch","tag","commit","browseReferences","chooseCommit","squash","messages","noFastForward","fastForwardOnly","noCommit","strategy","message"],read:{mm.options.squash},publish:{mm.options.squash.toggle()},setQuit:{mm.confirmingQuit=$0},longCaption:long)
        let reset=ResetWindowController(repository:repo,access:nil,revision:"HEAD",preferences:prefs);own(reset)
        reset.model.load();try await wait(reset.window){reset.model.canEditForm}
        let rm=reset.model
        try await referenceControls(reset,name:"reset",commandID:"soft",sourceKey:"s",expectedIDs:["branch","tag","commit","browseReferences","chooseCommit","soft","mixed","hard","modifiedFiles"],read:{rm.mode == .soft},publish:{rm.mode = .mixed},setQuit:{rm.confirmingQuit=$0},longCaption:long)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterRefs=try await repo.run(["show-ref"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout
        try require(afterHead==head && afterRefs==refs && afterIndex==index,"Reference form controls mutated Git instead of retaining drafts")
    }
    @MainActor static func cleanup()async->Bool {
        for file in releaseFiles{try? FileManager.default.removeItem(at:file)}
        for owner in owners.reversed(){if let window=owner.window{if let child=window.attachedSheet{window.endSheet(child,returnCode:.abort);child.close()};window.close()}}
        for window in NSApp.windows{window.orderOut(nil);window.close()}
        for _ in 0..<1600 {
            if BranchTagWindowModel.activeReads==0 && BranchTagWindowModel.activeCreations==0 && SwitchWindowModel.activeReads==0 && MergeWindowModel.activeReads==0 && ResetWindowModel.activeReads==0 && PushWindowModel.activePreparationReads==0 && PushWindowModel.activePushWorkflows==0 && SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowModel.activePushWorkflows==0{return true}
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        return false
    }
    @MainActor static func main()async {
        NSApp.setActivationPolicy(.prohibited)
        var failure:Error?
        do {
            let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
            for name in CommandLine.arguments.dropFirst(3) {
                let repo=try await fixture(base.appendingPathComponent(name),git)
                let suite="TurtleGit.SourceForms."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
                defer{prefs.removePersistentDomain(forName:suite)}
                prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"TGitAutoLoadSSHKey");prefs.set(false,forKey:"ConfirmKillProcess")
                switch name {case "references":try await references(repo,prefs);case "transport":try await transport(repo,prefs);default:throw Failure(description:"Unknown source form case")}
                print("PASS source form case: "+name)
            }
        }catch{failure=error}
        if !(await cleanup()),failure==nil{failure=Failure(description:"Owned native form workers did not drain")}
        if let failure{fputs("Source form controls failed: \(failure)\n",stderr);exit(1)}
        print("PASS source form controls: "+CommandLine.arguments.dropFirst(3).joined(separator:", ")+"; all owned windows/workers closed")
    }
}
