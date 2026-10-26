// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func turtleGitBlameToolbarOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        // Frame persistence is the behavior under test. Preserve AppKit's real
        // screen geometry and hide every owned window before it is ordered.
        alphaValue=0
        turtleGitBlameToolbarOrder(place,relativeTo:number)
    }
}

@MainActor
@main struct BlameToolbarPlacementVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static var owners:[BlameWindowController]=[]
    static var otherWindows:[NSWindowController]=[]
    static var palettes:[NSToolbar]=[]
    static var preferences:[(UserDefaults,String)]=[]
    static func phase(_ message:String){print("Blame toolbar placement phase: "+message);fflush(stdout)}
    static func finishPalette(_ toolbar:NSToolbar)throws {
        guard toolbar.customizationPaletteIsRunning else{return}
        let buttons=NSApp.windows.flatMap{views($0.contentView)}.compactMap{$0 as? NSButton}
        guard let done=buttons.first(where:{$0.title=="Done" && $0.action != nil}) else {
            phase("Palette native buttons: "+buttons.map{$0.title+":"+String(describing:$0.action)}.joined(separator:" | "))
            throw Failure(description:"AppKit customization palette has no native Done control")
        }
        done.performClick(nil)
    }
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {
        if !value {throw Failure(description:"Blame toolbar assertion at \(line): \(message)")}
    }
    static func wait(_ message:String,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Blame toolbar timeout at \(line): \(message)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func identifier(_ id:String)->NSToolbarItem.Identifier {
        id=="space" ? .space:id=="flexibleSpace" ? .flexibleSpace:.init("TurtleGit.Blame.Command."+id)
    }
    static func item(_ id:String,in chrome:BlameToolbarController)throws->NSToolbarItem {
        guard let value=chrome.toolbar.items.first(where:{$0.itemIdentifier==identifier(id)}) else {throw Failure(description:"Missing native toolbar item: "+id)}
        return value
    }
    static func invoke(_ item:NSToolbarItem)throws {
        guard let action=item.action else {throw Failure(description:"Toolbar item has no native action")}
        try require(NSApp.sendAction(action,to:item.target,from:item),"Native toolbar target rejected dispatch")
    }
    static func invoke(_ item:NSMenuItem)throws {
        guard let action=item.action else {throw Failure(description:"Toolbar overflow item has no native action")}
        try require(NSApp.sendAction(action,to:item.target,from:item),"Native overflow target rejected dispatch")
    }
    static func invoke(_ button:NSButton)throws {
        guard let action=button.action else {throw Failure(description:"Native placement button has no action")}
        try require(NSApp.sendAction(action,to:button.target,from:button),"Native placement button rejected dispatch")
    }
    static func event(_ type:NSEvent.EventType,view:NSView,clicks:Int=1,modifiers:NSEvent.ModifierFlags=[] )throws->NSEvent {
        guard let window=view.window,let event=NSEvent.mouseEvent(with:type,location:view.convert(NSPoint(x:view.bounds.midX,y:view.bounds.midY),to:nil),modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:clicks,pressure:1) else {throw Failure(description:"Cannot construct private native handle event")}
        return event
    }
    static func capture(_ view:NSView?,_ name:String) {
        guard CommandLine.arguments.count>3,let view else{return}
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {phase("Capture unavailable: "+name);return}
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let bytes=bitmap.representation(using:.png,properties:[:]) else {phase("Capture PNG unavailable: "+name);return}
        let path=URL(fileURLWithPath:CommandLine.arguments[3]).appendingPathComponent(name+".png")
        do {try bytes.write(to:path);phase("Offscreen content capture: "+path.path)}catch{phase("Capture failed: "+String(describing:error))}
    }
    static func invisible()throws {
        try require(NSApp.windows.allSatisfy{!$0.isVisible || $0.alphaValue==0},"Placement/floating workflow exposed a window")
    }
    static func drained()->Bool {
        BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && BlameDocumentOpener.activeReads==0
    }
    static func cleanup()async {
        phase("cleanup begin")
        for toolbar in palettes {try? finishPalette(toolbar)}
        for owner in owners {owner.model.busy=false;owner.close()}
        for owner in otherWindows {owner.close()}
        try? await wait("Owned Blame toolbar workers, palettes and windows drain") {
            drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}
        }
        DialogGeometry.install(preferences:.standard)
        for (defaults,suite) in preferences {defaults.removePersistentDomain(forName:suite)}
        preferences=[]
        phase("cleanup drained")
    }
    static func source(_ owner:BlameWindowController)throws->NSTextView {
        guard let value=views(owner.window?.contentView).compactMap({$0 as? NSTextView}).first(where:{$0.accessibilityLabel()=="Blame source text"}) else {throw Failure(description:"Blame source editor missing")}
        return value
    }
    static func settle(_ owner:BlameWindowController)async throws {
        try await wait("Blame document and actual source controls") {
            !owner.model.busy && !owner.model.syntaxWorking && owner.model.lines.count==3 && views(owner.window?.contentView).contains{($0 as? NSTextView)?.accessibilityLabel()=="Blame source text"}
        }
        owner.window?.contentView?.layoutSubtreeIfNeeded()
    }
    static func main()async {
        NSApp.setActivationPolicy(.prohibited)
        let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitBlameToolbarOrder(_:relativeTo:)))!
        method_exchangeImplementations(normal,hidden)
        do {try await verify();await cleanup();try require(drained(),"Final Blame workers survived cleanup");try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil},"Final owned panel/window survived cleanup")}
        catch {await cleanup();fputs("Blame toolbar failed: \(error)\n",stderr);method_exchangeImplementations(normal,hidden);exit(1)}
        method_exchangeImplementations(normal,hidden)
        print("PASS Blame toolbar placement: native docks/floating panels, quick customization and live ownership; Git HEAD/index/files unchanged")
    }
    static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repository=GitRepository(root:root,executable:git)
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Blame Toolbar QA"),("user.email","toolbar@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
        let firstPath="toolbar A 雪.txt",secondPath="toolbar B.txt",firstURL=root.appendingPathComponent(firstPath),secondURL=root.appendingPathComponent(secondPath)
        try Data("A first\nA original\nA last\n".utf8).write(to:firstURL)
        try Data("B original\nB middle\nB last\n".utf8).write(to:secondURL)
        try await repository.stage([firstPath,secondPath]);_ = try await repository.commit(message:"Toolbar parent")
        try Data("A first\nA changed\nA last\n".utf8).write(to:firstURL)
        try Data("B changed\nB middle\nB last\n".utf8).write(to:secondURL)
        try await repository.stage([firstPath,secondPath]);_ = try await repository.commit(message:"Toolbar current")
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),firstBytes=try Data(contentsOf:firstURL),secondBytes=try Data(contentsOf:secondURL)
        let suite="TurtleGit.BlameToolbar.Placement.Native."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        preferences.append((prefs,suite))
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"Blame.EnableLexer");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        DialogGeometry.install(preferences:prefs)
        let privateScreen=NSRect(x:-18100,y:-18100,width:1600,height:1200)
        let actualScreens=NSScreen.screens.map(\.visibleFrame)
        guard let actualScreen=actualScreens.first else {throw Failure(description:"Native floating panel needs a connected screen")}
        func owner(_ path:String)->BlameWindowController {
            let owner=BlameWindowController(repository:repository,access:nil,path:path,revision:"HEAD",options:GitBlameOptions(),preferences:prefs,requireScope:false)
            owners.append(owner);owner.commandKeyWindow={ [weak owner] in owner?.window }
            owner.toolbarChrome?.screenFrames={actualScreens}
            owner.toolbarChrome?.presentFloating={panel in panel.alphaValue=0;panel.orderFront(nil)}
            owner.toolbarChrome?.refresh();owner.window?.orderFront(nil);return owner
        }
        phase("open private documents")
        let first=owner(firstPath),second=owner(secondPath)
        try await settle(first);try await settle(second)
        guard let chrome=first.toolbarChrome,let window=first.window else {throw Failure(description:"Placement owner chrome missing")}
        let standardID=BlameToolbarConfiguration.standardID,store=BlameToolbarConfigurationStore(defaults:prefs)
        phase("same-layout external reset invalidates old receipts and refreshes new drags")
        let oldEpoch=chrome.configuration.generation
        try require(chrome.beginCommandDrag(barID:standardID,index:0),"Pre-reset drag capture failed")
        let externallyReset=store.reset()
        try require(externallyReset==chrome.configuration && externallyReset.generation != oldEpoch,"External reset did not preserve layout with a new epoch")
        try require(!chrome.finishCommandDrag(destinationID:standardID,index:2),"Old receipt survived equal-layout external reset")
        try await wait("Equal-layout epoch adopted after cancelled stale drop") {chrome.configuration.generation==store.load().generation}
        try require(chrome.beginCommandDrag(barID:standardID,index:0),"Fresh drag stayed blocked after external reset")
        try require(chrome.finishCommandDrag(destinationID:standardID,index:chrome.configuration.standard.items.count),"Fresh receipt stayed stale after equal-layout reset")
        try require(chrome.configuration.standard.items.last=="open","Fresh post-reset drag did not move native source command")
        chrome.reset()
        guard let reviewID=chrome.createBar(name:"Review placement"),let navigationID=chrome.createBar(name:"Navigation placement") else {throw Failure(description:"Placement custom bars missing")}
        func bar(_ id:UUID)->BlameToolbarBar {chrome.configuration.allBars.first{$0.id==id}!}
        func update(_ id:UUID,_ change:(inout BlameToolbarBar)->Void){var value=bar(id);change(&value);chrome.update(value)}
        update(reviewID){$0.items=["find","wrap","about"]}
        update(navigationID){$0.items=["copy"]}
        phase("all dock regions and standard/custom native hosts")
        for placement in [BlameToolbarPlacement.top,.bottom,.left,.right] {
            chrome.setPlacement(barID:standardID,placement:placement)
            chrome.setPlacement(barID:reviewID,placement:placement)
            try await wait("Saved dock \(placement.rawValue)") {store.load().standard.placement==placement && store.load().customBars.first{$0.id==reviewID}?.placement==placement}
            try await wait("Actual \(placement.rawValue) native dock host") {chrome.stripHosts.values.compactMap(\.view).contains{$0.barID==reviewID && $0.window === window && $0.accessibilityIdentifier().hasSuffix("."+placement.rawValue)==true && views($0).compactMap{$0 as? BlameToolbarGrip}.contains{chrome.authenticatedGrip($0)}}}
            window.contentView?.layoutSubtreeIfNeeded()
            let actual=chrome.stripHosts.values.compactMap(\.view).filter{$0.window === window && !$0.isHiddenOrHasHiddenAncestor}
            try require(actual.contains{$0.barID==reviewID},"Dock region has no actual native custom row")
            guard let nativeReview=actual.first(where:{$0.barID==reviewID}) else {throw Failure(description:"Native dock controls missing")}
            let controls=nativeReview.subviews.compactMap{$0 as? NSButton}.filter{!($0 is NSPopUpButton)}
            try require(controls.map(\.toolTip)==["find","wrap","about"].map{Optional(BlameToolbarController.title($0))},"Dock host changed native command order")
            let shown=controls.filter{!$0.isHidden}
            if placement == .left || placement == .right {
                try require(shown.count==3 && zip(shown,shown.dropFirst()).allSatisfy{$0.frame.maxY <= $1.frame.minY},"Vertical dock failed native control flow")
                let sourceEditor=try source(first)
                let dockRect=nativeReview.convert(nativeReview.bounds,to:window.contentView),sourceRect=sourceEditor.convert(sourceEditor.bounds,to:window.contentView)
                try require(placement == .left ? dockRect.maxX<=sourceRect.minX:dockRect.minX>=sourceRect.maxX,"Native dock appeared on wrong side of source")
            }else{
                try require(shown.count==3 && zip(shown,shown.dropFirst()).allSatisfy{$0.frame.maxX <= $1.frame.minX},"Horizontal dock failed native control flow")
            }
            if placement != .top {try require(actual.contains{$0.barID==standardID},"Non-top standard toolbar lost its native controls")}
            try require(chrome.toolbar.isVisible == (placement == .top),"AppKit titlebar toolbar did not follow standard placement")
            try require(chrome.floatingPanels.isEmpty,"Dock placement left a floating owner")
            try require(chrome.configuration.standard.items==BlameToolbarConfiguration.defaults.standard.items,"Docking changed standard source composition")
            try invisible()
            if placement == .left || placement == .right {capture(window.contentView,"dock-"+placement.rawValue)}
        }
        phase("native handle context menu and double-click float/dock")
        let menu=chrome.contextMenu(barID:reviewID)
        for placement in BlameToolbarPlacement.allCases {
            try require(menu.items.contains{$0.title==NSLocalizedString(placement.title,comment:"") && $0.action != nil},"Handle fallback menu missing placement \(placement.rawValue)")
        }
        guard let top=menu.items.first(where:{$0.title==NSLocalizedString(BlameToolbarPlacement.top.title,comment:"")}) else {throw Failure(description:"Top fallback item missing")}
        try invoke(top)
        try require(bar(reviewID).placement == .top,"Handle fallback native menu failed placement action")
        try await wait("Actual native custom toolbar handle") {views(window.contentView).compactMap{$0 as? BlameToolbarGrip}.contains{$0.barID==reviewID && chrome.authenticatedGrip($0)}}
        guard let reviewGrip=views(window.contentView).compactMap({$0 as? BlameToolbarGrip}).first(where:{$0.barID==reviewID && chrome.authenticatedGrip($0)}) else {throw Failure(description:"Custom toolbar native grip missing")}
        try require(reviewGrip.menu(for:try event(.rightMouseDown,view:reviewGrip))?.items.contains{$0.title==NSLocalizedString("Floating",comment:"")}==true,"Native handle context-menu path missing docking alternatives")
        let gripDoubleClick=try event(.leftMouseDown,view:reviewGrip,clicks:2)
        reviewGrip.mouseDown(with:gripDoubleClick)
        try await wait("Double-click native custom handle floats") {chrome.floatingPanels[reviewID]?.window != nil}
        reviewGrip.mouseDown(with:gripDoubleClick)
        try require(bar(reviewID).placement == .floating && chrome.dockDrag==nil,"Detached old native grip retained docking authority")
        guard let floatingGrip=views(chrome.floatingPanels[reviewID]?.window?.contentView).compactMap({$0 as? BlameToolbarGrip}).first else {throw Failure(description:"Floating custom native handle missing")}
        floatingGrip.mouseDown(with:try event(.leftMouseDown,view:floatingGrip,clicks:2))
        try await wait("Floating double-click returns custom toolbar to top") {bar(reviewID).placement == .top && chrome.floatingPanels[reviewID]==nil}
        chrome.setPlacement(barID:standardID,placement:.top)
        guard let titleGrip=chrome.titlebarGrip?.view as? BlameToolbarGrip else {throw Failure(description:"Standard titlebar native handle missing")}
        titleGrip.mouseDown(with:try event(.leftMouseDown,view:titleGrip,clicks:2))
        try await wait("Standard native handle floats") {chrome.floatingPanels[standardID]?.window != nil}
        guard let standardGrip=views(chrome.floatingPanels[standardID]?.window?.contentView).compactMap({$0 as? BlameToolbarGrip}).first else {throw Failure(description:"Standard floating native grip missing")}
        standardGrip.mouseDown(with:try event(.leftMouseDown,view:standardGrip,clicks:2))
        try await wait("Floating standard handle docks back") {bar(standardID).placement == .top && chrome.floatingPanels[standardID]==nil}

        phase("accepted dock drags and cancellation")
        let beforeDock=chrome.configuration
        try require(chrome.beginDockDrag(barID:reviewID),"Native dock handle could not start")
        chrome.updateDockDrag(point:NSPoint(x:window.frame.minX+1,y:window.frame.midY))
        chrome.cancelDockDrag()
        try require(chrome.configuration==beforeDock && store.load()==beforeDock,"Cancelled handle drag changed saved placement")
        try require(chrome.beginDockDrag(barID:reviewID),"Second dock drag failed")
        try require(chrome.finishDockDrag(point:NSPoint(x:window.frame.minX+1,y:window.frame.midY)),"Left-edge docking drop rejected")
        try require(bar(reviewID).placement == .left,"Dock drop ignored owner left edge")
        let dragSnapshot=chrome.configuration
        try require(chrome.beginCommandDrag(barID:reviewID,index:0),"Option command drag did not capture live occurrence")
        chrome.cancelCommandDrag()
        try require(chrome.configuration==dragSnapshot && store.load()==dragSnapshot,"Cancelled Option drag changed source composition")
        try require(chrome.beginCommandDrag(barID:reviewID,index:0),"Reorder drag did not begin")
        try require(chrome.finishCommandDrag(destinationID:reviewID,index:3),"Accepted within-bar reorder failed")
        try require(bar(reviewID).items==["wrap","about","find"],"Within-bar drop used wrong insertion/source occurrence")
        do {
        try await wait("Actual source/destination native command drop hosts") {
            let hosts=chrome.stripHosts.values.compactMap(\.view)
            return hosts.contains{$0.barID==reviewID && $0.window === window && views($0).compactMap{$0 as? NSButton}.contains{$0.toolTip==BlameToolbarController.title("find") && chrome.authenticatedPointerSource($0)}} && hosts.contains{$0.barID==navigationID && $0.window === window && views($0).compactMap{$0 as? NSButton}.contains{$0.toolTip==BlameToolbarController.title("copy") && chrome.authenticatedPointerSource($0)}}
        }
        }catch{
            phase("Drop host state available=\(chrome.available) epoch=\(chrome.configuration.generation) pending=\(chrome.commandDrag != nil)")
            for host in chrome.stripHosts.values.compactMap(\.view) {
                let buttons=views(host).compactMap{$0 as? NSButton}.map{($0.toolTip ?? $0.title)+":auth="+String(chrome.authenticatedPointerSource($0))+":hidden="+String($0.isHidden)}.joined(separator:" | ")
                phase("Drop host \(String(describing:host.barID)) owner=\(host.window === window) "+buttons)
            }
            throw error
        }
        window.contentView?.layoutSubtreeIfNeeded()
        guard let sourceHost=chrome.stripHosts.values.compactMap(\.view).first(where:{$0.barID==reviewID && $0.window === window}),
              let destinationHost=chrome.stripHosts.values.compactMap(\.view).first(where:{$0.barID==navigationID && $0.window === window}),
              let dragged=views(sourceHost).compactMap({$0 as? NSButton}).first(where:{$0.toolTip==BlameToolbarController.title("find") && chrome.authenticatedPointerSource($0)}),
              let destinationButton=views(destinationHost).compactMap({$0 as? NSButton}).first(where:{$0.toolTip==BlameToolbarController.title("copy") && chrome.authenticatedPointerSource($0)}) else {throw Failure(description:"Native Option drag controls missing")}
        let targetPoint=destinationButton.convert(NSPoint(x:destinationButton.bounds.minX+1,y:destinationButton.bounds.midY),to:nil)
        guard let mouseUp=NSEvent.mouseEvent(with:.leftMouseUp,location:targetPoint,modifierFlags:.option,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0) else {throw Failure(description:"Native drop event missing")}
        NSApp.postEvent(mouseUp,atStart:true)
        dragged.mouseDown(with:try event(.leftMouseDown,view:dragged,modifiers:.option))
        try require(bar(reviewID).items==["wrap","about"] && bar(navigationID).items==["find","copy"],"Accepted transfer failed to remove only confirmed source")
        try require(!chrome.authenticatedPointerSource(dragged),"Removed/rebuilt native command retained pointer authority")
        let beforeOutside=chrome.configuration
        try require(chrome.beginCommandDrag(barID:navigationID,index:0),"Outside drop source capture failed")
        try require(!chrome.finishCommandDrag(destinationID:nil,index:0),"Unconfirmed outside drop invented command deletion")
        try require(chrome.configuration==beforeOutside,"Outside drop changed toolbar despite no accepted destination")
        try require(chrome.beginCommandDrag(barID:navigationID,index:0),"Stale drag did not capture")
        update(navigationID){$0.items=["copy","find"]}
        let staleSnapshot=chrome.configuration
        try require(!chrome.finishCommandDrag(destinationID:reviewID,index:0) && chrome.configuration==staleSnapshot,"Stale command drag redirected changed source occurrence")

        phase("floating standard/custom ownership, bounds, hide/show, resize and persistence")
        chrome.screenFrames={ [privateScreen] }
        let clamped=chrome.clampedFrame(NSRect(x:1_000_000,y:1_000_000,width:9000,height:9000))
        try require(privateScreen.contains(clamped) && clamped.width==privateScreen.width && clamped.height==privateScreen.height,"Floating frame failed connected-screen bounds")
        chrome.screenFrames={actualScreens}
        chrome.setPlacement(barID:standardID,placement:.floating)
        chrome.setPlacement(barID:reviewID,placement:.floating)
        try await wait("Two owned floating toolbar panels") {chrome.floatingPanels[standardID]?.window != nil && chrome.floatingPanels[reviewID]?.window != nil}
        guard let standardPanel=chrome.floatingPanels[standardID]?.window,let reviewPanel=chrome.floatingPanels[reviewID]?.window else {throw Failure(description:"Floating native panels missing")}
        try require(standardPanel !== reviewPanel && standardPanel.parent === window && reviewPanel.parent === window,"Floating bars lost document ownership")
        capture(standardPanel.contentView,"floating-standard");capture(reviewPanel.contentView,"floating-custom")
        first.setDarkMode(true);chrome.refresh()
        try await wait("Floating appearance follows owner") {standardPanel.appearance?.name == .darkAqua && reviewPanel.appearance?.name == .darkAqua}
        first.followSystemAppearance();chrome.refresh()
        try await wait("Floating appearance returns to system") {standardPanel.appearance==nil && reviewPanel.appearance==nil}
        try invisible()
        phase("Resize current=\(chrome.floatingPanels[reviewID]?.window === reviewPanel) available=\(chrome.available) before=\(reviewPanel.frame) stored=\(String(describing:store.load().customBars.first{$0.id==reviewID}?.floatingRect))")
        reviewPanel.setFrame(NSRect(x:actualScreen.minX+40,y:actualScreen.minY+40,width:480,height:90),display:false)
        do {
            try await wait("Floating panel frame persistence") {store.load().customBars.first{$0.id==reviewID}?.floatingRect?.width==480}
        }catch{
            phase("Resize failed actual=\(reviewPanel.frame) current=\(String(describing:chrome.floatingPanels[reviewID]?.window?.frame)) stored=\(String(describing:store.load().customBars.first{$0.id==reviewID}?.floatingRect)) available=\(chrome.available)")
            throw error
        }
        var external=store.load(),externalBar=bar(reviewID)
        externalBar.items=["about","wrap"];external.updateBar(externalBar);store.save(external)
        chrome.captureFloatingFrame(barID:reviewID,frame:NSRect(x:actualScreen.minX+40,y:actualScreen.minY+40,width:490,height:90))
        try require(store.load().customBars.first{$0.id==reviewID}?.items==["about","wrap"] && store.load().customBars.first{$0.id==reviewID}?.floatingRect?.width==490,"Delayed frame callback overwrote external command composition")
        reviewPanel.performClose(nil)
        try await wait("Native close hides floating custom bar") {bar(reviewID).isVisible==false && chrome.floatingPanels[reviewID]?.window?.isVisible != true}
        try require(store.load().customBars.first{$0.id==reviewID}?.placement == .floating,"Closing panel discarded its saved floating placement")
        update(reviewID){$0.isVisible=true}
        try await wait("Restored floating custom bar") {chrome.floatingPanels[reviewID]?.window?.isVisible==true}
        let savedLayout=store.load()
        let reopened=owner(secondPath);try await settle(reopened)
        if reopened.toolbarChrome?.configuration != savedLayout {
            phase("Reopen expected="+String(describing:savedLayout))
            phase("Reopen actual="+String(describing:reopened.toolbarChrome?.configuration))
        }
        try require(reopened.toolbarChrome?.configuration==savedLayout,"Dock/float/frame state did not survive reopen")
        reopened.close()
        chrome.toggleFloating(barID:reviewID)
        try require(bar(reviewID).placement == .left,"Double-click dock return lost the previous dock edge")
        chrome.toggleFloating(barID:reviewID)
        try await wait("Refloated custom bar") {chrome.floatingPanels[reviewID]?.window != nil}
        chrome.setPlacement(barID:navigationID,placement:.floating)
        try await wait("Floating deletion target") {chrome.floatingPanels[navigationID]?.window != nil}
        let deletedPanel=chrome.floatingPanels[navigationID]?.window
        chrome.removeBar(navigationID)
        try require(!chrome.configuration.customBars.contains{$0.id==navigationID} && chrome.floatingPanels[navigationID]==nil && deletedPanel?.isVisible != true && deletedPanel?.parent==nil,"Deleting floating toolbar failed to retire its native owner")

        phase("floating focus, native menus, private Copy, About and deferred Open")
        let standardFallback=chrome.contextMenu(barID:standardID)
        guard let hideStandard=standardFallback.items.first(where:{$0.title==NSLocalizedString("Hide Toolbar",comment:"")}) else {throw Failure(description:"Floating standard hide menu missing")}
        try invoke(hideStandard)
        try await wait("Native menu hides floating standard bar") {!first.model.showToolbar && chrome.floatingPanels[standardID]==nil}
        let mainContext=BlameMenuContext(keyWindow:{window});mainContext.perform(.toolbar)
        try await wait("View menu restores floating standard placement") {first.model.showToolbar && chrome.floatingPanels[standardID]?.window?.isVisible==true}
        try require(bar(standardID).placement == .floating,"View menu restore lost standard floating placement")
        guard let focusPanel=chrome.floatingPanels[standardID]?.window else {throw Failure(description:"Restored floating focus panel missing")}
        focusPanel.makeKeyAndOrderFront(nil)
        first.commandKeyWindow={ [weak focusPanel] in focusPanel }
        let context=BlameMenuContext(keyWindow:{focusPanel})
        context.refresh()
        try require(context.owner === first && context.available,"Floating panel did not resolve its own live Blame document")
        context.perform(.find)
        try await wait("Floating menu Find target") {first.findWindow?.model === first.model}
        try require(second.findWindow==nil,"Floating Find targeted another document")
        first.findWindow?.close()
        let pasteboard=NSPasteboard.withUniqueName();defer{pasteboard.releaseGlobally()}
        first.model.writeClipboard={value in pasteboard.clearContents();pasteboard.setString(value,forType:.string)}
        let sourceView=try source(first);sourceView.setSelectedRange(NSRange(location:0,length:7));window.makeFirstResponder(sourceView)
        focusPanel.makeKeyAndOrderFront(nil)
        chrome.refresh();try require(chrome.enabled("copy"),"Owned floating focus lost source Copy target")
        let copyMenu=chrome.menuItem("copy")
        try invoke(copyMenu)
        try require(pasteboard.string(forType:.string)=="A first","Floating Copy failed private owner source responder")
        var about=0;chrome.showAbout={about += 1}
        let aboutMenu=chrome.menuItem("about")
        try invoke(aboutMenu);try require(about==1,"Floating About did not dispatch scoped tool callback")
        var pickers=0;var reply:((URL?)->Void)?
        first.chooseFile={panel,owner,completion in pickers += 1;reply=completion;panel.alphaValue=0;precondition(owner === window)}
        chrome.perform("open")
        try require(pickers==1 && first.model.openingDocument,"Floating Open did not use own injected picker")
        reply?(nil);try require(!first.model.openingDocument,"Floating Open cancellation left owner blocked")
        window.animationBehavior = .none;window.miniaturize(nil)
        try await wait("Minimized owner hides floating bars") {window.isMiniaturized && chrome.floatingPanels.values.allSatisfy{$0.window?.isVisible != true}}
        window.deminiaturize(nil)
        try await wait("Restored owner shows floating bars") {!window.isMiniaturized && chrome.floatingPanels.values.allSatisfy{$0.window?.isVisible==true}}
        first.model.busy=true
        let busySnapshot=chrome.configuration
        try require(!chrome.beginDockDrag(barID:reviewID) && !chrome.beginCommandDrag(barID:reviewID,index:0),"Busy floating document accepted drag")
        chrome.perform("about");chrome.setPlacement(barID:reviewID,placement:.bottom)
        try require(about==1 && chrome.configuration==busySnapshot,"Busy document accepted floating action/placement")
        first.model.busy=false
        let blocking=NSPanel(contentRect:NSRect(x:0,y:0,width:240,height:100),styleMask:.titled,backing:.buffered,defer:false);blocking.alphaValue=0
        window.beginSheet(blocking,completionHandler:nil)
        try require(!chrome.beginDockDrag(barID:reviewID) && !chrome.beginCommandDrag(barID:reviewID,index:0),"Owner sheet accepted floating drag")
        chrome.perform("about");try require(about==1,"Owner sheet allowed floating callback reentry")
        window.endSheet(blocking);blocking.close()
        try await wait("Floating owner sheet released") {window.attachedSheet==nil}
        let staleModel=first.model
        try require(chrome.beginCommandDrag(barID:reviewID,index:0),"Replacement stale-drag source did not capture")
        chrome.perform("open");try require(pickers==2,"Floating replacement picker failed")
        reply?(secondURL)
        try await wait("Floating document replacement") {first.model !== staleModel && !first.model.busy}
        try await settle(first)
        try require(staleModel.retired && !chrome.live && chrome.floatingPanels.isEmpty,"Replacement retained retired floating panels/model")
        try require(!chrome.finishCommandDrag(destinationID:standardID,index:0),"Retired pending drag mutated replacement toolbar")
        try invoke(aboutMenu);chrome.cancelDockDrag();chrome.cancelCommandDrag()
        try require(about==1 && !chrome.beginCommandDrag(barID:reviewID,index:0),"Retired floating control retained authority")
        guard let replacement=first.toolbarChrome else {throw Failure(description:"Replacement placement chrome missing")}
        replacement.reset()
        try require(replacement.configuration==BlameToolbarConfiguration.defaults && replacement.floatingPanels.isEmpty,"Reset failed to restore source top placement and close floating owners")
        replacement.setPlacement(barID:standardID,placement:.floating)
        try await wait("Replacement floating panel") {replacement.floatingPanels[standardID]?.window != nil}
        let closingPanels=replacement.floatingPanels.values.compactMap(\.window)
        first.close();second.close()
        try require(!replacement.live && replacement.floatingPanels.isEmpty && closingPanels.allSatisfy{!$0.isVisible && $0.parent==nil},"Owner close leaked floating panels/targets")
        try invisible()
        try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,"Placement workflows changed HEAD")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Placement workflows changed index bytes")
        try require(try Data(contentsOf:firstURL)==firstBytes && Data(contentsOf:secondURL)==secondBytes,"Placement workflows changed working files")
    }
}
