// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor struct BlameToolbarContextVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws {
        if !condition {throw Failure(description:"Blame toolbar context at \(line): "+message)}
    }
    static func wait(_ message:String,_ ready:()->Bool)async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Blame toolbar context timeout: "+message)
    }
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func entry(_ menu:NSMenu,_ title:String)throws->NSMenuItem {
        guard let item=menu.items.first(where:{$0.title==title}) else{throw Failure(description:"Missing actual menu item: "+title)}
        return item
    }
    static func invoke(_ item:NSMenuItem)throws {
        guard let action=item.action else{throw Failure(description:"Menu item lacks native action: "+item.title)}
        try require(NSApp.sendAction(action,to:item.target,from:item),"Native context action target missing")
    }
    static func mouse(_ view:NSView)throws->NSEvent {
        guard let window=view.window,let event=NSEvent.mouseEvent(with:.rightMouseDown,location:view.convert(.init(x:view.bounds.midX,y:view.bounds.midY),to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1) else{throw Failure(description:"Cannot create owned pointer event")}
        return event
    }
    static func key(_ view:NSView,_ flags:NSEvent.ModifierFlags = [.shift,.function])throws->NSEvent {
        guard let window=view.window,let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:109) else{throw Failure(description:"Cannot create owned context key")}
        return event
    }
    static func allItems(_ menu:NSMenu)->[NSMenuItem] {menu.items.flatMap{[$0]+($0.submenu.map(allItems) ?? [])}}
    /// SwiftUI can expose an actionable Button only through public AX proxy
    /// children. Activation still uses the displayed Done control, never its
    /// model/controller closure. Traverse only this owned panel's public tree.
    static func doneAction(_ panel:NSWindow)->(action:(()->Bool)?,diagnostic:String) {
        panel.contentView?.layoutSubtreeIfNeeded()
        if let button=views(panel.contentView).compactMap({$0 as? NSButton}).first(where:{$0.isEnabled && !$0.isHiddenOrHasHiddenAncestor && ($0.title=="Done" || $0.accessibilityLabel()=="Done")}) {
            return ({[weak button,weak panel] in guard let button,let panel,button.window === panel,button.isEnabled else{return false};button.performClick(nil);return true},"Native NSButton Done")
        }
        var seen=Set<ObjectIdentifier>(),budget=4096,details=[String]()
        func property(_ object:NSObject,_ name:String)->Any? {
            let selector=NSSelectorFromString(name);guard object.responds(to:selector) else{return nil}
            return object.perform(selector)?.takeUnretainedValue()
        }
        func find(_ value:Any,_ depth:Int)->(()->Bool)? {
            guard depth<48,budget>0,let object=value as? NSObject,seen.insert(ObjectIdentifier(object)).inserted else{return nil}
            budget -= 1
            let node=value as? NSAccessibilityProtocol
            let label=node?.accessibilityLabel() ?? property(object,"accessibilityLabel") as? String
            let title=property(object,"accessibilityTitle") as? String
            let role=node?.accessibilityRole()?.rawValue ?? property(object,"accessibilityRole") as? String
            let children=(node?.accessibilityChildren() ?? property(object,"accessibilityChildren") as? [Any] ?? []) + (property(object,"accessibilityChildrenInNavigationOrder") as? [Any] ?? [])
            let enabled=node?.isAccessibilityEnabled()
            if details.count<160 {details.append("\(type(of:value)) role=\(role ?? "none") label=\(String(reflecting:label)) title=\(String(reflecting:title)) enabled=\(String(describing:enabled)) children=\(children.count)")}
            if role==NSAccessibility.Role.button.rawValue,(label=="Done" || title=="Done") {
                if let node,node.isAccessibilityEnabled() {return {node.isAccessibilityEnabled() && node.accessibilityPerformPress()}}
                let press=NSSelectorFromString("accessibilityPerformPress"),isEnabled=NSSelectorFromString("isAccessibilityEnabled")
                if object.responds(to:press),object.responds(to:isEnabled) {
                    typealias BooleanMethod = @convention(c) (AnyObject,Selector)->Bool
                    let can=unsafeBitCast(object.method(for:isEnabled),to:BooleanMethod.self)
                    if can(object,isEnabled) {return {guard can(object,isEnabled) else{return false};let action=unsafeBitCast(object.method(for:press),to:BooleanMethod.self);return action(object,press)}}
                }
            }
            for child in children {if let action=find(child,depth+1){return action}}
            return nil
        }
        var action=find(panel,0)
        if action==nil {for view in views(panel.contentView) {if let found=find(view,0){action=found;break}}}
        return (action,"visited=\(seen.count) remainingBudget=\(budget)\n"+details.joined(separator:"\n"))
    }
    static func verify(base:URL,git:URL)async throws {
        let root=base.appendingPathComponent("toolbar-context",isDirectory:true).standardizedFileURL
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root,executable:git),path="toolbar 雪.txt",nextPath="toolbar next.txt"
        _=try await repository.run(["init","-b","main"])
        for (name,value) in [("user.name","Toolbar Context QA"),("user.email","toolbar-context@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",name,value])}
        try Data("first\noriginal\nlast\n".utf8).write(to:root.appendingPathComponent(path))
        try Data("next first\nnext middle\nnext last\n".utf8).write(to:root.appendingPathComponent(nextPath))
        try await repository.stage([path,nextPath]);_=try await repository.commit(message:"Toolbar context base")
        try Data("first\nchanged\nlast\n".utf8).write(to:root.appendingPathComponent(path));try await repository.stage([path]);_=try await repository.commit(message:"Toolbar context current")
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),source=try Data(contentsOf:root.appendingPathComponent(path)),otherSource=try Data(contentsOf:root.appendingPathComponent(nextPath))
        let suite="TurtleGit.Blame.ToolbarContext."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"Blame.EnableLexer");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        defer{prefs.removePersistentDomain(forName:suite)}
        let owner=BlameWindowController(repository:repository,access:nil,path:path,revision:"HEAD",options:GitBlameOptions(),preferences:prefs,requireScope:false)
        guard let window=owner.window,let chrome=owner.toolbarChrome else{throw Failure(description:"Actual Blame window/chrome unavailable")}
        var keyWindow:NSWindow?=window
        owner.commandKeyWindow={keyWindow};chrome.presentPalette={_ in}
        chrome.presentFloating={panel in panel.alphaValue=0;panel.setFrameOrigin(.init(x:-22000,y:-22000));panel.orderFront(nil)}
        window.alphaValue=0;window.setFrameOrigin(.init(x:-22000,y:-22000));window.orderFront(nil)
        let foreign=NSWindow(contentRect:.init(x:-22000,y:-22000,width:320,height:140),styleMask:[.titled],backing:.buffered,defer:false)
        foreign.isReleasedWhenClosed=false;foreign.alphaValue=0;foreign.orderFront(nil)
        func cleanup()async throws {
            chrome.presentContextMenu=nil;owner.toolbarChrome?.presentContextMenu=nil
            owner.close();foreign.close()
            try await wait("owned editor/window/worker retirement") {
                BlameToolbarController.activeEditors==0 && BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && BlameDocumentOpener.activeReads==0 && BlameWindowController.activeNavigationOperations==0 && !window.isVisible && window.attachedSheet==nil
            }
        }
        do {
            try await wait("loaded actual source and titlebar grip") {!owner.model.busy && !owner.model.syntaxWorking && owner.model.lines.count==3 && chrome.titlebarGrip?.view.window === window}
            guard let grip=chrome.titlebarGrip?.view as? BlameToolbarGrip else{throw Failure(description:"Mounted standard toolbar grip missing")}
            let standard=BlameToolbarConfiguration.standardID
            try require(chrome.contextMenu(barID:UUID()).items.isEmpty,"Unknown bar invented contextual authority")
            let expected:[NSToolbarItem.Identifier]=[.init("TurtleGit.Blame.Command.open"),.space,.init("TurtleGit.Blame.Command.previousChange"),.init("TurtleGit.Blame.Command.nextChange"),.space,.init("TurtleGit.Blame.Command.copy"),.space,.init("TurtleGit.Blame.Command.about")]
            try require(chrome.toolbar.items.map(\.itemIdentifier)==expected,"Source standard command/separator composition changed")
            guard let customID=chrome.createBar(name:"Review 雪 & Git") else{throw Failure(description:"Private named toolbar creation failed")}
            var bar=chrome.configuration.customBars.first{$0.id==customID}!;bar.placement = .bottom;bar.items=["about","wrap"];chrome.update(bar)
            try await wait("mounted custom strip/grip/buttons") {chrome.stripHosts.values.compactMap(\.view).contains{$0.barID==customID && $0.window === window && !$0.isHiddenOrHasHiddenAncestor}}
            guard let strip=chrome.stripHosts.values.compactMap(\.view).first(where:{$0.barID==customID && $0.window === window}) else{throw Failure(description:"Actual named toolbar strip unavailable")}
            window.contentView?.layoutSubtreeIfNeeded();strip.layoutSubtreeIfNeeded()
            guard let customGrip=views(strip).compactMap({$0 as? BlameToolbarGrip}).first,
                  let button=views(strip).compactMap({$0 as? NSButton}).first(where:{$0.toolTip==BlameToolbarController.title("about") && chrome.authenticatedPointerSource($0)}) else{throw Failure(description:"Actual named toolbar controls unavailable")}
            var popupCount=0,popupHost:NSView?,popupMenu:NSMenu?,popupPoint=NSPoint.zero
            chrome.presentContextMenu={menu,point,host in popupCount += 1;popupMenu=menu;popupPoint=point;popupHost=host}
            let hosts:[NSView]=[grip,customGrip,strip,button]
            for host in hosts {
                guard let menu=host.menu(for:try mouse(host)) else{throw Failure(description:"Mounted toolbar host lacks pointer context")}
                let expected:[String:MenuIcon]=["Customize Toolbar…":.settingsDialogs,"Manage Toolbars…":.settingsContextMenu,"Reset All Toolbars":.restore,"Hide Toolbar":.mergeCollapse,"Toolbars and Panes":.settingsDialogs]
                for (title,icon) in expected {try require(try entry(menu,title).image?.tiffRepresentation==icon.contextImage(defaults:prefs)?.tiffRepresentation,"Wrong contextual source artwork: "+title)}
                try require(allItems(menu).filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Context menu lost a command/submenu icon")
                let menuBarID=host === grip ? standard:customID,currentPlacement=chrome.configuration.allBars.first{$0.id==menuBarID}!.placement
                for placement in BlameToolbarPlacement.allCases {try require(try entry(menu,NSLocalizedString(placement.title,comment:"")).state == (placement==currentPlacement ? .on:.off),"Context placement check did not follow originating bar")}
                let before=popupCount
                try require(host.accessibilityPerformShowMenu() && popupCount==before+1 && popupHost === host && popupMenu?.items.isEmpty == false,"AX Show Menu failed actual host route")
                let rect=host.visibleRect
                try require(popupPoint.x>=rect.minX-1 && popupPoint.x<=rect.maxX+1 && popupPoint.y>=rect.minY-1 && popupPoint.y<=rect.maxY+1,"AX menu anchor escaped current host viewport")
                try require(window.makeFirstResponder(host),"Mounted toolbar host refused keyboard focus")
                host.keyDown(with:try key(host));try require(popupCount==before+2 && popupHost === host,"Focused Shift-F10 did not share actual native menu path")
                try require(!chrome.contextKey(try key(host,[]),from:host,barID:menuBarID) && popupCount==before+2,"Unmodified F10 opened context menu")
            }
            prefs.set(false,forKey:"ShowAppContextMenuIcons")
            try require(allItems(chrome.contextMenu(barID:standard)).filter{!$0.isSeparatorItem}.allSatisfy{$0.image==nil},"Private icon policy ignored in toolbar/pane menus")
            prefs.set(true,forKey:"ShowAppContextMenuIcons")
            let visibility=try entry(chrome.contextMenu(barID:standard),"Toolbars and Panes").submenu!
            try require(try entry(visibility,"Review 雪 & Git").state == .on && entry(visibility,"Log").state == (owner.model.showLog ? .on:.off),"Literal custom name or checked pane state changed")
            let hideCustom=try entry(visibility,"Review 雪 & Git");try invoke(hideCustom)
            try require(chrome.configuration.customBars.first{$0.id==customID}?.isVisible==false,"Captured other-bar visibility did not hide it")
            try invoke(hideCustom);try require(chrome.configuration.customBars.first{$0.id==customID}?.isVisible==false,"Visibility command invoked twice")
            let hiddenChoice=try entry(chrome.contextMenu(barID:standard),"Toolbars and Panes").submenu!
            try require(try entry(hiddenChoice,"Review 雪 & Git").state == .off,"Hidden bar disappeared from recovery choices")
            try invoke(try entry(hiddenChoice,"Review 雪 & Git"));try require(chrome.configuration.customBars.first{$0.id==customID}?.isVisible==true,"Context recovery did not restore hidden bar")
            let paneChoice=try entry(chrome.contextMenu(barID:standard),"Toolbars and Panes").submenu!,oldLog=owner.model.showLog
            try invoke(try entry(paneChoice,"Log"));try require(owner.model.showLog != oldLog,"Pane visibility choice did not apply")
            owner.model.showLog=oldLog
            // Retained menu receipts cannot act across a replacement menu,
            // content epoch, pane layout, external configuration or live host.
            func staleHide(_ change:()->Void)throws {
                let menu=chrome.contextMenu(barID:standard),item=try entry(menu,"Hide Toolbar")
                change();try invoke(item);try require(chrome.configuration.standard.isVisible,"Stale context receipt changed toolbar visibility")
            }
            try staleHide{_ = chrome.contextMenu(barID:standard)}
            try staleHide{owner.model.busy=true;owner.model.busy=false}
            try staleHide{owner.model.setPanePlacement(.properties,.left)}
            try staleHide{_ = BlameToolbarConfigurationStore(defaults:prefs).reset()}
            try await wait("adopt externally reset configuration epoch") {chrome.configuration.generation==BlameToolbarConfigurationStore(defaults:prefs).load().generation}
            // A blocked owner, hidden host or a reparented retained view does
            // not gain authority from its old bar ID and keyboard event.
            let beforeBlocked=popupCount
            try require(window.makeFirstResponder(grip),"Restored standard grip refused focus")
            keyWindow=foreign;try require(!chrome.contextKey(try key(grip),from:grip,barID:standard) && popupCount==beforeBlocked,"Foreign key window opened toolbar popup");keyWindow=window
            owner.model.confirmingQuit=true;try require(!grip.accessibilityPerformShowMenu(),"Quit-blocked owner accepted AX context");owner.model.confirmingQuit=false
            grip.isHidden=true;try require(!grip.accessibilityPerformShowMenu(),"Hidden context host remained actionable");grip.isHidden=false
            guard let parentView=grip.superview else{throw Failure(description:"Mounted grip lost parent")}
            let oldFrame=grip.frame,reparentedMenu=chrome.contextMenu(barID:standard,source:grip),reparentedItem=try entry(reparentedMenu,"Hide Toolbar")
            grip.removeFromSuperview();foreign.contentView?.addSubview(grip);try require(!grip.accessibilityPerformShowMenu(),"Foreign reparented host accepted AX context")
            try invoke(reparentedItem);try require(chrome.configuration.standard.isVisible,"Reparented retained receipt remained actionable")
            grip.removeFromSuperview();parentView.addSubview(grip);grip.frame=oldFrame
            // Actual managed editor surfaces keep their session and Quit lease
            // until both native sheet links detach; late writes remain refused.
            try await wait("independent document workers idle before Quit test") {BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && BlameDocumentOpener.activeReads==0 && BlameWindowController.activeNavigationOperations==0}
            let baseline=BlameToolbarController.activeEditors
            try require(baseline==0,"Previous toolbar editor lease leaked")
            enum CloseRoute:CaseIterable {case done,escape,nativeCloseRequest}
            for route in CloseRoute.allCases {
                print("Blame toolbar dismissal route: \(route)")
                var captured:NSWindow?
                chrome.presentEditor={parent,panel in captured=panel;panel.alphaValue=0;parent.beginSheet(panel)}
                switch route {
                case .done:try invoke(try entry(chrome.contextMenu(barID:standard,source:grip),"Manage Toolbars…"))
                default:chrome.edit()
                }
                guard let editor=chrome.editor,let panel=captured else{throw Failure(description:"Actual managed editor not admitted")}
                try await wait("managed editor native sheet") {panel.sheetParent === window && window.attachedSheet === panel}
                try require(BlameToolbarController.activeEditors==baseline+1 && !owner.commandsAvailable && !owner.windowShouldClose(window),"Managed editor lost owner/Quit admission before close")
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored actual toolbar editor")
                var callbacks=0,callbackOwned=false,callbackDrained=false
                let original=editor.onClosed
                editor.onClosed={callbacks += 1;callbackOwned=BlameToolbarController.activeEditors==baseline+1 && chrome.editor === editor;callbackDrained=panel.sheetParent==nil && window.attachedSheet !== panel && !panel.isVisible;original()}
                switch route {
                case .done:
                    panel.contentView?.layoutSubtreeIfNeeded();panel.contentView?.displayIfNeeded()
                    await Task.yield()
                    let found=doneAction(panel)
                    if let done=found.action {
                        try require(done(),"Actual native/public-AX Done action refused its press")
                        print("Blame toolbar Done route: native/public-AX control")
                    } else {
                        // SwiftUI may omit its button proxies from an invisible
                        // receiver's public AX tree. Invoke the displayed Done
                        // button's production default-action key equivalent.
                        guard let enter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:panel.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36) else{throw Failure(description:"Cannot create owned Done Return event")}
                        let consumed=panel.performKeyEquivalent(with:enter)
                        if !consumed {
                            print("Blame Done presentation diagnostic: canConfigure=\(chrome.canConfigure(editor.sessionID)) canFind=\(owner.model.canFind) child=\(owner.hasBlockingHistoryChild) goTo=\(owner.goToWindow != nil) isClosing=\(editor.isClosing) childLink=\(panel.sheetParent === window) parentLink=\(window.attachedSheet === panel) alpha=\(panel.alphaValue) visible=\(panel.isVisible)")
                            print("Blame Done native view types: "+views(panel.contentView).map{String(describing:type(of:$0))}.prefix(100).joined(separator:", "))
                            print("Blame Done public AX tree: "+found.diagnostic)
                        }
                        try require(consumed,"Actual owned Done default Return key equivalent was not consumed")
                        print("Blame toolbar Done route: actual default Return key equivalent (public AX button unavailable)")
                    }
                    try await wait("actual Done entered closing state") {editor.isClosing}
                case .escape:panel.cancelOperation(nil)
                case .nativeCloseRequest:
                    // Attached sheets need not expose an enabled titlebar close
                    // button. Exercise the real NSWindowDelegate admission
                    // boundary without claiming a physical close-button click.
                    let accepted=panel.delegate?.windowShouldClose?(panel)
                    try require(accepted == false,"Native editor close delegate did not retain asynchronous drainage")
                }
                if !editor.isClosing {
                    let close=panel.standardWindowButton(.closeButton)
                    print("Blame dismissal not started: route=\(route) closeButton=\(close != nil) closeEnabled=\(String(describing:close?.isEnabled)) closeHidden=\(String(describing:close?.isHidden)) childLink=\(panel.sheetParent === window) canConfigure=\(chrome.canConfigure(editor.sessionID)) sameEditor=\(chrome.editor === editor)")
                }
                try require(editor.isClosing,"Actual \(route) dismissal did not enter closing state")
                let snapshot=chrome.configuration,canWrite=chrome.canConfigure(editor.sessionID)
                let lateID=chrome.createBar(name:"Rejected closing write",session:editor.sessionID)
                if chrome.configuration != snapshot || lateID != nil {
                    print("Blame late write: route=\(route) canConfigureBefore=\(canWrite) canConfigureAfter=\(chrome.canConfigure(editor.sessionID)) returnedID=\(String(describing:lateID)) isClosing=\(editor.isClosing) sameEditor=\(chrome.editor === editor) sameSession=\(chrome.editor?.sessionID == editor.sessionID)")
                }
                try require(lateID==nil && chrome.configuration==snapshot,"Closing \(route) editor accepted a late configuration write")
                editor.closeEditor()
                try await wait("editor paired release and dedicated lease") {chrome.editor==nil && BlameToolbarController.activeEditors==baseline}
                try require(callbacks==1 && callbackOwned && callbackDrained && panel.sheetParent==nil && window.attachedSheet !== panel,"Editor completion preceded native detachment or released twice")
                try require(owner.commandsAvailable,"Owner commands did not return after actual editor closure")
            }
            // File Open replaces the model/chrome; retained context callbacks
            // continue to belong to the old document rather than the new one.
            let priorModel=owner.model,retained=try entry(chrome.contextMenu(barID:standard),"Manage Toolbars…")
            owner.chooseFile={_,_,reply in reply(root.appendingPathComponent(nextPath))}
            owner.openDocument()
            try await wait("accepted File Open replaces model and chrome") {owner.model !== priorModel && owner.toolbarChrome !== chrome && !owner.model.busy && !owner.model.syntaxWorking}
            try invoke(retained);chrome.edit();try require(chrome.editor==nil && !chrome.live && !grip.accessibilityPerformShowMenu(),"Retired chrome regained editor/menu authority")
            guard let current=owner.toolbarChrome else{throw Failure(description:"Replacement chrome missing")}
            current.presentFloating={panel in panel.alphaValue=0;panel.setFrameOrigin(.init(x:-22000,y:-22000));panel.orderFront(nil)}
            var forcedPanel:NSWindow?
            current.presentEditor={parent,panel in forcedPanel=panel;panel.alphaValue=0;parent.beginSheet(panel)}
            current.edit()
            guard let forced=current.editor,let panel=forcedPanel else{throw Failure(description:"Forced editor missing")}
            try await wait("forced editor native attachment") {panel.sheetParent === window && window.attachedSheet === panel}
            var closed=0,parentFinishedAfterChild=false
            owner.onClosed={closed += 1;parentFinishedAfterChild=current.editor==nil && BlameToolbarController.activeEditors==baseline && panel.sheetParent==nil && window.attachedSheet !== panel}
            let session=forced.sessionID
            try require(BlameToolbarController.activeEditors==baseline+1,"Replacement editor did not retain its own Quit lease")
            owner.close()
            if current.hasPendingWork {try require(BlameToolbarController.activeEditors==baseline+1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced parent closure dropped the pending editor Quit lease")}
            let afterRetire=current.configuration
            _=current.createBar(name:"Rejected retired write",session:session);current.edit()
            try require(current.configuration==afterRetire && !current.live,"Retired managed chrome accepted new session writes")
            try await wait("forced parent completion after editor release") {closed==1 && current.editor==nil && BlameToolbarController.activeEditors==baseline}
            try require(parentFinishedAfterChild && !panel.isVisible,"Parent completion or Quit lease escaped child drainage")
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent(path))==source && Data(contentsOf:root.appendingPathComponent(nextPath))==otherSource,"Context/editor read workflows changed repository state")
            try await cleanup()
        } catch {try? await cleanup();throw error}
        print("PASS: Blame toolbar context actual pointer/Shift-F10/AX hosts, source icons/private policy, captured bar/pane visibility, stale menu/document/config/host/retirement, managed Done/Escape/native close-request/forced paired-sheet drainage, dedicated Quit lease and unchanged repository; no physical gestures, palette or signed acceptance claimed")
    }
}
