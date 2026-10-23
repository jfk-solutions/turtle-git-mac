// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import ScreenCaptureKit
import TurtleGitCore

private extension NSWindow {
    @objc func primaryCorrectionFrame(_ requested:NSRect,to screen:NSScreen?)->NSRect {requested}
    @objc func primaryCorrectionOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));primaryCorrectionOrder(mode,relativeTo:number)
    }
}
@MainActor @main enum PrimaryPresentationCorrectionsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value{throw Failure(description:"Primary presentation \(line): "+message)}}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func items(_ menu:NSMenu)->[NSMenuItem] {menu.items.flatMap{[$0]+($0.submenu.map{items($0)} ?? [])}}
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2400 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Primary presentation timeout \(line)")
    }
    static func drained()->Bool {CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activePreferenceOperations==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0}
    static func own(_ owner:NSWindowController)throws {
        guard let window=owner.window else{throw Failure(description:"Owner window missing")}
        window.alphaValue=0;window.orderFront(nil)
        let union=NSScreen.screens.reduce(NSRect.null){$0.union($1.frame)},screen=union.isNull ? .zero:union
        window.setFrameOrigin(.init(x:screen.minX-window.frame.width-1024,y:screen.minY-window.frame.height-1024))
        try require(window.alphaValue==0 && NSScreen.screens.allSatisfy{!$0.frame.intersects(window.frame)},"Owned window escaped invisible/offscreen placement")
    }
    static func visualAcceptance(_ window:NSWindow,_ state:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_PRIMARY_VISUAL_ACCEPTANCE"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Deliberate current-process visual acceptance unavailable")}
        let directory=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for(theme,name)in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            guard let screen=NSScreen.main ?? NSScreen.screens.first else{throw Failure(description:"Visual acceptance requires a visible screen")}
            let oldAppearance=window.appearance,oldFrame=window.frame
            guard let constrain=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),let unconstrained=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.primaryCorrectionFrame(_:to:))),let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.primaryCorrectionOrder(_:relativeTo:))) else{throw Failure(description:"Visual acceptance ownership override unavailable")}
            // The normal case remains invisible. Only this explicitly requested
            // photograph temporarily uses ordinary AppKit frame/order behavior.
            method_exchangeImplementations(constrain,unconstrained);method_exchangeImplementations(order,hidden)
            defer {
                window.alphaValue=0;window.orderOut(nil);window.appearance=oldAppearance
                method_exchangeImplementations(order,hidden);method_exchangeImplementations(constrain,unconstrained)
                window.setFrame(oldFrame,display:false)
            }
            window.appearance=NSAppearance(named:theme)
            window.setFrameOrigin(.init(x:screen.visibleFrame.midX-window.frame.width/2,y:screen.visibleFrame.midY-window.frame.height/2))
            try require(screen.visibleFrame.insetBy(dx:-1,dy:-1).contains(window.frame),"Deliberate Commit acceptance window does not fit screen")
            window.alphaValue=1;window.orderFrontRegardless();window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
            try await Task.sleep(nanoseconds:600_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Actual Commit acceptance window missing")}
            let options=SCStreamConfiguration();options.width=Int(window.frame.width*2);options.height=Int(window.frame.height*2);options.showsCursor=false;options.ignoreShadowsSingleWindow=true;options.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:options)
            guard let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw Failure(description:"Commit acceptance PNG unavailable")}
            let filename="commit-source-bands-"+state+"-"+name+".png"
            try png.write(to:directory.appendingPathComponent(filename));print("Deliberate actual Commit visual acceptance: \(filename) \(image.width)x\(image.height)");fflush(stdout)
        }
        try require(window.alphaValue==0 && NSScreen.screens.allSatisfy{!$0.frame.intersects(window.frame)},"Commit visual acceptance did not restore invisible/offscreen owner")
    }
    static func seed(_ root:URL,_ git:URL)async throws->GitRepository {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        _=try await repo.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Presentation QA"),("user.email","presentation@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("literal.txt"));try await repo.stage(["literal.txt"]);_=try await repo.commit(message:"base")
        _=try await repo.run(["switch","-c","side"])
        try Data("side\n".utf8).write(to:root.appendingPathComponent("side.txt"));try await repo.stage(["side.txt"]);_=try await repo.commit(message:"side")
        _=try await repo.run(["switch","main"])
        try Data("main\n".utf8).write(to:root.appendingPathComponent("literal.txt"));try await repo.stage(["literal.txt"]);_=try await repo.commit(message:"main")
        _=try await repo.run(["merge","--no-ff","--no-edit","side"])
        return repo
    }
    static func press(_ item:NSMenuItem)throws {guard item.isEnabled,let action=item.action else{throw Failure(description:"Native command unavailable: "+item.title)};_=NSApp.sendAction(action,to:item.target,from:item)}
    static func commit(_ repo:GitRepository,_ preferences:UserDefaults,_ owners:inout[NSWindowController])async throws {
        try Data("main\nprivate edit\n".utf8).write(to:repo.root.appendingPathComponent("literal.txt"))
        preferences.set(true,forKey:"ShowUnversioned");preferences.set(1,forKey:"HintStagingMode");preferences.set(1,forKey:"CommitMergeHint")
        let owner=CommitWindowController(repository:repo,access:nil,defaults:preferences);owners.append(owner);try own(owner)
        let model=owner.model;model.confirmCancel={$0(true)};model.reload()
        try await wait(owner.window){!model.busy && model.changelistsLoaded && owner.commandsAvailable && owner.messageEditor() != nil && owner.fileTable() != nil}
        let privateMenu=NSMenu(title:"Private Commit menu")
        guard let router=owner.commandMenu else{throw Failure(description:"Commit command router missing")}
        router.applicationMenu={privateMenu};router.keyWindow={ [weak owner] in owner?.window};router.install()
        func command(_ name:String)async throws->NSMenuItem {
            try await wait(owner.window){router.install();return items(privateMenu).contains{$0.identifier?.rawValue=="TurtleGit.Commit.Form."+name && $0.isEnabled}}
            guard let item=items(privateMenu).first(where:{$0.identifier?.rawValue=="TurtleGit.Commit.Form."+name}) else{throw Failure(description:"Missing Commit menu "+name)};return item
        }
        func geometry()throws {
            guard let window=owner.window,let content=window.contentView,let editor=owner.messageEditor(),let table=owner.fileTable(),let action=views(content).first(where:{$0.identifier?.rawValue=="TurtleGit.Commit.Action"}) as? CommitNativeActionControl else{throw Failure(description:"Actual Commit native layout participants missing")}
            let messageViewport:NSView=editor.enclosingScrollView ?? editor,fileViewport:NSView=table.enclosingScrollView ?? table
            for view in [messageViewport,fileViewport,action] as [NSView] {
                let rect=view.convert(view.bounds,to:content)
                try require(rect.width>40 && rect.height>10 && content.bounds.insetBy(dx:-1,dy:-1).contains(rect),"Actual Commit participant escaped content: \(type(of:view)) \(rect) / \(content.bounds)")
            }
            try require(action.segmentCount==2 && action.menu(forSegment:1)?.items.map(\.title)==["Commit","ReCommit","Commit & Push"],"Source Commit split footer actions changed")
            let footer=action.convert(action.bounds,to:content),message=messageViewport.convert(messageViewport.bounds,to:content),files=fileViewport.convert(fileViewport.bounds,to:content)
            try require(!footer.intersects(message) && !footer.intersects(files),"Commit footer overlaps message/file area")
            try require(window.alphaValue==0,"Commit check made its owner visible")
        }
        for size in [NSSize(width:900,height:680),.init(width:1100,height:800)] {owner.window?.setContentSize(size);try await wait(owner.window){views(owner.window?.contentView).contains{$0 is CommitNativeActionControl}};try geometry()}
        try press(try await command("amend"));try await wait(owner.window){model.amend && !model.loadingAmendMessage && !model.loadingAuthorIdentity && !model.busy};_=try await command("amendComparison");try geometry()
        if let window=owner.window {try await visualAcceptance(window,"classic")}
        try press(try await command("staging"));try await wait(owner.window){model.stagingEnabled && !model.busy && CommitWindowModel.activePreferenceOperations==0 && owner.commandsAvailable};try geometry()
        if let window=owner.window {try await visualAcceptance(window,"staging")}
        try press(try await command("staging"));try await wait(owner.window){!model.stagingEnabled && !model.busy && CommitWindowModel.activePreferenceOperations==0 && owner.commandsAvailable}
        let newFile=repo.root.appendingPathComponent("after-snapshot.txt");try Data("private\n".utf8).write(to:newFile)
        try require(!model.entries.contains{$0.path=="after-snapshot.txt"},"Refresh fixture appeared before explicit read")
        owner.window?.makeFirstResponder(nil)
        guard let window=owner.window,let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:String(UnicodeScalar(NSF5FunctionKey)!),charactersIgnoringModifiers:String(UnicodeScalar(NSF5FunctionKey)!),isARepeat:false,keyCode:96) else{throw Failure(description:"F5 event unavailable")}
        try require(window.performKeyEquivalent(with:event),"Actual F5 Refresh was lost after footer simplification")
        try await wait(window){!model.busy && model.entries.contains{$0.path=="after-snapshot.txt"}}
        let stale=try await command("refresh");model.confirmingQuit=true
        if let action=stale.action{_=NSApp.sendAction(action,to:stale.target,from:stale)}
        try require(!model.busy && !owner.refreshCommandAvailable,"Retained Refresh crossed Quit fence")
        model.confirmingQuit=false;owner.close();try await wait{CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0}
        print("Commit: native split/footer and minimum/default bounds, ordinary/amend/staging, actual F5 and stale Refresh guard. Exact virtual SwiftUI option-band geometry remains visual acceptance.")
    }
    static func log(_ repo:GitRepository,_ preferences:UserDefaults,_ other:UserDefaults,_ owners:inout[NSWindowController])async throws {
        var logs:[LogWindowController]=[]
        for(prefs,icons)in[(preferences,false),(other,true)] {
            prefs.set(icons,forKey:"ShowAppContextMenuIcons");prefs.set(false,forKey:"LogIncludeWorkingTreeChanges");prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar")
            let owner=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false);owners.append(owner);logs.append(owner);try own(owner);owner.model.reload()
            try await wait(owner.window){!owner.model.busy && owner.model.entries.first?.parents.count==2}
            let hash=owner.model.entries[0].hash;owner.model.select([hash])
            try await wait(owner.window){!owner.model.busy && owner.model.revision?.hash==hash && owner.model.revision?.parents.count==2}
        }
        func assertMenu(_ owner:LogWindowController,_ icons:Bool)throws {
            guard let table=views(owner.window?.contentView).compactMap({$0 as? HistoryTableView}).first,let coordinator=table.dataSource as? RevisionTable.Coordinator,let menu=table.menu else{throw Failure(description:"Actual Log native menu missing")}
            table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);coordinator.menuNeedsUpdate(menu)
            guard let copy=menu.items.first(where:{$0.title=="Copy to clipboard"}),let children=copy.submenu?.items,let revert=menu.items.first(where:{$0.title=="Revert change by this commit" && $0.submenu != nil}),let names=children.first(where:{$0.title=="Tag/branch names"}) else{throw Failure(description:"Actual merge-parent Revert/Copy/name menu surface missing: \(menu.items.map(\.title))")}
            try require(!children.isEmpty && children.contains{$0.title=="Messages"},"Copy menu lost source leaves")
            for item in [copy,revert,names]+children.filter({!$0.isSeparatorItem}) {try require((item.image != nil)==icons,"Native Log item ignored owning icon preference: \(item.title), expected=\(icons)")}
            try require(owner.window?.alphaValue==0,"Log menu check made owner visible")
        }
        try assertMenu(logs[0],false);try assertMenu(logs[1],true)
        preferences.set(true,forKey:"ShowAppContextMenuIcons");other.set(false,forKey:"ShowAppContextMenuIcons")
        try assertMenu(logs[0],true);try assertMenu(logs[1],false)
        logs.forEach{$0.close()};try await wait{LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0}
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let methods=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.primaryCorrectionFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.primaryCorrectionOrder(_:relativeTo:))))]
        for(a,b)in methods {if let a,let b {method_exchangeImplementations(a,b)}}
        defer{for(a,b)in methods.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let suite="TurtleGit.PrimaryCorrections."+UUID().uuidString,otherSuite="TurtleGit.PrimaryCorrectionsOther."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,other=UserDefaults(suiteName:otherSuite)!
        prefs.set(false,forKey:"UseLibgit2");DialogGeometry.install(preferences:prefs)
        defer{DialogGeometry.install(preferences:.standard)}
        var owners:[NSWindowController]=[]
        func cleanup()async {owners.forEach{$0.close()};for _ in 0..<2400 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite);other.removePersistentDomain(forName:otherSuite)}
        do {
            let repo=try await seed(URL(fileURLWithPath:CommandLine.arguments[1]),URL(fileURLWithPath:CommandLine.arguments[2])),kind=CommandLine.arguments[3]
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["write-tree"]).stdout
            switch kind {case "commit":try await commit(repo,prefs,&owners);case "log":try await log(repo,prefs,other,&owners);default:throw Failure(description:"Unknown presentation case")}
            let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalIndex=try await repo.run(["write-tree"]).stdout
            try require(head==finalHead && index==finalIndex,"Display verification mutated HEAD/index tree")
            await cleanup();try require(drained() && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Presentation owners/work did not drain")
            print("PASS: primary presentation corrections "+kind);fflush(stdout)
        }catch {await cleanup();fputs("Primary presentation corrections failed: \(error)\n",stderr);exit(1)}
    }
}
